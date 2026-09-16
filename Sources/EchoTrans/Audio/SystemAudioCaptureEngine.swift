import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

/// 通过 ScreenCaptureKit 采集系统输出的音频（自动排除本 App 自身的声音）。
///
/// 注意：系统会要求「屏幕录制」权限（ScreenCaptureKit 复用该权限来捕获系统音频），
/// 且授权后必须**完全退出并重新打开 App** 才生效（macOS 的限制）。
///
/// App 切到后台或窗口被遮挡时，采集期间持有 beginActivity 以避免 App Nap；
/// 同时由断流看门狗自动重建 SCStream。显示器关闭、系统睡眠和合盖期间不保证采集。
/// 对外保持同一个音频帧流，重连不会结束当前会话。
final class SystemAudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {

    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 采集异常事件通知（主线程回调），用于状态栏提示与诊断
    var onStall: ((String) -> Void)?

    private struct State {
        var userStopped = true
        var streamStartedAt: Date?
        var lastBufferAt: Date?
        var restarting = false
        var consecutiveFailures = 0
    }

    /// 回调线程（SCK 队列）、主线程、看门狗 task 都会触碰状态，统一串行化
    private let stateQueue = DispatchQueue(label: "echotrans.capture.state")
    private var state = State()

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var buffers: AsyncStream<AVAudioPCMBuffer>?
    private var stream: SCStream?
    private var watchdogTask: Task<Void, Never>?

    /// 采集期间持有的系统活动断言：避免切到后台后被 App Nap 节流。
    /// beginActivity 返回不透明对象（_NSActivityAssertion），按 NSObject 持有传回 endActivity。
    private var activity: (any NSObjectProtocol)?

    /// 断流判定：超过该时长没有任何音频帧（SCK 静音时也持续发静音帧，真正断流才完全静默）
    private let stallThreshold: TimeInterval = 8
    private let watchdogInterval: TimeInterval = 3
    /// 连续重建失败达到该次数后放弃，结束采集会话
    private let maxConsecutiveFailures = 10

    deinit {
        endActivity()
    }

    /// 开始采集，返回音频帧流（每帧为一个 AVAudioPCMBuffer）。
    /// 返回的流在整个会话期间有效——内部断流重连不会更换流。
    func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard buffers == nil else {
            throw CaptureError(message: "已经在采集会话中")
        }

        // 权限预检：未授权时先触发系统弹窗，并明确告知需授权后重启 App
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            throw CaptureError(message: "需要「屏幕录制」权限：请在弹窗中点「打开系统设置」开启 EchoTrans，然后完全退出（⌘Q）并重新打开 App 再试")
        }

        // 限深缓冲：消费端异常滞后时丢最旧帧，避免内存无界增长
        let buffers = AsyncStream(
            AVAudioPCMBuffer.self,
            bufferingPolicy: .bufferingNewest(256)
        ) { self.continuation = $0 }
        self.buffers = buffers
        continuation?.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }

        stateQueue.sync {
            state = State(userStopped: false)
        }

        do {
            try await makeStream()
        } catch {
            await stop()
            throw error
        }

        beginCaptureActivity()
        startWatchdog()
        return buffers
    }

    /// 停止采集并结束音频流。
    func stop() async {
        stateQueue.sync { state.userStopped = true }
        watchdogTask?.cancel()
        watchdogTask = nil
        endActivity()
        await teardownStream()
        continuation?.finish()
        continuation = nil
        buffers = nil
    }

    // MARK: - 系统活动断言（免疫 App Nap）

    private func beginCaptureActivity() {
        guard activity == nil else { return }
        // 声明用户发起的持续活动，避免后台采集时定时器被合并、CPU 被降优先级；
        // 允许显示器和系统按用户的电源设置正常睡眠。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "EchoTrans 正在采集系统音频"
        )
    }

    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    // MARK: - SCStream 生命周期

    /// （重新）创建并启动 SCStream。调用方需已在 stateQueue 中标记 restarting。
    private func makeStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError(message: "没有可用的显示器，无法采集系统音频")
        }

        // 捕获整个显示器对应的系统音频（不含被排除的窗口；音频层面排除本进程自身）
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        config.queueDepth = 8
        // ScreenCaptureKit 要求视频参数，给一个极小的占位（2x2、10fps），几乎不消耗资源
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        _ = try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
        try await stream.startCapture()

        // startCapture 期间用户可能已停止采集，避免留下孤儿流
        let userStopped: Bool = stateQueue.sync {
            if state.userStopped { return true }
            self.stream = stream
            state.streamStartedAt = Date()
            state.lastBufferAt = nil
            state.restarting = false
            return false
        }
        if userStopped {
            await stopCapture(stream, timeout: 2)
            throw CancellationError()
        }
    }

    /// 停掉当前 SCStream（挂死的 stopCapture 用超时兜底，避免看门狗被卡住）
    private func teardownStream() async {
        let stream: SCStream? = stateQueue.sync {
            let s = self.stream
            self.stream = nil
            return s
        }
        guard let stream else { return }
        await stopCapture(stream, timeout: 2)
    }

    /// `stopCapture()` 偶尔不响应任务取消。这里使用非结构化任务竞速，确保调用方
    /// 到达超时时间后即可继续；迟到的系统回调只会落到已结束的 AsyncStream 中。
    private func stopCapture(_ stream: SCStream, timeout: TimeInterval) async {
        let completions = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task {
                try? await stream.stopCapture()
                continuation.yield(())
                continuation.finish()
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                continuation.yield(())
                continuation.finish()
            }
        }
        for await _ in completions {
            break
        }
    }

    // MARK: - 断流看门狗

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.watchdogInterval ?? 3) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.watchdogTick()
            }
        }
    }

    private func watchdogTick() async {
        let needsRestart: Bool = stateQueue.sync {
            guard !state.userStopped, !state.restarting else { return false }
            guard let reference = state.lastBufferAt ?? state.streamStartedAt else { return false }
            return Date().timeIntervalSince(reference) > stallThreshold
        }
        guard needsRestart else { return }
        await restartStream(reason: "音频帧超过 \(Int(stallThreshold)) 秒未到达")
    }

    /// 重建 SCStream 并恢复采集；对外音频流保持不变
    private func restartStream(reason: String) async {
        let shouldProceed: Bool = stateQueue.sync {
            guard !state.userStopped, !state.restarting else { return false }
            state.restarting = true
            return true
        }
        guard shouldProceed else { return }

        notifyStall("检测到系统音频中断（\(reason)），正在恢复采集…")
        await teardownStream()

        do {
            try await makeStream()
            stateQueue.sync { state.consecutiveFailures = 0 }
            notifyStall("系统音频已恢复采集 ✓（会话内自动重连，落盘继续）")
        } catch {
            let giveUp: Bool = stateQueue.sync {
                guard !state.userStopped else {
                    state.restarting = false
                    return false
                }
                state.consecutiveFailures += 1
                if state.consecutiveFailures >= maxConsecutiveFailures {
                    return true
                }
                // 解除 restarting 并重置断流计时，让看门狗按退避节奏重试
                state.restarting = false
                state.streamStartedAt = Date()
                state.lastBufferAt = nil
                return false
            }
            if giveUp {
                notifyStall("系统音频多次重连失败，已停止采集：\(error.localizedDescription)")
                await stop()
            } else {
                notifyStall("系统音频重连失败，稍后重试：\(error.localizedDescription)")
            }
        }
    }

    private func notifyStall(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStall?(message)
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        // 注意：音频帧没有 SCStreamFrameInfo.status 附件（那是视频帧的校验），直接使用
        guard sampleBuffer.isValid else { return }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clamping: numSamples)) else {
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(clamping: numSamples)

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(clamping: numSamples),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return }

        let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation? = stateQueue.sync {
            // 已被替换的旧流可能在 stopCapture 超时后继续回调，不能让旧帧污染新会话。
            guard self.stream === stream, !state.userStopped else { return nil }
            state.lastBufferAt = Date()
            // 不能在锁内 yield：消费端慢时 bufferingNewest 可能丢弃并触发 onTermination 回调
            return self.continuation
        }
        continuation?.yield(pcmBuffer)
    }

    // MARK: - SCStreamDelegate

    /// 流意外终止（如系统回收）：交给看门狗立即重连，而不是静默结束整个会话
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wasActive: Bool = stateQueue.sync {
            guard self.stream === stream, !state.userStopped else { return false }
            self.stream = nil
            state.lastBufferAt = .distantPast  // 让看门狗下一轮立即触发重连
            return true
        }
        if wasActive {
            notifyStall("系统音频流意外终止，正在自动恢复：\(error.localizedDescription)")
        }
    }
}

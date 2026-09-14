import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

/// 通过 ScreenCaptureKit 采集系统输出的音频（自动排除本 App 自身的声音）。
///
/// 注意：系统会要求「屏幕录制」权限（ScreenCaptureKit 复用该权限来捕获系统音频），
/// 且授权后必须**完全退出并重新打开 App** 才生效（macOS 的限制）。
final class SystemAudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {

    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var buffers: AsyncStream<AVAudioPCMBuffer>?
    private var stream: SCStream?

    /// 开始采集，返回音频帧流（每帧为一个 AVAudioPCMBuffer）。
    func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard stream == nil else {
            throw CaptureError(message: "已经在采集会话中")
        }

        // 权限预检：未授权时先触发系统弹窗，并明确告知需授权后重启 App
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            throw CaptureError(message: "需要「屏幕录制」权限：请在弹窗中点「打开系统设置」开启 EchoTrans，然后完全退出（⌘Q）并重新打开 App 再试")
        }

        let buffers = AsyncStream<AVAudioPCMBuffer> { self.continuation = $0 }
        self.buffers = buffers

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

        self.stream = stream
        return buffers
    }

    /// 停止采集并结束音频流。
    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        continuation?.finish()
        continuation = nil
        buffers = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let continuation else { return }
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

        continuation.yield(pcmBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation?.finish()
        continuation = nil
        self.stream = nil
        buffers = nil
    }
}

import Foundation

/// 应用主状态机：采集 → 转写 → 翻译 → 落盘。
@MainActor
final class AppModel: ObservableObject {

    private struct AppError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Phase: Equatable {
        case idle        // 空闲
        case capturing   // 采集中
        case finalizing  // 正在结束转写 / 生成翻译
    }

    struct TranslationResult: Identifiable {
        let id = UUID()
        let language: String
        let text: String
        let fileURL: URL?
        let error: String?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusMessage = "就绪"
    /// 本会话已确认的转写文本
    @Published private(set) var finalizedText = ""
    /// 识别中的临时文本
    @Published private(set) var partialText = ""
    @Published private(set) var translationResults: [TranslationResult] = []
    @Published private(set) var lastSessionDirectory: URL?

    // 采集诊断：实时时长与电平（用于确认音频是否真的进来了）
    @Published private(set) var capturedSeconds: Double = 0
    @Published private(set) var audioLevel: Double = 0  // 0...1，RMS 映射

    // 实时对照翻译（右列）：按句增量翻译已稳定的文本
    @Published private(set) var liveTranslation = ""
    private var liveTranslatedOffset = 0
    private var liveTranslatedSource = ""
    private var liveTranslationTask: Task<Void, Never>?
    private var liveTranslationDebounceTask: Task<Void, Never>?
    private var lastLiveTranslateAt = Date.distantPast
    private var lastTranscriptUpdateAt = Date.distantPast
    private let liveTranslateInterval: TimeInterval = 2.0
    private let liveTranslationDebounce: TimeInterval = 0.8
    private let liveSoftBoundaryDelay: TimeInterval = 2.5
    private let liveSoftBoundaryLength = 24

    let settings: AppSettings
    let modelManager: ModelManager

    private let engine = SystemAudioCaptureEngine()
    private let store: SessionStore
    private var consumeTask: Task<Void, Never>?
    private var session: SessionStore.Session?
    private var audioWriter: WavFileWriter?
    private var liveLocal: LocalLiveTranscriber?
    private var liveNova: CloudflareNovaTranscriber?

    init(settings: AppSettings = AppSettings.load()) {
        self.settings = settings
        self.modelManager = ModelManager(settings: settings)
        self.store = SessionStore(rootDirectory: settings.outputDirectoryURL)
    }

    // MARK: - 对外操作

    func start() {
        guard phase == .idle else { return }
        let realtimeReady: Bool
        switch settings.realtimeTranscriptionEngine {
        case .cloudflareNova3:
            realtimeReady = settings.cloudflareNovaConfigured
        case .whisper:
            realtimeReady = modelManager.whisperInstalled
        case .senseVoice:
            realtimeReady = modelManager.senseVoiceInstalled
        }
        guard realtimeReady else {
            statusMessage = settings.realtimeTranscriptionEngine == .cloudflareNova3
                ? "请先在设置中配置 Cloudflare Nova-3"
                : "请先在设置中下载实时转写模型"
            return
        }
        let finalReady = settings.finalTranscriptionEngine == .whisper
            ? modelManager.whisperInstalled : modelManager.senseVoiceInstalled
        guard finalReady else {
            statusMessage = "请先在设置中下载最终转写模型"
            return
        }
        phase = .capturing
        Task { await startSession() }
    }

    func stop() {
        guard phase == .capturing else { return }
        phase = .finalizing
        Task { await finishSession() }
    }

    // MARK: - 会话流程

    private func startSession() async {
        do {
            finalizedText = ""
            partialText = ""
            translationResults = []
            lastSessionDirectory = nil
            capturedSeconds = 0
            audioLevel = 0
            liveTranslation = ""
            liveTranslatedOffset = 0
            liveTranslatedSource = ""
            liveTranslationTask?.cancel()
            liveTranslationTask = nil
            liveTranslationDebounceTask?.cancel()
            liveTranslationDebounceTask = nil
            lastLiveTranslateAt = .distantPast
            lastTranscriptUpdateAt = .distantPast

            // 每次开始采集 -> 新建一个会话目录（文字版落点）
            let newSession = try store.beginSession(startedAt: Date())
            session = newSession

            // 采集音频同步落盘为 audio.wav，供本地引擎在结束时重新转写
            audioWriter = WavFileWriter(url: newSession.url.appendingPathComponent("audio.wav"))

            // 断流重连、睡眠恢复等采集事件的提示（不影响 phase，采集继续）
            engine.onStall = { [weak self] message in
                self?.statusMessage = message
            }
            let buffers = try await engine.start()

            switch settings.realtimeTranscriptionEngine {
            case .cloudflareNova3:
                let nova = CloudflareNovaTranscriber(configuration: .init(
                    accountID: settings.cloudflareAccountID,
                    gatewayID: settings.cloudflareGatewayID,
                    apiToken: settings.cloudflareAPIToken,
                    language: settings.recognitionLocale
                ))
                nova.onUpdate = { [weak self] committed, partial, isFinal in
                    guard let self else { return }
                    let changed = self.finalizedText != committed || self.partialText != partial
                    self.finalizedText = committed
                    self.partialText = partial
                    if changed { self.lastTranscriptUpdateAt = Date() }
                    // Nova 的 interim 也需要驱动防抖计时；否则一段话迟迟没有
                    // is_final 时，右侧实时译文会一直为空。
                    if changed { self.scheduleLiveTranslation() }
                    // is_final 的 committed 文本在 tryLiveTranslation 中会被直接视为稳定文本。
                    if isFinal { self.tryLiveTranslation() }
                }
                nova.onError = { [weak self] message in self?.statusMessage = message }
                try nova.start()
                liveNova = nova
            case .whisper, .senseVoice:
                let engine: TranscriptionEngine = settings.realtimeTranscriptionEngine == .whisper ? .whisper : .senseVoice
                guard let local = LocalLiveTranscriber(engine: engine, settings: settings) else {
                    throw AppError(message: "本地实时模型不可用，请在设置中确认模型已安装")
                }
                liveLocal = local
                local.onUpdate = { [weak self] committed, partial in
                    guard let self else { return }
                    let changed = self.finalizedText != committed || self.partialText != partial
                    self.finalizedText = committed
                    self.partialText = partial
                    if changed { self.lastTranscriptUpdateAt = Date() }
                    self.scheduleLiveTranslation()
                }
                local.onError = { [weak self] message in
                    self?.statusMessage = "本地实时引擎出错：\(message)"
                }
                local.start()
            }
            statusMessage = "正在采集…（实时引擎：\(settings.realtimeTranscriptionEngine.displayName)）"

            // detached：音频落盘与喂帧不占用主线程；writer/实时引擎提前捕获引用
            let writer = audioWriter
            let liveLocalEngine = liveLocal
            let liveNovaEngine = liveNova
            var totalFrames: Double = 0
            var windowSquared: Double = 0
            var windowCount: Int = 0
            var lastPublish = Date.distantPast
            consumeTask = Task.detached {
                for await buffer in buffers {
                    writer?.append(buffer: buffer)
                    liveLocalEngine?.append(buffer: buffer)
                    liveNovaEngine?.append(buffer: buffer)

                    // 采集统计（每 0.5s 发布一次，顺便做实时电平表）
                    let frames = Double(buffer.frameLength)
                    totalFrames += frames
                    if let channel = buffer.floatChannelData {
                        let pointer = channel[0]
                        let n = Int(buffer.frameLength)
                        var sum: Double = 0
                        for i in 0..<n {
                            let sample = Double(pointer[i])
                            sum += sample * sample
                        }
                        windowSquared += sum
                        windowCount += n
                    }
                    let now = Date()
                    if now.timeIntervalSince(lastPublish) > 0.5 {
                        let seconds = totalFrames / 16000.0
                        let rms = windowCount > 0 ? sqrt(windowSquared / Double(windowCount)) : 0
                        // RMS → dB → 0...1（-60dB…0dB）
                        let db = rms > 0 ? 20 * log10(rms) : -160
                        let level = max(0, min(1, (db + 60) / 60))
                        windowSquared = 0
                        windowCount = 0
                        lastPublish = now
                        let captured = seconds
                        Task { @MainActor [weak self] in
                            self?.capturedSeconds = captured
                            self?.audioLevel = level
                        }
                    }
                }
            }

            statusMessage = "正在采集系统音频并转写…（识别语言：\(settings.recognitionLocale)）"
        } catch {
            if let nova = liveNova { _ = await nova.stop() }
            liveNova = nil
            liveLocal = nil
            await engine.stop()
            consumeTask?.cancel()
            consumeTask = nil
            audioWriter?.finalize()
            audioWriter = nil
            if let failedSession = session {
                try? FileManager.default.removeItem(at: failedSession.url)
            }
            phase = .idle
            session = nil
            statusMessage = "启动失败：\(error.localizedDescription)"
        }
    }

    private func finishSession() async {
        statusMessage = "正在结束转写…"

        // 停止后进入最终转写/翻译流程，不再让实时翻译请求修改右侧预览。
        liveTranslationDebounceTask?.cancel()
        liveTranslationDebounceTask = nil
        liveTranslationTask?.cancel()
        liveTranslationTask = nil

        // 先让 ScreenCaptureKit 停止产出并结束 AsyncStream，再等待消费端排空。
        // 这保证停止瞬间的最后几帧既写入 WAV，也送达所选实时引擎。
        engine.onStall = nil
        await engine.stop()
        if let task = consumeTask {
            await task.value
        }
        consumeTask = nil

        // 停止本地实时引擎（提交剩余块 + 释放模型）
        var localStopText: String?
        if let local = liveLocal {
            localStopText = await withCheckedContinuation { continuation in
                local.stop { text in continuation.resume(returning: text) }
            }
            liveLocal = nil
            if let localStopText, !localStopText.isEmpty {
                finalizedText = localStopText
                partialText = ""
            }
        }
        if let nova = liveNova {
            let novaText = await nova.stop()
            liveNova = nil
            if !novaText.isEmpty {
                finalizedText = novaText
                partialText = ""
            }
        }

        audioWriter?.finalize()
        audioWriter = nil

        guard let session else {
            phase = .idle
            statusMessage = "当前没有进行中的会话"
            return
        }

        // 诊断提示：音频几乎没进来，多半是屏幕录制权限或没在播放声音
        if capturedSeconds < 1 {
            statusMessage = "⚠️ 本次几乎未采集到音频（\(String(format: "%.1f", capturedSeconds))s）：请确认已授予「屏幕录制」权限，且采集期间有其他 App 在播放声音"
        }

        // ── 生成最终文字版 ──────────────────────────────
        var transcript = fullTranscript

        let engineName = settings.finalTranscriptionEngine.displayName
        statusMessage = "正在本地重新转写（\(engineName)，长会议需要一点时间）…"
        let locale = settings.recognitionLocale
        let finalEngine = settings.finalTranscriptionEngine
        let whisperPath = settings.effectiveWhisperModelPath
        let svModelPath = settings.effectiveSenseVoiceModelPath
        let svTokensPath = settings.effectiveSenseVoiceTokensPath
        let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
            do {
                let wav = session.url.appendingPathComponent("audio.wav")
                let (samples, sampleRate) = try WavFileReader.readSamples(url: wav)
                switch finalEngine {
                case .whisper:
                    return .success(try LocalTranscriber.transcribeWhisper(
                        modelPath: whisperPath,
                        language: LocalTranscriber.whisperLanguage(fromLocale: locale),
                        samples: samples
                    ))
                case .senseVoice:
                    return .success(try LocalTranscriber.transcribeSenseVoice(
                        modelPath: svModelPath,
                        tokensPath: svTokensPath,
                        language: LocalTranscriber.senseVoiceLanguage(fromLocale: locale),
                        samples: samples,
                        sampleRate: sampleRate
                    ))
                }
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            transcript = text
            finalizedText = text
            partialText = ""
        case .failure(let error):
            statusMessage = "\(engineName) 转写失败，已回退实时识别结果：\(error.localizedDescription)"
        default:
            statusMessage = "\(engineName) 转写结果为空，已回退实时识别结果"
        }

        do {
            try store.writeTranscript(transcript, session: session)
        } catch {
            statusMessage = "保存转写文本失败：\(error.localizedDescription)"
        }

        if settings.needsTranslationAPI,
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let language = settings.targetLanguage
            statusMessage = "正在调用大模型翻译…（\(language)）"
            let service = TranslationService(config: settings.translationConfig)
            do {
                let translated = try await service.translate(
                    text: transcript,
                    to: language,
                    sourceLocale: settings.recognitionLocale
                )
                let fileURL = try? store.writeTranslation(
                    translated, language: language, session: session
                )
                translationResults.append(
                    TranslationResult(language: language, text: translated, fileURL: fileURL, error: nil)
                )
            } catch {
                translationResults.append(
                    TranslationResult(language: language, text: "", fileURL: nil, error: error.localizedDescription)
                )
            }
            statusMessage = "完成 ✓ 已保存到 \(session.url.path)"
        } else if settings.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            statusMessage = "完成 ✓ 已保存 transcript.txt（未配置 API Key，跳过翻译）"
        } else {
            statusMessage = "完成 ✓ 已保存 transcript.txt"
        }

        lastSessionDirectory = session.url
        self.session = nil
        phase = .idle
    }

    // MARK: - 实时对照翻译

    /// 实时译文列使用所选目标语言；只翻译已完结的句子（节流 + 增量，避免重复翻译与频繁请求）
    private func scheduleLiveTranslation() {
        guard settings.needsTranslationAPI else { return }
        // 识别器会在很短时间内连续修正同一句话，先合并这些更新，
        // 避免每个 partial 都触发一次网络请求。
        liveTranslationDebounceTask?.cancel()
        let debounce = liveTranslationDebounce
        liveTranslationDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.liveTranslationDebounceTask = nil
                self.tryLiveTranslation()
            }
        }
    }

    /// 在 debounce 后真正尝试翻译；如果仍在节流窗口内，延迟到窗口结束再重试。
    private func tryLiveTranslation() {
        guard settings.needsTranslationAPI else { return }
        guard liveTranslationTask == nil else { return }

        let now = Date()
        let wait = liveTranslateInterval - now.timeIntervalSince(lastLiveTranslateAt)
        if wait > 0 {
            liveTranslationDebounceTask?.cancel()
            liveTranslationDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.liveTranslationDebounceTask = nil
                    self?.tryLiveTranslation()
                }
            }
            return
        }

        let full = fullTranscript
        let (stable, pending) = Self.splitStableTail(full)

        var source = stable
        var consumedCount = stable.count

        // Nova 已确认的文本不依赖标点：is_final 本身就是稳定边界，可以立即翻译。
        // partial 仍走下面的“停止更新一段时间”软边界，避免频繁翻译抖动文本。
        if settings.realtimeTranscriptionEngine == .cloudflareNova3,
           finalizedText.count > liveTranslatedOffset {
            source = finalizedText
            consumedCount = finalizedText.count
        }

        // 口语识别经常很久没有标点。尾巴达到一定长度且停止更新一段时间后，
        // 把它当作软边界翻译，否则右列会长时间空白。
        if source.count <= liveTranslatedOffset, pending.count >= liveSoftBoundaryLength {
            let stableFor = now.timeIntervalSince(lastTranscriptUpdateAt)
            if stableFor >= liveSoftBoundaryDelay {
                source = full
                consumedCount = full.count
            } else {
                // debounce 通常早于软边界到期。必须安排剩余时间后的重试，
                // 否则 Nova 停止更新后不会再有事件来触发实时翻译。
                scheduleLiveTranslationRetry(after: liveSoftBoundaryDelay - stableFor)
                return
            }
        }

        // 本地 ASR 会反复修正当前块。已经显示的译文保持不动，并把增量游标
        // 重新锚定到最新原文；不要因为一次长度回退而把整列译文清空。
        if liveTranslatedOffset > 0 && !source.hasPrefix(liveTranslatedSource) {
            liveTranslatedSource = source
            liveTranslatedOffset = source.count
            return
        }

        guard consumedCount >= liveTranslatedOffset + 6 else { return }
        let chunk = String(source.dropFirst(liveTranslatedOffset))
        guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let config = settings.translationConfig
        let locale = settings.recognitionLocale
        let language = settings.targetLanguage
        lastLiveTranslateAt = now

        liveTranslationTask = Task { [weak self] in
            do {
                let service = TranslationService(config: config)
                let translated = try await service.translate(text: chunk, to: language, sourceLocale: locale)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.liveTranslation.isEmpty {
                        self.liveTranslation = translated
                    } else {
                        self.liveTranslation += "\n" + translated
                    }
                    self.liveTranslatedOffset = consumedCount
                    self.liveTranslatedSource = source
                    self.liveTranslationTask = nil
                    self.tryLiveTranslation() // 处理请求期间积压的新句子
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.liveTranslationTask = nil
                    self.statusMessage = "实时翻译失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func scheduleLiveTranslationRetry(after delay: TimeInterval) {
        liveTranslationDebounceTask?.cancel()
        liveTranslationDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.liveTranslationDebounceTask = nil
                self.tryLiveTranslation()
            }
        }
    }

    /// 把文本切成（已完结句部分, 未完结句尾巴）；已完结句可安全送翻
    static func splitStableTail(_ text: String) -> (stable: String, pending: String) {
        let terminators: Set<Character> = ["。", "！", "？", "!", "?", ".", "\n"]
        guard !text.isEmpty else { return ("", "") }
        var idx = text.index(before: text.endIndex)
        while idx > text.startIndex {
            if terminators.contains(text[idx]) {
                let boundary = text.index(after: idx)
                return (String(text[text.startIndex..<boundary]), String(text[boundary...]))
            }
            idx = text.index(before: idx)
        }
        return ("", text)
    }

    private var fullTranscript: String {
        var parts: [String] = []
        if !finalizedText.isEmpty { parts.append(finalizedText) }
        let partial = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty { parts.append(partial) }
        return parts.joined(separator: "\n\n")
    }
}

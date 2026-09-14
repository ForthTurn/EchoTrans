import Foundation

/// 应用主状态机：采集 → 转写 → 翻译 → 落盘。
@MainActor
final class AppModel: ObservableObject {

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
    private var liveTranslationTask: Task<Void, Never>?
    private var lastLiveTranslateAt = Date.distantPast
    private let liveTranslateInterval: TimeInterval = 2.0

    let settings: AppSettings
    let modelManager: ModelManager

    private let engine = SystemAudioCaptureEngine()
    private let transcriber = TranscriptionService()
    private let store: SessionStore
    private var consumeTask: Task<Void, Never>?
    private var session: SessionStore.Session?
    private var audioWriter: WavFileWriter?
    private var waitingForFinal = false
    private var liveLocal: LocalLiveTranscriber?
    private var applePreviewActive = false

    init(settings: AppSettings = AppSettings.load()) {
        self.settings = settings
        self.modelManager = ModelManager(settings: settings)
        self.store = SessionStore(rootDirectory: settings.outputDirectoryURL)
        transcriber.onResult = { [weak self] text, isFinal in
            Task { @MainActor [weak self] in
                self?.handleTranscription(text: text, isFinal: isFinal)
            }
        }
    }

    // MARK: - 对外操作

    func start() {
        guard phase == .idle else { return }
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
            guard await TranscriptionService.requestAuthorization() else {
                throw TranscriptionService.TranscriptionError(
                    message: "未获得语音识别权限，请在「系统设置 → 隐私与安全性 → 语音识别」中授权"
                )
            }

            finalizedText = ""
            partialText = ""
            translationResults = []
            lastSessionDirectory = nil
            capturedSeconds = 0
            audioLevel = 0
            liveTranslation = ""
            liveTranslatedOffset = 0
            liveTranslationTask?.cancel()
            liveTranslationTask = nil
            lastLiveTranslateAt = .distantPast

            // 每次开始采集 -> 新建一个会话目录（文字版落点）
            let newSession = try store.beginSession(startedAt: Date())
            session = newSession

            // 采集音频同步落盘为 audio.wav，供本地引擎在结束时重新转写
            audioWriter = WavFileWriter(url: newSession.url.appendingPathComponent("audio.wav"))

            let buffers = try await engine.start()

            // ── 实时预览引擎：本地引擎可用则直接本地实时，否则回退苹果 ASR ──
            applePreviewActive = true
            if settings.transcriptionEngine != .apple,
               let local = LocalLiveTranscriber(engine: settings.transcriptionEngine, settings: settings) {
                liveLocal = local
                applePreviewActive = false
                local.onUpdate = { [weak self] committed, partial in
                    guard let self else { return }
                    self.finalizedText = committed
                    self.partialText = partial
                    self.scheduleLiveTranslation()
                }
                local.onError = { [weak self] message in
                    self?.statusMessage = "本地实时引擎出错：\(message)"
                }
                local.start()
                statusMessage = "正在采集…（实时引擎：\(settings.transcriptionEngine.shortName) · 本地）"
            } else {
                if settings.transcriptionEngine != .apple {
                    statusMessage = "本地模型不可用，实时预览回退苹果识别；停止后仍会用本地引擎出定稿"
                } else {
                    statusMessage = "正在采集…（实时引擎：苹果系统识别）"
                }
                try transcriber.start(localeIdentifier: settings.recognitionLocale)
            }

            // detached：音频落盘与喂帧不占用主线程；writer/transcriber 提前在主线程捕获引用
            let transcriber = self.transcriber
            let writer = audioWriter
            let liveLocalEngine = liveLocal
            var totalFrames: Double = 0
            var windowSquared: Double = 0
            var windowCount: Int = 0
            var lastPublish = Date.distantPast
            consumeTask = Task.detached {
                for await buffer in buffers {
                    transcriber.append(buffer)
                    writer?.append(buffer: buffer)
                    liveLocalEngine?.append(buffer: buffer)

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
            phase = .idle
            session = nil
            statusMessage = "启动失败：\(error.localizedDescription)"
        }
    }

    private func finishSession() async {
        statusMessage = "正在结束转写…"

        consumeTask?.cancel()
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

        await engine.stop()
        transcriber.endAudio()

        // 等待苹果识别器吐出最终结果（最多 5 秒；仅当苹果预览在跑时）
        if applePreviewActive {
            waitingForFinal = true
            let waitStart = Date()
            while waitingForFinal, Date().timeIntervalSince(waitStart) < 5 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        audioWriter?.finalize()

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

        if settings.transcriptionEngine != .apple {
            let engineName = settings.transcriptionEngine == .whisper ? "Whisper" : "SenseVoice"
            statusMessage = "正在本地重新转写（\(engineName)，长会议需要一点时间）…"
            let locale = settings.recognitionLocale
            let engine = settings.transcriptionEngine
            let whisperPath = settings.effectiveWhisperModelPath
            let svModelPath = settings.effectiveSenseVoiceModelPath
            let svTokensPath = settings.effectiveSenseVoiceTokensPath
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do {
                    let wav = session.url.appendingPathComponent("audio.wav")
                    let (samples, sampleRate) = try WavFileReader.readSamples(url: wav)
                    switch engine {
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
                    case .apple:
                        return .success("")
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
        }

        do {
            try store.writeTranscript(transcript, session: session)
        } catch {
            statusMessage = "保存转写文本失败：\(error.localizedDescription)"
        }

        if settings.needsTranslationAPI,
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessage = "正在调用大模型翻译…（\(settings.targetLanguages.joined(separator: "、"))）"
            let service = TranslationService(config: settings.translationConfig)
            for language in settings.targetLanguages {
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

    // MARK: - 转写结果处理

    private func handleTranscription(text: String, isFinal: Bool) {
        if isFinal {
            appendFinalSegment(text)
            partialText = ""
            waitingForFinal = false
        } else {
            partialText = text
        }
        scheduleLiveTranslation()
    }

    // MARK: - 实时对照翻译

    /// 实时译文列使用第一个目标语言；只翻译已完结的句子（节流 + 增量，避免重复翻译与频繁请求）
    private func scheduleLiveTranslation() {
        guard settings.needsTranslationAPI else { return }
        guard liveTranslationTask == nil else { return }
        guard Date().timeIntervalSince(lastLiveTranslateAt) > liveTranslateInterval else { return }

        let full = fullTranscript
        let (stable, _) = Self.splitStableTail(full)

        // ASR 修正导致文本回退时重置，避免重复拼接
        if stable.count < liveTranslatedOffset {
            liveTranslatedOffset = 0
            liveTranslation = ""
        }
        guard stable.count >= liveTranslatedOffset + 6 else { return }

        let chunk = String(stable.dropFirst(liveTranslatedOffset))
        let config = settings.translationConfig
        let locale = settings.recognitionLocale
        let language = settings.targetLanguages.first ?? "English"

        lastLiveTranslateAt = Date()
        liveTranslationTask = Task { [weak self] in
            do {
                let service = TranslationService(config: config)
                let translated = try await service.translate(text: chunk, to: language, sourceLocale: locale)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.liveTranslation.isEmpty {
                        self.liveTranslation = translated
                    } else {
                        self.liveTranslation += "\n" + translated
                    }
                    self.liveTranslatedOffset = stable.count
                    self.liveTranslationTask = nil
                    self.scheduleLiveTranslation()  // 处理积压的新句子
                }
            } catch {
                await MainActor.run { [weak self] in self?.liveTranslationTask = nil }
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

    private func appendFinalSegment(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if finalizedText.isEmpty {
            finalizedText = trimmed
        } else {
            finalizedText += "\n\n" + trimmed
        }
    }

    private var fullTranscript: String {
        var parts: [String] = []
        if !finalizedText.isEmpty { parts.append(finalizedText) }
        let partial = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty { parts.append(partial) }
        return parts.joined(separator: "\n\n")
    }
}

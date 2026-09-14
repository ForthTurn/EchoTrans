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

    let settings: AppSettings
    let modelManager: ModelManager

    private let engine = SystemAudioCaptureEngine()
    private let transcriber = TranscriptionService()
    private let store: SessionStore
    private var consumeTask: Task<Void, Never>?
    private var session: SessionStore.Session?
    private var audioWriter: WavFileWriter?
    private var waitingForFinal = false

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

            // 每次开始采集 -> 新建一个会话目录（文字版落点）
            let newSession = try store.beginSession(startedAt: Date())
            session = newSession

            // 采集音频同步落盘为 audio.wav，供本地引擎在结束时重新转写
            audioWriter = WavFileWriter(url: newSession.url.appendingPathComponent("audio.wav"))

            let buffers = try await engine.start()
            try transcriber.start(localeIdentifier: settings.recognitionLocale)

            // detached：音频落盘与喂帧不占用主线程；writer/transcriber 提前在主线程捕获引用
            let transcriber = self.transcriber
            let writer = audioWriter
            consumeTask = Task.detached {
                for await buffer in buffers {
                    transcriber.append(buffer)
                    writer?.append(buffer: buffer)
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
        await engine.stop()
        transcriber.endAudio()

        // 等待识别器吐出最终结果（最多 5 秒；选择了本地引擎时只需实时预览文本）
        if settings.transcriptionEngine == .apple {
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

        // ── 生成最终文字版 ──────────────────────────────
        var transcript = fullTranscript

        if settings.transcriptionEngine != .apple {
            let engineName = settings.transcriptionEngine == .whisper ? "Whisper" : "SenseVoice"
            statusMessage = "正在本地重新转写（\(engineName)，长会议需要一点时间）…"
            let locale = settings.recognitionLocale
            let engine = settings.transcriptionEngine
            let whisperPath = settings.whisperModelPath
            let svModelPath = settings.senseVoiceModelPath
            let svTokensPath = settings.senseVoiceTokensPath
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

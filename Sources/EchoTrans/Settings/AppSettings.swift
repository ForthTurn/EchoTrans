import Foundation

enum RealtimeTranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    case cloudflareNova3
    case whisper
    case senseVoice

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cloudflareNova3: return "Cloudflare Nova-3"
        case .whisper: return "本地 Whisper"
        case .senseVoice: return "本地 SenseVoice"
        }
    }
}

enum FinalTranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    case whisper
    case senseVoice

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .whisper: return "本地 Whisper"
        case .senseVoice: return "本地 SenseVoice"
        }
    }
}

/// 应用设置，持久化到 ~/Library/Application Support/EchoTrans/settings.json
final class AppSettings: ObservableObject {

    static let availableTargetLanguages = [
        "English",
        "简体中文",
        "日本語",
        "한국어",
        "Français",
        "Deutsch",
        "Español",
        "Português",
        "Русский",
        "العربية"
    ]

    static let availableRecognitionLocales: [(code: String, label: String)] = [
        (code: "zh-CN", label: "中文（普通话）"),
        (code: "zh-TW", label: "中文（台湾）"),
        (code: "en-US", label: "English (US)"),
        (code: "en-GB", label: "English (UK)"),
        (code: "ja-JP", label: "日本語"),
        (code: "ko-KR", label: "한국어"),
        (code: "fr-FR", label: "Français"),
        (code: "de-DE", label: "Deutsch"),
        (code: "es-ES", label: "Español"),
        (code: "ru-RU", label: "Русский")
    ]

    @Published var recognitionLocale: String = "zh-CN"
    @Published var targetLanguage: String = "English"
    @Published var apiBaseURL: String = ""
    @Published var apiKey: String = ""
    @Published var apiModel: String = ""
    @Published var outputDirectoryPath: String = SessionStore.defaultRootDirectory.path

    /// 旧版统一引擎字段，仅用于设置迁移。
    @Published var transcriptionEngine: TranscriptionEngine = .whisper
    @Published var realtimeTranscriptionEngine: RealtimeTranscriptionEngine = .cloudflareNova3
    @Published var finalTranscriptionEngine: FinalTranscriptionEngine = .whisper
    @Published var cloudflareAccountID: String = ""
    @Published var cloudflareGatewayID: String = ""
    @Published var cloudflareAPIToken: String = ""
    @Published var whisperModelPath: String = AppSettings.defaultWhisperModelPath
    @Published var senseVoiceModelDir: String = AppSettings.defaultSenseVoiceModelDir
    /// HuggingFace 镜像（国内网络）
    @Published var useHFMirror: Bool = false

    var senseVoiceModelPath: String {
        URL(fileURLWithPath: senseVoiceModelDir, isDirectory: true)
            .appendingPathComponent("model.int8.onnx").path
    }

    var senseVoiceTokensPath: String {
        URL(fileURLWithPath: senseVoiceModelDir, isDirectory: true)
            .appendingPathComponent("tokens.txt").path
    }

    // MARK: - App 内置模型（make-app.sh 打包进 Contents/Resources/models 时存在）

    static func bundledModelURL(_ relativePath: String) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = URL(fileURLWithPath: resourceURL.path, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var whisperBundled: Bool {
        Self.bundledModelURL("ggml-large-v3-turbo.bin") != nil
    }

    var senseVoiceBundled: Bool {
        Self.bundledModelURL("sensevoice/model.int8.onnx") != nil
            && Self.bundledModelURL("sensevoice/tokens.txt") != nil
    }

    /// 实际生效的模型路径：优先 App 内置，否则用户目录
    var effectiveWhisperModelPath: String {
        Self.bundledModelURL("ggml-large-v3-turbo.bin")?.path ?? whisperModelPath
    }

    var effectiveSenseVoiceModelPath: String {
        Self.bundledModelURL("sensevoice/model.int8.onnx")?.path ?? senseVoiceModelPath
    }

    var effectiveSenseVoiceTokensPath: String {
        Self.bundledModelURL("sensevoice/tokens.txt")?.path ?? senseVoiceTokensPath
    }

    var outputDirectoryURL: URL {
        URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
    }

    /// 是否具备调用翻译 API 的条件
    var needsTranslationAPI: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiModel.trimmingCharacters(in: .whitespaces).isEmpty
            && !targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var translationConfig: TranslationService.Config {
        .init(baseURL: apiBaseURL, apiKey: apiKey, model: apiModel)
    }

    var cloudflareNovaConfigured: Bool {
        !cloudflareAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cloudflareGatewayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("EchoTrans/models", isDirectory: true)
    }

    static var defaultWhisperModelPath: String {
        modelsDirectory.appendingPathComponent("ggml-large-v3-turbo.bin").path
    }

    static var defaultSenseVoiceModelDir: String {
        modelsDirectory.appendingPathComponent("sensevoice", isDirectory: true).path
    }

    // MARK: - 持久化

    private struct Payload: Codable {
        var recognitionLocale: String
        /// targetLanguages 用于读取旧版多选配置；新版本只写 targetLanguage。
        var targetLanguages: [String]?
        var targetLanguage: String?
        var apiBaseURL: String
        var apiKey: String
        var apiModel: String
        var outputDirectoryPath: String
        var transcriptionEngine: String
        var whisperModelPath: String
        var senseVoiceModelDir: String
        var useHFMirror: Bool
        var realtimeTranscriptionEngine: String?
        var finalTranscriptionEngine: String?
        var cloudflareAccountID: String?
        var cloudflareGatewayID: String?
        var cloudflareAPIToken: String?
    }

    private static var settingsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("EchoTrans/settings.json")
    }

    func save() {
        let payload = Payload(
            recognitionLocale: recognitionLocale,
            targetLanguages: nil,
            targetLanguage: targetLanguage,
            apiBaseURL: apiBaseURL,
            apiKey: apiKey,
            apiModel: apiModel,
            outputDirectoryPath: outputDirectoryPath,
            transcriptionEngine: transcriptionEngine.rawValue,
            whisperModelPath: whisperModelPath,
            senseVoiceModelDir: senseVoiceModelDir,
            useHFMirror: useHFMirror,
            realtimeTranscriptionEngine: realtimeTranscriptionEngine.rawValue,
            finalTranscriptionEngine: finalTranscriptionEngine.rawValue,
            cloudflareAccountID: cloudflareAccountID,
            cloudflareGatewayID: cloudflareGatewayID,
            cloudflareAPIToken: cloudflareAPIToken
        )
        let url = Self.settingsURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func load() -> AppSettings {
        let settings = AppSettings()
        guard let data = try? Data(contentsOf: settingsURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return settings
        }
        settings.recognitionLocale = payload.recognitionLocale
        let migratedTarget = payload.targetLanguage ?? payload.targetLanguages?.first ?? "English"
        settings.targetLanguage = AppSettings.availableTargetLanguages.contains(migratedTarget)
            ? migratedTarget : "English"
        // 兼容旧版本：如果用户从未修改过旧默认值，迁移为空白 placeholder
        settings.apiBaseURL = payload.apiBaseURL == "https://api.openai.com/v1" ? "" : payload.apiBaseURL
        settings.apiKey = payload.apiKey
        settings.apiModel = payload.apiModel == "gpt-4o-mini" ? "" : payload.apiModel
        settings.outputDirectoryPath = payload.outputDirectoryPath
        let storedEngine = TranscriptionEngine(rawValue: payload.transcriptionEngine) ?? .whisper
        // Apple Speech 对长时间系统音频效果很差，旧配置自动迁移到 Whisper。
        settings.transcriptionEngine = storedEngine == .apple ? .whisper : storedEngine
        settings.whisperModelPath = payload.whisperModelPath
        settings.senseVoiceModelDir = payload.senseVoiceModelDir
        settings.useHFMirror = payload.useHFMirror
        if let raw = payload.realtimeTranscriptionEngine,
           let engine = RealtimeTranscriptionEngine(rawValue: raw) {
            settings.realtimeTranscriptionEngine = engine
        } else {
            settings.realtimeTranscriptionEngine = storedEngine == .senseVoice ? .senseVoice : .whisper
        }
        if let raw = payload.finalTranscriptionEngine,
           let engine = FinalTranscriptionEngine(rawValue: raw) {
            settings.finalTranscriptionEngine = engine
        } else {
            settings.finalTranscriptionEngine = storedEngine == .senseVoice ? .senseVoice : .whisper
        }
        settings.cloudflareAccountID = payload.cloudflareAccountID ?? ""
        settings.cloudflareGatewayID = payload.cloudflareGatewayID ?? ""
        settings.cloudflareAPIToken = payload.cloudflareAPIToken ?? ""
        return settings
    }
}

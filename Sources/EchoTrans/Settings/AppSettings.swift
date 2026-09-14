import Foundation

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
    @Published var targetLanguages: [String] = ["English", "日本語"]
    @Published var apiBaseURL: String = "https://api.openai.com/v1"
    @Published var apiKey: String = ""
    @Published var apiModel: String = "gpt-4o-mini"
    @Published var outputDirectoryPath: String = SessionStore.defaultRootDirectory.path

    var outputDirectoryURL: URL {
        URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
    }

    /// 是否具备调用翻译 API 的条件
    var needsTranslationAPI: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiModel.trimmingCharacters(in: .whitespaces).isEmpty
            && !targetLanguages.isEmpty
    }

    var translationConfig: TranslationService.Config {
        .init(baseURL: apiBaseURL, apiKey: apiKey, model: apiModel)
    }

    // MARK: - 持久化

    private struct Payload: Codable {
        var recognitionLocale: String
        var targetLanguages: [String]
        var apiBaseURL: String
        var apiKey: String
        var apiModel: String
        var outputDirectoryPath: String
    }

    private static var settingsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("EchoTrans/settings.json")
    }

    func save() {
        let payload = Payload(
            recognitionLocale: recognitionLocale,
            targetLanguages: targetLanguages,
            apiBaseURL: apiBaseURL,
            apiKey: apiKey,
            apiModel: apiModel,
            outputDirectoryPath: outputDirectoryPath
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
        settings.targetLanguages = payload.targetLanguages
        settings.apiBaseURL = payload.apiBaseURL
        settings.apiKey = payload.apiKey
        settings.apiModel = payload.apiModel
        settings.outputDirectoryPath = payload.outputDirectoryPath
        return settings
    }
}

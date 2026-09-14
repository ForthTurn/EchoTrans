import Foundation

/// 调用 OpenAI 兼容接口（/chat/completions）进行翻译。
/// 支持 OpenAI、new-api、one-api、各类自建网关。
struct TranslationService {

    struct Config: Codable {
        var baseURL: String
        var apiKey: String
        var model: String
    }

    enum TranslationError: LocalizedError {
        case badURL
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "API 地址无效"
            case .http(let code, let body):
                return "HTTP \(code)：\(body.prefix(300))"
            }
        }
    }

    let config: Config

    /// 把文本翻译成指定语言。
    func translate(text: String, to language: String, sourceLocale: String) async throws -> String {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") {
            base = String(base.dropLast())
        }
        guard let url = URL(string: base + "/chat/completions") else {
            throw TranslationError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
        You are a professional subtitle/transcript translator. Translate the user's transcript into the \
        requested target language. Preserve the original meaning and tone, keep paragraph breaks, and output \
        only the translation itself without any explanations or notes.
        """
        let userPrompt = """
        请将下面的文字（原始语言代码：\(sourceLocale)）翻译成【\(language)】：

        \(text)
        """

        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranslationError.http(http?.statusCode ?? -1, body)
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.http(200, "响应中没有翻译内容")
        }
        return content
    }
}

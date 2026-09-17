import Foundation
import AVFoundation

/// Cloudflare Workers AI Nova-3 实时转写。
/// 音频通过 AI Gateway WebSocket 发送为 16kHz/mono/linear16；interim 只更新预览，
/// is_final 结果追加到已确认文本。API Token 由用户配置并只保存在本机。
final class CloudflareNovaTranscriber {
    struct Configuration {
        let accountID: String
        let gatewayID: String
        let apiToken: String
        let language: String
    }

    enum NovaError: LocalizedError {
        case invalidConfiguration
        case invalidURL
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: return "Cloudflare Account ID、Gateway ID 或 API Token 未配置"
            case .invalidURL: return "Cloudflare WebSocket 地址无效"
            case .server(let message): return "Nova-3 实时转写失败：\(message)"
            }
        }
    }

    var onUpdate: ((_ committed: String, _ partial: String, _ isFinal: Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let configuration: Configuration
    private let stateQueue = DispatchQueue(label: "echotrans.cloudflare-nova.state")
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var sendContinuation: AsyncStream<Data>.Continuation?
    private var sendTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var committed: [String] = []
    private var stopped = false

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func start() throws {
        let account = configuration.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let gateway = configuration.gatewayID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = configuration.apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !gateway.isEmpty, !token.isEmpty else {
            throw NovaError.invalidConfiguration
        }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "gateway.ai.cloudflare.com"
        components.path = "/v1/\(account)/\(gateway)/workers-ai"
        var queryItems = [
            URLQueryItem(name: "model", value: "@cf/deepgram/nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "endpointing", value: "300"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "vad_events", value: "true")
        ]
        let language = Self.languageCode(from: configuration.language)
        if !language.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw NovaError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "cf-aig-authorization")
        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: request)

        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(256)) { continuation in
            self.sendContinuation = continuation
        }
        stateQueue.sync {
            stopped = false
            committed = []
            self.session = session
            self.socket = socket
        }
        socket.resume()

        sendTask = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            for await data in stream {
                if Task.isCancelled { return }
                do {
                    try await socket.send(.data(data))
                } catch {
                    self.report(error)
                    return
                }
            }
        }
        receiveTask = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    self.handle(message)
                } catch {
                    if !self.stateQueue.sync(execute: { self.stopped }) {
                        self.report(error)
                    }
                    return
                }
            }
        }
    }

    func append(buffer: AVAudioPCMBuffer) {
        let continuation = stateQueue.sync { stopped ? nil : sendContinuation }
        guard let continuation else { return }
        guard let channel = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var samples = [Int16]()
        samples.reserveCapacity(count)
        for sample in UnsafeBufferPointer(start: channel[0], count: count) {
            let clamped = max(-1, min(1, sample))
            samples.append(Int16(clamped * 32767).littleEndian)
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        continuation.yield(data)
    }

    func stop() async -> String {
        let continuation = stateQueue.sync { () -> AsyncStream<Data>.Continuation? in
            stopped = true
            let value = sendContinuation
            sendContinuation = nil
            return value
        }
        // 先结束输入并等待已排队的 PCM 全部发出，避免停止瞬间丢掉句尾。
        continuation?.finish()
        await sendTask?.value
        sendTask = nil

        if let socket {
            try? await socket.send(.string("{\"type\":\"Close\"}"))
            // Nova 会在 Close 后补发最后一个 is_final。给接收循环一个很短的收尾窗口；
            // 本地 Whisper 仍会基于完整 WAV 生成最终稿，因此这里不应无限等待网络。
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            socket.cancel(with: .normalClosure, reason: nil)
        }
        receiveTask?.cancel()
        await receiveTask?.value
        receiveTask = nil
        session?.invalidateAndCancel()
        session = nil
        socket = nil
        return stateQueue.sync { committed.joined(separator: "\n") }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let error = Self.serverErrorMessage(from: object) {
            report(NovaError.server(error))
            return
        }
        guard let channel = object["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let text = alternatives.first?["transcript"] as? String else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let isFinal = object["is_final"] as? Bool ?? false

        let values: (String, String) = stateQueue.sync {
            if isFinal {
                let previous = committed.joined(separator: "\n")
                let continuation = TranscriptTextStitcher.continuation(after: previous, newText: cleaned)
                if !continuation.isEmpty { committed.append(continuation) }
                return (committed.joined(separator: "\n"), "")
            }
            return (committed.joined(separator: "\n"), cleaned)
        }
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(values.0, values.1, isFinal)
        }
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error.localizedDescription)
        }
    }

    private static func serverErrorMessage(from object: [String: Any]) -> String? {
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty { return message }
            if let description = error["description"] as? String, !description.isEmpty { return description }
            return String(describing: error)
        }
        let type = (object["type"] as? String)?.lowercased()
        if type == "error" {
            return (object["message"] as? String)
                ?? (object["description"] as? String)
                ?? "Cloudflare 返回未知错误"
        }
        return nil
    }

    private static func languageCode(from locale: String) -> String {
        guard locale != "auto" else { return "" }
        return Locale(identifier: locale).language.languageCode?.identifier ?? ""
    }
}

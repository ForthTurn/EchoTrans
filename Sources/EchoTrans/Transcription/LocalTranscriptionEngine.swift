import Foundation
import AVFoundation

/// 转写引擎
enum TranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    case apple       // 苹果系统 ASR（实时流式）
    case whisper     // whisper.cpp（本地，实时 + 最终稿）
    case senseVoice  // sherpa-onnx SenseVoice（本地，实时 + 最终稿）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "苹果系统识别"
        case .whisper: return "Whisper 本地转写"
        case .senseVoice: return "SenseVoice 本地转写"
        }
    }

    var shortName: String {
        switch self {
        case .apple: return "苹果"
        case .whisper: return "Whisper"
        case .senseVoice: return "SenseVoice"
        }
    }

    var isLocal: Bool { self != .apple }

    /// 引擎特点说明（设置页展示）
    var featureDescription: String {
        switch self {
        case .apple:
            return "实时流式、开箱即用、零下载；长会议与专有名词准确率一般，需「语音识别」权限"
        case .whisper:
            return "实时 + 停止后定稿均本地完成；中英日等混合会议综合准确率最高，Metal GPU 加速，句级延迟（约 4-10s）"
        case .senseVoice:
            return "实时 + 停止后定稿均本地完成；中日韩英速度极快、自带标点；英文输出为全大写风格，句级延迟（约 4-8s）"
        }
    }
}

/// 本地引擎的伪流式实时转写：
/// 音频按 25s 块切分，每 4s 对当前块重新转写一次（模型常驻内存），
/// 块满后提交并开启下一块。句级延迟低、CPU 占用可控。
///
/// 注意：句柄非线程安全，所有操作内部串行在同一队列执行。
final class LocalLiveTranscriber {

    enum LiveError: LocalizedError {
        case modelUnavailable(String)
        case transcribeFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .modelUnavailable(let p): return "模型不可用：\(p)"
            case .transcribeFailed(let c): return "实时转写失败（错误码 \(c)）"
            }
        }
    }

    /// 文本更新回调（主线程）：committed = 已提交块拼接，partial = 当前块最新结果
    var onUpdate: ((_ committed: String, _ partial: String) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "echotrans.local-live")
    private var handle: UnsafeMutableRawPointer?
    private let engine: TranscriptionEngine
    private let whisperLanguage: String
    private var chunk: [Float] = []
    private var committed: [String] = []
    private var partialText: String = ""
    private var timer: DispatchSourceTimer?

    private let sampleRate = 16000
    private let maxChunkSamples = 16000 * 25   // 满块提交
    private let minTickSamples = 16000 * 2     // 不足 2s 不值得跑一次
    private let tickInterval: TimeInterval = 4

    init?(engine: TranscriptionEngine, settings: AppSettings) {
        self.engine = engine
        switch engine {
        case .apple:
            return nil
        case .whisper:
            let path = settings.effectiveWhisperModelPath
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            guard let h = et_whisper_open(path) else { return nil }
            handle = h
            whisperLanguage = LocalTranscriber.whisperLanguage(fromLocale: settings.recognitionLocale)
        case .senseVoice:
            let model = settings.effectiveSenseVoiceModelPath
            let tokens = settings.effectiveSenseVoiceTokensPath
            guard FileManager.default.fileExists(atPath: model),
                  FileManager.default.fileExists(atPath: tokens) else { return nil }
            let lang = LocalTranscriber.senseVoiceLanguage(fromLocale: settings.recognitionLocale)
            guard let h = et_sensevoice_open(model, tokens, lang) else { return nil }
            handle = h
            whisperLanguage = ""
        }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// 追加采集到的音频帧（可从任意线程调用）
    func append(buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // 关键：AVAudioPCMBuffer 的底层指针只在当前回调期间有效，
        // 不能把 channel[0] 指针捕获到异步队列；先复制成值类型数组。
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: frames))
        queue.async { [weak self, samples] in
            self?.chunk.append(contentsOf: samples)
        }
    }

    private func tick() {
        guard chunk.count >= minTickSamples else { return }
        do {
            let text = try transcribeCurrentChunk()
            if chunk.count >= maxChunkSamples {
                // 满块提交，开启下一块
                if !text.isEmpty { committed.append(text) }
                chunk.removeAll(keepingCapacity: true)
                partialText = ""
            } else {
                partialText = text
            }
            publish()
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onError?(error.localizedDescription)
            }
        }
    }

    private func transcribeCurrentChunk() throws -> String {
        guard let handle else { throw LiveError.modelUnavailable("") }
        var out: UnsafeMutablePointer<CChar>?
        let rc = chunk.withUnsafeBufferPointer { buffer -> Int32 in
            switch engine {
            case .whisper:
                return et_whisper_transcribe_ctx(handle, whisperLanguage, buffer.baseAddress,
                                                 Int32(clamping: buffer.count), &out)
            case .senseVoice:
                return et_sensevoice_transcribe_ctx(handle, buffer.baseAddress,
                                                    Int32(clamping: buffer.count), Int32(sampleRate), &out)
            case .apple:
                return -1
            }
        }
        guard rc == 0, let out else { throw LiveError.transcribeFailed(rc) }
        defer { et_free_string(out) }
        return String(cString: out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func publish() {
        let committedText = committed.joined(separator: "\n")
        let partial = partialText
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(committedText, partial)
        }
    }

    /// 停止：提交剩余音频、释放模型，完成后回调（主线程）
    func stop(completion: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            if self.chunk.count >= self.minTickSamples,
               let text = try? self.transcribeCurrentChunk(),
               !text.isEmpty {
                self.committed.append(text)
            }
            if let handle = self.handle {
                switch self.engine {
                case .whisper: et_whisper_close(handle)
                case .senseVoice: et_sensevoice_close(handle)
                case .apple: break
                }
                self.handle = nil
            }
            let joined = self.committed.joined(separator: "\n")
            DispatchQueue.main.async {
                completion(joined)
            }
        }
    }
}

/// 本地转写引擎的 Swift 封装（调用 C 桥接层）
enum LocalTranscriber {

    enum LocalTranscriptionError: LocalizedError {
        case modelNotFound(String)
        case bridgeFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let path):
                return "模型文件不存在：\(path)，请到设置中下载模型"
            case .bridgeFailed(let code):
                return "本地转写失败（错误码 \(code)）"
            }
        }
    }

    /// 从识别语言 locale 推导 Whisper 语言代码（"zh-CN" -> "zh"；"auto" -> 自动检测）
    static func whisperLanguage(fromLocale locale: String) -> String {
        if locale == "auto" { return "auto" }
        let code = Locale(identifier: locale).language.languageCode?.identifier ?? ""
        return code.isEmpty ? "auto" : code
    }

    /// SenseVoice 支持的语言（空串 = 自动检测）
    static func senseVoiceLanguage(fromLocale locale: String) -> String {
        if locale == "auto" { return "" }
        let code = Locale(identifier: locale).language.languageCode?.identifier ?? ""
        return ["zh", "en", "ja", "ko", "yue"].contains(code) ? code : ""
    }

    /// Whisper 转写（16kHz 单声道 PCM）
    static func transcribeWhisper(
        modelPath: String,
        language: String,
        samples: [Float]
    ) throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LocalTranscriptionError.modelNotFound(modelPath)
        }
        var out: UnsafeMutablePointer<CChar>?
        let rc = samples.withUnsafeBufferPointer { buffer -> Int32 in
            et_whisper_transcribe(
                modelPath,
                language,
                buffer.baseAddress,
                Int32(clamping: samples.count),
                &out
            )
        }
        guard rc == 0, let out else {
            throw LocalTranscriptionError.bridgeFailed(rc)
        }
        defer { et_free_string(out) }
        return String(cString: out)
    }

    /// SenseVoice 转写（16kHz 单声道 PCM；桥接层内部按 30s 分块）
    static func transcribeSenseVoice(
        modelPath: String,
        tokensPath: String,
        language: String,
        samples: [Float],
        sampleRate: Int32 = 16000
    ) throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LocalTranscriptionError.modelNotFound(modelPath)
        }
        guard FileManager.default.fileExists(atPath: tokensPath) else {
            throw LocalTranscriptionError.modelNotFound(tokensPath)
        }
        var out: UnsafeMutablePointer<CChar>?
        let rc = samples.withUnsafeBufferPointer { buffer -> Int32 in
            et_sensevoice_transcribe(
                modelPath,
                tokensPath,
                language,
                buffer.baseAddress,
                Int32(clamping: samples.count),
                sampleRate,
                &out
            )
        }
        guard rc == 0, let out else {
            throw LocalTranscriptionError.bridgeFailed(rc)
        }
        defer { et_free_string(out) }
        return String(cString: out)
    }
}

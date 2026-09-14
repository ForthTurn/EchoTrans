import Foundation

/// 转写引擎
enum TranscriptionEngine: String, Codable, CaseIterable, Identifiable {
    case apple       // 苹果系统 ASR（实时流式）
    case whisper     // whisper.cpp（本地，最终稿）
    case senseVoice  // sherpa-onnx SenseVoice（本地，最终稿）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "苹果系统识别"
        case .whisper: return "Whisper 本地转写"
        case .senseVoice: return "SenseVoice 本地转写"
        }
    }

    var isLocal: Bool { self != .apple }
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

    /// 从识别语言 locale 推导 Whisper 语言代码（"zh-CN" -> "zh"）
    static func whisperLanguage(fromLocale locale: String) -> String {
        let code = Locale(identifier: locale).language.languageCode?.identifier ?? ""
        return code.isEmpty ? "auto" : code
    }

    /// SenseVoice 支持的语言（空串 = 自动检测）
    static func senseVoiceLanguage(fromLocale locale: String) -> String {
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

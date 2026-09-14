import Foundation
import AVFoundation
import Speech

/// 基于 Apple Speech 框架的实时流式转写。
final class TranscriptionService {

    struct TranscriptionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// 转写结果回调：(文本, 是否最终结果)
    var onResult: ((String, Bool) -> Void)?

    /// 请求语音识别权限。
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// 开始一次转写会话。
    func start(localeIdentifier: String) throws {
        cancelTask()

        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError(message: "不支持该识别语言：\(localeIdentifier)")
        }
        guard recognizer.isAvailable else {
            throw TranscriptionError(message: "语音识别服务当前不可用，请检查网络或稍后重试")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        self.recognizer = recognizer
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.onResult?(result.bestTranscription.formattedString, result.isFinal)
            }
            if error != nil || result?.isFinal == true {
                self.task = nil
            }
        }
    }

    /// 追加一帧音频。
    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    /// 通知识别器音频输入结束，之后会收到最终结果。
    func endAudio() {
        request?.endAudio()
    }

    func cancelTask() {
        task?.cancel()
        task = nil
        request = nil
    }
}

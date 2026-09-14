import Foundation

/// 本地引擎模型下载管理：App 内一键下载 Whisper / SenseVoice 模型并解压到位。
/// 注意：非线程安全类，@Published 更新统一回主线程；下载/解压过程在 delegate 线程执行。
final class ModelManager: NSObject, ObservableObject {

    enum DownloadState: Equatable {
        case idle
        case downloading(progress: Double)
        case extracting
        case installed
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .extracting: return true
            default: return false
            }
        }
    }

    @Published private(set) var whisperState: DownloadState = .idle
    @Published private(set) var senseVoiceState: DownloadState = .idle

    private let settings: AppSettings
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var whisperTask: URLSessionDownloadTask?
    private var senseVoiceTask: URLSessionDownloadTask?

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    // MARK: - 安装状态

    var whisperBundled: Bool { settings.whisperBundled }
    var senseVoiceBundled: Bool { settings.senseVoiceBundled }

    var whisperInstalled: Bool {
        FileManager.default.fileExists(atPath: settings.effectiveWhisperModelPath)
    }

    var senseVoiceInstalled: Bool {
        FileManager.default.fileExists(atPath: settings.effectiveSenseVoiceModelPath)
            && FileManager.default.fileExists(atPath: settings.effectiveSenseVoiceTokensPath)
    }

    // MARK: - 下载入口

    private var hfBaseURL: String {
        settings.useHFMirror ? "https://hf-mirror.com" : "https://huggingface.co"
    }

    func downloadWhisperModel() {
        guard !whisperState.isBusy else { return }
        whisperError = nil
        whisperState = .downloading(progress: 0)
        let url = URL(string: "\(hfBaseURL)/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
        whisperTask = session.downloadTask(with: url)
        whisperTask?.taskDescription = "whisper"
        whisperTask?.resume()
    }

    func downloadSenseVoiceModel() {
        guard !senseVoiceState.isBusy else { return }
        senseVoiceError = nil
        senseVoiceState = .downloading(progress: 0)
        let url = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2")!
        senseVoiceTask = session.downloadTask(with: url)
        senseVoiceTask?.taskDescription = "sensevoice"
        senseVoiceTask?.resume()
    }

    private func installWhisper(from location: URL) throws {
        let dest = URL(fileURLWithPath: settings.whisperModelPath)
        let dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: location, to: dest)
    }

    /// SenseVoice 包是 tar.bz2，用系统 tar 解压出 model.int8.onnx 与 tokens.txt
    private func installSenseVoice(from location: URL) throws {
        let dir = URL(fileURLWithPath: settings.senseVoiceModelDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("echotrans-sensevoice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let archive = tmp.appendingPathComponent("model.tar.bz2")
        try FileManager.default.moveItem(at: location, to: archive)

        DispatchQueue.main.async { [weak self] in
            self?.senseVoiceState = .extracting
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", tmp.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ModelManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "模型包解压失败"])
        }

        let pkgDir = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .first { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("sherpa-onnx-sense-voice") }

        let model = pkgDir?.appendingPathComponent("model.int8.onnx")
        let tokens = pkgDir?.appendingPathComponent("tokens.txt")
        guard let model, let tokens,
              FileManager.default.fileExists(atPath: model.path),
              FileManager.default.fileExists(atPath: tokens.path) else {
            throw NSError(domain: "ModelManager", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "模型包内容异常"])
        }

        let destModel = dir.appendingPathComponent("model.int8.onnx")
        let destTokens = dir.appendingPathComponent("tokens.txt")
        for dest in [destModel, destTokens] where FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: model, to: destModel)
        try FileManager.default.moveItem(at: tokens, to: destTokens)
    }

    // MARK: - 状态展示辅助

    @Published var whisperError: String?
    @Published var senseVoiceError: String?

    func whisperProgress() -> Double? {
        if case .downloading(let p) = whisperState { return p }
        return nil
    }

    func senseVoiceProgress() -> Double? {
        if case .downloading(let p) = senseVoiceState { return p }
        return nil
    }

    func whisperStatusText() -> String {
        if whisperBundled { return "App 内置 ✓" }
        if whisperInstalled { return "已安装 ✓" }
        switch whisperState {
        case .idle: return "未安装"
        case .downloading(let p): return "下载中 \(Int(p * 100))%"
        case .extracting: return "解压中…"
        case .failed: return "下载失败"
        case .installed: return "已安装 ✓"
        }
    }

    func senseVoiceStatusText() -> String {
        if senseVoiceBundled { return "App 内置 ✓" }
        if senseVoiceInstalled { return "已安装 ✓" }
        switch senseVoiceState {
        case .idle: return "未安装"
        case .downloading(let p): return "下载中 \(Int(p * 100))%"
        case .extracting: return "解压中…"
        case .failed: return "下载失败"
        case .installed: return "已安装 ✓"
        }
    }
}

extension ModelManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(max(totalBytesExpectedToWrite, 1))
        let isWhisper = downloadTask.taskDescription == "whisper"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isWhisper {
                self.whisperState = .downloading(progress: progress)
            } else {
                self.senseVoiceState = .downloading(progress: progress)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let isWhisper = downloadTask.taskDescription == "whisper"
        do {
            if isWhisper {
                try installWhisper(from: location)
            } else {
                try installSenseVoice(from: location)
            }
            DispatchQueue.main.async { [weak self] in
                if isWhisper { self?.whisperState = .installed }
                else { self?.senseVoiceState = .installed }
            }
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in
                if isWhisper {
                    self?.whisperState = .failed(message)
                    self?.whisperError = message
                } else {
                    self?.senseVoiceState = .failed(message)
                    self?.senseVoiceError = message
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        let message = error.localizedDescription
        let isWhisper = task.taskDescription == "whisper"
        DispatchQueue.main.async { [weak self] in
            if isWhisper {
                self?.whisperState = .failed(message)
                self?.whisperError = message
            } else {
                self?.senseVoiceState = .failed(message)
                self?.senseVoiceError = message
            }
        }
    }
}

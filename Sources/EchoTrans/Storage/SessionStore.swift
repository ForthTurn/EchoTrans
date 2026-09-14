import Foundation

/// 管理会话目录与文字版文件的读写。
///
/// 目录结构：
/// ```
/// <root>/<yyyy-MM-dd HH-mm-ss>/
/// ├── transcript.txt          # 原始转写文字版
/// └── translations/
///     ├── English.md
///     └── 日本語.md
/// ```
struct SessionStore {

    struct Session {
        let url: URL
        let startedAt: Date
    }

    static var defaultRootDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("EchoTrans", isDirectory: true)
    }

    let rootDirectory: URL

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()

    func beginSession(startedAt: Date) throws -> Session {
        let url = rootDirectory.appendingPathComponent(
            Self.nameFormatter.string(from: startedAt),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Session(url: url, startedAt: startedAt)
    }

    @discardableResult
    func writeTranscript(_ text: String, session: Session) throws -> URL {
        let fileURL = session.url.appendingPathComponent("transcript.txt")
        try Data(text.utf8).write(to: fileURL, options: .atomic)
        return fileURL
    }

    @discardableResult
    func writeTranslation(_ text: String, language: String, session: Session) throws -> URL {
        let dir = session.url.appendingPathComponent("translations", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = language
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = dir.appendingPathComponent("\(safeName).md")
        try Data(text.utf8).write(to: fileURL, options: .atomic)
        return fileURL
    }
}

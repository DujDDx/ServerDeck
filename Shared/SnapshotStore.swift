import Foundation

/// 采集结果的落盘位置。
enum SnapshotStore {
    static let appFolderName = "ServerDeck"

    /// 主程序未启用沙盒，直接使用用户目录下的 Application Support。
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appFolderName, isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("snapshot.json") }

    /// ControlMaster socket 目录（无空格短路径，避免 ssh -o 解析问题）。
    static var sshDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent("ssh", isDirectory: true)
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func load() -> SnapshotFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(SnapshotFile.self, from: data)
    }

    static func save(_ file: SnapshotFile) {
        ensureDirectory()
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

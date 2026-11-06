import Foundation
import Darwin

/// A compare-and-swap write under an OS lock. A stale instance cannot replace
/// newer data; the previous committed bytes survive in a bounded backup set.
public final class ProtectedDatabaseFile {
    public enum Failure: LocalizedError {
        case conflict, lockUnavailable
        public var errorDescription: String? {
            switch self {
            case .conflict: "记录已被另一个实例修改，已阻止覆盖。请重新打开应用后再编辑。"
            case .lockUnavailable: "无法取得记录写入锁，已停止保存以保护原数据。"
            }
        }
    }
    public let url: URL
    private var expected: Data?

    public init(url: URL) throws {
        self.url = url
        expected = try Self.readIfPresent(url)
    }

    public func loadedData() -> Data? { expected }

    public func recoverIfNeeded(isValid: (Data) -> Bool) throws -> Data? {
        guard let damaged = expected, !isValid(damaged) else { return expected }
        let directory = url.deletingLastPathComponent()
        let backups = directory.appendingPathComponent("DatabaseBackups")
        let files = (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        for candidate in files.filter({ $0.lastPathComponent.hasPrefix("database-") && $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: candidate), isValid(data) else { continue }
            // Keep the unreadable original separately from the rotating backups.
            let quarantine = directory.appendingPathComponent("database-unreadable-\(UUID().uuidString).json")
            try damaged.write(to: quarantine, options: .atomic)
            try save(data)
            return data
        }
        return damaged // Caller reports the original decoding error, never a blank DB.
    }

    private static func readIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.lockUnavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.lockUnavailable }
        defer { flock(fd, LOCK_UN) }
        let current = try Self.readIfPresent(url)
        guard current == expected else { throw Failure.conflict }
        guard data != current else { return }
        let backups = directory.appendingPathComponent("DatabaseBackups", isDirectory: true)
        if let current {
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let name = "database-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"
            try current.write(to: backups.appendingPathComponent(name), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
        expected = data
        if let files = try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil) {
            let owned = files.filter { $0.lastPathComponent.hasPrefix("database-") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            // Only this class's backup generations are eligible for pruning.
            for old in owned.dropFirst(20) { try? fm.removeItem(at: old) }
        }
    }
}

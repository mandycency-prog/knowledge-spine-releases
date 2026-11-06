import Foundation
import Darwin

struct LocalProcessOutcome: Sendable {
    let status: Int32
    let tail: Data
    let timedOut: Bool
}

/// Output goes directly to a local log, not an unbounded in-memory pipe.
/// A stalled child cannot monopolize the final-processing queue indefinitely.
enum BoundedLocalProcess {
    static func run(executable: String, arguments: [String], environment: [String: String],
                    logURL: URL, timeout: TimeInterval,
                    cancelled: @Sendable () -> Bool = { false }) throws -> LocalProcessOutcome {
        // Keep an active local job out of App Nap / idle sleep, but do not
        // override an explicit sleep request or closing the laptop lid.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "正在本地处理课程内容")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = environment
        child.standardOutput = log; child.standardError = log
        let finished = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in finished.signal() }
        try child.run()
        let deadline = Date().addingTimeInterval(timeout)
        var expired = false
        while finished.wait(timeout: .now() + 0.1) == .timedOut {
            if cancelled() || Date() >= deadline {
                expired = Date() >= deadline
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                break
            }
        }
        child.waitUntilExit()
        try? log.synchronize()
        let reader = try FileHandle(forReadingFrom: logURL)
        defer { try? reader.close() }
        let end = try reader.seekToEnd()
        try reader.seek(toOffset: end > 8_000 ? end - 8_000 : 0)
        return LocalProcessOutcome(status: child.terminationStatus, tail: try reader.readToEnd() ?? Data(), timedOut: expired)
    }
}

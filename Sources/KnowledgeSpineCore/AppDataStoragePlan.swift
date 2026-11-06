import Foundation

/// Resolves persistent and disposable app storage before AppStore starts.
/// Demo data must never share a directory with the user's formal database.
public struct AppDataStoragePlan: Equatable, Sendable {
    public let inMemory: Bool
    public let dataRoot: URL

    public init(
        requestedInMemory: Bool,
        seedDemo: Bool,
        applicationSupportRoot: URL,
        temporaryRoot: URL,
        processIdentifier: Int32
    ) {
        inMemory = requestedInMemory || seedDemo
        if inMemory {
            let mode = seedDemo ? "Demo" : "Preview"
            dataRoot = temporaryRoot
                .appendingPathComponent("KnowledgeSpine-\(mode)-\(processIdentifier)", isDirectory: true)
        } else {
            dataRoot = applicationSupportRoot
                .appendingPathComponent("直播与课程知识骨架", isDirectory: true)
        }
    }
}

import Foundation
import KnowledgeSpineCore

/// Explicit diagnostic on a new disposable root. No UI, credentials or capture.
@MainActor enum DistributionSmokeTest {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--distribution-smoke-test") else { return }
        do {
            guard Bundle.main.object(forInfoDictionaryKey: "KnowledgeSpineDistributionPreview") as? Bool == true,
                  args.count > index + 1 else { throw CheckFailure.invalidBundle }
            let root = URL(fileURLWithPath: args[index + 1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
            guard root.deletingLastPathComponent().resolvingSymlinksInPath().path == parent.path,
                  root.lastPathComponent.hasPrefix("KnowledgeSpine-Distribution-"),
                  !FileManager.default.fileExists(atPath: root.path) else { throw CheckFailure.invalidRoot }
            let defaults = AppSettings()
            let resources = Bundle.main.resourceURL!.path + "/"
            guard [defaults.pythonPath, defaults.whisperModelPath, defaults.ffmpegPath].allSatisfy({
                $0.hasPrefix(resources) && FileManager.default.fileExists(atPath: $0)
            }) else { throw CheckFailure.missingRuntime }
            let first = AppStore(storageRoot: root)
            guard first.database.sessions.isEmpty, first.database.settings?.apiConfiguration == nil else { throw CheckFailure.nonempty }
            _ = first.createSession(title: "Synthetic portability test", sourceName: "Synthetic", sourceKind: "test")
            guard first.flush() else { throw CheckFailure.persistence }
            let second = AppStore(storageRoot: root)
            guard second.database.sessions.count == 1,
                  second.database.sessions[0].title == "Synthetic portability test" else { throw CheckFailure.persistence }
            let result: [String: Any] = ["emptyFirstLaunch": true, "persistence": true,
                "runtimeInsideBundle": true, "dataDirectory": PortableRuntime.dataDirectoryName,
                "databaseRoot": root.path, "bundleIdentifier": Bundle.main.bundleIdentifier ?? ""]
            let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(bytes + Data([10]))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Distribution smoke check failed: \(error)\n".utf8))
            exit(1)
        }
    }
    enum CheckFailure: Error { case invalidBundle, invalidRoot, missingRuntime, nonempty, persistence }
}

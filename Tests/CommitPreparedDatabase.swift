import Foundation
import KnowledgeSpineCore
import CryptoKit
import Darwin

/// A release-only compare-and-swap, not a processing or recovery shortcut.
/// The caller must first close the target app and pass the exact read-only
/// baseline plus the separately reviewed, audio-preserving prepared database.
@main enum CommitPreparedDatabase {
    struct Failure: Error, CustomStringConvertible { let message: String; var description: String { message } }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, args.allSatisfy({ $0.hasPrefix("/") }) else {
            throw Failure(message: "Explicit baseline, prepared, destination database paths required")
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build").standardizedFileURL.resolvingSymlinksInPath()
        let urls = args.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        let formal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("直播与课程知识骨架/database.json").resolvingSymlinksInPath()
        guard urls[0].path.hasPrefix(project.path + "/"), urls[1].path.hasPrefix(project.path + "/"),
              urls[2] == formal || (urls[2].path.hasPrefix(project.path + "/") && urls[2].lastPathComponent == "database.json"),
              urls[2] != urls[0], urls[2] != urls[1] else { throw Failure(message: "Refused path or overwrite scope") }
        let expected = try Data(contentsOf: urls[0]), prepared = try Data(contentsOf: urls[1])
        let receiptURL = urls[1].appendingPathExtension("receipt.json").resolvingSymlinksInPath()
        try require(receiptURL.path.hasPrefix(project.path + "/"), "Receipt outside project .build")
        guard let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any],
              let target = receipt["targetID"] as? String, UUID(uuidString: target) != nil else { throw Failure(message: "Missing/invalid bound receipt") }
        try require(receipt["schemaVersion"] as? Int == 1 && receipt["baselineSHA256"] as? String == digest(expected) && receipt["preparedSHA256"] as? String == digest(prepared), "Receipt hash mismatch")
        // Independently enforce the exact preparation whitelist at the raw JSON
        // layer, including unknown future fields. Never trust a hash alone.
        guard var baselineObject = try JSONSerialization.jsonObject(with: expected) as? [String: Any],
              let preparedObject = try JSONSerialization.jsonObject(with: prepared) as? [String: Any],
              var before = baselineObject["sessions"] as? [[String: Any]],
              let after = preparedObject["sessions"] as? [[String: Any]], !before.isEmpty, before.count == after.count else { throw Failure(message: "Empty or wrong database") }
        try require(Set(before.compactMap { $0["id"] as? String }).count == before.count && Set(after.compactMap { $0["id"] as? String }).count == after.count, "Duplicate/missing session IDs")
        guard let index = before.firstIndex(where: { ($0["id"] as? String)?.uppercased() == target.uppercased() }),
              (after[index]["id"] as? String)?.uppercased() == target.uppercased() else { throw Failure(message: "Receipt target not present at original position") }
        let allowed = ["nodes", "versions", "candidateVersions", "transcript", "speakers", "thoughts", "importantMarks", "pendingImportantTimes", "analysisWarnings", "updatedAt", "status", "structureSaved", "transcriptComplete", "recoveryPending", "processingRunLabel", "processingRetranscribe", "lastProcessingError"]
        for key in allowed { before[index][key] = after[index][key] }
        baselineObject["sessions"] = before
        try require(NSDictionary(dictionary: baselineObject).isEqual(to: preparedObject), "Prepared database changed settings/collections/other sessions or protected target metadata")
        let file = try ProtectedDatabaseFile(url: urls[2])
        guard file.loadedData() == expected else { throw Failure(message: "Live data changed: refused stale release overwrite") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let database = try decoder.decode(AppDatabase.self, from: prepared)
        for session in database.sessions {
            for node in session.nodes where !node.isDeleted { try IntegrityValidator.validateStoredNode(node, transcript: session.transcript) }
        }
        // ProtectedDatabaseFile obtains the app's lock, rechecks these exact
        // bytes under the lock, and keeps a previous-generation backup.
        try file.save(prepared)
        guard try Data(contentsOf: urls[2]) == prepared else { throw Failure(message: "Post-commit verification failed") }
        print("PASS: reviewed database committed under app lock/CAS; previous bytes backed up")
    }
}

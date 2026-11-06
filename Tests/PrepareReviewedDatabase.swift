import Foundation
import CryptoKit
import KnowledgeSpineCore
import Darwin

/// Prepares a full, audio-preserving release database only inside .build.
/// It never writes the live app's data directory. The installer must still
/// compare the live bytes with the baseline immediately before committing.
@main enum PrepareReviewedDatabase {
    struct Failure: Error, CustomStringConvertible { let message: String; var description: String { message } }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        try require(args.count == 4, "baseline.json reviewed-directory target-uuid new-output.json required")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build").standardizedFileURL.resolvingSymlinksInPath()
        func confined(_ path: String) throws -> URL {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            try require(path.hasPrefix("/") && url.path.hasPrefix(root.path + "/"), "Explicit project .build paths only")
            return url
        }
        let baselineURL = try confined(args[0]), reviewed = try confined(args[1]), output = try confined(args[3])
        let receiptURL = output.appendingPathExtension("receipt.json")
        try require(!FileManager.default.fileExists(atPath: output.path), "Refused output overwrite")
        try require(!FileManager.default.fileExists(atPath: receiptURL.path), "Refused receipt overwrite")
        guard let id = UUID(uuidString: args[2]) else { throw Failure(message: "Invalid target") }
        let baseline = try Data(contentsOf: baselineURL)
        let payloadData = try Data(contentsOf: confined(reviewed.appendingPathComponent("reviewed-map-payload.json").path))
        guard let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { throw Failure(message: "Invalid payload") }
        try require(payload["baselineDatabaseSHA256"] as? String == digest(baseline), "Reviewed source baseline mismatch")
        try require((payload["sessionID"] as? String)?.uppercased() == id.uuidString, "Reviewed target mismatch")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var database = try decoder.decode(AppDatabase.self, from: baseline)
        let resultDatabase = try decoder.decode(AppDatabase.self, from: Data(contentsOf: confined(reviewed.appendingPathComponent("database.json").path)))
        try require(!database.sessions.isEmpty && !resultDatabase.sessions.isEmpty, "Empty database refused")
        guard let index = database.sessions.firstIndex(where: { $0.id == id }),
              let processed = resultDatabase.sessions.first(where: { $0.id == id }) else { throw Failure(message: "Target missing") }
        let original = database.sessions[index]
        try require(payload["baselineSessionSHA256"] as? String == digest(try encoder.encode(original)), "Reviewed session mismatch")
        try require(payload["verifiedSessionSHA256"] as? String == digest(try encoder.encode(processed)), "Entire reviewed session changed after verification")
        func decodePayload<T: Decodable>(_ key: String, as type: T.Type) throws -> T {
            guard let value = payload[key] else { throw Failure(message: "Missing verified payload") }
            return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: value))
        }
        try require(processed.nodes == decodePayload("verifiedNodes", as: [KnowledgeNode].self), "Reviewed nodes changed")
        try require(processed.versions == decodePayload("verifiedVersions", as: [StructureSnapshot].self), "Reviewed versions changed")
        try require(processed.status == .ready && processed.structureSaved, "Map is not ready")
        for node in processed.nodes where !node.isDeleted { try IntegrityValidator.validateStoredNode(node, transcript: processed.transcript) }
        // Only the reviewed analysis state is adopted. In particular no audio
        // metadata, settings, collection membership, or other course is copied
        // from the intentionally audio-stripped test database.
        var target = original
        target.nodes = processed.nodes; target.versions = processed.versions
        target.candidateVersions = processed.candidateVersions
        target.transcript = processed.transcript; target.speakers = processed.speakers
        target.thoughts = processed.thoughts; target.importantMarks = processed.importantMarks
        target.pendingImportantTimes = processed.pendingImportantTimes
        target.analysisWarnings = processed.analysisWarnings; target.updatedAt = processed.updatedAt
        target.status = processed.status; target.structureSaved = processed.structureSaved
        target.transcriptComplete = processed.transcriptComplete
        target.recoveryPending = processed.recoveryPending
        target.processingRunLabel = processed.processingRunLabel
        target.processingRetranscribe = processed.processingRetranscribe
        target.lastProcessingError = processed.lastProcessingError
        database.sessions[index] = target
        try require(target.audioRelativePaths == original.audioRelativePaths && target.audioState == original.audioState && target.audioTrashedAt == original.audioTrashedAt, "Audio metadata changed")
        let data = try encoder.encode(database)
        _ = try decoder.decode(AppDatabase.self, from: data)
        let receipt: [String: Any] = ["schemaVersion": 1, "baselineSHA256": digest(baseline), "preparedSHA256": digest(data), "targetID": id.uuidString]
        let receiptData = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .atomic)
        try require(try Data(contentsOf: baselineURL) == baseline, "Source changed")
        try receiptData.write(to: receiptURL, options: .atomic)
        print("PASS: prepared reviewed database; original audio metadata/settings/other records preserved; live database NOT modified")
        print(output.path)
    }
}

import Foundation
import CryptoKit
import Darwin

@main enum ReviewedReleaseSafetyProbe {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var fm: FileManager { .default }
    static var build: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build").standardizedFileURL.resolvingSymlinksInPath() }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func json(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }
    static func data(_ json: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted]) }
    static func process(_ tool: String, _ args: [String], success: Bool) throws -> String {
        let p = Process(); p.executableURL = build.appendingPathComponent(tool); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
        try require((p.terminationStatus == 0) == success, "Unexpected exit \(p.terminationStatus) from \(tool): \(output)")
        return output
    }
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let generated = try process("apply-reviewed-map", ["--self-test"], success: true)
        guard let line = generated.split(separator: "\n").first(where: { $0.hasPrefix("Output: ") }) else { throw Failure(description: "Self-test output missing") }
        let reviewed = URL(fileURLWithPath: String(line.dropFirst(8))).standardizedFileURL.resolvingSymlinksInPath()
        try require(reviewed.path.hasPrefix(build.path + "/apply-reviewed-selftest-"), "Refused non-selftest source")
        let baseline = reviewed.deletingLastPathComponent().appendingPathComponent("source/database.json")
        let original = try Data(contentsOf: baseline)
        let source = try json(original)
        let target = (source["sessions"] as! [[String: Any]])[0]["id"] as! String
        let root = build.appendingPathComponent("reviewed-release-safety-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let prepared = root.appendingPathComponent("prepared.json"), destination = root.appendingPathComponent("database.json")
        _ = try process("prepare-reviewed-database", [baseline.path, reviewed.path, target, prepared.path], success: true)
        let preparedBytes = try Data(contentsOf: prepared)
        try original.write(to: destination)
        _ = try process("commit-prepared-database", [baseline.path, prepared.path, destination.path], success: true)
        try require(try Data(contentsOf: destination) == preparedBytes, "Positive commit failed")
        let stale = try process("commit-prepared-database", [baseline.path, prepared.path, destination.path], success: false)
        try require(stale.contains("stale release overwrite"), "Second old-baseline commit was not rejected by CAS")
        try require(try Data(contentsOf: destination) == preparedBytes, "Stale attempt changed output")
        let backups = try fm.contentsOfDirectory(at: root.appendingPathComponent("DatabaseBackups"), includingPropertiesForKeys: nil)
        try require(try backups.contains { try Data(contentsOf: $0) == original }, "Prior database bytes not backed up")

        // Tampering the reviewed thought while keeping nodes unchanged must
        // fail the complete reviewed-session hash before preparation.
        let tamperedReview = root.appendingPathComponent("tampered-review", isDirectory: true)
        try fm.createDirectory(at: tamperedReview, withIntermediateDirectories: false)
        var reviewJSON = try json(Data(contentsOf: reviewed.appendingPathComponent("database.json")))
        var rows = reviewJSON["sessions"] as! [[String: Any]], thoughts = rows[0]["thoughts"] as! [[String: Any]]
        thoughts[0]["text"] = "审核后改写的思考"; rows[0]["thoughts"] = thoughts; reviewJSON["sessions"] = rows
        try data(reviewJSON).write(to: tamperedReview.appendingPathComponent("database.json"))
        try fm.copyItem(at: reviewed.appendingPathComponent("reviewed-map-payload.json"), to: tamperedReview.appendingPathComponent("reviewed-map-payload.json"))
        let changed = try process("prepare-reviewed-database", [baseline.path, tamperedReview.path, target, root.appendingPathComponent("must-not-prepare.json").path], success: false)
        try require(changed.contains("Entire reviewed session changed"), "Reviewed thought tamper not caught by session hash")

        let negativeRoot = root.appendingPathComponent("negative", isDirectory: true)
        try fm.createDirectory(at: negativeRoot, withIntermediateDirectories: false)
        let untouched = negativeRoot.appendingPathComponent("database.json"); try original.write(to: untouched)
        let validReceipt = try Data(contentsOf: prepared.appendingPathExtension("receipt.json"))
        func rejected(_ name: String, altered: [String: Any], rebindReceipt: Bool = true, targetOverride: String? = nil, omitReceipt: Bool = false) throws {
            let file = negativeRoot.appendingPathComponent(name + ".json"), bytes = try data(altered)
            try bytes.write(to: file)
            if !omitReceipt {
                var receipt = try json(validReceipt)
                if rebindReceipt { receipt["preparedSHA256"] = hash(bytes) }
                if let targetOverride { receipt["targetID"] = targetOverride }
                try data(receipt).write(to: file.appendingPathExtension("receipt.json"))
            }
            _ = try process("commit-prepared-database", [baseline.path, file.path, untouched.path], success: false)
            try require(try Data(contentsOf: untouched) == original, "Rejected \(name) changed target")
        }
        let valid = try json(preparedBytes)
        var tampered = valid, tamperedRows = valid["sessions"] as! [[String: Any]]
        var tamperedThoughts = tamperedRows[0]["thoughts"] as! [[String: Any]]
        tamperedThoughts[0]["text"] = "准备后改写的思考"; tamperedRows[0]["thoughts"] = tamperedThoughts; tampered["sessions"] = tamperedRows
        try rejected("changed-thought", altered: tampered, rebindReceipt: false)
        var settings = valid; settings["settings"] = ["unexpected": "changed"]
        try rejected("changed-settings", altered: settings)
        var wrong = valid, wrongRows = valid["sessions"] as! [[String: Any]]
        wrongRows[0]["id"] = UUID().uuidString; wrong["sessions"] = wrongRows
        try rejected("wrong-database", altered: wrong)
        var empty = valid; empty["sessions"] = [[String: Any]]()
        try rejected("empty-database", altered: empty)
        var title = valid, titledRows = valid["sessions"] as! [[String: Any]]
        titledRows[0]["title"] = "未经许可改标题"; title["sessions"] = titledRows
        try rejected("changed-protected-title", altered: title)
        try rejected("wrong-target", altered: valid, targetOverride: UUID().uuidString)
        try rejected("missing-receipt", altered: valid, omitReceipt: true)
        try require(try Data(contentsOf: baseline) == original, "Source fixture changed")
        print("PASS: full reviewed-session tamper guard; bound receipt; independent protected-field checks; first CAS commit + backup; stale baseline refusal; changed thoughts/settings/title, wrong/empty database, wrong target and missing receipt all rejected without writes.")
        print("ISOLATED ONLY: \(root.path)\nReviewed fixture: \(reviewed.path)\nNo model, App, or formal database used.")
    }
}

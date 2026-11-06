import Foundation
import CryptoKit
import Darwin

/// Raw JSON preparation only: no AppStore, retention audit, model, or App.
@main enum PrepareAudioFreeFixture {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }
    static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        try require(args.count == 6, "--baseline ABS_BUILD_JSON --input-root ABS_NEW_BUILD_DIR --fixture-root ABS_NEW_BUILD_DIR required")
        var values: [String: String] = [:]
        for index in stride(from: 0, to: args.count, by: 2) {
            try require(values[args[index]] == nil, "Duplicate argument")
            values[args[index]] = args[index + 1]
        }
        try require(Set(values.keys) == Set(["--baseline", "--input-root", "--fixture-root"]), "Invalid arguments")
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let build = project.appendingPathComponent(".build").standardizedFileURL.resolvingSymlinksInPath()
        func confined(_ path: String) throws -> URL {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            try require(path.hasPrefix("/") && url.path.hasPrefix(build.path + "/"), "Explicit project .build paths only")
            return url
        }
        let baseline = try confined(values["--baseline"]!)
        let input = try confined(values["--input-root"]!)
        let fixture = try confined(values["--fixture-root"]!)
        try require(input != fixture && !input.path.hasPrefix(fixture.path + "/") && !fixture.path.hasPrefix(input.path + "/"), "Output roots must be distinct and non-nested")
        let fm = FileManager.default
        try require(!fm.fileExists(atPath: input.path) && !fm.fileExists(atPath: fixture.path), "Output exists; refusing overwrite")
        let bytes = try Data(contentsOf: baseline)
        guard let original = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let sessions = original["sessions"] as? [[String: Any]] else { throw Failure(description: "Invalid database JSON") }
        var prepared = original
        prepared["sessions"] = sessions.map { source in
            var copy = source; copy["audioRelativePaths"] = [String](); copy["audioState"] = "none"; return copy
        }
        let fixtureBytes = try JSONSerialization.data(withJSONObject: prepared, options: [.prettyPrinted, .sortedKeys])
        var checked = try JSONSerialization.jsonObject(with: fixtureBytes) as! [String: Any]
        var checkedSessions = checked["sessions"] as! [[String: Any]]
        try require(checkedSessions.allSatisfy { ($0["audioRelativePaths"] as? [String]) == [] && ($0["audioState"] as? String) == "none" }, "Audio stripping failed")
        for index in sessions.indices {
            checkedSessions[index]["audioRelativePaths"] = sessions[index]["audioRelativePaths"]
            checkedSessions[index]["audioState"] = sessions[index]["audioState"]
        }
        checked["sessions"] = checkedSessions
        try require(NSDictionary(dictionary: checked).isEqual(to: original), "A non-audio JSON field changed")
        // Both destinations were validated before creating either. This tool
        // intentionally never overwrites or removes a previous fixture.
        try fm.createDirectory(at: input, withIntermediateDirectories: false)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        try bytes.write(to: input.appendingPathComponent("database.json"), options: .atomic)
        try fixtureBytes.write(to: fixture.appendingPathComponent("database.json"), options: .atomic)
        try require(try Data(contentsOf: baseline) == bytes, "Source changed during preparation")
        try require(try Data(contentsOf: input.appendingPathComponent("database.json")) == bytes, "Input is not a byte-exact baseline copy")
        let report = "sourceSHA256=\(digest(bytes))\nfixtureSHA256=\(digest(fixtureBytes))\naudioPathCount=0\nallAudioStates=none\nsessionCount=\(sessions.count)\nnonAudioJSONFields=identical\ninputRoot=\(input.path)\nfixtureRoot=\(fixture.path)\nWARNING: fixture is audio-stripped, not a replacement for the formal database. Input root preserves original bytes for guarded review only. No AppStore/model/App started.\n"
        try Data(report.utf8).write(to: fixture.appendingPathComponent("fixture-verification.txt"), options: .atomic)
        print(report)
    }
}

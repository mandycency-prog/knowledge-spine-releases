import Foundation
import CryptoKit
import Darwin
import KnowledgeSpineCore

private struct ReviewFailure: Error, CustomStringConvertible { let description: String }

/// Deliberately excludes audio metadata, storage settings, and other sessions.
/// Consumers must compare baselineSessionSHA256 before using production APIs.
private struct ReviewedMapPayload: Codable {
    let schemaVersion: Int
    let sessionID: UUID
    let baselineDatabaseSHA256: String
    let baselineSessionSHA256: String
    let verifiedSessionSHA256: String
    let modelResult: LocalProcessingResult
    let verifiedNodes: [KnowledgeNode]
    let verifiedVersions: [StructureSnapshot]
    let verifiedCandidateVersions: [StructureSnapshot]
    let allowedMetadataNormalizations: [String]
    let instructions: String
}

@main struct ApplyReviewedMap {
    static var fm: FileManager { .default }
    static var projectRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() }
    static var buildRoot: URL { projectRoot.appendingPathComponent(".build").resolvingSymlinksInPath() }
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ReviewFailure(description: message) }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encoded<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }

    static func confined(_ path: String, newDirectory: Bool = false) throws -> URL {
        try require(path.hasPrefix("/"), "Paths must be explicit absolute paths")
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try require(url.path.hasPrefix(buildRoot.path + "/"), "Refused path outside this project's .build: \(path)")
        if newDirectory { try require(!fm.fileExists(atPath: url.path), "Output already exists; refusing overwrite: \(url.path)") }
        return url
    }

    @MainActor static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\nNo verified payload was issued; any partial output remains an isolated test artifact.\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--self-test"] { try selfTest(); return }
        try require(args.count == 8, "Usage: --source-root ABS_PROJECT_BUILD_DIR --result ABS_RESULT_JSON --session-id UUID --output-root ABS_NEW_PROJECT_BUILD_DIR; or --self-test")
        var values: [String: String] = [:]
        for index in stride(from: 0, to: args.count, by: 2) {
            try require(values[args[index]] == nil, "Duplicate argument")
            values[args[index]] = args[index + 1]
        }
        try require(Set(values.keys) == Set(["--source-root", "--result", "--session-id", "--output-root"]), "Unknown or missing argument")
        guard let id = UUID(uuidString: values["--session-id"]!) else { throw ReviewFailure(description: "Invalid session ID") }
        try apply(sourcePath: values["--source-root"]!, resultPath: values["--result"]!, sessionID: id, outputPath: values["--output-root"]!)
    }

    @MainActor static func apply(sourcePath: String, resultPath: String, sessionID: UUID, outputPath: String) throws {
        let source = try confined(sourcePath), resultURL = try confined(resultPath), output = try confined(outputPath, newDirectory: true)
        let sourceFile = try confined(source.appendingPathComponent("database.json").path)
        try require(!output.path.hasPrefix(source.path + "/"), "Output cannot be nested in the read-only source database root")
        let inputBytes = try Data(contentsOf: sourceFile)
        let input = try decoder.decode(AppDatabase.self, from: inputBytes)
        guard let original = input.sessions.first(where: { $0.id == sessionID }) else { throw ReviewFailure(description: "Target session not found") }
        try require(original.deletedAt == nil, "Refused deleted target")
        let result = try decoder.decode(LocalProcessingResult.self, from: Data(contentsOf: resultURL))
        try require(!result.candidates.isEmpty, "Model result has no candidates")
        try compareManuscript(original.transcript, result.spans)

        // AppStore initialization runs retention. Never open the source store;
        // no media is copied, and isolated stores cannot act on source audio.
        var isolated = input
        for index in isolated.sessions.indices {
            isolated.sessions[index].audioRelativePaths = []
            isolated.sessions[index].audioState = .none
        }
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        try encoded(isolated).write(to: output.appendingPathComponent("database.json"), options: .atomic)
        let store = AppStore(storageRoot: output)
        guard let before = store.database.sessions.first(where: { $0.id == sessionID }) else { throw ReviewFailure(description: "Isolated load lost target") }
        try comparePreserved(original, before)
        try require(store.completeLocalProcessing(result, sessionID: sessionID), "Production completion rejected result: \(store.statusMessage ?? "unknown")")
        if store.database.sessions.first(where: { $0.id == sessionID })?.candidateVersions?.last != nil {
            store.acceptLatestCandidate(sessionID: sessionID, arrangeAsNewMap: true)
        }
        store.finishProcessingAttempts(sessionID: sessionID)
        guard let processed = store.database.sessions.first(where: { $0.id == sessionID }) else { throw ReviewFailure(description: "Processed target missing") }
        try require(processed.status == .ready && processed.structureSaved, "Processing did not produce a ready map")
        try require(Set(result.candidates.map(\.nodeID)).isSubset(of: Set(processed.nodes.map(\.id))), "Reviewed candidate was not applied in full")
        try comparePreserved(original, processed)
        try require(processed.versions.contains { $0.nodes == before.nodes && $0.thoughts == before.thoughts && $0.transcript == before.transcript }, "Old complete map is not recoverable in a snapshot")
        for node in processed.nodes where !node.isDeleted { try IntegrityValidator.validateStoredNode(node, transcript: processed.transcript) }
        let navigationIDs = Set(result.candidates.filter { $0.navigationRoot == true }.map(\.nodeID))
        for node in processed.nodes where navigationIDs.contains(node.id) {
            try require(node.parentID == nil && node.aiSummary == nil && !node.isSecondaryEdit && node.manualRevisionAt == nil, "Navigation root became AI content or protected manual content")
        }
        let oldNavigationIDs = Set(before.nodes.filter {
            $0.parentID == nil && $0.kind != .thought && $0.importantMarkID == nil &&
            $0.userLabel == before.title && $0.aiSummary == nil && !$0.isSecondaryEdit && $0.manualRevisionAt == nil
        }.map(\.id)).subtracting(result.candidates.map(\.nodeID))
        try require(oldNavigationIDs.isDisjoint(with: processed.nodes.map(\.id)), "Old automatic navigation roots accumulated")
        try require(store.flush(), "Isolated write lock/CAS rejected save")
        let reopened = AppStore(storageRoot: output)
        guard let restarted = reopened.database.sessions.first(where: { $0.id == sessionID }) else { throw ReviewFailure(description: "Restart lost target") }
        try require(try encoded(processed) == encoded(restarted), "Restart changed processed session")

        // Undo runs on a second disposable copy, never the reviewed output.
        let undoRoot = output.appendingPathComponent("undo-check", isDirectory: true)
        try fm.createDirectory(at: undoRoot, withIntermediateDirectories: false)
        try fm.copyItem(at: output.appendingPathComponent("database.json"), to: undoRoot.appendingPathComponent("database.json"))
        let undoStore = AppStore(storageRoot: undoRoot)
        undoStore.restoreLatestVersion(sessionID: sessionID)
        guard let restored = undoStore.database.sessions.first(where: { $0.id == sessionID }) else { throw ReviewFailure(description: "Undo lost target") }
        try require(restored.nodes == before.nodes, "Undo did not restore the prior nodes")
        try comparePreserved(before, restored)
        try require(undoStore.flush(), "Undo save failed")
        let undoReopened = AppStore(storageRoot: undoRoot)
        try require(undoReopened.database.sessions.first(where: { $0.id == sessionID })?.nodes == before.nodes, "Undo did not persist")
        try require(try Data(contentsOf: sourceFile) == inputBytes, "Read-only source database changed during verification")

        let payload = ReviewedMapPayload(schemaVersion: 1, sessionID: sessionID,
            baselineDatabaseSHA256: digest(inputBytes), baselineSessionSHA256: digest(try encoded(original)), verifiedSessionSHA256: digest(try encoded(processed)), modelResult: result,
            verifiedNodes: processed.nodes, verifiedVersions: processed.versions, verifiedCandidateVersions: processed.candidateVersions ?? [],
            allowedMetadataNormalizations: try markNormalizations(original, processed) + ((original.pendingImportantTimes == nil && processed.pendingImportantTimes == []) ? ["pendingImportantTimes: nil → [] (empty intent unchanged)"] : []),
            instructions: "Proposal only. Re-check baselineSessionSHA256 against the live session before applying modelResult via AppStore APIs. Never replace a formal database with this directory/database.json: that test database intentionally strips audio paths. Audio/storage/other sessions are excluded from this payload. Any intervening user edits require revalidation.")
        try encoded(payload).write(to: output.appendingPathComponent("reviewed-map-payload.json"), options: .atomic)
        let normalizations = payload.allowedMetadataNormalizations.isEmpty ? "None" : payload.allowedMetadataNormalizations.joined(separator: "\n")
        let report = "PASS: original transcript IDs/text/corrections/times/speakers + thought identity/text/metadata and mark identity/source/protected ranges preserved; thought attachments may safely follow new nodes; old map snapshot; navigation root safety; persisted apply and isolated undo; source DB bytes unchanged.\nAllowed metadata normalization:\n\(normalizations)\nTest DB is AUDIO-STRIPPED and NOT production-ready. Use reviewed-map-payload.json only with baseline checks and authorized production APIs. No model or formal database opened.\n"
        try Data(report.utf8).write(to: output.appendingPathComponent("verification.txt"), options: .atomic)
        print(report + "Output: " + output.path)
    }

    static func compareManuscript(_ old: [TranscriptSpan], _ new: [TranscriptSpan]) throws {
        try require(old.count == new.count && Set(old.map(\.id)).count == old.count && Set(new.map(\.id)).count == new.count && Set(old.map(\.id)) == Set(new.map(\.id)), "Transcript source IDs/count changed or duplicated")
        let byID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        for span in old {
            guard let fresh = byID[span.id] else { throw ReviewFailure(description: "Missing transcript ID") }
            try require(span.originalText == fresh.originalText && span.correctedText == fresh.correctedText && span.startTime == fresh.startTime && span.endTime == fresh.endTime && span.sequence == fresh.sequence && span.speakerID == fresh.speakerID && span.origin == fresh.origin,
                        "Original manuscript text/correction/order/time changed at \(span.id)")
        }
        // Background classifications may legitimately change after review.
    }

    static func comparePreserved(_ old: SessionRecord, _ new: SessionRecord) throws {
        try compareManuscript(old.transcript, new.transcript)
        let oldThoughts = old.thoughts.map { thought in var copy = thought; copy.attachedNodeID = nil; return copy }.sorted { $0.id.uuidString < $1.id.uuidString }
        let newThoughts = new.thoughts.map { thought in var copy = thought; copy.attachedNodeID = nil; return copy }.sorted { $0.id.uuidString < $1.id.uuidString }
        try require(oldThoughts == newThoughts, "User thought IDs/text/createdAt/isSecondaryEdit/isDeleted/anchorTime changed")
        let activeNodeIDs = Set(new.nodes.filter { !$0.isDeleted }.map(\.id))
        for thought in new.thoughts where !thought.isDeleted {
            try require(thought.attachedNodeID == nil || activeNodeIDs.contains(thought.attachedNodeID!), "Thought attachment is dangling")
        }
        try require(old.speakers == new.speakers, "Speaker identity or names changed")
        _ = try markNormalizations(old, new)
        try require((old.pendingImportantTimes ?? []) == (new.pendingImportantTimes ?? []), "Pending important times changed")
    }

    static func markNormalizations(_ old: SessionRecord, _ new: SessionRecord) throws -> [String] {
        let previous = old.importantMarks ?? [], current = new.importantMarks ?? []
        try require(previous.count == current.count && Set(previous.map(\.id)) == Set(current.map(\.id)), "User mark IDs/count changed")
        var notes: [String] = []
        for mark in previous {
            guard var fresh = current.first(where: { $0.id == mark.id }) else { throw ReviewFailure(description: "Mark disappeared") }
            let resolvedTime = fresh.anchorTime
            if mark.anchorTime == nil, let time = fresh.anchorTime {
                guard let anchor = old.transcript.first(where: { $0.id == mark.anchorSpanID }) else { throw ReviewFailure(description: "Legacy mark has no existing anchor source") }
                try require(time == (anchor.startTime + anchor.endTime) / 2, "Legacy mark midpoint normalization deviated: \(mark.id)")
                notes.append("mark \(mark.id): anchorTime nil → \(time); original source interval [\(anchor.startTime), \(anchor.endTime)]; source/protected IDs unchanged")
                fresh.anchorTime = nil
            }
            if fresh.protectedSpanIDs != mark.protectedSpanIDs,
               mark.anchorTime == nil, let time = resolvedTime,
               let anchor = old.transcript.first(where: { $0.id == mark.anchorSpanID }) {
                let eligible = old.transcript.filter {
                    (!old.isMergedRecord && anchor.origin == nil) ||
                    ($0.origin?.sessionID == anchor.origin?.sessionID &&
                     ($0.origin?.authoredByUser == true) == (anchor.origin?.authoredByUser == true))
                }
                let expected = eligible.filter { $0.startTime <= time + 12 && $0.endTime >= time - 12 }.map(\.id)
                try require(fresh.anchorSpanID == mark.anchorSpanID && fresh.protectedSpanIDs == expected &&
                            Set(mark.protectedSpanIDs).isSubset(of: Set(fresh.protectedSpanIDs)),
                            "Legacy mark protection must be the exact same-source 12-second expansion, never shrink or reanchor")
                notes.append("mark \(mark.id): legacy protected range expands \(mark.protectedSpanIDs.count) → \(fresh.protectedSpanIDs.count) within ±12 seconds; all original IDs and anchor retained")
                fresh.protectedSpanIDs = mark.protectedSpanIDs
            }
            try require(mark == fresh, "User mark metadata/anchor/protected sources changed: \(mark.id); before=\(String(decoding: try encoded(mark), as: UTF8.self)); after=\(String(decoding: try encoded(fresh), as: UTF8.self))")
        }
        return notes
    }

    @MainActor static func selfTest() throws {
        let sandbox = buildRoot.appendingPathComponent("apply-reviewed-selftest-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: false)
        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        let speaker = Speaker(role: .host)
        let spans = (0..<4).map { TranscriptSpan(sequence: $0 + 1, startTime: Double($0 * 30), endTime: Double($0 * 30 + 20), speakerID: speaker.id, originalText: "合成验收原文 \($0)") }
        let node = KnowledgeNode(sourceSpanIDs: [spans[0].id], kind: .main, relation: .root, position: CanvasPoint(x: 200, y: 200), aiSummary: "旧概括")
        let thoughts = (0..<3).map { UserThought(text: "  原样思考 \($0)\n不更改。  ", attachedNodeID: node.id, isSecondaryEdit: true) }
        let mark = ImportantMark(anchorSpanID: spans[0].id, protectedSpanIDs: [spans[0].id])
        let session = SessionRecord(title: "合成检查", sourceName: "synthetic", sourceKind: "test", status: .ready, speakers: [speaker], transcript: spans, nodes: [node], thoughts: thoughts, transcriptComplete: true, structureSaved: true, importantMarks: [mark])
        try encoded(AppDatabase(sessions: [session])).write(to: source.appendingPathComponent("database.json"))
        var normalized = session
        normalized.importantMarks?[0].anchorTime = (spans[0].startTime + spans[0].endTime) / 2
        try require(try markNormalizations(session, normalized).count == 1, "Expected explicit legacy midpoint normalization")
        normalized.importantMarks?[0].anchorTime = 10.001
        do { _ = try markNormalizations(session, normalized); throw ReviewFailure(description: "Mark guard unexpectedly allowed a shifted timestamp") }
        catch let error as ReviewFailure { try require(!error.description.hasPrefix("Mark guard unexpectedly"), error.description) }
        var legacy = session
        let nearby = TranscriptSpan(sequence: 5, startTime: 19, endTime: 24, speakerID: speaker.id, originalText: "附近上下文")
        legacy.transcript.append(nearby)
        var expanded = legacy
        expanded.importantMarks?[0].anchorTime = 10
        expanded.importantMarks?[0].protectedSpanIDs = [spans[0].id, nearby.id]
        try require(try markNormalizations(legacy, expanded).count == 2, "Exact legacy context expansion should be recorded")
        for invalid in [[nearby.id], [spans[0].id, spans[3].id]] {
            expanded.importantMarks?[0].protectedSpanIDs = invalid
            do { _ = try markNormalizations(legacy, expanded); throw ReviewFailure(description: "Mark guard unexpectedly allowed shrinking/foreign expansion") }
            catch let error as ReviewFailure { try require(!error.description.hasPrefix("Mark guard unexpectedly"), error.description) }
        }
        var candidate = StructureCandidate(sourceSpanIDs: [spans[0].id], kind: .main, relation: .root, confidence: 1)
        candidate.navigationRoot = true
        let branch = StructureCandidate(sourceSpanIDs: [spans[1].id], kind: .branch, parentID: candidate.nodeID, relation: .child, confidence: 0.9, summary: "模拟审阅后的概括", coveredSourceSpanIDs: spans.map(\.id))
        let result = LocalProcessingResult(speakers: [speaker], spans: spans, candidates: [candidate, branch], warnings: [])
        let resultURL = sandbox.appendingPathComponent("result.json")
        try encoded(result).write(to: resultURL)
        var changedBackground = spans
        changedBackground[0].isBackgroundAudio = true
        try compareManuscript(spans, changedBackground)
        var changedWords = spans
        changedWords[0].originalText += "改字"
        do { try compareManuscript(spans, changedWords); throw ReviewFailure(description: "Word guard unexpectedly allowed a change") }
        catch let error as ReviewFailure { try require(!error.description.hasPrefix("Word guard unexpectedly"), error.description) }
        for invalid in ["/tmp/forbidden-map-output", buildRoot.path, source.path] {
            do { _ = try confined(invalid, newDirectory: true); throw ReviewFailure(description: "Path guard unexpectedly allowed \(invalid)") }
            catch let error as ReviewFailure { try require(!error.description.hasPrefix("Path guard unexpectedly"), error.description) }
        }
        try apply(sourcePath: source.path, resultPath: resultURL.path, sessionID: session.id, outputPath: sandbox.appendingPathComponent("reviewed").path)
        do { _ = try confined(sandbox.appendingPathComponent("reviewed").path, newDirectory: true); throw ReviewFailure(description: "Overwrite guard unexpectedly allowed reviewed output") }
        catch let error as ReviewFailure { try require(!error.description.hasPrefix("Overwrite guard unexpectedly"), error.description) }
        print("PASS: explicit path guards + synthetic three-thought apply/undo/restart self-test")
    }
}

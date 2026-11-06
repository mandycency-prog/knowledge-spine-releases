import Foundation
import KnowledgeSpineCore

/// Applies a real model result through production AppStore, but only to a new
/// disposable database with NO audio paths. It cannot write the source database.
@main struct DiscourseApplication {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("source-database result-json new-build-directory") }
        let source = URL(fileURLWithPath: args[1]).standardizedFileURL
        let resultURL = URL(fileURLWithPath: args[2]).standardizedFileURL
        let root = URL(fileURLWithPath: args[3]).standardizedFileURL
        let build = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/").standardizedFileURL
        precondition(root.path.hasPrefix(build.path + "/") && !FileManager.default.fileExists(atPath: root.path))
        let beforeBytes = try Data(contentsOf: source)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var db = try decoder.decode(AppDatabase.self, from: beforeBytes)
        let result = try decoder.decode(LocalProcessingResult.self, from: Data(contentsOf: resultURL))
        let candidateSources = Set(result.candidates.flatMap(\.sourceSpanIDs))
        guard candidateSources.isSubset(of: Set(result.spans.map(\.id))),
              let chosen = db.sessions.first(where: { candidateSources.isSubset(of: Set($0.transcript.map(\.id))) }) ?? (db.sessions.count == 1 ? db.sessions.first : nil) else {
            fatalError("No matching source session")
        }
        precondition(!result.candidates.isEmpty && result.candidates.count <= 8)
        db.sessions = [chosen]
        db.sessions[0].audioRelativePaths = []; db.sessions[0].audioState = .none
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try encoder.encode(db).write(to: root.appendingPathComponent("database.json"), options: .atomic)
        let store = AppStore(storageRoot: root)
        precondition(store.dataRoot == root && !store.isEphemeral)
        store.completeLocalProcessing(result, sessionID: chosen.id, reportIssues: false)
        precondition(store.database.sessions[0].status == .ready, "Real model result rejected by AppStore")
        precondition(store.database.sessions[0].candidateVersions?.isEmpty == false)
        precondition(store.database.sessions[0].transcript == chosen.transcript, "Candidate generation replaced the current manuscript")
        store.acceptLatestCandidate(sessionID: chosen.id, arrangeAsNewMap: true)
        precondition(store.flush())
        let reopened = AppStore(storageRoot: root)
        let saved = reopened.database.sessions[0]
        let active = saved.nodes.filter { !$0.isDeleted }
        let ids = Set(active.map(\.id))
        precondition(active.filter { $0.parentID == nil }.count == 1, "New map layout split into unrelated roots")
        let priorLayout = saved.versions.last { $0.reason == "接受候选版本前" }!
        precondition(saved.transcript.map(\.originalText) == result.spans.sorted { $0.sequence < $1.sequence }.map(\.originalText), "Accepted recognition text was rewritten")
        precondition(priorLayout.transcript?.map(\.originalText) == chosen.transcript.map(\.originalText), "Original transcript missing from version history")
        precondition(Dictionary(uniqueKeysWithValues: chosen.thoughts.map { ($0.id, $0.text) }) ==
                     Dictionary(uniqueKeysWithValues: saved.thoughts.map { ($0.id, $0.text) }))
        precondition(Set((chosen.importantMarks ?? []).map(\.id)) == Set((saved.importantMarks ?? []).map(\.id)))
        for node in chosen.nodes where !node.isDeleted && node.manualRevisionAt != nil {
            precondition(ids.contains(node.id), "Authored node lost")
            precondition(priorLayout.nodes.contains { $0.id == node.id && $0.position == node.position }, "Authored original position missing from undo history")
            if node.sourceSpanIDs.contains(where: { oldID in !saved.transcript.contains { $0.id == oldID } }) {
                let retained = active.first { $0.id == node.id }!
                let archive = retained.archivedSourceSpans ?? []
                for oldID in node.sourceSpanIDs {
                    if let span = chosen.transcript.first(where: { $0.id == oldID }) {
                        precondition(archive.contains { $0.id == oldID && $0.originalText == span.originalText && $0.correctedText == span.correctedText }, "Authored source evidence was not archived")
                    }
                }
            }
        }
        for node in active {
            try IntegrityValidator.validateStoredNode(node, transcript: saved.transcript)
            precondition(node.parentID == nil || ids.contains(node.parentID!))
        }
        for thought in saved.thoughts where !thought.isDeleted {
            let node = active.first { $0.thoughtID == thought.id }!
            precondition(AnnotationPresentation.thoughts(for: node, in: saved).contains { $0.id == thought.id && $0.text == thought.text })
        }
        let markdown = ExportService.makeKnowledgeMarkdown(session: saved, speakerName: { reopened.speakerName($0, in: saved) })
        try markdown.write(to: root.appendingPathComponent("知识骨架.md"), atomically: true, encoding: .utf8)
        let afterBytes = try Data(contentsOf: source)
        precondition(afterBytes == beforeBytes, "Source database changed")
        let report: [String: Any] = ["modelNodes": result.candidates.count, "visibleNodesWithUserEdits": active.count,
            "transcriptCount": saved.transcript.count, "thoughtCount": saved.thoughts.count,
            "importantMarkCount": saved.importantMarks?.count ?? 0, "sourceDatabaseUnchanged": true,
            "restartChecked": true, "uiChecked": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("acceptance-report.json"))
        print("PASS: isolated real-result application, authored notes/marks preserved, exact manuscript, restart and export; UI still required")
        print(root.path)
    }
}

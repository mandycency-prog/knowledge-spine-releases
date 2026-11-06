import Foundation
import KnowledgeSpineCore

@main struct SemanticRoleProbe {
    @MainActor static func main() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let speaker = Speaker(role: .host, displayName: "合成讲师")
        let spans = [TranscriptSpan(sequence: 1, startTime: 0, endTime: 20, speakerID: speaker.id, originalText: "先理解问题，再选择容易开始的小行动。"),
                     TranscriptSpan(sequence: 2, startTime: 20, endTime: 40, speakerID: speaker.id, originalText: "行动以后，用自己的例子检查理解。")]
        let legacy = StructureCandidate(sourceSpanIDs: [spans[0].id], kind: .main, relation: .root, confidence: 1, summary: "旧版未分类主题")
        let decodedLegacy = try decoder.decode(StructureCandidate.self, from: encoder.encode(legacy))
        precondition(decodedLegacy.semanticRole == nil)
        let legacyNode = KnowledgeNode(sourceSpanIDs: [spans[0].id], kind: .main, relation: .root, position: CanvasPoint(x: 0, y: 0))
        let decodedLegacyNode = try decoder.decode(KnowledgeNode.self, from: encoder.encode(legacyNode))
        precondition(decodedLegacyNode.semanticRole == nil)
        var invalidJSON = try JSONSerialization.jsonObject(with: encoder.encode(legacy)) as! [String: Any]
        invalidJSON["semanticRole"] = "unsupported-role"
        do { _ = try decoder.decode(StructureCandidate.self, from: JSONSerialization.data(withJSONObject: invalidJSON)); preconditionFailure("Unknown semantic role accepted") }
        catch is DecodingError { }
        func candidates(_ title: String) -> [StructureCandidate] {
            let root = StructureCandidate(sourceSpanIDs: spans.map(\.id), kind: .main, relation: .root, confidence: 1,
                                          summary: title, argumentSummary: "", semanticRole: .topic)
            let child = StructureCandidate(sourceSpanIDs: [spans[1].id], kind: .main, parentID: root.nodeID, relation: .child,
                                           confidence: 1, summary: "行动后检查理解", argumentSummary: "用自己的例子复述能帮助发现理解缺口。", semanticRole: .assertion)
            return [root, child]
        }
        let initial = candidates("合成主题：理解、行动与检查")
        try IntegrityValidator.validate(candidates: initial, transcript: spans)
        let decodedTopic = try decoder.decode(StructureCandidate.self, from: encoder.encode(initial[0]))
        precondition(decodedTopic.semanticRole == .topic)
        var badChild = initial
        badChild[1].semanticRole = .topic; badChild[1].argumentSummary = ""
        do { try IntegrityValidator.validate(candidates: badChild, transcript: spans); preconditionFailure("Child topic accepted") }
        catch IntegrityViolation.invalidSemanticRole { }
        var badArgument = initial
        badArgument[0].argumentSummary = "主题不应携带这个论断"
        do { try IntegrityValidator.validate(candidates: badArgument, transcript: spans); preconditionFailure("Topic argument accepted") }
        catch IntegrityViolation.invalidSemanticRole { }
        var badRelation = initial
        badRelation[0].relation = .child
        do { try IntegrityValidator.validate(candidates: badRelation, transcript: spans); preconditionFailure("Non-root relation topic accepted") }
        catch IntegrityViolation.invalidSemanticRole { }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/semantic-role-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let session = SessionRecord(title: "合成语义角色验收", sourceName: "合成，无音频", sourceKind: "test", status: .failed,
                                    speakers: [speaker], transcript: spans, transcriptComplete: true)
        try encoder.encode(AppDatabase(sessions: [session])).write(to: root.appendingPathComponent("database.json"))
        let store = AppStore(storageRoot: root)
        precondition(store.completeLocalProcessing(LocalProcessingResult(speakers: [speaker], spans: spans, candidates: initial, warnings: []), sessionID: session.id))
        precondition(store.database.sessions[0].nodes.first { $0.id == initial[0].nodeID }?.semanticRole == .topic)
        let updated = candidates("合成新版主题：把理解变成可检查的行动")
        precondition(store.completeLocalProcessing(LocalProcessingResult(speakers: [speaker], spans: spans, candidates: updated, warnings: []), sessionID: session.id))
        precondition(store.database.sessions[0].candidateVersions?.last?.nodes.first { $0.id == updated[0].nodeID }?.semanticRole == .topic)
        store.acceptLatestCandidate(sessionID: session.id, arrangeAsNewMap: true)
        precondition(store.flush())
        let reopened = AppStore(storageRoot: root)
        let saved = reopened.database.sessions[0]
        precondition(saved.nodes.first { $0.id == updated[0].nodeID }?.semanticRole == .topic)
        precondition(saved.nodes.first { $0.id == updated[1].nodeID }?.semanticRole == .assertion)
        precondition(saved.versions.last?.nodes.first { $0.id == initial[0].nodeID }?.semanticRole == .topic)
        let markdown = ExportService.makeKnowledgeMarkdown(session: saved, speakerName: { _ in "合成讲师" })
        precondition(markdown.contains(updated[0].summary!) && markdown.contains(updated[1].summary!))
        let mergedID = reopened.createMergedRecord(title: "合成复制", sourceSessionIDs: [session.id])!
        let merged = reopened.database.sessions.first { $0.id == mergedID }!
        precondition(merged.nodes.contains { $0.semanticRole == .topic && $0.aiSummary == updated[0].summary })
        precondition(merged.nodes.contains { $0.semanticRole == .assertion && $0.aiSummary == updated[1].summary })
        let retainedTopic = merged.nodes.first { $0.semanticRole == .topic }!
        reopened.updateNodePosition(retainedTopic.id, point: CanvasPoint(x: 900, y: 600), sessionID: mergedID)
        let third = candidates("合成第三版主题")
        precondition(reopened.completeLocalProcessing(LocalProcessingResult(speakers: [speaker], spans: spans, candidates: third, warnings: []), sessionID: mergedID))
        reopened.acceptLatestCandidate(sessionID: mergedID, arrangeAsNewMap: true)
        let demoted = reopened.database.sessions.first { $0.id == mergedID }!.nodes.first { $0.id == retainedTopic.id }!
        precondition(demoted.parentID != nil && demoted.semanticRole == nil && demoted.aiSummary == retainedTopic.aiSummary,
                     "A manually retained old topic below the new topic keeps its words, not a false topic/assertion classification")
        reopened.updateNodePosition(updated[0].nodeID, point: CanvasPoint(x: 800, y: 700), sessionID: session.id)
        precondition(reopened.database.sessions[0].nodes.first { $0.id == updated[0].nodeID }?.semanticRole == .topic, "Dragging is not a semantic edit")
        reopened.renameNode(updated[0].nodeID, label: "用户自己改的标题", sessionID: session.id)
        let renamed = reopened.database.sessions[0].nodes.first { $0.id == updated[0].nodeID }!
        precondition(renamed.semanticRole == nil && renamed.aiSummary == updated[0].summary && renamed.sourceSpanIDs == updated[0].sourceSpanIDs)
        reopened.addUserNode("用户原样正文", kind: .main, parentID: updated[0].nodeID, sessionID: session.id)
        precondition(reopened.database.sessions[0].nodes.last?.semanticRole == nil && reopened.database.sessions[0].nodes.last?.userEditedText == "用户原样正文")
        reopened.splitNodeBySource(third[0].nodeID, sessionID: mergedID)
        precondition(reopened.database.sessions.first { $0.id == mergedID }!.nodes.allSatisfy { $0.semanticRole != .topic })
        let invalidStored = KnowledgeNode(sourceSpanIDs: [spans[0].id], kind: .main, parentID: UUID(), relation: .child,
                                         position: CanvasPoint(x: 0, y: 0), aiSummary: "错误子主题", semanticRole: .topic)
        do { try IntegrityValidator.validateStoredNode(invalidStored, transcript: spans); preconditionFailure("Stored child topic accepted") }
        catch IntegrityViolation.invalidSemanticRole { }
        print("PASS: legacy nil/new roles/invalid roles, topic shape validation, candidate acceptance/history/restart, copy merge/export, coordinate retention and authored edits preserve words without model-role labels.")
        print("No formal data, app launch, audio, model or GUI test. Isolated output: \(root.path)")
    }
}

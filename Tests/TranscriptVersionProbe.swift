import Foundation
import KnowledgeSpineCore

@main struct TranscriptVersionProbe {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KnowledgeSpine-TranscriptVersions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let speaker = Speaker(role: .host, displayName: "用户命名")
        let old: [TranscriptSpan] = (0..<438).map { index -> TranscriptSpan in
            let correction: String? = index == 31 ? "用户逐字修正，不能丢失" : nil
            return TranscriptSpan(sequence: index + 1, startTime: Double(index) * 3, endTime: Double(index + 1) * 3,
                           speakerID: speaker.id, originalText: "旧原文\(index)", correctedText: correction, isImportant: index == 31)
        }
        let first = KnowledgeNode(sourceSpanIDs: [old[0].id], kind: .main, relation: .root, position: CanvasPoint(x: 100, y: 100))
        let manual = KnowledgeNode(sourceSpanIDs: [old[31].id], kind: .branch, parentID: first.id, relation: .child,
                                   position: CanvasPoint(x: 777, y: 888), userEditedText: "  我的编辑\n保持原样  ",
                                   isSecondaryEdit: true, manualRevisionAt: Date(), coveredSourceSpanIDs: [old[31].id])
        let thought = UserThought(text: "  我的思考\n原样保留  ", attachedNodeID: manual.id, isSecondaryEdit: true, anchorTime: 95)
        let mark = ImportantMark(anchorSpanID: old[31].id, protectedSpanIDs: [old[31].id])
        let session = SessionRecord(title: "隔离版本验收", sourceName: "合成", sourceKind: "test", status: .ready,
                                    speakers: [speaker], transcript: old, nodes: [first, manual], thoughts: [thought],
                                    transcriptComplete: true, structureSaved: true,
                                    candidateVersions: [StructureSnapshot(reason: "旧版仅节点候选", nodes: [first], thoughts: [])],
                                    importantMarks: [mark])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try encoder.encode(AppDatabase(sessions: [session])).write(to: root.appendingPathComponent("database.json"))
        let store = AppStore(storageRoot: root)
        let before = store.database.sessions[0]
        let newSpeaker = Speaker(role: .host)
        let fresh = (0..<140).map { index in
            TranscriptSpan(sequence: index + 1, startTime: Double(index) * 10, endTime: Double(index + 1) * 10,
                           speakerID: newSpeaker.id, originalText: "新识别原文\(index)")
        }
        let candidate = StructureCandidate(sourceSpanIDs: [fresh[9].id], kind: .main, relation: .root, confidence: 0.9, summary: "讲述思路")
        let result = LocalProcessingResult(speakers: [newSpeaker], spans: fresh, candidates: [candidate], warnings: ["3条内容尚未能安全概括"],
                                           annotationSummaries: [AnnotationSummary(id: thought.id, summary: "独立的思考概括")],
                                           annotationInputs: AnnotationInput.from(before))
        precondition(store.completeLocalProcessing(result, sessionID: session.id))
        let pending = store.database.sessions[0]
        precondition(pending.transcript == before.transcript && pending.nodes == before.nodes && pending.thoughts == before.thoughts)
        precondition(pending.importantMarks == before.importantMarks && pending.speakers == before.speakers)
        precondition(pending.candidateVersions?.last?.transcript?.count == 140)
        precondition(pending.candidateVersions?.last?.analysisWarnings == result.warnings && pending.analysisWarnings == before.analysisWarnings)
        precondition(pending.candidateVersions?.last?.transcript?.allSatisfy { $0.correctedText == nil } == true)
        store.acceptLatestCandidate(sessionID: session.id, arrangeAsNewMap: true)
        let accepted = store.database.sessions[0]
        precondition(accepted.analysisWarnings == result.warnings)
        store.acceptLatestCandidate(sessionID: session.id)
        precondition(store.database.sessions[0] == accepted, "Legacy candidate with missing source IDs must not apply")
        precondition(accepted.transcript.count == 140, "Must not append old transcript to new continuous manuscript")
        let kept = accepted.nodes.first { $0.id == manual.id }!
        precondition(kept.userEditedText == manual.userEditedText)
        precondition(kept.archivedSourceSpans?.first?.originalText == old[31].originalText)
        precondition(kept.archivedSourceSpans?.first?.correctedText == old[31].correctedText)
        let activeIDs = Set(accepted.nodes.filter { !$0.isDeleted }.map(\.id))
        for node in accepted.nodes where !node.isDeleted {
            try IntegrityValidator.validateStoredNode(node, transcript: accepted.transcript)
            precondition(Set(node.sourceSpanIDs + (node.coveredSourceSpanIDs ?? [])).isSubset(of: Set(accepted.transcript.map(\.id))))
            precondition(node.parentID == nil || activeIDs.contains(node.parentID!))
        }
        precondition(accepted.thoughts.first?.text == thought.text)
        precondition(accepted.nodes.first { $0.thoughtID == thought.id }?.aiSummary == "独立的思考概括")
        precondition(Set(accepted.transcript.map(\.id)).contains(accepted.importantMarks!.first!.anchorSpanID))
        precondition(store.flush())
        let reopened = AppStore(storageRoot: root)
        precondition(reopened.database.sessions[0].nodes.first { $0.id == manual.id }?.archivedSourceSpans == kept.archivedSourceSpans)
        reopened.restoreLatestVersion(sessionID: session.id)
        let restored = reopened.database.sessions[0]
        precondition(restored.analysisWarnings?.isEmpty == true)
        precondition(restored.transcript == before.transcript && restored.speakers == before.speakers)
        precondition(restored.nodes == before.nodes && restored.thoughts == before.thoughts && restored.importantMarks == before.importantMarks)
        let failed = LocalProcessingResult(speakers: [newSpeaker], spans: fresh, candidates: [], warnings: ["验收失败"])
        precondition(!reopened.completeLocalProcessing(failed, sessionID: session.id))
        precondition(reopened.database.sessions[0].transcript == restored.transcript && reopened.database.sessions[0].nodes == restored.nodes)
        precondition(reopened.completeLocalProcessing(result, sessionID: session.id))
        reopened.toggleImportant(spanID: old[31].id, sessionID: session.id)
        reopened.renameSpeaker(speaker.id, to: "分析期间改的名字", sessionID: session.id)
        reopened.acceptLatestCandidate(sessionID: session.id)
        precondition(reopened.database.sessions[0].importantMarks?.isEmpty == true)
        precondition(!reopened.database.sessions[0].transcript.contains { $0.isImportant })
        precondition(reopened.database.sessions[0].speakers.first?.displayName == "分析期间改的名字")
        precondition(reopened.flush())
        let again = AppStore(storageRoot: root)
        precondition(!again.database.sessions[0].transcript.contains { $0.isImportant })
        precondition(again.database.sessions[0].speakers.first?.displayName == "分析期间改的名字")
        // Legacy JSON omitted every new field; it must remain decodable.
        let legacy = StructureSnapshot(reason: "旧版本", nodes: [manual], thoughts: [thought])
        let decoded = try decoder.decode(StructureSnapshot.self, from: encoder.encode(legacy))
        precondition(decoded.transcript == nil && decoded.nodes.first?.id == manual.id && decoded.nodes.first?.userEditedText == manual.userEditedText)
        print("PASS: 438→140 full-candidate isolation, source/correction preservation, single manuscript, marks/thoughts, accept/restart/undo, safe rejection, legacy decode")
        print(root.path)
    }
}

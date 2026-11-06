import Foundation
import KnowledgeSpineCore

@main struct IntegrationFlowProbe {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KnowledgeSpine-IntegrationFlow-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        func bytes<T: Encodable>(_ value: T) -> Data { try! encoder.encode(value) }
        let host = Speaker(role: .host, displayName: "合成讲者")
        func span(_ text: String, sequence: Int) -> TranscriptSpan {
            TranscriptSpan(sequence: sequence, startTime: Double(sequence * 100), endTime: Double(sequence * 100 + 20), speakerID: host.id, originalText: text)
        }
        let wholeSpans = [span("整课原文：先明确问题。", sequence: 1), span("尚未进入原图的有意义原文，整课选择不能漏掉。", sequence: 2)]
        let wholeNode = KnowledgeNode(sourceSpanIDs: [wholeSpans[0].id], kind: .main, relation: .root, position: CanvasPoint(x: 200, y: 180), aiSummary: "已有概括")
        let thought = UserThought(text: "  我的原样思考\n不能替换我的措辞。  ", attachedNodeID: wholeNode.id, isSecondaryEdit: true)
        let mark = ImportantMark(anchorSpanID: wholeSpans[0].id, protectedSpanIDs: [wholeSpans[0].id])
        let whole = SessionRecord(title: "合成整课", sourceName: "synthetic", sourceKind: "test", status: .ready,
            speakers: [host], transcript: wholeSpans, nodes: [wholeNode], thoughts: [thought], transcriptComplete: true, structureSaved: true, importantMarks: [mark])
        let partialSpans = [span("选中主题原文。", sequence: 1), span("选中主题的下级证据。", sequence: 2), span("未选的另一主题，不能混入材料。", sequence: 3)]
        let topic = KnowledgeNode(sourceSpanIDs: [partialSpans[0].id], kind: .main, relation: .root, position: CanvasPoint(x: 200, y: 180), aiSummary: "已有主题概括")
        let child = KnowledgeNode(sourceSpanIDs: [partialSpans[1].id], kind: .evidence, parentID: topic.id, relation: .child, position: CanvasPoint(x: 600, y: 180))
        let unrelated = KnowledgeNode(sourceSpanIDs: [partialSpans[2].id], kind: .main, relation: .root, position: CanvasPoint(x: 200, y: 600))
        let partial = SessionRecord(title: "合成部分课程", sourceName: "synthetic", sourceKind: "test", status: .ready, speakers: [host], transcript: partialSpans,
            nodes: [topic, child, unrelated], transcriptComplete: true, structureSaved: true)
        let authoredTitle = "手工标题：保留限定条件"
        let authoredBody = "  用户写的正文\n不可把 AI 的说法冒充这段原文。  "
        let authored = KnowledgeNode(sourceSpanIDs: [], kind: .main, relation: .root, position: CanvasPoint(x: 200, y: 180), userEditedText: authoredBody,
            isSecondaryEdit: true, userLabel: authoredTitle, aiSummary: "AI摘要绝不能变成原话")
        let aiOnly = KnowledgeNode(sourceSpanIDs: [], kind: .branch, parentID: authored.id, relation: .child, position: CanvasPoint(x: 600, y: 180), aiSummary: "只有AI摘要，不存在人工原文")
        let manual = SessionRecord(title: "合成 Markdown 手工图", sourceName: "synthetic", sourceKind: "Markdown", status: .ready, nodes: [authored, aiOnly], structureSaved: true)
        try encoder.encode(AppDatabase(sessions: [whole, partial, manual])).write(to: root.appendingPathComponent("database.json"), options: .atomic)

        let store = AppStore(storageRoot: root)
        let sourceIDs = Set([whole.id, partial.id, manual.id])
        let sourceBytes = try encoder.encode(store.database.sessions.filter { sourceIDs.contains($0.id) })
        let id = store.createIntegrationRecord(title: "合成专题验收", wholeSessionIDs: [whole.id, manual.id], topicNodeIDs: [topic.id, child.id])!
        func current() -> SessionRecord { store.database.sessions.first { $0.id == id }! }
        let draft = current()
        precondition(draft.status == .draft && !draft.structureSaved && draft.isMergedRecord)
        precondition(draft.nodes.allSatisfy { $0.kind == .thought || $0.thoughtID != nil || $0.importantMarkID != nil }, "New topic must not copy the old sentence map onto its canvas")
        precondition(draft.nodes.allSatisfy { $0.positionEditedAt == nil && $0.positionIsAutomatic == true }, "A new topic must lay out its carried annotations independently of the original map")
        precondition(draft.transcript.contains { $0.originalText == wholeSpans[1].originalText && $0.origin?.itemID == wholeSpans[1].id })
        precondition(draft.transcript.contains { $0.origin?.itemID == partialSpans[0].id } && draft.transcript.contains { $0.origin?.itemID == partialSpans[1].id })
        precondition(!draft.transcript.contains { $0.origin?.itemID == partialSpans[2].id || $0.originalText == partialSpans[2].originalText })
        let written = draft.transcript.first { $0.origin?.sessionID == manual.id && $0.origin?.itemID == authored.id }!
        precondition(written.originalText == authoredTitle + "\n" + authoredBody)
        precondition(!draft.transcript.contains { $0.originalText.contains("AI摘要绝不能变成原话") || $0.originalText.contains("只有AI摘要") })
        precondition(draft.thoughts.contains { $0.text == thought.text } && !(draft.importantMarks ?? []).isEmpty)
        precondition(draft.versions.contains { $0.nodes.contains { $0.origin?.itemID == wholeNode.id } }, "Pre-analysis source map remains in an isolated snapshot")
        let collection = store.collections.first { $0.name == "合成专题验收" }!
        precondition(Set(collection.sessionIDs) == sourceIDs.union([id]))
        precondition(bytes(store.database.sessions.filter { sourceIDs.contains($0.id) }) == sourceBytes)

        func result(_ rootSource: UUID) -> LocalProcessingResult {
            var rootCandidate = StructureCandidate(sourceSpanIDs: [rootSource], kind: .main, relation: .root, confidence: 1, summary: "不该显示的程序导航摘要")
            rootCandidate.navigationRoot = true
            let branch = StructureCandidate(sourceSpanIDs: [draft.transcript[1].id], kind: .branch, parentID: rootCandidate.nodeID, relation: .child, confidence: 0.9,
                summary: "测试模拟的整合结论", coveredSourceSpanIDs: draft.transcript.map(\.id))
            return LocalProcessingResult(speakers: draft.speakers, spans: draft.transcript, candidates: [rootCandidate, branch], warnings: [])
        }
        precondition(store.completeLocalProcessing(result(draft.transcript[0].id), sessionID: id))
        let first = current()
        precondition(first.status == .ready && first.structureSaved && (first.candidateVersions ?? []).isEmpty, "First model map applies automatically despite preexisting annotations")
        let firstRoot = first.nodes.first { $0.parentID == nil && $0.kind != .thought && $0.importantMarkID == nil }!
        precondition(firstRoot.userLabel == first.title && firstRoot.aiSummary == nil && !firstRoot.isSecondaryEdit && firstRoot.manualRevisionAt == nil)
        precondition(!NodeCardBodyContent.resolve(node: firstRoot, transcript: first.transcript, hasCustomLabel: true).isAISummary)
        precondition(first.thoughts.contains { $0.text == thought.text })
        for node in first.nodes { try IntegrityValidator.validateStoredNode(node, transcript: first.transcript) }
        precondition(store.completeLocalProcessing(result(draft.transcript.last!.id), sessionID: id))
        precondition(!(current().candidateVersions ?? []).isEmpty)
        store.acceptLatestCandidate(sessionID: id, arrangeAsNewMap: true)
        let accepted = current()
        precondition(!accepted.nodes.contains { $0.id == firstRoot.id }, "Old program-owned root must not accumulate as a protected manual edit")
        precondition(accepted.nodes.filter { $0.parentID == nil && $0.kind != .thought && $0.importantMarkID == nil }.count == 1)
        precondition(bytes(store.database.sessions.filter { sourceIDs.contains($0.id) }) == sourceBytes, "Source IDs, nodes and authored bytes never change")
        precondition(store.flush())
        let expected = try encoder.encode(accepted)
        let reopened = AppStore(storageRoot: root)
        precondition(bytes(reopened.database.sessions.first { $0.id == id }!) == expected)
        precondition(bytes(reopened.database.sessions.filter { sourceIDs.contains($0.id) }) == sourceBytes)
        precondition(reopened.collections.first { $0.id == collection.id }?.sessionIDs == collection.sessionIDs)
        try boundaryChecks(root: root)
        print("PASS: whole unpublished transcript + partial scope; authored Markdown provenance without AI-as-source; clean draft with annotations; topic collection; automatic first map; neutral navigation root; reanalysis without old-root accumulation; restart and source byte preservation.")
        print("Scope: isolated AppStore integration with synthetic model output, NOT real model/UI acceptance. Fixture: \(root.path)")
    }

    @MainActor static func boundaryChecks(root: URL) throws {
        let host = Speaker(role: .host)
        let separated = ["需要核对这些资料，", "若条件不满足不能采用。", "还要记录异常。"].enumerated().map { index, text in
            TranscriptSpan(sequence: index + 1, startTime: Double(index * 10), endTime: Double(index * 10 + 9), speakerID: host.id, originalText: text)
        }
        let selectedEnds = [separated[0], separated[2]].map {
            KnowledgeNode(sourceSpanIDs: [$0.id], kind: .main, relation: .root, position: CanvasPoint(x: 0, y: 0))
        }
        let sparseSource = SessionRecord(title: "稀疏节点来源", sourceName: "synthetic", sourceKind: "test", speakers: [host], transcript: separated, nodes: selectedEnds)
        let sparse = KnowledgeRecordMerger.combine(title: "只选首尾", sources: [sparseSource], selectedNodeIDs: Set(selectedEnds.map(\.id)))!
        let sparseAgain = KnowledgeRecordMerger.combine(title: "再次整合", sources: [sparse])!
        for combined in [sparse, sparseAgain] {
            precondition(combined.transcript.count == 2 && combined.transcript[1].sequence > combined.transcript[0].sequence + 1,
                         "Partial integration must retain omitted-source gaps even on re-integration")
            let forged = OriginalExcerpt(text: combined.transcript.map(\.originalText).joined(), parts: combined.transcript.map {
                OriginalExcerptPart(sourceID: $0.id, startOffset: 0, endOffset: $0.originalText.unicodeScalars.count)
            }, origin: combined.transcript[0].origin, time: nil)
            var candidate = StructureCandidate(sourceSpanIDs: combined.transcript.map(\.id), kind: .main, relation: .root, confidence: 1, summary: forged.text)
            candidate.sourceBoundStatus = "extracted"; candidate.coreOriginals = [forged]
            do {
                try IntegrityValidator.validate(candidates: [candidate], transcript: combined.transcript)
                preconditionFailure("Two nonadjacent original passages must never validate as a continuous quote")
            } catch is IntegrityViolation { }
        }
        let aSpan = TranscriptSpan(sequence: 1, startTime: 0, endTime: 10, speakerID: host.id, originalText: "A课尾部原话")
        let bSpan = TranscriptSpan(sequence: 1, startTime: 0, endTime: 10, speakerID: host.id, originalText: "B课开头原话")
        let aNode = KnowledgeNode(sourceSpanIDs: [aSpan.id], kind: .main, relation: .root, position: CanvasPoint(x: 200, y: 200))
        let bNode = KnowledgeNode(sourceSpanIDs: [bSpan.id], kind: .main, relation: .root, position: CanvasPoint(x: 200, y: 200))
        let known = ImportantMark(anchorSpanID: aSpan.id, protectedSpanIDs: [aSpan.id], anchorTime: 9)
        let missing = ImportantMark(anchorSpanID: UUID(), protectedSpanIDs: [], anchorTime: 11)
        let late = ImportantMark(anchorSpanID: UUID(), protectedSpanIDs: [], anchorTime: 500)
        let a = SessionRecord(title: "合成A", sourceName: "test", sourceKind: "test", speakers: [host], transcript: [aSpan], nodes: [aNode], importantMarks: [known, missing, late])
        let b = SessionRecord(title: "合成B", sourceName: "test", sourceKind: "test", speakers: [host], transcript: [bSpan], nodes: [bNode])
        var merged = KnowledgeRecordMerger.combine(title: "边界回归", sources: [a, b])!
        let bIndex = merged.transcript.firstIndex { $0.origin?.sessionID == b.id }!
        precondition(merged.transcript[bIndex].startTime >= 525, "Timeline offset must include unresolved late mark times and a safe inter-course gap")
        // Recreate a pre-fix merged timeline with only one second between A/B.
        // The origin fence must protect existing old merged records too.
        merged.transcript[bIndex].startTime = 11; merged.transcript[bIndex].endTime = 21
        merged.transcript[bIndex].isImportant = true
        let pollutedMarkIndex = merged.importantMarks!.firstIndex { $0.anchorTime == 9 }!
        merged.importantMarks?[pollutedMarkIndex].protectedSpanIDs.append(merged.transcript[bIndex].id)
        let boundaryRoot = root.appendingPathComponent("course-boundary", isDirectory: true)
        try FileManager.default.createDirectory(at: boundaryRoot, withIntermediateDirectories: false)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(AppDatabase(sessions: [merged])).write(to: boundaryRoot.appendingPathComponent("database.json"))
        let store = AppStore(storageRoot: boundaryRoot)
        store.markNearbyImportant(sessionID: merged.id, elapsedTime: 999)
        let checked = store.database.sessions.first { $0.id == merged.id }!
        let anchor = checked.importantMarks!.first { $0.anchorTime == 9 }!
        let checkedByID = Dictionary(uniqueKeysWithValues: checked.transcript.map { ($0.id, $0) })
        precondition(anchor.protectedSpanIDs.allSatisfy { checkedByID[$0]?.origin?.sessionID == a.id })
        precondition(!checked.transcript.first { $0.origin?.sessionID == b.id }!.isImportant, "A's tail mark must never highlight B's opening")
        for time in [11.0, 500.0] {
            let unresolved = checked.importantMarks!.first { $0.anchorTime == time }!
            precondition(checkedByID[unresolved.anchorSpanID] == nil && unresolved.protectedSpanIDs.isEmpty, "A's unresolved mark must not anchor itself to B")
        }

        var edited = aNode
        edited.userEditedText = "  用户补充的判断\n保留空格与原字。  "; edited.isSecondaryEdit = true
        edited.userLabel = "用户给这段起的名称"
        edited.aiSummary = "不能被当作来源的AI概括"
        var authoredHost = aSpan; authoredHost.sequence = 17
        let archivedOnly = TranscriptSpan(sequence: 40, startTime: 20, endTime: 25, speakerID: host.id, originalText: "旧版本独有的原话")
        edited.archivedSourceSpans = [authoredHost, archivedOnly]
        func excerpt(_ span: TranscriptSpan) throws -> OriginalExcerpt {
            let data = try JSONSerialization.data(withJSONObject: ["text": span.originalText,
                "parts": [["sourceID": span.id.uuidString, "startOffset": 0, "endOffset": span.originalText.count]]])
            return try JSONDecoder().decode(OriginalExcerpt.self, from: data)
        }
        edited.coreOriginals = [try excerpt(authoredHost)]
        edited.conditionOriginals = [try excerpt(archivedOnly)]
        edited.sourceBoundStatus = "sourceBound"
        var titled = aNode; titled.id = UUID(); titled.userLabel = "程序生成的导航名称"; titled.aiSummary = nil
        let authored = SessionRecord(title: "有稿且有人工编辑", sourceName: "test", sourceKind: "test", speakers: [host], transcript: [authoredHost], nodes: [edited, titled])
        let selected = KnowledgeRecordMerger.combine(title: "用户材料", sources: [authored], selectedNodeIDs: [edited.id], includeAuthoredSourceText: true)!
        precondition(selected.transcript.contains { $0.originalText == aSpan.originalText && $0.origin?.itemID == aSpan.id && $0.origin?.authoredByUser != true })
        let written = selected.transcript.first { $0.origin?.authoredByUser == true }!
        precondition(written.originalText == edited.userLabel! + "\n" + edited.userEditedText!)
        precondition(written.origin?.itemID == edited.id && written.origin?.sessionID == authored.id)
        precondition(selected.speakers.first { $0.id == written.speakerID }?.role == .user)
        precondition(!selected.transcript.contains { $0.originalText.contains("不能被当作来源的AI概括") || $0.originalText.contains("程序生成的导航名称") })
        let all = KnowledgeRecordMerger.combine(title: "全部用户材料", sources: [authored], includeAuthoredSourceText: true)!
        precondition(!all.transcript.contains { $0.originalText == "程序生成的导航名称" }, "Program navigation titles are not authored quotations")
        let copied = selected.nodes.first { $0.origin?.itemID == edited.id }!
        let copiedHost = selected.transcript.first { $0.origin?.itemID == aSpan.id }!
        let archived = copied.archivedSourceSpans!
        precondition(archived.first { $0.originalText == aSpan.originalText }?.id == copiedHost.id)
        precondition(archived.first { $0.id == copiedHost.id }?.sequence == copiedHost.sequence && copiedHost.sequence != authoredHost.sequence)
        precondition(archived.first { $0.id == archivedOnly.id }?.origin?.itemID == archivedOnly.id)
        precondition(archived.first { $0.id == archivedOnly.id }?.sequence == archivedOnly.sequence)
        precondition(copied.coreOriginals?.first?.parts.first?.sourceID == copiedHost.id)
        precondition(copied.coreOriginals?.first?.origin == archived.first { $0.id == copiedHost.id }?.origin)
        precondition(copied.conditionOriginals?.first?.parts.first?.sourceID == archivedOnly.id)
        precondition(copied.conditionOriginals?.first?.origin == archived.first { $0.id == archivedOnly.id }?.origin)
        precondition(copied.sourceBoundStatus == edited.sourceBoundStatus)
        precondition(archived.allSatisfy { $0.origin?.sessionID == authored.id && $0.speakerID == copiedHost.speakerID })
        precondition(authored.transcript == [authoredHost] && authored.nodes[0].sourceSpanIDs == [aSpan.id], "Source host manuscript/evidence was not replaced by user words")
        let repeated = KnowledgeRecordMerger.combine(title: "再次整合", sources: [selected], includeAuthoredSourceText: true)!
        precondition(repeated.transcript.filter { $0.origin?.authoredByUser == true }.count == 1, "Repeated integration reuses the same node's exact existing user source")
        print("PASS: source-fenced marks on legacy +1 timelines; unresolved tail marks stay unanchored; offset includes late marks; authored text coexists with host transcript; AI/program labels excluded; archived source remapping.")
    }
}

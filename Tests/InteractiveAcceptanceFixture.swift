import Foundation
import KnowledgeSpineCore

/// Purely synthetic, no audio and no model invocation. Leaves a complete new
/// manuscript/map candidate pending so the UI must perform the acceptance.
@main struct InteractiveAcceptanceFixture {
    @MainActor static func main() throws {
        let build = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build")
        let root = build.appendingPathComponent("ui-fixture-\(UUID().uuidString.lowercased())")
        precondition(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let speaker = Speaker(role: .host, displayName: "合成验收讲师")
        let texts = [
            "这是一段合成验收课程。学习时先把注意力放在理解上，不必一边听一边整理所有句子。",
            "先听清楚老师要解决的问题，再辨认他给出的理由。导图呈现思路，不是句子清单。",
            "开始行动时，先把起步门槛降下来。每天练习五分钟，比准备一套复杂流程容易开始。",
            "这里的五分钟只是这个合成例子，不是适合所有人的固定标准。重点是找到自己能坚持的起点。",
            "听完以后，用一个新例子复述今天的主要方法，检查自己是不是真的理解。",
            "如果复述卡住，就回到对应原文。这不是要求把整节课重新听一遍。"
        ]
        let spans: [TranscriptSpan] = texts.enumerated().map { index, text in
            TranscriptSpan(sequence: index + 1, startTime: Double(index) * 20, endTime: Double(index + 1) * 20,
                           speakerID: speaker.id, originalText: text,
                           correctedText: index == 2 ? "人工修正（合成验收）：先降低起步门槛，再选择能坚持的小练习。" : nil,
                           isImportant: index == 2 || index == 3)
        }
        let center = KnowledgeNode(sourceSpanIDs: [spans[0].id, spans[4].id], kind: .main, relation: .root,
                                   position: CanvasPoint(x: 300, y: 260), aiSummary: "合成验收：让学习少一点打断")
        let summaries = ["先理解讲述思路", "降低行动门槛", "用复述检查理解"]
        var nodes = [center]
        for index in 0..<3 {
            nodes.append(KnowledgeNode(sourceSpanIDs: [spans[index * 2].id, spans[index * 2 + 1].id], kind: .main,
                                       parentID: center.id, relation: .child, position: CanvasPoint(x: 680, y: 100 + Double(index) * 190),
                                       aiSummary: summaries[index], argumentSummary: "合成验收阶段\(index + 1)：\(summaries[index])。",
                                       relationToPrevious: index == 0 ? "先明确目标" : (index == 1 ? "再转向行动" : "最后回看效果"),
                                       coveredSourceSpanIDs: [spans[index * 2].id, spans[index * 2 + 1].id]))
        }
        let manual = KnowledgeNode(sourceSpanIDs: [spans[2].id], kind: .evidence, parentID: nodes[2].id, relation: .supports,
                                   position: CanvasPoint(x: 1060, y: 300), userEditedText: "我的编辑（合成验收）：先能开始，再慢慢调整。",
                                   isSecondaryEdit: true, manualRevisionAt: Date(), userLabel: "人工编辑：小步开始")
        nodes.append(manual)
        let exactThought = "我的思考（合成验收）：\n我希望听课时只管听，不要为了记笔记错过后面的解释。\n“想到了就先记下”，这句话请原封不动留下。"
        let thought = UserThought(text: exactThought, attachedNodeID: nodes[2].id, isSecondaryEdit: true, anchorTime: 61)
        let mark = ImportantMark(anchorSpanID: spans[2].id, protectedSpanIDs: [spans[2].id, spans[3].id], anchorTime: 60)
        var session = SessionRecord(title: "合成验收｜讲述思路与原话保护", sourceName: "合成验收，无真实录音", sourceKind: "isolated-ui-fixture",
                                    status: .ready, speakers: [speaker], transcript: spans, nodes: nodes, thoughts: [thought],
                                    transcriptComplete: true, structureSaved: true, importantMarks: [mark])
        session.analysisWarnings = ["合成验收旧版说明：本记录仅用于界面验证，不是真实课程，也不是模型质量证明。"]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(AppDatabase(sessions: [session])).write(to: root.appendingPathComponent("database.json"), options: .atomic)
        let store = AppStore(storageRoot: root)
        let initial = store.database.sessions[0]
        let annotationSummaries = [AnnotationSummary(id: thought.id, summary: "希望听课少被记录打断，并完整保留当时的想法。"),
                                   AnnotationSummary(id: mark.id, summary: "先选择容易开始的小练习；例子中的时长不是统一标准。")]
        store.applyAnnotationSummaries(annotationSummaries, inputs: AnnotationInput.from(initial), sessionID: session.id)
        let before = store.database.sessions[0]
        let fresh: [TranscriptSpan] = (0..<3).map { index -> TranscriptSpan in
            let start = Double(index) * 40.0
            let end = Double(index + 1) * 40.0
            let text = texts[index * 2] + texts[index * 2 + 1]
            return TranscriptSpan(sequence: index + 1, startTime: start, endTime: end,
                           speakerID: speaker.id, originalText: text)
        }
        let newRootID = UUID()
        var candidates = [StructureCandidate(nodeID: newRootID, sourceSpanIDs: [fresh[0].id, fresh[2].id], kind: .main,
                                             relation: .root, confidence: 1, summary: "合成验收新版：理解 → 行动 → 检查",
                                             argumentSummary: "先听懂讲述，再选择小步行动，最后通过复述检查理解。",
                                             coveredSourceSpanIDs: fresh.map(\.id))]
        for index in 0..<3 {
            candidates.append(StructureCandidate(sourceSpanIDs: [fresh[index].id], kind: .main, parentID: newRootID,
                                                 relation: .child, confidence: 1, summary: summaries[index],
                                                 argumentSummary: ["把问题和理由联系起来，不把每句话都摆上导图。", "降低开始的阻力，按个人情况选择可坚持的行动。", "用新例子检验理解，卡住时只回看相关原文。"][index],
                                                 relationToPrevious: ["起点：先理解", "从理解走向行动", "用回顾检查行动与理解"][index],
                                                 coveredSourceSpanIDs: [fresh[index].id]))
        }
        candidates.append(StructureCandidate(sourceSpanIDs: [fresh[1].id], kind: .evidence, parentID: candidates[2].nodeID,
                                             relation: .supports, confidence: 1, summary: "细节（合成验收）：五分钟只是示例，不是统一要求。"))
        let warnings = ["合成验收新版说明：有 1 处补充细节未纳入主线；完整内容仍在逐字稿中。", "此说明为合成验收文字，不能作为真实模型覆盖率证据。"]
        let result = LocalProcessingResult(speakers: [speaker], spans: fresh, candidates: candidates, warnings: warnings,
                                           annotationSummaries: annotationSummaries, annotationInputs: AnnotationInput.from(before))
        precondition(store.completeLocalProcessing(result, sessionID: session.id))
        let pending = store.database.sessions[0]
        precondition(pending.transcript == before.transcript && pending.nodes == before.nodes)
        precondition(pending.candidateVersions?.last?.transcript?.count == 3 && pending.transcript.count == 6)
        precondition(store.flush())
        let currentInputs = AnnotationInput.from(pending)
        for node in pending.nodes where node.thoughtID != nil || node.importantMarkID != nil {
            let id = node.thoughtID ?? node.importantMarkID!
            precondition(node.aiSummary?.isEmpty == false && node.annotationInputFingerprint == currentInputs.first { $0.id == id }?.fingerprint)
        }
        // Generate an isolated expected-after reference through the same AppStore
        // API. Parent copies only root/database.json to the isolated UI app.
        let expectedRoot = root.appendingPathComponent("expected-after")
        try FileManager.default.createDirectory(at: expectedRoot, withIntermediateDirectories: false)
        try encoder.encode(store.database).write(to: expectedRoot.appendingPathComponent("database.json"), options: .atomic)
        let expected = AppStore(storageRoot: expectedRoot)
        expected.acceptLatestCandidate(sessionID: session.id, arrangeAsNewMap: true)
        precondition(expected.flush())
        let accepted = expected.database.sessions[0]
        precondition(accepted.transcript.count == 3 && accepted.candidateVersions?.isEmpty == true)
        precondition(accepted.nodes.first { $0.id == manual.id }?.archivedSourceSpans?.first?.correctedText == spans[2].correctedText)
        precondition(accepted.thoughts.first?.text == exactThought)
        let acceptedInputs = AnnotationInput.from(accepted)
        for node in accepted.nodes where node.thoughtID != nil || node.importantMarkID != nil {
            let id = node.thoughtID ?? node.importantMarkID!
            precondition(node.aiSummary?.isEmpty == false && node.annotationInputFingerprint == acceptedInputs.first { $0.id == id }?.fingerprint)
        }
        let report: [String: Any] = ["synthetic": true, "sessionID": session.id.uuidString, "manualNodeID": manual.id.uuidString,
                                   "thoughtID": thought.id.uuidString, "importantMarkID": mark.id.uuidString,
                                   "oldTranscriptCount": 6, "newTranscriptCount": 3, "currentNodeCount": pending.nodes.count,
                                   "expectedAcceptedNodeCount": accepted.nodes.count, "thoughtExactText": exactThought,
                                   "modelsInvoked": false, "audioPaths": [], "copyToQA": root.appendingPathComponent("database.json").path]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("fixture-manifest.json"))
        print("PASS: isolated synthetic current+complete-candidate fixture; no audio, no model, annotation fingerprints complete")
        print(root.path)
    }
}

import Foundation

@main
@MainActor
struct PortableMindMapProbe {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw MindMapExchangeError.invalid("Probe failed: \(message)") }
        checks += 1
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; return }
        throw MindMapExchangeError.invalid("Probe accepted invalid input: \(message)")
    }
    static func sample() -> SessionRecord {
        let speaker = Speaker(role: .host, displayName: "人工命名")
        let span = TranscriptSpan(sequence: 1, startTime: 3, endTime: 8, speakerID: speaker.id,
                                  originalText: "這是原始識別", correctedText: "这是人工修正，不要改写。", isImportant: true)
        var thought = UserThought(text: "我的原话：并不一定如此。\n还需要检验。", isSecondaryEdit: true, anchorTime: 5)
        let mark = ImportantMark(anchorSpanID: span.id, protectedSpanIDs: [span.id], anchorTime: 5)
        var node = KnowledgeNode(sourceSpanIDs: [span.id], kind: .main, relation: .root,
                                 position: CanvasPoint(x: 35, y: 90), userEditedText: "人工节点原封不动", isSecondaryEdit: true,
                                 manualRevisionAt: Date(), thoughtID: thought.id, importantMarkID: mark.id,
                                 aiSummary: "原有摘要", coveredSourceSpanIDs: [span.id], archivedSourceSpans: [span])
        node.annotationInputFingerprint = "old-machine-fingerprint"
        thought.attachedNodeID = node.id
        let snapshot = StructureSnapshot(reason: "人工编辑前", nodes: [node], thoughts: [thought], transcript: [span],
                                         speakers: [speaker], importantMarks: [mark], pendingImportantTimes: [7],
                                         transcriptComplete: true, structureSaved: true,
                                         analysisWarnings: ["/private/old-machine/log"])
        var candidate = snapshot; candidate.id = UUID(); candidate.reason = "候选版本"
        var session = SessionRecord(title: "人工课程标题", sourceName: "/private/recording/input.wav", sourceKind: "文件导入",
                                    status: .recording, speakers: [speaker], transcript: [span], nodes: [node], thoughts: [thought],
                                    versions: [snapshot], audioRelativePaths: ["/private/audio.m4a"], audioState: .retained,
                                    transcriptComplete: true, structureSaved: true, candidateVersions: [candidate],
                                    importantMarks: [mark], pendingImportantTimes: [7], recoveryPending: true)
        session.analysisWarnings = ["/Users/private/model/path"]
        session.processingRunLabel = "private-processing-task"
        return session
    }
    static func main() throws {
        let original = sample()
        let unchanged = original
        let data = try PortableMindMap.exportData(sessions: [original])
        let encoded = String(decoding: data, as: UTF8.self)
        try check(!encoded.contains("audioRelativePaths") && !encoded.contains("structureModelPath"), "no machine configuration")
        try check(!encoded.contains("/private/") && !encoded.contains("/Users/private/") && !encoded.contains("private-processing-task"), "no runtime paths/logs")
        let imported = try PortableMindMap.importData(data, existingSessions: [original])[0]
        try check(original == unchanged, "existing session unchanged")
        try check(imported.id != original.id && imported.nodes[0].id != original.nodes[0].id, "fresh session/node IDs")
        try check(imported.transcript[0].id != original.transcript[0].id && imported.speakers[0].id != original.speakers[0].id, "fresh source/speaker IDs")
        try check(imported.thoughts[0].id != original.thoughts[0].id && imported.importantMarks![0].id != original.importantMarks![0].id, "fresh annotation IDs")
        try check(imported.versions[0].id != original.versions[0].id && imported.candidateVersions![0].id != original.candidateVersions![0].id, "fresh snapshot IDs")
        try check(imported.nodes[0].sourceSpanIDs == [imported.transcript[0].id], "source links remapped")
        try check(imported.nodes[0].thoughtID == imported.thoughts[0].id && imported.thoughts[0].attachedNodeID == imported.nodes[0].id, "thought links remapped")
        try check(imported.nodes[0].importantMarkID == imported.importantMarks![0].id, "mark node link remapped")
        try check(imported.importantMarks![0].anchorSpanID == imported.transcript[0].id, "mark anchor remapped")
        try check(imported.versions[0].nodes[0].id == imported.nodes[0].id && imported.versions[0].transcript![0].id == imported.transcript[0].id, "identity stable across versions")
        try check(imported.nodes[0].archivedSourceSpans![0].id == imported.transcript[0].id, "archived spans remapped")
        try check(imported.thoughts[0].text == original.thoughts[0].text && imported.nodes[0].userEditedText == original.nodes[0].userEditedText, "authored words unchanged")
        try check(imported.transcript[0].originalText == original.transcript[0].originalText && imported.transcript[0].correctedText == original.transcript[0].correctedText, "raw and corrected text unchanged")
        try check(imported.audioRelativePaths.isEmpty && imported.audioState == .none && imported.recoveryPending == false && imported.status == .ready, "no audio or running recovery imported")
        try check(imported.nodes[0].annotationInputFingerprint == nil, "old UUID fingerprint invalidated")
        try check(imported.analysisWarnings?.first?.contains("处理说明") == true, "path-only warning remains visible")
        var warned = original
        warned.analysisWarnings = ["有 2 条观点未完成：03:10–04:20。日志位于 /Users/private/my folder/log.json；逐字稿仍完整。", "已核对 3/4，仍有一条待核。"]
        warned.versions[0].analysisWarnings = ["后段方法未能安全整理。详见 file:///private/log.json"]
        warned.candidateVersions![0].analysisWarnings = ["有一条观点待核；日志 C:\\Users\\name\\log.txt"]
        warned.thoughts[0].text = "用户原文：/Users/private/my note，请原封不动。"
        let warningCopy = try PortableMindMap.importData(PortableMindMap.exportData(sessions: [warned]))[0]
        try check(warningCopy.analysisWarnings![0].contains("03:10–04:20") && warningCopy.analysisWarnings![0].contains("逐字稿仍完整"), "completeness scope survives path sanitizing")
        try check(warningCopy.analysisWarnings![1] == warned.analysisWarnings![1], "nonpath warning exact and ratio preserved")
        try check(warningCopy.versions[0].analysisWarnings![0].contains("后段方法未能安全整理") && !warningCopy.versions[0].analysisWarnings![0].contains("/private"), "historical completeness warning preserved")
        try check(warningCopy.candidateVersions![0].analysisWarnings![0].contains("有一条观点待核") && !warningCopy.candidateVersions![0].analysisWarnings![0].contains("C:"), "candidate warning Windows path redacted")
        try check(warningCopy.thoughts[0].text == warned.thoughts[0].text, "authored literal path never sanitized")
        let twice = try PortableMindMap.importData(data, existingSessions: [original, imported])[0]
        try check(twice.id != imported.id && twice.transcript[0].id != imported.transcript[0].id, "repeat import creates independent copy")

        var composite = sample()
        composite.transcript[0].origin = SourceReference(sessionID: original.id, sessionTitle: original.title,
                                                       itemID: original.transcript[0].id, startTime: 3)
        composite.nodes[0].origin = SourceReference(sessionID: original.id, sessionTitle: original.title,
                                                  itemID: original.nodes[0].id, startTime: 3)
        let pair = try PortableMindMap.importData(PortableMindMap.exportData(sessions: [original, composite]))
        try check(pair[1].transcript[0].origin?.sessionID == pair[0].id && pair[1].transcript[0].origin?.itemID == pair[0].transcript[0].id, "internal span provenance maps to actual copied source")
        try check(pair[1].nodes[0].origin?.itemID == pair[0].nodes[0].id, "internal node provenance remapped")
        let external = try PortableMindMap.importData(PortableMindMap.exportData(sessions: [composite]))[0]
        try check(external.nodes[0].origin == composite.nodes[0].origin && external.transcript[0].origin == composite.transcript[0].origin, "external provenance remains truthful")
        let compositeData = try PortableMindMap.exportData(sessions: [composite])
        let batch = try PortableMindMap.importBatch([data, compositeData], existingSessions: [original])
        try check(batch[1].nodes[0].origin?.sessionID == batch[0].id && batch[1].nodes[0].origin?.itemID == batch[0].nodes[0].id,
                  "separate files share actual remapped node provenance")
        try check(batch[1].transcript[0].origin?.itemID == batch[0].transcript[0].id, "separate files remap span provenance")
        let reversed = try PortableMindMap.importBatch([compositeData, data])
        try check(reversed[0].nodes[0].origin?.sessionID == reversed[1].id, "batch provenance independent of file order")
        try rejects("duplicate file selection") { _ = try PortableMindMap.importBatch([data, data]) }
        var changedVersion = original; changedVersion.title = "同一原记录另一版本"
        try rejects("ambiguous original ID across files") {
            _ = try PortableMindMap.importBatch([data, PortableMindMap.exportData(sessions: [changedVersion])])
        }
        try rejects("malformed later file is atomic") { _ = try PortableMindMap.importBatch([data, Data("bad".utf8)]) }
        try rejects("empty batch") { _ = try PortableMindMap.importBatch([]) }
        try rejects("batch total byte limit") {
            _ = try PortableMindMap.importBatch([data, Data(repeating: 32, count: PortableMindMap.maximumBytes)])
        }
        var timeOnly = sample()
        timeOnly.importantMarks!.append(ImportantMark(anchorSpanID: UUID(), protectedSpanIDs: [], anchorTime: 15))
        let timed = try PortableMindMap.importData(PortableMindMap.exportData(sessions: [timeOnly]))[0]
        try check(timed.importantMarks!.last!.anchorTime == 15 && timed.importantMarks!.last!.anchorSpanID != timeOnly.importantMarks!.last!.anchorSpanID, "pending timed mark remapped")

        for mutation in 0..<9 {
            var bad = original
            switch mutation {
            case 0: bad.nodes.append(bad.nodes[0])
            case 1: bad.nodes[0].sourceSpanIDs = [UUID()]
            case 2: bad.nodes[0].parentID = bad.nodes[0].id
            case 3: bad.nodes[0].position.x = .nan
            case 4: bad.nodes[0].position.y = 10_000_000
            case 5: bad.thoughts[0].attachedNodeID = UUID()
            case 6: bad.transcript[0].speakerID = UUID()
            case 7: bad.versions[0].nodes[0].parentID = UUID()
            default: bad.importantMarks![0].protectedSpanIDs = [UUID()]
            }
            try rejects("invalid structure \(mutation)") { _ = try PortableMindMap.exportData(sessions: [bad]) }
        }
        try rejects("duplicate sessions") { _ = try PortableMindMap.exportData(sessions: [original, original]) }
        try rejects("empty data") { _ = try PortableMindMap.importData(Data()) }
        try rejects("oversize data") { _ = try PortableMindMap.importData(Data(repeating: 32, count: PortableMindMap.maximumBytes + 1)) }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["version"] = 999
        try rejects("future version") { _ = try PortableMindMap.importData(JSONSerialization.data(withJSONObject: object)) }
        object["version"] = 1
        var sessions = object["sessions"] as! [[String: Any]]
        var invalid = sessions[0]; invalid["nodes"] = [["id": "broken"]]
        sessions.append(invalid); object["sessions"] = sessions
        try rejects("invalid second session must not partially import first") { _ = try PortableMindMap.importData(JSONSerialization.data(withJSONObject: object), existingSessions: [original]) }
        try check(original == unchanged, "failure never mutates original")

        let markdown = "# 完整课程\n正文保持原样：不是必然有效。\n- 第一条\n  - 子条，保留条件\n- 第二条\n## 后段方法\n1. 我自己的话\n"
        let md = try PortableMindMap.importMarkdown(markdown, title: "本地导入", existingSessions: [original])
        try check(md.nodes.count == 6, "Markdown heading and list node count")
        try check(md.nodes[2].parentID == md.nodes[1].id && md.nodes[3].parentID == md.nodes[0].id, "indent hierarchy preserved")
        try check(md.nodes[4].parentID == md.nodes[0].id && md.nodes[5].parentID == md.nodes[4].id, "heading scopes preserved")
        try check(md.nodes.allSatisfy { $0.isSecondaryEdit && $0.aiSummary == nil && $0.semanticRole == nil }, "Markdown explicitly human, never AI")
        try check(md.nodes[0].userEditedText == "完整课程\n正文保持原样：不是必然有效。", "Markdown paragraph original wording")
        try check(md.transcript.isEmpty && md.audioRelativePaths.isEmpty && md.sourceKind.contains("用户内容"), "Markdown does not fabricate ASR")
        try rejects("empty Markdown") { _ = try PortableMindMap.importMarkdown(" \n\t") }
        try rejects("empty Markdown markers") { _ = try PortableMindMap.importMarkdown("# \n- \n## ") }
        print("PortableMindMapProbe passed \(checks) checks")
    }
}

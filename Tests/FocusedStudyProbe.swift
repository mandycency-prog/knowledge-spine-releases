import Foundation
import KnowledgeSpineCore

@main struct FocusedStudyProbe {
    @MainActor static func main() async throws {
        precondition(LocalProcessingService.processingTimeout(audioCount: 0, checkpoint: nil, asrOnly: false, runLabel: "focus-test") == 900)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FocusedStudy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storageRoot: root)
        precondition(store.analysisProvider == "local")
        let oldSettings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings()))
        precondition(oldSettings.analysisProvider == nil && oldSettings.apiConfiguration == nil)
        let endpoint = "https://example.invalid/v1"
        store.analysisProvider = "api"
        store.apiConfiguration = APIConfiguration(baseURL: endpoint, model: "test-model")
        var config = store.apiConfiguration
        config.approvedEndpoint = endpoint
        store.apiConfiguration = config
        precondition(store.apiConfiguration.isApproved)
        precondition(store.flush())
        do {
            let restarted = AppStore(storageRoot: root)
            precondition(restarted.analysisProvider == "api" && restarted.apiConfiguration.isApproved)
            var changed = restarted.apiConfiguration
            changed.baseURL = "https://other.invalid/v1"
            restarted.apiConfiguration = changed
            precondition(!restarted.apiConfiguration.isApproved)
        }
        store.analysisProvider = "local"
        let id = store.createSession(title: "隔离专题测试", sourceName: "fixture", sourceKind: "test")
        let speaker = Speaker(role: .host)
        let span = TranscriptSpan(sequence: 1, startTime: 0, endTime: 10, speakerID: speaker.id, originalText: "志愿活动需要在平台报名。")
        let complete = LocalProcessingResult(speakers: [speaker], spans: [span], candidates: [StructureCandidate(sourceSpanIDs: [span.id], kind: .main, relation: .root, confidence: 1, summary: "志愿活动报名")], warnings: [])
        precondition(store.completeLocalProcessing(complete, sessionID: id))
        precondition(store.flush())
        let original = store.database.sessions.first { $0.id == id }!
        let question = "志愿学分怎么获取？"
        let report = FocusedStudyReport(question: question, sections: [FocusedStudySection(heading: "报名", explanation: "先在平台报名。", sourceSpanIDs: [span.id])], gaps: ["本段没有足以确定学分数量的依据。"])
        let processor = LocalProcessingService(runner: { _, paths, _, _, _, label, checkpoint, _ in
            precondition(paths.isEmpty && label.hasPrefix("focus-"))
            precondition(checkpoint?.spans == [span] && checkpoint?.focusQuestion == question)
            var result = complete; result.focusedReport = report; return result
        }, notifier: { _, _ in })
        processor.processFocus(question: question, sessionID: id, store: store)
        for _ in 0..<300 {
            if !processor.isFocusing(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!processor.isFocusing(id))
        let after = store.database.sessions.first { $0.id == id }!
        precondition(after.focusedStudyReports == [report])
        precondition(after.nodes == original.nodes && after.transcript == original.transcript && after.speakers == original.speakers)
        let reopened = AppStore(storageRoot: root)
        let restored = reopened.database.sessions.first { $0.id == id }?.focusedStudyReports?.first
        precondition(restored?.id == report.id && restored?.sections == report.sections && restored?.question == question && restored?.gaps == report.gaps)
        let bad = FocusedStudyReport(question: question, sections: [FocusedStudySection(heading: "伪来源", explanation: "不能写入", sourceSpanIDs: [UUID()])])
        precondition(!store.saveFocusedStudy(bad, sessionID: id, baseline: [span]))
        precondition(!store.saveFocusedStudy(report, sessionID: id, baseline: []))
        let noEvidence = FocusedStudyReport(question: question, sections: [], gaps: ["没有提取到足以回答的内容。"])
        precondition(store.saveFocusedStudy(noEvidence, sessionID: id, baseline: [span]))
        store.failFocusedStudy("模拟失败", sessionID: id)
        precondition(store.database.sessions.first { $0.id == id }?.focusedStudyReports == [report, noEvidence])
        if let databasePath = CommandLine.arguments.dropFirst().first {
            let restartRoot = root.appendingPathComponent("saved-api-restart")
            try FileManager.default.createDirectory(at: restartRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: databasePath),
                to: restartRoot.appendingPathComponent("database.json"))
            let fresh = AppStore(storageRoot: restartRoot)
            let saved = fresh.database.sessions.flatMap { $0.focusedStudyReports ?? [] }
            precondition(saved.contains { $0.sections.count == 13 })
            print("PASS: actual API report reloads with all 13 sections in isolated AppStore")
        }
        print("PASS: question pipeline, no ASR, map preservation, persistence/restart, invalid/stale evidence rejection, empty evidence, failure preserves history")
    }
}

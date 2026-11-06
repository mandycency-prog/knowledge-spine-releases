import Foundation
import KnowledgeSpineCore

@main struct ProcessingFailureProbe {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeSpine-FailureFeedback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storageRoot: root)
        let id = store.createSession(title: "隔离失败反馈测试", sourceName: "fixture", sourceKind: "test")
        let speaker = Speaker(role: .host)
        let span = TranscriptSpan(sequence: 1, startTime: 0, endTime: 12, speakerID: speaker.id, originalText: "先确定目标，再拆解行动。")
        let node = StructureCandidate(sourceSpanIDs: [span.id], kind: .main, relation: .root, confidence: 1, summary: "先确定目标")
        let complete = LocalProcessingResult(speakers: [speaker], spans: [span], candidates: [node], warnings: [])
        let error = "核心原话选择超出上下文预算"
        let failed = complete.failedCheckpoint(detail: error, logPath: "/isolated/last-run.log")
        precondition(failed.candidates.isEmpty, "Nonzero process exit must never publish partial candidates")
        precondition(failed.spans == complete.spans)
        let decoded = try LocalProcessingResult.decode(JSONEncoder().encode(failed))
        precondition(decoded.processingError?.contains(error) == true)

        let failing = LocalProcessingService(runner: { _, _, _, _, _, _, _, _ in failed }, notifier: { _, _ in })
        failing.process(sessionID: id, audioPaths: ["/synthetic-not-opened.wav"], store: store)
        await waitFor(failing, id)
        let afterFailure = store.database.sessions.first { $0.id == id }!
        precondition(afterFailure.transcript == [span] && afterFailure.transcriptComplete)
        precondition(afterFailure.lastProcessingError?.contains(error) == true)
        precondition(store.statusMessage?.contains("来源校验") != true, "A budget failure must not be relabelled as a provenance rejection")
        precondition(store.flush())
        let reopened = AppStore(storageRoot: root)
        precondition(reopened.database.sessions.first { $0.id == id }?.lastProcessingError == afterFailure.lastProcessingError)

        let success = LocalProcessingService(runner: { _, paths, _, _, _, _, checkpoint, _ in
            precondition(paths.isEmpty && checkpoint?.spans == [span], "Retry must reuse the saved transcript without ASR")
            return complete
        }, notifier: { _, _ in })
        success.process(sessionID: id, audioPaths: [], store: reopened)
        await waitFor(success, id)
        let recovered = reopened.database.sessions.first { $0.id == id }!
        precondition(recovered.structureSaved && recovered.lastProcessingError == nil)

        // A later failure keeps the already accepted manuscript/map intact.
        let later = LocalProcessingService(runner: { _, _, _, _, _, _, _, _ in failed }, notifier: { _, _ in })
        later.process(sessionID: id, audioPaths: [], store: reopened)
        await waitFor(later, id)
        let preserved = reopened.database.sessions.first { $0.id == id }!
        precondition(preserved.nodes == recovered.nodes && preserved.transcript == recovered.transcript)
        precondition(preserved.lastProcessingError?.contains(error) == true && preserved.status == .ready)
        precondition(reopened.flush())

        // A concurrent external writer must result in an unsaved warning,
        // never the normal completion progress or completion notification.
        let conflicting = LocalProcessingService(runner: { _, _, _, directory, _, _, _, _ in
            let databaseURL = directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("database.json")
            var bytes = try Data(contentsOf: databaseURL); bytes.append(Data("\n".utf8))
            try bytes.write(to: databaseURL, options: .atomic)
            return complete
        }, notifier: { _, _ in })
        conflicting.process(sessionID: id, audioPaths: [], store: reopened)
        await waitFor(conflicting, id)
        precondition(conflicting.progress[id]?.contains("尚未保存") == true)
        precondition(reopened.statusMessage?.contains("保存失败") == true)

        if CommandLine.arguments.count == 2 {
            let result = try LocalProcessingResult.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            print("PASS: real read-only checkpoint decoded: \(result.spans.count) spans, \(result.candidates.count) candidates")
        }
        print("PASS: actual failure persists, restart retains cause, saved-manuscript retry recovers, later failure preserves accepted map, CAS failure stays visible")
    }

    @MainActor static func waitFor(_ processor: LocalProcessingService, _ id: UUID) async {
        for _ in 0..<300 {
            if !processor.isProcessing(id) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Scripted processing did not finish")
    }
}

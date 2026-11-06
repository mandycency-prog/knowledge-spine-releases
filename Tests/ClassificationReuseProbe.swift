import Foundation
import KnowledgeSpineCore

private actor ReuseObservations {
    var reused: [UUID: Bool] = [:]
    var checkpointPresent: [UUID: Bool] = [:]
    var callCounts: [UUID: Int] = [:]
    var proofreadingReused: [UUID: Bool] = [:]
    func record(_ id: UUID, _ saved: LocalProcessingResult?) {
        reused[id] = saved?.reuseTranscriptClassification == true
        checkpointPresent[id] = saved != nil
        callCounts[id, default: 0] += 1
        proofreadingReused[id] = LocalProcessingService.mayReuseProofreading(saved)
    }
    func value(_ id: UUID) -> Bool? { reused[id] }
    func hasCheckpoint(_ id: UUID) -> Bool? { checkpointPresent[id] }
    func count(_ id: UUID) -> Int { callCounts[id, default: 0] }
    func reusedProofreading(_ id: UUID) -> Bool? { proofreadingReused[id] }
}

@main struct ClassificationReuseProbe {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KnowledgeSpine-ClassificationReuse-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let speaker = Speaker(role: .host)
        let sessions = (0..<4).map { index in
            let span = TranscriptSpan(sequence: 1, startTime: 0, endTime: 10, speakerID: speaker.id, originalText: "合成分类策略验收 \(index)", isBackgroundAudio: false)
            return SessionRecord(title: "合成 \(index)", sourceName: "test", sourceKind: "test", speakers: [speaker], transcript: [span], transcriptComplete: index != 0)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(AppDatabase(sessions: sessions)).write(to: root.appendingPathComponent("database.json"))
        let store = AppStore(storageRoot: root), observations = ReuseObservations()
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let runner: LocalProcessingService.Runner = { id, _, _, _, _, _, saved, _ in
            await observations.record(id, saved)
            try await Task.sleep(for: .milliseconds(30))
            let session = byID[id]!
            let candidate = StructureCandidate(sourceSpanIDs: [session.transcript[0].id], kind: .main, relation: .root, confidence: 1, summary: "仅测试桩，不调用模型")
            return LocalProcessingResult(speakers: session.speakers, spans: session.transcript, candidates: [candidate], warnings: [])
        }
        let processor = LocalProcessingService(runner: runner, notifier: { _, _ in })
        processor.process(sessionID: sessions[0].id, audioPaths: [], store: store, reuseTranscriptClassification: true)
        processor.process(sessionID: sessions[1].id, audioPaths: [], store: store, reuseTranscriptClassification: true)
        processor.process(sessionID: sessions[2].id, audioPaths: [], store: store)
        processor.process(sessionID: sessions[3].id, audioPaths: ["/synthetic-not-opened.wav"], store: store, retranscribe: true, reuseTranscriptClassification: true)
        for _ in 0..<500 {
            if sessions.allSatisfy({ !processor.isProcessing($0.id) }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(sessions.allSatisfy { !processor.isProcessing($0.id) })
        let first = await observations.value(sessions[0].id), queued = await observations.value(sessions[1].id)
        let ordinary = await observations.value(sessions[2].id), relisten = await observations.value(sessions[3].id)
        precondition(first == true && queued == true && ordinary == false && relisten == false)
        let relistenCheckpoint = await observations.hasCheckpoint(sessions[3].id)
        precondition(relistenCheckpoint == false, "Explicit relistening must not use the old manuscript")
        for (index, session) in sessions.enumerated() {
            let bytes = try Data(contentsOf: store.sessionDirectory(session.id).appendingPathComponent("Processing/classification-policy.json"))
            let policy = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            precondition(policy["reuse"] as? Bool == (index < 2), "Queued classification policy must be durable and explicit")
        }
        store.prepareProcessingJob(sessionID: sessions[1].id, runLabel: "final", retranscribe: false, resetBudget: true)
        store.setStatus(.failed, sessionID: sessions[1].id)
        let recoveryObservations = ReuseObservations()
        let recovery = LocalProcessingService(runner: { id, _, _, _, _, _, saved, _ in
            await recoveryObservations.record(id, saved)
            let session = byID[id]!
            return LocalProcessingResult(speakers: session.speakers, spans: session.transcript,
                candidates: [StructureCandidate(sourceSpanIDs: [session.transcript[0].id], kind: .main, relation: .root, confidence: 1, summary: "恢复测试桩")], warnings: [])
        }, notifier: { _, _ in })
        recovery.resumeInterrupted(store: store)
        for _ in 0..<500 {
            if !recovery.isProcessing(sessions[1].id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let restoredPolicy = await recoveryObservations.value(sessions[1].id)
        precondition(restoredPolicy == true, "Automatic recovery must retain the saved explicit choice")
        let failures = ReuseObservations()
        let failing = LocalProcessingService(runner: { id, _, _, _, _, _, saved, _ in
            await failures.record(id, saved)
            throw NSError(domain: "SyntheticFailure", code: 1)
        }, notifier: { _, _ in })
        failing.process(sessionID: sessions[0].id, audioPaths: [], store: store)
        failing.process(sessionID: sessions[1].id, audioPaths: [], store: store)
        for _ in 0..<500 {
            if !failing.isProcessing(sessions[0].id) && !failing.isProcessing(sessions[1].id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for session in sessions.prefix(2) {
            let count = await failures.count(session.id)
            precondition(count == 1, "A failed model run must not automatically repeat the entire analysis")
            precondition(!failing.isProcessing(session.id), "A failure must drain the processing queue")
        }
        var saved = LocalProcessingResult(speakers: [speaker], spans: sessions[0].transcript, candidates: [], warnings: [])
        saved.reuseTranscriptClassification = true
        let decoded = try JSONDecoder().decode(LocalProcessingResult.self, from: JSONEncoder().encode(saved))
        precondition(decoded.reuseTranscriptClassification == true)
        let longManuscript = LocalProcessingResult(speakers: [speaker], spans: Array(repeating: sessions[0].transcript[0], count: 367), candidates: [], warnings: [])
        precondition(LocalProcessingService.processingTimeout(audioCount: 0, checkpoint: longManuscript, asrOnly: false, runLabel: "final") == 6_000)
        precondition(LocalProcessingService.processingTimeout(audioCount: 0, checkpoint: longManuscript, asrOnly: true, runLabel: "final") == 1_800)
        precondition(LocalProcessingService.processingTimeout(audioCount: 10_000, checkpoint: nil, asrOnly: false, runLabel: "final") == 21_600)
        precondition(LocalProcessingService.processingTimeout(audioCount: 0, checkpoint: longManuscript, asrOnly: false, runLabel: "annotations") == 180)
        for asrOnly in [false, true] {
            precondition(!LocalProcessingService.mayReuseClassification(requested: true, retranscribe: true, asrOnly: asrOnly, hasTranscript: true))
        }
        precondition(!LocalProcessingService.mayReuseClassification(requested: true, retranscribe: false, asrOnly: true, hasTranscript: true))
        // Completed attempts are reusable even when their model/version tag
        // is absent; only the original-bound attempt metadata is required.
        var proofread = sessions[0].transcript[0]
        proofread.proofreadBasis = proofread.originalText
        proofread.proofreadText = proofread.originalText
        proofread.proofreadUncertainties = []
        proofread.proofreadingVersion = nil
        func proofreadingCheckpoint(_ spans: [TranscriptSpan]) -> LocalProcessingResult {
            LocalProcessingResult(speakers: [speaker], spans: spans, candidates: [], warnings: [])
        }
        precondition(LocalProcessingService.mayReuseProofreading(proofreadingCheckpoint([proofread])), "Completed unchanged attempt without a version must not trigger another proofreading run")
        var changedBasis = proofread; changedBasis.originalText += "新内容"
        precondition(!LocalProcessingService.mayReuseProofreading(proofreadingCheckpoint([changedBasis])))
        for missingField in 0..<3 {
            var incomplete = proofread
            switch missingField {
            case 0: incomplete.proofreadBasis = nil
            case 1: incomplete.proofreadText = nil
            default: incomplete.proofreadUncertainties = nil
            }
            precondition(!LocalProcessingService.mayReuseProofreading(proofreadingCheckpoint([proofread, incomplete])), "Every eligible span needs complete attempt metadata")
        }
        var emptyProofread = proofread; emptyProofread.proofreadText = " \n "
        precondition(!LocalProcessingService.mayReuseProofreading(proofreadingCheckpoint([emptyProofread])))
        var manual = sessions[0].transcript[0]; manual.correctedText = "人工内容"
        var authored = sessions[0].transcript[0]
        authored.origin = SourceReference(sessionID: UUID(), sessionTitle: "合成用户文字", itemID: UUID(), authoredByUser: true)
        precondition(LocalProcessingService.mayReuseProofreading(proofreadingCheckpoint([proofread, manual, authored])), "Manual/user spans are excluded from required AI-attempt metadata")
        precondition(!LocalProcessingService.mayReuseProofreading(proofreadingCheckpoint([manual, authored])), "Excluded spans alone do not claim a reusable AI attempt")
        precondition(!LocalProcessingService.mayReuseProofreading(nil))
        try await verifyFailedProofreadingRecovery(root: root, speaker: speaker)
        // Exercise real manifest/checkpoint serialization, but execute the
        // system's no-op failure binary instead of Python or any model.
        store.asrCommandPath = "/usr/bin/false"
        let manifestProbe = LocalProcessingService(notifier: { _, _ in })
        manifestProbe.process(sessionID: sessions[0].id, audioPaths: [], store: store, reuseTranscriptClassification: true)
        for _ in 0..<500 {
            if !manifestProbe.isProcessing(sessions[0].id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(!manifestProbe.isProcessing(sessions[0].id))
        let processing = store.sessionDirectory(sessions[0].id).appendingPathComponent("Processing")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: processing.appendingPathComponent("manifest-final.json"))) as! [String: Any]
        precondition(manifest["reuse_transcript_classification"] as? Bool == true && manifest["retranscribe"] as? Bool == false)
        let durable = try JSONDecoder().decode(LocalProcessingResult.self, from: Data(contentsOf: processing.appendingPathComponent("structure-input.json")))
        precondition(durable.reuseTranscriptClassification == true)
        let progressLog = root.appendingPathComponent("synthetic-progress.log")
        let start = Date().addingTimeInterval(-1)
        try Data("正在概括第 2/4 个阶段的完整思路\nTraceback ignored\n本地处理完成\n".utf8).write(to: progressLog)
        precondition(LocalProcessingService.latestProgress(logURL: progressLog, since: start) == "正在概括第 2/4 个阶段的完整思路")
        precondition(LocalProcessingService.latestProgress(logURL: progressLog, since: Date().addingTimeInterval(10)) == nil, "Old run progress must not leak into a new attempt")
        print("PASS: completed proofreading attempt without version reuses; changed basis/missing metadata/empty result refuse; manual and user-authored spans are excluded.")
        print("PASS: explicit + queued reuse, default reclassification, durable recovery/checkpoint flag, incomplete existing manuscript without ASR, retranscribe/asrOnly veto, actual manifest flag. Synthetic runner and /usr/bin/false only; no model. \(root.path)")
    }

    @MainActor private static func verifyFailedProofreadingRecovery(root: URL, speaker: Speaker) async throws {
        let directory = root.appendingPathComponent("proofreading-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let baseline = (0..<3).map { index in
            let span = TranscriptSpan(sequence: 1, startTime: 0, endTime: 10, speakerID: speaker.id, originalText: "合成力息 \(index)", isBackgroundAudio: false)
            let node = KnowledgeNode(sourceSpanIDs: [span.id], kind: .main, relation: .root, position: CanvasPoint(x: 0, y: 0))
            return SessionRecord(title: "校订失败恢复 \(index)", sourceName: "test", sourceKind: "test", status: .ready,
                speakers: [speaker], transcript: [span], nodes: [node], transcriptComplete: true, structureSaved: true)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(AppDatabase(sessions: baseline)).write(to: directory.appendingPathComponent("database.json"))
        let store = AppStore(storageRoot: directory), observations = ReuseObservations()
        let records = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        let runner: LocalProcessingService.Runner = { id, _, _, output, _, _, saved, _ in
            await observations.record(id, saved)
            if await observations.count(id) == 1 {
                let old = records[id]!
                var spans = old.transcript
                spans[0].proofreadBasis = spans[0].originalText
                spans[0].proofreadText = spans[0].originalText.replacingOccurrences(of: "力息", with: "利息")
                spans[0].proofreadUncertainties = [] // no version is a completed attempt
                spans[0].proofreadPunctuatedText = spans[0].proofreadText! + "。"
                let partial = LocalProcessingResult(speakers: old.speakers, spans: spans, candidates: [], warnings: [])
                let processing = output.appendingPathComponent("Processing", isDirectory: true)
                try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
                try JSONEncoder().encode(partial).write(to: processing.appendingPathComponent("result-final.json"), options: .atomic)
            }
            try await Task.sleep(for: .milliseconds(80))
            throw NSError(domain: "SyntheticMapFailureAfterProofreading", code: 1)
        }
        let processor = LocalProcessingService(runner: runner, notifier: { _, _ in })
        func record(_ id: UUID) -> SessionRecord { store.database.sessions.first { $0.id == id }! }
        func waitForFinish(_ id: UUID) async throws {
            for _ in 0..<500 {
                if !processor.isProcessing(id) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(!processor.isProcessing(id))
        }
        let first = baseline[0]
        processor.process(sessionID: first.id, audioPaths: [], store: store, reuseTranscriptClassification: true)
        try await waitForFinish(first.id)
        precondition(record(first.id).transcript[0].validProofreadText == "合成利息 0")
        precondition(record(first.id).transcript[0].validProofreadPunctuatedText == "合成利息 0。")
        precondition(record(first.id).nodes == first.nodes && record(first.id).versions == first.versions)
        processor.process(sessionID: first.id, audioPaths: [], store: store, reuseTranscriptClassification: true)
        try await waitForFinish(first.id)
        let reused = await observations.reusedProofreading(first.id)
        precondition(reused == true, "Explicit classification-reuse retry must receive the saved failed-run proofreading")
        store.clearCorrectedText(spanID: first.transcript[0].id, sessionID: first.id)
        processor.process(sessionID: first.id, audioPaths: [], store: store, reuseTranscriptClassification: true)
        try await waitForFinish(first.id)
        let restored = await observations.reusedProofreading(first.id)
        precondition(restored == false && record(first.id).transcript[0].proofreadText == nil, "Old disk checkpoint must not resurrect restored raw text")
        precondition(record(first.id).transcript[0].proofreadPunctuatedText == nil)
        for (index, source) in baseline.enumerated() where index > 0 {
            processor.process(sessionID: source.id, audioPaths: [], store: store, reuseTranscriptClassification: true)
            for _ in 0..<500 {
                if await observations.count(source.id) > 0 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            if index == 1 {
                store.updateCorrectedText("处理中我的修正", spanID: source.transcript[0].id, sessionID: source.id)
            } else {
                store.clearCorrectedText(spanID: source.transcript[0].id, sessionID: source.id)
            }
            let versions = record(source.id).versions
            try await waitForFinish(source.id)
            precondition(record(source.id).transcript[0].proofreadText == nil)
            precondition(record(source.id).versions == versions && record(source.id).nodes == source.nodes)
            if index == 1 { precondition(record(source.id).transcript[0].correctedText == "处理中我的修正") }
        }
        let current = record(first.id)
        var changed = current.transcript
        changed[0].proofreadBasis = changed[0].originalText; changed[0].proofreadText = "错误缓存"
        changed[0].proofreadUncertainties = []; changed[0].isBackgroundAudio = true
        precondition(!store.preserveProofreadingAfterFailure(LocalProcessingResult(speakers: current.speakers, spans: changed, candidates: [], warnings: []), matching: current), "A failed result cannot change background classification through a proof-only save")
        changed[0].isBackgroundAudio = current.transcript[0].isBackgroundAudio
        let candidate = StructureCandidate(sourceSpanIDs: [changed[0].id], kind: .main, relation: .root, confidence: 1, summary: "not a failure checkpoint")
        precondition(!store.preserveProofreadingAfterFailure(LocalProcessingResult(speakers: current.speakers, spans: changed, candidates: [candidate], warnings: []), matching: current))
        print("PASS: current failed runner checkpoint saves proof fields only; reuse retry keeps them; stale disk, manual edits, in-flight restore, source changes and completed candidates cannot overwrite current content.")
    }
}

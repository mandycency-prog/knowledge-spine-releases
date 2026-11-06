import Combine
import Foundation
import KnowledgeSpineCore

private actor RelistenProbeRuns {
    let result: LocalProcessingResult
    let expectedResumeLabel: String?
    let expectsResumeCheckpoint: Bool
    var labels: [String] = []
    var notices: [String] = []
    init(result: LocalProcessingResult, expectedResumeLabel: String? = nil, expectsResumeCheckpoint: Bool = true) {
        self.result = result
        self.expectedResumeLabel = expectedResumeLabel
        self.expectsResumeCheckpoint = expectsResumeCheckpoint
    }
    func invoke(label: String, checkpoint: LocalProcessingResult?, directory: URL) throws -> LocalProcessingResult {
        labels.append(label)
        precondition(label.hasPrefix("relisten-") && UUID(uuidString: String(label.dropFirst(9))) != nil)
        if let expectedResumeLabel {
            precondition(label == expectedResumeLabel && (expectsResumeCheckpoint
                         ? checkpoint?.spans.map(\.id) == result.spans.map(\.id) : checkpoint == nil),
                         "Restart did not reuse this relisten job's exact checkpoint")
            return result
        }
        if labels.count == 1 {
            precondition(checkpoint == nil, "Fresh relisten reused the old manuscript or final checkpoint")
            let processing = directory.appendingPathComponent("Processing", isDirectory: true)
            try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
            let partial = LocalProcessingResult(speakers: result.speakers, spans: result.spans, candidates: [], warnings: [])
            try JSONEncoder().encode(partial).write(to: processing.appendingPathComponent("result-\(label).json"), options: .atomic)
            throw LocalProcessingFailure.processFailed("isolated structure failure after fresh ASR")
        }
        precondition(labels.count == 2 && label == labels[0], "Retry changed the relisten job identity")
        precondition(checkpoint?.spans.map(\.id) == result.spans.map(\.id), "Retry reused a different job's old checkpoint")
        return result
    }
    func notify(_ title: String) { notices.append(title) }
}

@MainActor final class CaptureEvents: CaptureEventSource {
    var recordingSessionID: UUID?
    var isRecording = true
    var segmentOffsets: [String: TimeInterval] = [:]
    let segments = PassthroughSubject<[URL], Never>()
    let interruptions = PassthroughSubject<CaptureInterruption?, Never>()
    let warnings = PassthroughSubject<String?, Never>()
    var completedSegmentsPublisher: AnyPublisher<[URL], Never> { segments.eraseToAnyPublisher() }
    var interruptionPublisher: AnyPublisher<CaptureInterruption?, Never> { interruptions.eraseToAnyPublisher() }
    var warningPublisher: AnyPublisher<String?, Never> { warnings.eraseToAnyPublisher() }
}

@main struct Probe {
    @MainActor static func main() async throws {
        let store = AppStore(inMemory: true)
        precondition(!store.dataRoot.path.contains("Application Support"), "Test is not isolated")
        let id = store.createSession(title: "学习流程测试", sourceName: "测试事件", sourceKind: "测试")
        let otherID = store.createSession(title: "正在浏览的另一场", sourceName: "", sourceKind: "测试")
        let source = CaptureEvents()
        source.recordingSessionID = id
        var previews: [(UUID, String, TimeInterval)] = []
        var interrupted: [UUID] = []
        var warnings: [String] = []
        let lifecycle = CaptureLifecycleCoordinator(
            store: store, source: source,
            enqueuePreview: { previews.append(($0, $1, $2)) },
            processInterrupted: { id, _ in interrupted.append(id) },
            notifyIssue: { warnings.append($0) }
        )
        // No SwiftUI view/window exists. Drive the production subscription.
        let audio = ["audio-0001.m4a", "audio-0002.m4a"].map { store.dataRoot.appendingPathComponent($0) }
        source.segmentOffsets[audio[0].path] = 0
        source.segmentOffsets[audio[1].path] = 14.82
        source.segments.send([audio[1]]) // completion callbacks may arrive out of order
        source.segments.send([audio[1], audio[0]])
        source.segments.send([audio[1], audio[0]])
        precondition(previews.count == 2 && previews.allSatisfy { $0.0 == id })
        precondition(previews.first?.2 == 14.82, "Actual offset was replaced with assumed 15 seconds")
        precondition(store.database.sessions.first { $0.id == id }!.audioRelativePaths == audio.map(\.path))
        precondition(store.database.sessions.first { $0.id == otherID }!.audioRelativePaths.isEmpty)
        source.warnings.send("没有收到声音")
        source.warnings.send("没有收到声音")
        precondition(warnings.count == 1)
        source.warnings.send(nil)
        source.warnings.send("没有收到声音")
        precondition(warnings.count == 2)
        let interruption = CaptureInterruption(sessionID: id, urls: audio, message: "测试中断")
        source.interruptions.send(interruption)
        source.interruptions.send(interruption)
        precondition(interrupted == [id], "Interruption was lost or processed twice")
        withExtendedLifetime(lifecycle) {}

        store.statusMessage = nil
        store.addThought("我自己的思考，必须原封不动。", sessionID: id, live: true, anchorTime: 2)
        let thoughtNodeID = store.database.sessions.first { $0.id == id }!.nodes.first { $0.thoughtID != nil }!.id
        store.markNearbyImportant(sessionID: id, elapsedTime: 2)
        precondition(store.statusMessage == nil, "Marking interrupted learning with a modal")
        let speaker = Speaker(role: .host)
        let span = TranscriptSpan(sequence: 1, startTime: 0, endTime: 5, speakerID: speaker.id, originalText: "学习之后主动回忆，再找一个新的例子应用。")
        let candidate = StructureCandidate(sourceSpanIDs: [span.id], kind: .main, relation: .root, confidence: 0.9, summary: "主动回忆与应用")
        let recordedInputs = AnnotationInput.from(store.database.sessions.first { $0.id == id }!)
        let recordedMark = recordedInputs.first { $0.kind == "important" }!
        let result = LocalProcessingResult(speakers: [speaker], spans: [span], candidates: [candidate], warnings: [],
            annotationSummaries: [AnnotationSummary(id: recordedMark.id, summary: "主动回忆后迁移应用")], annotationInputs: recordedInputs)
        store.completeLocalProcessing(result, sessionID: id)
        let ready = store.database.sessions.first { $0.id == id }!
        precondition(ready.status == .ready && ready.structureSaved)
        precondition((ready.candidateVersions ?? []).isEmpty, "First result requires manual acceptance")
        precondition(ready.nodes.contains { $0.id == candidate.nodeID })
        precondition(ready.nodes.contains { $0.id == thoughtNodeID && $0.userEditedText == "我自己的思考，必须原封不动。" && $0.parentID == candidate.nodeID })
        precondition(ready.nodes.contains { $0.importantMarkID != nil && $0.parentID == candidate.nodeID })
        precondition(ready.transcript[0].isImportant)
        let readyMark = ready.nodes.first { $0.importantMarkID == recordedMark.id }!
        precondition(readyMark.aiSummary == "主动回忆后迁移应用", "Final ASR resolution incorrectly discarded the mark summary")
        precondition(readyMark.annotationInputFingerprint == AnnotationInput.from(ready).first { $0.id == recordedMark.id }!.fingerprint)
        precondition(store.statusMessage == nil)

        // Cancelling a timed bookmark is permanent, even when ASR IDs change.
        let stableMarkID = ready.importantMarks!.first!.id
        store.toggleImportant(spanID: ready.transcript[0].id, sessionID: id)
        store.appendLiveTranscription(LocalProcessingResult(speakers: [speaker], spans: [span], candidates: [], warnings: []), sessionID: id, timeOffset: 10)
        precondition(store.database.sessions.first { $0.id == id }!.importantMarks!.allSatisfy { $0.id != stableMarkID })
        precondition(store.database.sessions.first { $0.id == id }!.transcript[0].isImportant == false, "Cancelled timed bookmark returned")
        store.setStatus(.ready, sessionID: id)

        // Notes added after the outline are summarized on their own, not by
        // rerunning ASR/the map, and the exact user text remains authoritative.
        let noteStore = AppStore(inMemory: true)
        let noteID = noteStore.createSession(title: "后添思考", sourceName: "", sourceKind: "test")
        noteStore.completeLocalProcessing(result, sessionID: noteID)
        let exactNote = "  **原文**，不能改。\n第二行。  "
        noteStore.addThought(exactNote, sessionID: noteID, live: false)
        let addedNoteID = noteStore.database.sessions.first!.thoughts.first!.id
        let retryRuns = ScriptedRuns(result: LocalProcessingResult(speakers: [speaker], spans: [span], candidates: [], warnings: [],
            annotationSummaries: [AnnotationSummary(id: addedNoteID, summary: "保留原文")]))
        let noteWorker = LocalProcessingService(runner: { _, audio, _, _, _, label, checkpoint, inputs in
            precondition(audio.isEmpty && label == "annotations" && checkpoint?.spans.count == 1 && inputs.count == 1)
            return try await retryRuns.invoke(id: noteID, checkpoint: checkpoint, alwaysFail: false)
        }, notifier: { _, _ in })
        noteWorker.scheduleMissingAnnotations(store: noteStore)
        for _ in 0..<300 {
            if noteStore.database.sessions.first!.nodes.contains(where: { $0.thoughtID != nil && $0.aiSummary == "保留原文" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let annotationTries = await retryRuns.attempts[noteID]
        precondition(annotationTries == 2, "Transient annotation failure did not retry")
        precondition(noteStore.database.sessions.first!.thoughts.first!.text == exactNote)
        precondition(noteStore.database.sessions.first!.nodes.contains { $0.thoughtID != nil && $0.aiSummary == "保留原文" })
        precondition(noteStore.database.sessions.first!.nodes.filter { $0.thoughtID == nil }.map(\.id) == [candidate.nodeID])
        noteStore.toggleImportant(spanID: span.id, sessionID: noteID)
        let oldMarkInput = AnnotationInput.from(noteStore.database.sessions.first!).first { $0.kind == "important" }!
        noteStore.applyAnnotationSummaries([AnnotationSummary(id: oldMarkInput.id, summary: "旧版本已成功概括")], inputs: [oldMarkInput], sessionID: noteID)
        precondition(noteStore.database.sessions.first!.nodes.first { $0.importantMarkID == oldMarkInput.id }?.aiSummary != nil)
        noteStore.updateCorrectedText("用户修正后的用词", spanID: span.id, sessionID: noteID)
        let currentMarkInput = AnnotationInput.from(noteStore.database.sessions.first!).first { $0.kind == "important" }!
        precondition(oldMarkInput.fingerprint != currentMarkInput.fingerprint)
        precondition(noteStore.database.sessions.first!.nodes.first { $0.importantMarkID == oldMarkInput.id }?.aiSummary == nil,
                     "Changed source still displayed the obsolete annotation summary")
        noteStore.applyAnnotationSummaries([AnnotationSummary(id: oldMarkInput.id, summary: "旧版本概括")], inputs: [oldMarkInput], sessionID: noteID)
        precondition(noteStore.database.sessions.first!.nodes.first { $0.importantMarkID == oldMarkInput.id }?.aiSummary == nil,
                     "Stale correction summary was applied")

        // A second analysis must still preserve the user's existing graph.
        store.updateNodePosition(candidate.nodeID, point: CanvasPoint(x: 777, y: 888), sessionID: id)
        let before = store.database.sessions.first { $0.id == id }!.nodes
        try store.applyStructureCandidates([candidate], sessionID: id)
        let after = store.database.sessions.first { $0.id == id }!
        precondition(after.nodes == before && after.candidateVersions?.count == 1)
        let sameMeaningNewID = StructureCandidate(sourceSpanIDs: [span.id], kind: .main, relation: .root, confidence: 0.9, summary: "主动回忆与应用")
        try store.applyStructureCandidates([sameMeaningNewID], sessionID: id)
        let fitBefore = store.canvasFitRevisions[id, default: 0]
        store.acceptLatestCandidate(sessionID: id, arrangeAsNewMap: true)
        precondition(store.canvasFitRevisions[id, default: 0] == fitBefore + 1, "Same-root relayout did not request viewport fit")
        let arranged = store.database.sessions.first { $0.id == id }!
        let arrangedIDs = Set(arranged.nodes.map(\.id))
        precondition(arranged.nodes.filter { $0.parentID == nil }.count == 1)
        precondition(arranged.nodes.allSatisfy { $0.parentID == nil || arrangedIDs.contains($0.parentID!) }, "Relayout used a replaced candidate root ID")
        precondition(arranged.versions.last!.nodes.contains { $0.id == candidate.nodeID && $0.position == CanvasPoint(x: 777, y: 888) })
        store.restoreLatestVersion(sessionID: id)
        precondition(store.canvasFitRevisions[id, default: 0] == fitBefore + 2, "Undo did not request viewport fit")
        let newID = store.sessionForNewRecording(from: id)
        precondition(newID != id && store.database.sessions.first { $0.id == id }!.audioRelativePaths == audio.map(\.path))
        precondition(store.sessionForNewRecording(from: newID) == newID)
        print("PASS: window-independent event handling, exact offsets, deduplication, wrong-session guard, interruption recovery, nonmodal marks, automatic first outline with verbatim thoughts/marks, reanalysis protection, safe subsequent recording")
        try runCanvasDragChecks()
        try await runRelistenChecks()
        try await RecoveryChecks.run()
    }

    @MainActor private static func runRelistenChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeSpine-Relisten-Isolation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let speaker = Speaker(role: .host)
        let oldSpan = TranscriptSpan(sequence: 1, startTime: 0, endTime: 20, speakerID: speaker.id, originalText: "旧稿不能冒充这次重新识别的结果。")
        let oldNode = StructureCandidate(sourceSpanIDs: [oldSpan.id], kind: .main, relation: .root, confidence: 0.9, summary: "旧版课程问题")
        let oldResult = LocalProcessingResult(speakers: [speaker], spans: [oldSpan], candidates: [oldNode], warnings: [])
        let newSpan = TranscriptSpan(sequence: 1, startTime: 0, endTime: 20, speakerID: speaker.id, originalText: "本次重新识别得到的新稿，先保存成完整候选。")
        let newNode = StructureCandidate(sourceSpanIDs: [newSpan.id], kind: .main, relation: .root, confidence: 0.9, summary: "新版课程问题")
        let newResult = LocalProcessingResult(speakers: [speaker], spans: [newSpan], candidates: [newNode], warnings: [])
        let disk = AppStore(storageRoot: root.appendingPathComponent("fresh"))
        let id = disk.createSession(title: "独立重听验收", sourceName: "合成测试", sourceKind: "test")
        precondition(disk.completeLocalProcessing(oldResult, sessionID: id))
        disk.attachAudio(paths: [disk.sessionDirectory(id).appendingPathComponent("not-opened-by-mock.m4a").path], sessionID: id)
        let processing = disk.sessionDirectory(id).appendingPathComponent("Processing", isDirectory: true)
        try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
        try JSONEncoder().encode(oldResult).write(to: processing.appendingPathComponent("result-final.json"), options: .atomic)
        let before = disk.database.sessions.first!
        let runs = RelistenProbeRuns(result: newResult)
        let worker = LocalProcessingService(runner: { _, _, _, directory, _, label, checkpoint, _ in
            try await runs.invoke(label: label, checkpoint: checkpoint, directory: directory)
        }, notifier: { title, _ in await runs.notify(title) })
        worker.process(sessionID: id, audioPaths: before.audioRelativePaths, store: disk, retranscribe: true)
        for _ in 0..<500 where worker.isProcessing(id) { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!worker.isProcessing(id))
        for _ in 0..<50 { if await runs.notices.count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let labels = await runs.labels
        let notices = await runs.notices
        precondition(labels.count == 2 && labels[0] == labels[1])
        precondition(notices == ["新版稿件与导图已准备好"], "A staged candidate was announced as replacing the current course")
        let prepared = disk.database.sessions.first!
        precondition(prepared.transcript == before.transcript && prepared.nodes == before.nodes && prepared.status == .ready)
        precondition(prepared.candidateVersions?.last?.transcript?.map(\.id) == [newSpan.id])
        precondition(prepared.processingRunLabel == nil && prepared.processingRetranscribe == nil)
        precondition(disk.flush())
        let rejectedResult = LocalProcessingResult(speakers: [speaker], spans: [newSpan], candidates: [], warnings: ["隔离的无效结构结果"])
        let rejectedRuns = RelistenProbeRuns(result: rejectedResult)
        let rejectedWorker = LocalProcessingService(runner: { _, _, _, directory, _, label, checkpoint, _ in
            try await rejectedRuns.invoke(label: label, checkpoint: checkpoint, directory: directory)
        }, notifier: { title, _ in await rejectedRuns.notify(title) })
        rejectedWorker.process(sessionID: id, audioPaths: before.audioRelativePaths, store: disk, retranscribe: true)
        for _ in 0..<500 where rejectedWorker.isProcessing(id) { try await Task.sleep(for: .milliseconds(20)) }
        for _ in 0..<50 { if await rejectedRuns.notices.count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let rejectedNotices = await rejectedRuns.notices
        precondition(!rejectedWorker.isProcessing(id) && rejectedNotices == ["课程整理需要注意"],
                     "A rejected candidate was announced as successfully prepared")
        let rejected = disk.database.sessions.first!
        precondition(rejected.status == .ready && rejected.transcript == prepared.transcript && rejected.nodes == prepared.nodes)
        precondition(rejected.candidateVersions == prepared.candidateVersions, "Rejected processing changed the saved candidate")
        precondition(disk.flush())

        // Persist a crashed relisten after ASR, including an unrelated old final
        // checkpoint. Recovery must select the durable per-job result instead.
        let recoveryRoot = root.appendingPathComponent("restart")
        let seeded = AppStore(storageRoot: recoveryRoot)
        let recoveryID = seeded.createSession(title: "重听中断恢复", sourceName: "合成测试", sourceKind: "test")
        precondition(seeded.completeLocalProcessing(oldResult, sessionID: recoveryID))
        seeded.attachAudio(paths: [seeded.sessionDirectory(recoveryID).appendingPathComponent("not-opened-by-mock.m4a").path], sessionID: recoveryID)
        let resumeLabel = "relisten-\(UUID().uuidString)"
        seeded.beginProcessingAttempt(sessionID: recoveryID, resetBudget: true, runLabel: resumeLabel, retranscribe: true)
        let resumeDirectory = seeded.sessionDirectory(recoveryID).appendingPathComponent("Processing", isDirectory: true)
        try FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(oldResult).write(to: resumeDirectory.appendingPathComponent("result-final.json"), options: .atomic)
        try JSONEncoder().encode(newResult).write(to: resumeDirectory.appendingPathComponent("result-\(resumeLabel).json"), options: .atomic)
        precondition(seeded.flush())
        let reopened = AppStore(storageRoot: recoveryRoot)
        precondition(reopened.database.sessions.first!.status == .failed && reopened.database.sessions.first!.processingRunLabel == resumeLabel)
        let resumedRuns = RelistenProbeRuns(result: newResult, expectedResumeLabel: resumeLabel)
        let resumer = LocalProcessingService(runner: { _, _, _, directory, _, label, checkpoint, _ in
            try await resumedRuns.invoke(label: label, checkpoint: checkpoint, directory: directory)
        }, notifier: { _, _ in })
        resumer.resumeInterrupted(store: reopened)
        for _ in 0..<500 where resumer.isProcessing(recoveryID) { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!resumer.isProcessing(recoveryID))
        let resumedLabels = await resumedRuns.labels
        precondition(resumedLabels == [resumeLabel])
        precondition(reopened.database.sessions.first!.transcript.map(\.id) == [oldSpan.id])
        precondition(reopened.database.sessions.first!.candidateVersions?.last?.transcript?.map(\.id) == [newSpan.id])
        precondition(reopened.flush())
        // The queued request must be recoverable even before its first runner
        // invocation. Snapshot it while another session deliberately holds the
        // model lane, then recover that exact snapshot in a separate directory.
        let queuedStore = AppStore(storageRoot: root.appendingPathComponent("queued"))
        let blockerID = queuedStore.createSession(title: "占用模型通道", sourceName: "合成测试", sourceKind: "test")
        let queuedID = queuedStore.createSession(title: "尚未开始的重新转写", sourceName: "合成测试", sourceKind: "test")
        for value in [blockerID, queuedID] {
            precondition(queuedStore.completeLocalProcessing(oldResult, sessionID: value))
            queuedStore.attachAudio(paths: [queuedStore.sessionDirectory(value).appendingPathComponent("unused.m4a").path], sessionID: value)
        }
        let gate = NotificationGate()
        let dequeuedRuns = RelistenProbeRuns(result: newResult)
        let queueWorker = LocalProcessingService(runner: { value, _, _, directory, _, label, checkpoint, _ in
            if value == blockerID { await gate.hold(); return oldResult }
            return try await dequeuedRuns.invoke(label: label, checkpoint: checkpoint, directory: directory)
        }, notifier: { _, _ in })
        queueWorker.process(sessionID: blockerID, audioPaths: ["unused"], store: queuedStore)
        queueWorker.process(sessionID: queuedID, audioPaths: ["unused"], store: queuedStore, retranscribe: true)
        let queued = queuedStore.database.sessions.first { $0.id == queuedID }!
        precondition(queued.processingRetranscribe == true && queued.processingRunLabel?.hasPrefix("relisten-") == true,
                     "Queued relisten intent was not persisted before execution")
        precondition(queued.automaticRecoveryAttempts == 0 && queued.recoveryPending == true)
        let crashRoot = root.appendingPathComponent("queued-restart")
        try FileManager.default.createDirectory(at: crashRoot, withIntermediateDirectories: true)
        let persistedEncoder = JSONEncoder(); persistedEncoder.dateEncodingStrategy = .iso8601
        try persistedEncoder.encode(AppDatabase(sessions: [queued])).write(to: crashRoot.appendingPathComponent("database.json"), options: .atomic)
        let queuedRestart = AppStore(storageRoot: crashRoot)
        let queuedRuns = RelistenProbeRuns(result: newResult, expectedResumeLabel: queued.processingRunLabel!, expectsResumeCheckpoint: false)
        let queuedResumer = LocalProcessingService(runner: { _, _, _, directory, _, label, checkpoint, _ in
            try await queuedRuns.invoke(label: label, checkpoint: checkpoint, directory: directory)
        }, notifier: { _, _ in })
        queuedResumer.resumeInterrupted(store: queuedRestart)
        for _ in 0..<500 where queuedResumer.isProcessing(queuedID) { try await Task.sleep(for: .milliseconds(20)) }
        let queuedLabels = await queuedRuns.labels
        precondition(queuedLabels == [queued.processingRunLabel!])
        precondition(queuedRestart.database.sessions.first!.transcript.map(\.id) == [oldSpan.id])
        precondition(queuedRestart.database.sessions.first!.candidateVersions?.last?.transcript?.map(\.id) == [newSpan.id])
        for _ in 0..<50 { if await gate.count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        await gate.release()
        for _ in 0..<500 where queueWorker.isProcessing(queuedID) { try await Task.sleep(for: .milliseconds(20)) }
        let dequeuedLabels = await dequeuedRuns.labels
        precondition(dequeuedLabels == [queued.processingRunLabel!, queued.processingRunLabel!], "Dequeue or retry replaced a queued job identity")
        precondition(!queueWorker.isProcessing(queuedID) && queuedStore.flush() && queuedRestart.flush())
        print("PASS: fresh relisten ignores stale final output; retries/restart reuse only their durable job identity and announce a candidate without replacing current source")
    }

    @MainActor private static func runCanvasDragChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeSpine-Drag-Isolation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = AppStore(storageRoot: root)
        precondition(disk.dataRoot == root && !root.path.contains("Application Support"))
        let sessionID = disk.createSession(title: "拖动坐标隔离验收", sourceName: "隔离测试", sourceKind: "test")
        let speaker = Speaker(role: .host)
        let spans = (0..<4).map { index in
            TranscriptSpan(sequence: index + 1, startTime: Double(index * 10), endTime: Double(index * 10 + 8),
                           speakerID: speaker.id, originalText: "隔离原文第\(index + 1)段，保留方法与证据。")
        }
        let center = StructureCandidate(sourceSpanIDs: [spans[0].id], kind: .main, relation: .root, confidence: 0.9, summary: "学习方法的验证")
        let first = StructureCandidate(sourceSpanIDs: [spans[1].id], kind: .branch, parentID: center.nodeID, relation: .child, confidence: 0.9, summary: "先回忆再核对")
        let detail = StructureCandidate(sourceSpanIDs: [spans[2].id], kind: .evidence, parentID: center.nodeID, relation: .supports, confidence: 0.9, summary: "用于核对的细节")
        let last = StructureCandidate(sourceSpanIDs: [spans[3].id], kind: .branch, parentID: center.nodeID, relation: .child, confidence: 0.9, summary: "迁移到新的例子")
        disk.completeLocalProcessing(LocalProcessingResult(speakers: [speaker], spans: spans,
            candidates: [center, first, detail, last], warnings: []), sessionID: sessionID)
        let exactThought = "  我写的思考，不能因为拖动而改变。\n第二行原文。  "
        disk.addThought(exactThought, sessionID: sessionID, attachedNodeID: center.nodeID, live: false)
        let before = disk.database.sessions.first { $0.id == sessionID }!
        let visible = CanvasOverviewLayout.arrange(IntegrityValidator.presentationNodes(before.nodes, transcript: before.transcript, overviewOnly: true))
        let displayed = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.position) })
        precondition(displayed[detail.nodeID] == nil)
        let start = displayed[first.nodeID]!
        let moved = CanvasDragGeometry.position(origin: start, dx: 46, dy: 108, zoom: 0.88)
        let target = CanvasPoint(x: moved.x, y: moved.y)
        let fitBefore = disk.canvasFitRevisions[sessionID, default: 0]
        disk.updateNodePosition(first.nodeID, point: target, sessionID: sessionID, displayedPositions: displayed)
        let after = disk.database.sessions.first { $0.id == sessionID }!
        let afterOverview = CanvasOverviewLayout.arrange(IntegrityValidator.presentationNodes(after.nodes, transcript: after.transcript, overviewOnly: true))
        for old in before.nodes {
            let saved = after.nodes.first { $0.id == old.id }!
            if old.id == first.nodeID {
                precondition(saved.position == target && saved.manualRevisionAt != nil && saved.positionEditedAt != nil)
            } else {
                precondition(saved.manualRevisionAt == old.manualRevisionAt && saved.positionEditedAt == old.positionEditedAt,
                             "Dragging one node falsely marked a peer as an authored edit")
                if let position = displayed[old.id] {
                    precondition(saved.position == position && afterOverview.first { $0.id == old.id }!.position == position,
                                 "A peer moved after a different node was released")
                } else {
                    precondition(saved == old, "Dragging the overview changed a hidden detail")
                }
            }
            precondition(saved.userEditedText == old.userEditedText && saved.aiSummary == old.aiSummary && saved.parentID == old.parentID)
        }
        precondition(after.thoughts == before.thoughts && after.thoughts.first!.text == exactThought)
        precondition(disk.canvasFitRevisions[sessionID, default: 0] == fitBefore, "Dragging requested viewport recentering")
        // The full view must arrange newly visible automatic details around the
        // frozen overview; it must not move existing peers to avoid collisions.
        let full = CanvasOverviewLayout.arrange(IntegrityValidator.presentationNodes(after.nodes, transcript: after.transcript))
        for node in full where displayed[node.id] != nil {
            precondition(node.position == (node.id == first.nodeID ? target : displayed[node.id]!))
        }
        let revealed = full.first { $0.id == detail.nodeID }!
        precondition(full.filter { $0.id != detail.nodeID }.allSatisfy {
            abs($0.position.x - revealed.position.x) >= 320 || abs($0.position.y - revealed.position.y) >= 220
        }, "Newly revealed automatic detail overlapped a frozen visible node")
        precondition(disk.flush(), "Isolated drag state failed to persist")
        let restarted = AppStore(storageRoot: root)
        let reloaded = restarted.database.sessions.first { $0.id == sessionID }!
        let persistedEncoder = JSONEncoder()
        persistedEncoder.dateEncodingStrategy = .iso8601
        persistedEncoder.outputFormatting = [.sortedKeys]
        let beforeRestartNodes = try persistedEncoder.encode(after.nodes)
        let afterRestartNodes = try persistedEncoder.encode(reloaded.nodes)
        let beforeRestartThoughts = try persistedEncoder.encode(after.thoughts)
        let afterRestartThoughts = try persistedEncoder.encode(reloaded.thoughts)
        precondition(afterRestartNodes == beforeRestartNodes && afterRestartThoughts == beforeRestartThoughts,
                     "Restart changed frozen positions or authored content")
        let reloadedOverview = CanvasOverviewLayout.arrange(IntegrityValidator.presentationNodes(reloaded.nodes, transcript: reloaded.transcript, overviewOnly: true))
        precondition(Dictionary(uniqueKeysWithValues: reloadedOverview.map { ($0.id, $0.position) }) ==
                     Dictionary(uniqueKeysWithValues: afterOverview.map { ($0.id, $0.position) }),
                     "Restart changed the visible overview coordinates")
        let replacement = StructureCandidate(sourceSpanIDs: [spans[0].id], kind: .main, relation: .root, confidence: 0.9, summary: "重新归纳后的课程问题")
        let merged = StructureVersionMerge.merge(current: reloaded.nodes, candidate: [KnowledgeNode(id: replacement.nodeID,
            sourceSpanIDs: replacement.sourceSpanIDs, kind: .main, relation: .root, position: CanvasPoint(x: 190, y: 150), aiSummary: replacement.summary)])
        precondition(merged.contains { $0.id == first.nodeID }, "The truly dragged node lost manual protection")
        precondition(!merged.contains { $0.id == last.nodeID || $0.id == center.nodeID }, "Frozen layout peers were incorrectly protected as manual content during reanalysis")
        precondition(merged.contains { $0.thoughtID == after.thoughts.first!.id && $0.userEditedText == exactThought })
        print("PASS: isolated overview drag keeps peer positions, preserves authorship, avoids revealed-detail collisions, survives restart, and does not protect layout-only peers during reanalysis")
    }
}

@preconcurrency import AVFoundation
import Foundation
import Darwin
import KnowledgeSpineCore

actor ScriptedRuns {
    var attempts: [UUID: Int] = [:]
    var reused: [UUID: Bool] = [:]
    let result: LocalProcessingResult
    init(result: LocalProcessingResult) { self.result = result }
    func invoke(id: UUID, checkpoint: LocalProcessingResult?, alwaysFail: Bool) throws -> LocalProcessingResult {
        attempts[id, default: 0] += 1
        reused[id] = checkpoint != nil
        if alwaysFail || attempts[id] == 1 { throw LocalProcessingFailure.processFailed("injected transient failure") }
        return result
    }
}

actor NotificationGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async { await withCheckedContinuation { waiters.append($0) } }
    var count: Int { waiters.count }
    func release() { let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

enum RecoveryChecks {
    @MainActor static func run() async throws {
        // Reproduce stop/preview cancellation: the worker's reader disappears
        // immediately before a pending request is written. Default SIGPIPE
        // must not kill this test process or the recording app.
        signal(SIGPIPE, SIG_DFL)
        for _ in 0..<100 {
            let pipe = Pipe()
            try LiveTranscriptionWorker.protectPipeFromBrokenReader(pipe.fileHandleForWriting)
            try pipe.fileHandleForReading.close()
            do {
                try pipe.fileHandleForWriting.write(contentsOf: Data("request\n".utf8))
                preconditionFailure("Writing to a closed worker pipe unexpectedly succeeded")
            } catch { /* EPIPE is a failed preview, not a fatal app signal. */ }
            try pipe.fileHandleForWriting.close()
        }
        print("PASS: 100 closed-reader request writes survive with default SIGPIPE handling")
        var exitedWorkerSettings = AppSettings()
        exitedWorkerSettings.pythonPath = "/usr/bin/false"
        for index in 0..<40 {
            let previewWorker = LiveTranscriptionWorker()
            let request = Task { [exitedWorkerSettings] in
                try await previewWorker.transcribe(path: "unused-test-audio", settings: exitedWorkerSettings)
            }
            if index % 2 == 0 {
                try await Task.sleep(for: .milliseconds(1))
                previewWorker.cancel()
                await previewWorker.waitForExit()
            }
            do {
                _ = try await request.value
                preconditionFailure("Exited/cancelled worker returned a successful transcript")
            } catch {}
            previewWorker.cancel()
            await previewWorker.waitForExit()
        }
        print("PASS: 40 exited/cancelled real child requests fail without killing the parent")
        exitedWorkerSettings.pythonPath = "/nonexistent-KnowledgeSpine-test-python"
        let missingWorker = LiveTranscriptionWorker()
        do {
            _ = try await missingWorker.transcribe(path: "unused", settings: exitedWorkerSettings)
            preconditionFailure("Missing executable unexpectedly launched")
        } catch {}
        missingWorker.cancel()
        await missingWorker.waitForExit()
        print("PASS: failed launch also releases the worker completion group")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeSpine-recovery-tests-\(UUID())")
        // This test owns this unique directory; no production records are read.
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let speaker = Speaker(role: .host)
        let splitWords = [
            TranscriptSpan(sequence: 1, startTime: 0, endTime: 1, speakerID: speaker.id, originalText: "选择教"),
            TranscriptSpan(sequence: 2, startTime: 1, endTime: 2, speakerID: speaker.id, originalText: "材", punctuatedText: "材。")
        ]
        let splitRecord = SessionRecord(title: "索引不是句号", sourceName: "test", sourceKind: "test",
                                        speakers: [speaker], transcript: splitWords)
        let renderedTranscript = ExportService.makeTranscript(session: splitRecord, speakerName: { _ in "主播" })
        precondition(renderedTranscript.contains("选择教材。") && !renderedTranscript.contains("教。材"),
                     "Transcript export inserted punctuation at a timing-index boundary")
        precondition(splitWords.map(\.displayedText).joined() == "选择教材。")
        print("PASS: continuous manuscript display/export does not split a word with invented punctuation")
        let span = TranscriptSpan(sequence: 1, startTime: 0, endTime: 2, speakerID: speaker.id, originalText: "主动回忆能检验理解，应用能检验迁移。")
        let candidate = StructureCandidate(sourceSpanIDs: [span.id], kind: .main, relation: .root, confidence: 0.9, summary: "主动回忆与应用")
        let result = LocalProcessingResult(speakers: [speaker], spans: [span], candidates: [candidate], warnings: [])
        let mergeRoot = root.appendingPathComponent("candidate-merge")
        let mergeStore = AppStore(storageRoot: mergeRoot)
        let mergeID = mergeStore.createSession(title: "候选与人工思考", sourceName: "fixture", sourceKind: "test")
        mergeStore.completeLocalProcessing(result, sessionID: mergeID)
        let oldNodeID = mergeStore.database.sessions.first { $0.id == mergeID }!.nodes[0].id
        for _ in 0..<2 {
            mergeStore.addThought("同一句思考，不同的记录", sessionID: mergeID, attachedNodeID: oldNodeID, live: false)
        }
        let authored = mergeStore.database.sessions.first { $0.id == mergeID }!.thoughts
        for thought in authored { mergeStore.reattachThought(thought.id, to: oldNodeID, sessionID: mergeID) }
        let beforeNodes = mergeStore.database.sessions.first { $0.id == mergeID }!.nodes.filter { $0.thoughtID != nil }
        for (index, node) in beforeNodes.enumerated() {
            mergeStore.updateNodePosition(node.id, point: .init(x: 500 + Double(index) * 200, y: 600), sessionID: mergeID)
        }
        let replacement = StructureCandidate(sourceSpanIDs: [span.id], kind: .main, relation: .root, confidence: 0.9, summary: "检验学习效果的两种方法")
        try mergeStore.applyStructureCandidates([replacement], sessionID: mergeID)
        mergeStore.acceptLatestCandidate(sessionID: mergeID)
        precondition(mergeStore.flush())
        let reopenedMerge = AppStore(storageRoot: mergeRoot)
        let mergedSession = reopenedMerge.database.sessions.first { $0.id == mergeID }!
        let validIDs = Set(mergedSession.nodes.filter { !$0.isDeleted }.map(\.id))
        precondition(!validIDs.contains(oldNodeID) && mergedSession.nodes.count == 3)
        for (index, oldNode) in beforeNodes.enumerated() {
            let saved = mergedSession.nodes.first { $0.id == oldNode.id }!
            precondition(saved.thoughtID == oldNode.thoughtID && saved.userEditedText == oldNode.userEditedText)
            precondition(saved.position == .init(x: 500 + Double(index) * 200, y: 600))
            precondition(saved.parentID != nil && validIDs.contains(saved.parentID!))
            precondition(mergedSession.thoughts.first { $0.id == saved.thoughtID }?.attachedNodeID == saved.parentID,
                         "Artifact reconciliation restored an invalid old parent after accepting/restarting")
        }
        let store = AppStore(storageRoot: root)
        let id = store.createSession(title: "模拟中断", sourceName: "fixture", sourceKind: "test")
        store.completeLocalProcessing(result, sessionID: id)
        store.setStatus(.processing, sessionID: id)
        store.flush()
        let reopened = AppStore(storageRoot: root)
        precondition(reopened.database.sessions[0].status == .failed)
        let runs = ScriptedRuns(result: result)
        let worker = LocalProcessingService(runner: { id, _, _, _, _, _, checkpoint, _ in
            try await runs.invoke(id: id, checkpoint: checkpoint, alwaysFail: false)
        }, notifier: { _, _ in })
        worker.resumeInterrupted(store: reopened)
        try await wait(worker, id: id)
        let recoveredAttempts = await runs.attempts[id]
        let checkpointReused = await runs.reused[id]
        precondition(recoveredAttempts == 2)
        precondition(checkpointReused == true, "Restart unnecessarily repeated ASR")
        precondition(reopened.database.sessions[0].status == .ready)

        let failedID = reopened.createSession(title: "持续失败", sourceName: "", sourceKind: "test")
        reopened.attachAudio(paths: [root.appendingPathComponent("not-opened-by-mock.m4a").path], sessionID: failedID)
        let failedRuns = ScriptedRuns(result: result)
        let failing = LocalProcessingService(runner: { id, _, _, _, _, _, checkpoint, _ in
            try await failedRuns.invoke(id: id, checkpoint: checkpoint, alwaysFail: true)
        }, notifier: { _, _ in })
        failing.process(sessionID: failedID, audioPaths: ["mock"], store: reopened)
        try await wait(failing, id: failedID)
        let failureAttempts = await failedRuns.attempts[failedID]
        precondition(failureAttempts == 2)
        let again = AppStore(storageRoot: root)
        failing.resumeInterrupted(store: again)
        precondition(!failing.isProcessing(failedID), "Persistent failure retried forever across restart")

        let queued = AppStore(inMemory: true)
        let queueIDs = (0..<3).map { queued.createSession(title: "队列\($0)", sourceName: "test", sourceKind: "test") }
        let queueWorker = LocalProcessingService(runner: { _, _, _, _, _, _, _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return result
        }, notifier: { _, _ in })
        for id in queueIDs { queueWorker.process(sessionID: id, audioPaths: ["mock"], store: queued) }
        queued.moveSessionToTrash(queueIDs[1])
        try await wait(queueWorker, id: queueIDs[2])
        precondition(queued.database.sessions.first { $0.id == queueIDs[2] }?.status == .ready, "Deleted queue item stranded later work")

        let gate = NotificationGate()
        let notificationStore = AppStore(inMemory: true)
        let notificationIDs = (0..<2).map { notificationStore.createSession(title: "通知等待\($0)", sourceName: "test", sourceKind: "test") }
        let notificationWorker = LocalProcessingService(runner: { _, _, _, _, _, _, _, _ in result },
                                                         notifier: { _, _ in await gate.hold() })
        for id in notificationIDs { notificationWorker.process(sessionID: id, audioPaths: ["mock"], store: notificationStore) }
        try await wait(notificationWorker, id: notificationIDs[1])
        precondition(!notificationWorker.isProcessing(notificationIDs[0]), "Notification permission kept a finished job busy")
        for _ in 0..<20 {
            if await gate.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let heldNotifications = await gate.count
        precondition(heldNotifications == 2, "Both jobs must complete before either notification is delivered")
        await gate.release()

        var protectedSpan = span
        protectedSpan.isBackgroundAudio = true
        protectedSpan.isImportant = true
        precondition(!protectedSpan.isFilteredBackground)
        protectedSpan.isImportant = false
        protectedSpan.correctedText = "我的人工修正"
        precondition(!protectedSpan.isFilteredBackground)

        var drained = false
        let stopped = await CaptureShutdown.finish(stopSource: { throw CaptureFailure.noAudioReceived }, drain: {
            drained = true
            return AudioDrainResult(urls: [root.appendingPathComponent("sealed.m4a")], errors: [])
        })
        precondition(drained && stopped.urls.count == 1 && stopped.errors.count == 1)
        let now = Date()
        precondition(CaptureSignalHealth.warning(now: now, startedAt: now.addingTimeInterval(-31), lastSampleAt: now, lastAudibleAt: nil) != nil)
        precondition(CaptureSignalHealth.warning(now: now, startedAt: now.addingTimeInterval(-31), lastSampleAt: now, lastAudibleAt: now) == nil)

        let start = Date()
        let timeout = try await Task.detached {
            try BoundedLocalProcess.run(executable: "/bin/sleep", arguments: ["20"], environment: [:],
                                        logURL: root.appendingPathComponent("hung.log"), timeout: 0.2)
        }.value
        precondition(timeout.timedOut && Date().timeIntervalSince(start) < 3)
        let cancelledChild = Task.detached {
            try BoundedLocalProcess.run(executable: "/bin/sleep", arguments: ["20"], environment: [:],
                logURL: root.appendingPathComponent("cancelled-annotation.log"), timeout: 20,
                cancelled: { Task.isCancelled })
        }
        try await Task.sleep(for: .milliseconds(150))
        let cancelStart = Date()
        cancelledChild.cancel()
        let cancelledResult = try await cancelledChild.value
        precondition(cancelledResult.status != 0 && !cancelledResult.timedOut && Date().timeIntervalSince(cancelStart) < 3,
                     "Optional annotation cancellation left its real child running")
        try await encoder(root: root)
        try await normalExit(root: root)
        print("PASS: persisted restart recovery, checkpoint reuse, bounded automatic retry, stop failure still drains, silent packets detected, hung child killed, real AAC encoders fully drained")
    }

    @MainActor private static func normalExit(root: URL) async throws {
        let exitStore = AppStore(storageRoot: root.appendingPathComponent("normal-exit"))
        let id = exitStore.createSession(title: "不足15秒正常退出", sourceName: "fixture", sourceKind: "test")
        exitStore.setStatus(.recording, sessionID: id)
        let recorder = try AudioChunkRecorder(directory: exitStore.sessionDirectory(id).appendingPathComponent("Audio"),
            onChunk: { _, _ in }, onDuration: { _ in }, onFailure: { _ in })
        for index in 0..<6 {
            recorder.append(try sample(time: Double(index) * 0.1))
            try await Task.sleep(for: .milliseconds(50))
        }
        await CaptureExitCoordinator.finish(sessionID: id, store: exitStore, stop: {
            let drained = await recorder.finish()
            precondition(drained.errors.isEmpty)
            return drained.urls
        }, retained: { [] })
        let reopened = AppStore(storageRoot: root.appendingPathComponent("normal-exit"))
        let record = reopened.database.sessions.first { $0.id == id }!
        precondition(record.audioRelativePaths.count == 1 && record.recoveryPending == true)
        let duration = try await AVURLAsset(url: URL(fileURLWithPath: record.audioRelativePaths[0])).load(.duration)
        precondition(CMTimeGetSeconds(duration) >= 0.5, "Normal quit failed to seal the unfinished chunk")
        let stale = AppStore(storageRoot: root.appendingPathComponent("normal-exit"))
        reopened.updateTitle("较新的已保存版本", sessionID: id)
        precondition(reopened.flush())
        let savedBytes = try Data(contentsOf: reopened.dataRoot.appendingPathComponent("database.json"))
        stale.updateTitle("不能丢失的未保存修改", sessionID: id)
        precondition(!stale.flush(), "A conflicting save must not authorize application exit")
        let afterConflict = try Data(contentsOf: reopened.dataRoot.appendingPathComponent("database.json"))
        precondition(afterConflict == savedBytes)
        precondition(stale.database.sessions.first { $0.id == id }?.title == "不能丢失的未保存修改")
    }

    @MainActor private static func wait(_ worker: LocalProcessingService, id: UUID) async throws {
        for _ in 0..<200 {
            if !worker.isProcessing(id) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        preconditionFailure("Processing queue did not finish in ten seconds")
    }

    private static func encoder(root: URL) async throws {
        let recorder = try AudioChunkRecorder(directory: root.appendingPathComponent("Audio"), onChunk: { _, _ in }, onDuration: { _ in }, onFailure: { _ in })
        // Two real AAC writers. The PTS jump forces rollover while the first
        // finishWriting callback may still be pending; final stop drains both.
        for index in 0..<12 {
            recorder.append(try sample(time: index < 6 ? Double(index) * 0.1 : 15 + Double(index - 6) * 0.1))
            try await Task.sleep(for: .milliseconds(50))
        }
        let result = await recorder.finish()
        precondition(result.errors.isEmpty && result.urls.count == 2, "Valid AAC chunks did not seal: \(result.errors)")
        for url in result.urls {
            let duration = try await AVURLAsset(url: url).load(.duration)
            precondition(CMTimeGetSeconds(duration) >= 0.5, "ASR would receive an unreadable/unsealed file")
        }
        let secondFinish = await recorder.finish()
        precondition(secondFinish.urls == result.urls)
    }

    private static func sample(time: Double) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        var description: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        let frames = 4410
        let samples = (0..<frames).map { Float(sin(Double($0) * 2 * .pi * 440 / 44_100) * 0.2) }
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frames * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: frames * 4, flags: 0, blockBufferOut: &block) == noErr)
        samples.withUnsafeBytes { bytes in
            precondition(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frames * 4) == noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100), presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 44_100), decodeTimeStamp: .invalid)
        var size = 4
        var buffer: CMSampleBuffer?
        precondition(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description!, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr)
        return buffer!
    }
}

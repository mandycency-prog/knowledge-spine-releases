import Foundation
import AppKit
import Combine
import CryptoKit
import KnowledgeSpineCore
import UserNotifications

struct LocalProcessingResult: Codable, Sendable {
    let speakers: [Speaker]
    let spans: [TranscriptSpan]
    var candidates: [StructureCandidate]
    var warnings: [String]
    var annotationSummaries: [AnnotationSummary]? = nil
    var annotationInputs: [AnnotationInput]? = nil
    var sessionTitle: String? = nil
    var reuseTranscriptClassification: Bool? = nil
    /// A usable transcript checkpoint is not a successful map-generation result.
    var processingError: String? = nil
    var focusQuestion: String? = nil
    var focusedReport: FocusedStudyReport? = nil
    var imageAnalyses: [ImageAnalysisResult]? = nil
    // Private invocation inputs. Never add image interpretations to ASR spans.
    var imageInputs: [ImageAttachment]? = nil
    var imageContextNodes: [KnowledgeNode]? = nil
    var requiresAudioTranscription: Bool? = nil

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }

    func failedCheckpoint(detail: String, logPath: String) -> Self {
        var partial = self
        partial.candidates = []
        partial.processingError = "结构生成未完成：\(detail)"
        partial.warnings += ["结构生成未完成：\(detail)。逐字稿检查点已保存在本机；日志位于 \(logPath)"]
        return partial
    }
}

struct ImageAnalysisResult: Codable, Sendable {
    let id: UUID
    let fingerprint: String
    let model: String
    let extractedText: String
    let explanation: String
    let uncertainties: [String]
    var analysis: ImageAnalysis { ImageAnalysis(fingerprint: fingerprint, model: model,
        extractedText: extractedText, explanation: explanation, uncertainties: uncertainties) }
}

struct AnnotationSummary: Codable, Sendable {
    let id: UUID
    let summary: String
}

struct AnnotationInput: Codable, Sendable, Equatable {
    let id: UUID
    let kind: String
    let text: String
    let sourceSpanIDs: [UUID]
    let anchorTime: TimeInterval?

    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let version = kind == "important" ? Data("important-outline-v2:".utf8) : Data()
        return SHA256.hash(data: version + ((try? encoder.encode(self)) ?? Data())).map { String(format: "%02x", $0) }.joined()
    }

    static func from(_ session: SessionRecord) -> [Self] {
        session.thoughts.filter { !$0.isDeleted }.map {
            Self(id: $0.id, kind: "thought", text: $0.text, sourceSpanIDs: [], anchorTime: $0.anchorTime)
        } + (session.importantMarks ?? []).map { mark in
            let spans = session.transcript.filter { mark.protectedSpanIDs.contains($0.id) }
            return Self(id: mark.id, kind: "important", text: spans.map { $0.correctedText?.isEmpty == false ? $0.correctedText! : $0.originalText }.joined(separator: "\n"),
                        sourceSpanIDs: spans.map(\.id), anchorTime: mark.anchorTime ?? session.transcript.first { $0.id == mark.anchorSpanID }?.startTime)
        }
    }
}

enum LocalProcessingFailure: LocalizedError {
    case missingExecutable(String)
    case missingScript
    case processFailed(String)
    case invalidResult(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let path): "本地处理程序不存在：\(path)"
        case .missingScript: "APP 内缺少离线处理脚本，请重新安装当前版本"
        case .processFailed(let detail): "处理失败：\(detail)"
        case .invalidResult(let detail): "处理结果无法读取：\(detail)"
        }
    }
}

@MainActor
final class LocalProcessingService: ObservableObject {
    @Published private(set) var focusProgress: [UUID: String] = [:]
    private var focusTasks: [UUID: Task<Void, Never>] = [:]
    private var imageTasks: [UUID: Task<Void, Never>] = [:]
    @Published private(set) var activeSessionIDs: Set<UUID> = []
    @Published private(set) var progress: [UUID: String] = [:]
    @Published private(set) var modelHealth = "尚未校验"
    private var liveQueues: [UUID: [(path: String, offset: TimeInterval)]] = [:]
    private var liveRunning: Set<UUID> = []
    private var liveGeneration: [UUID: Int] = [:]
    private var liveWorkers: [UUID: LiveTranscriptionWorker] = [:]
    private var retiredWorkers: [UUID: [LiveTranscriptionWorker]] = [:]
    private var didAttemptRecovery = false
    private var pendingFinal: [(UUID, [String], AppStore, Bool, Bool, Bool, Bool, AppSettings)] = []
    private var annotationObservation: AnyCancellable?
    private var annotationTask: Task<Void, Never>?
    private var annotationAttempts: [String: Int] = [:]
    typealias Runner = @Sendable (UUID, [String], AppSettings, URL, Bool, String, LocalProcessingResult?, [AnnotationInput]) async throws -> LocalProcessingResult
    private let runner: Runner
    private let notifier: @Sendable (String, String) async -> Void

    init(runner: Runner? = nil, notifier: (@Sendable (String, String) async -> Void)? = nil) {
        self.runner = runner ?? { id, paths, settings, directory, asrOnly, label, checkpoint, annotations in
            try await Self.run(sessionID: id, audioPaths: paths, settings: settings,
                               sessionDirectory: directory, asrOnly: asrOnly, runLabel: label, checkpoint: checkpoint, annotations: annotations)
        }
        self.notifier = notifier ?? { await Self.notify(title: $0, body: $1) }
    }

    func isProcessing(_ sessionID: UUID) -> Bool {
        activeSessionIDs.contains(sessionID) || imageTasks[sessionID] != nil || pendingFinal.contains { $0.0 == sessionID }
    }

    func validateModelsAndRecoverIfNeeded(store: AppStore) async {
        if !store.isEphemeral && annotationObservation == nil {
            annotationObservation = store.$database.debounce(for: .seconds(10), scheduler: RunLoop.main)
                .sink { [weak self, weak store] _ in
                    guard let self, let store else { return }
                    self.scheduleMissingAnnotations(store: store)
                }
        }
        guard !didAttemptRecovery, !store.isEphemeral else { return }
        didAttemptRecovery = true
        var settings = store.database.settings ?? AppSettings()
        let fallback = AppSettings().whisperModelPath
        if Self.fileSize(settings.whisperModelPath) < 50_000_000, Self.fileSize(fallback) >= 50_000_000 {
            store.whisperModelPath = fallback
            settings.whisperModelPath = fallback
        }
        // Resume from stored work, not from matching particular error strings.
        resumeInterrupted(store: store)
        if !activeSessionIDs.isEmpty {
            modelHealth = "正在恢复处理；已有完整逐字稿直接续做结构"
            return
        }
        if let helper = LiveTranscriptionWorker.appleSpeechPath, await Self.nativeSpeechAvailable(helper) {
            modelHealth = "Mac 本机中文识别可用；使用系统已有资源，不加载 Whisper"
            return
        }
        modelHealth = "正在校验本地转写模型"
        if let error = await Self.validateWhisper(pythonPath: settings.pythonPath, modelPath: settings.whisperModelPath) {
            modelHealth = "转写模型不可用"
            store.statusMessage = "本地转写模型未通过校验：" + error
        } else {
            modelHealth = "Whisper 已通过实际载入校验"
        }
    }

    /// Quietly batch new notes after writing has settled. Never load Qwen beside
    /// capture/ASR/final analysis, and never require the user to rerun a course.
    func scheduleMissingAnnotations(store: AppStore) {
        guard store.analysisProvider == "local" else { return }
        // Software-only releases may retain an older installed analysis
        // backend. Do not call a CLI mode that backend does not implement.
        guard Bundle.main.object(forInfoDictionaryKey: "KnowledgeSpineAnnotationAnalysisEnabled") as? Bool != false else { return }
        guard annotationTask == nil else { return }
        annotationTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            defer { annotationTask = nil }
            while !Task.isCancelled {
                guard store.analysisProvider == "local" else { break }
                if !activeSessionIDs.isEmpty || !liveWorkers.isEmpty || store.activeSessions.contains(where: { $0.status == .recording }) {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                let pending = store.activeSessions.compactMap { session -> (SessionRecord, [AnnotationInput])? in
                    guard session.transcriptComplete, session.structureSaved, session.status == .ready else { return nil }
                    let inputs = AnnotationInput.from(session).filter { input in
                        let key = session.id.uuidString + ":" + input.fingerprint
                        return annotationAttempts[key, default: 0] < 2 && session.nodes.contains {
                            !$0.isDeleted && ($0.thoughtID == input.id || $0.importantMarkID == input.id) &&
                            ($0.aiSummary?.isEmpty != false || $0.annotationInputFingerprint != input.fingerprint)
                        }
                    }
                    return inputs.isEmpty ? nil : (session, inputs)
                }
                guard let (record, inputs) = pending.first else { break }
                for input in inputs { annotationAttempts[record.id.uuidString + ":" + input.fingerprint, default: 0] += 1 }
                activeSessionIDs.insert(record.id)
                progress[record.id] = "正在概括新重点与思考，原文已保存"
                let saved = LocalProcessingResult(speakers: record.speakers, spans: record.transcript, candidates: [], warnings: [])
                do {
                    let result = try await runner(record.id, [], store.database.settings ?? AppSettings(), store.sessionDirectory(record.id), false, "annotations", saved, inputs)
                    store.applyAnnotationSummaries(result.annotationSummaries ?? [], inputs: inputs, sessionID: record.id)
                } catch {
                    // Do not turn a safely saved thought into a failed course.
                    progress[record.id] = "思考原文已保存，概括暂未完成"
                }
                if Task.isCancelled {
                    for input in inputs { annotationAttempts.removeValue(forKey: record.id.uuidString + ":" + input.fingerprint) }
                }
                activeSessionIDs.remove(record.id)
                while !pendingFinal.isEmpty && activeSessionIDs.isEmpty {
                    let next = pendingFinal.removeFirst()
                    process(sessionID: next.0, audioPaths: next.1, store: next.2, asrOnly: next.3, automatic: next.4, retranscribe: next.5, reuseTranscriptClassification: next.6, requestedSettings: next.7)
                }
                if activeSessionIDs.isEmpty {
                    for id in Array(liveQueues.keys) { drainLiveQueue(sessionID: id, store: store) }
                }
                if !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
            }
        }
    }

    func resumeInterrupted(store: AppStore) {
        // Changing modes or opening the App must not upload old records or
        // incur charges through automatic recovery.
        guard store.analysisProvider == "local" else { return }
        for session in store.activeSessions where session.status == .failed
            && (session.recoveryPending == true || (session.recoveryPending == nil && !session.structureSaved))
            && (session.automaticRecoveryAttempts ?? 0) < 2
            && (!session.audioRelativePaths.isEmpty || !session.transcript.isEmpty) {
            process(sessionID: session.id, audioPaths: session.audioRelativePaths, store: store, automatic: true,
                    retranscribe: session.processingRetranscribe == true,
                    reuseTranscriptClassification: savedClassificationPolicy(sessionID: session.id, store: store))
        }
    }

    func isFocusing(_ id: UUID) -> Bool { focusProgress[id] != nil }

    func processFocus(question: String, sessionID: UUID, store: AppStore) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 600, focusTasks[sessionID] == nil,
              let record = store.database.sessions.first(where: { $0.id == sessionID }),
              record.deletedAt == nil, !record.transcript.isEmpty || record.images?.contains(where: { $0.deletedAt == nil }) == true,
              record.status != .recording && record.status != .paused else { return }
        guard store.prepareFocusedStudy(question, sessionID: sessionID) else { return }
        let requestedSettings = store.database.settings ?? AppSettings()
        focusProgress[sessionID] = "等待分析任务空闲，原图和稿件仍可查看"
        focusTasks[sessionID] = Task { [self] in
            // Serialize with normal analysis and annotation jobs: one large
            // model at a time. UI remains available while waiting.
            while !activeSessionIDs.isEmpty {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { focusProgress.removeValue(forKey: sessionID); focusTasks.removeValue(forKey: sessionID); return }
            }
            guard let current = store.database.sessions.first(where: { $0.id == sessionID }),
                  current.deletedAt == nil, !current.transcript.isEmpty || current.images?.contains(where: { $0.deletedAt == nil }) == true else {
                focusProgress.removeValue(forKey: sessionID); focusTasks.removeValue(forKey: sessionID); return
            }
            activeSessionIDs.insert(sessionID)
            defer {
                activeSessionIDs.remove(sessionID)
                focusProgress.removeValue(forKey: sessionID)
                focusTasks.removeValue(forKey: sessionID)
                while !pendingFinal.isEmpty && activeSessionIDs.isEmpty {
                    let next = pendingFinal.removeFirst()
                    process(sessionID: next.0, audioPaths: next.1, store: next.2, asrOnly: next.3, automatic: next.4, retranscribe: next.5, reuseTranscriptClassification: next.6, requestedSettings: next.7)
                }
                if activeSessionIDs.isEmpty {
                    for id in Array(liveQueues.keys) { drainLiveQueue(sessionID: id, store: store) }
                }
            }
            for id in Array(liveWorkers.keys) {
                liveGeneration[id, default: 0] += 1
                if let worker = liveWorkers.removeValue(forKey: id) {
                    worker.cancel(); retiredWorkers[id, default: []].append(worker)
                }
            }
            let retiring = retiredWorkers.values.flatMap { $0 }
            retiredWorkers.removeAll()
            for worker in retiring { await worker.waitForExit() }
            var saved = LocalProcessingResult(speakers: current.speakers, spans: current.transcript, candidates: [], warnings: [])
            saved.sessionTitle = current.title
            saved.focusQuestion = question
            saved.imageInputs = current.images?.filter { $0.deletedAt == nil }
            saved.imageContextNodes = current.nodes
            let label = "focus-\(UUID().uuidString)"
            let directory = store.sessionDirectory(sessionID)
            let started = Date()
            focusProgress[sessionID] = "正在围绕你的问题重新读取整份逐字稿"
            let progressReader = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    if let line = Self.latestProgress(logURL: directory.appendingPathComponent("Processing/\(label).log"), since: started) {
                        self?.focusProgress[sessionID] = line
                    }
                }
            }
            defer { progressReader.cancel() }
            do {
                let result = try await runner(sessionID, [], requestedSettings, directory, false, label, saved, [])
                guard store.applyImageAnalyses(result.imageAnalyses ?? [], inputs: saved.imageInputs ?? [], sessionID: sessionID) else {
                    throw LocalProcessingFailure.invalidResult("图片材料已变化或结果未能保存，请用当前材料重新整理。")
                }
                guard let report = result.focusedReport, result.processingError == nil else {
                    throw LocalProcessingFailure.processFailed(result.processingError ?? "没有生成可保存的专题结果")
                }
                if store.saveFocusedStudy(report, sessionID: sessionID, baseline: current.transcript, imageBaseline: current.images) {
                    store.statusMessage = "已围绕“\(question)”保存专题整理，原导图未改变。"
                    Task { await notifier("你关心的问题已整理好", current.title) }
                }
            } catch {
                store.recordImageFailure(error.localizedDescription, inputs: saved.imageInputs ?? [], sessionID: sessionID)
                store.failFocusedStudy("专题整理未完成：\(error.localizedDescription)。原稿和已有结果不变，可重新整理。", sessionID: sessionID)
            }
        }
    }

    private func checkpoint(for id: UUID, store: AppStore) -> LocalProcessingResult? {
        guard let record = store.database.sessions.first(where: { $0.id == id }) else { return nil }
        if (record.transcriptComplete && !record.transcript.isEmpty) ||
            (record.audioRelativePaths.isEmpty && record.images?.contains(where: { $0.deletedAt == nil }) == true) {
            return LocalProcessingResult(speakers: record.speakers, spans: record.transcript, candidates: [], warnings: [])
        }
        return diskCheckpoint(for: id, store: store)
    }

    private func diskCheckpoint(for id: UUID, store: AppStore, runLabel: String = "final") -> LocalProcessingResult? {
        // Python writes this atomically after all ASR, before the structure model.
        let output = store.sessionDirectory(id).appendingPathComponent("Processing/result-\(runLabel).json")
        guard let bytes = try? Data(contentsOf: output),
              let result = try? LocalProcessingResult.decode(bytes),
              !result.spans.isEmpty else { return nil }
        return LocalProcessingResult(speakers: result.speakers, spans: result.spans, candidates: [], warnings: result.warnings, reuseTranscriptClassification: result.reuseTranscriptClassification)
    }

    private func savedClassificationPolicy(sessionID: UUID, store: AppStore) -> Bool {
        let url = store.sessionDirectory(sessionID).appendingPathComponent("Processing/classification-policy.json")
        guard let bytes = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let session = store.database.sessions.first(where: { $0.id == sessionID }),
              value["runLabel"] as? String == (session.processingRunLabel ?? "final") else { return false }
        return value["reuse"] as? Bool == true && session.processingRetranscribe != true
    }

    nonisolated static func mayReuseClassification(requested: Bool, retranscribe: Bool, asrOnly: Bool, hasTranscript: Bool) -> Bool {
        requested && !retranscribe && !asrOnly && hasTranscript
    }

    nonisolated static func mayReuseProofreading(_ checkpoint: LocalProcessingResult?) -> Bool {
        let spans = checkpoint?.spans.filter {
            !$0.isFilteredBackground && $0.origin?.authoredByUser != true
                && ($0.correctedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? []
        return !spans.isEmpty && spans.allSatisfy {
            guard let basis = $0.proofreadBasis, let text = $0.proofreadText else { return false }
            return basis.utf8.elementsEqual($0.originalText.utf8)
                && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.proofreadUncertainties != nil
        }
    }

    nonisolated static func processingTimeout(audioCount: Int, checkpoint: LocalProcessingResult?, asrOnly: Bool, runLabel: String) -> Double {
        let imageBudget = Double(checkpoint?.imageInputs?.count ?? 0) * 150
        if runLabel.hasPrefix("images-") { return min(21_600, max(180, imageBudget + 30)) }
        if runLabel.hasPrefix("focus-") { return min(21_600, 900 + imageBudget) }
        if runLabel == "annotations" { return 180 }
        let audioBudget = max(1_800, Double(audioCount) * 30)
        if asrOnly { return min(21_600, audioBudget) }
        // Reorganizing an existing manuscript has no audioPaths. Its budget
        // must still include one proofreading pass and map generation. Real
        // local batches can take several minutes; 30 minutes for every text
        // length would kill a healthy job before its map is produced.
        let spans = checkpoint?.spans.filter { !$0.isFilteredBackground } ?? []
        let chars = spans.reduce(0) { $0 + $1.originalText.count }
        let batches = max(ceil(Double(spans.count) / 60), ceil(Double(chars) / 1_800))
        let textBudget = spans.isEmpty ? audioBudget * 2 : batches * 600 + 1_800
        return min(21_600, max(audioBudget, textBudget) + imageBudget)
    }

    nonisolated static func latestProgress(logURL: URL, since startedAt: Date) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let modified = attributes[.modificationDate] as? Date, modified >= startedAt,
              let reader = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? reader.close() }
        guard let end = try? reader.seekToEnd(),
              (try? reader.seek(toOffset: end > 65_536 ? end - 65_536 : 0)) != nil,
              let data = try? reader.readToEnd() else { return nil }
        // Only bounded, known progress messages; tracebacks and source text
        // are not a progress UI. Completion is set after AppStore accepts it.
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map(String.init).last { line in
                line.count <= 180 && ["正在", "已保留原始识别", "复用现有原稿", "专题阅读", "本地模型运算中断"].contains(where: line.hasPrefix)
            }
    }

    func process(sessionID: UUID, audioPaths: [String], store: AppStore, asrOnly: Bool = false, automatic: Bool = false, retranscribe: Bool = false, reuseTranscriptClassification: Bool = false, requestedSettings: AppSettings? = nil) {
        let settings = requestedSettings ?? store.database.settings ?? AppSettings()
        guard !automatic || (settings.analysisProvider ?? "local") == "local" else { return }
        guard !retranscribe || !audioPaths.isEmpty else { return }
        guard let existing = store.database.sessions.first(where: { $0.id == sessionID }), existing.deletedAt == nil,
              !activeSessionIDs.contains(sessionID), !pendingFinal.contains(where: { $0.0 == sessionID }),
              !audioPaths.isEmpty || checkpoint(for: sessionID, store: store) != nil ||
                (reuseTranscriptClassification && !asrOnly && !retranscribe && !existing.transcript.isEmpty) else { return }
        if automatic && existing.images?.contains(where: { $0.deletedAt == nil }) == true {
            store.statusMessage = "这场记录含图片，请手动继续整理，以确认本次识图请求。"
            return
        }
        if automatic && (existing.automaticRecoveryAttempts ?? 0) >= 2 { return }
        let previousLabel = existing.processingRunLabel
        let validPrevious = previousLabel.map { $0.hasPrefix("relisten-") && UUID(uuidString: String($0.dropFirst(9))) != nil } ?? false
        let resumingRelisten = retranscribe && existing.processingRetranscribe == true && validPrevious
            && (automatic || (existing.status == .processing && existing.recoveryPending == true))
        let runLabel = retranscribe ? (resumingRelisten ? previousLabel! : "relisten-\(UUID().uuidString)") : "final"
        let reuseClassification = Self.mayReuseClassification(requested: reuseTranscriptClassification,
            retranscribe: retranscribe, asrOnly: asrOnly, hasTranscript: !existing.transcript.isEmpty)
        do {
            let policyDirectory = store.sessionDirectory(sessionID).appendingPathComponent("Processing", isDirectory: true)
            try FileManager.default.createDirectory(at: policyDirectory, withIntermediateDirectories: true)
            let policy: [String: Any] = ["runLabel": runLabel, "reuse": reuseClassification]
            try JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys]).write(to: policyDirectory.appendingPathComponent("classification-policy.json"), options: .atomic)
        } catch {
            store.statusMessage = "未能保存本次整理方式，未开始处理：\(error.localizedDescription)"
            return
        }
        store.prepareProcessingJob(sessionID: sessionID, runLabel: runLabel, retranscribe: retranscribe, resetBudget: !automatic)
        if !activeSessionIDs.isEmpty {
            cancelLive(sessionID: sessionID)
            pendingFinal.append((sessionID, audioPaths, store, asrOnly, automatic, retranscribe, reuseClassification, settings))
            store.setStatus(.processing, sessionID: sessionID)
            store.flush()
            progress[sessionID] = "等待前一场处理完成"
            return
        }
        cancelLive(sessionID: sessionID)
        // One heavy phase at a time, including when a second course is being
        // recorded while the first is organized. Audio capture itself continues.
        for id in Array(liveWorkers.keys) {
            liveGeneration[id, default: 0] += 1
            if let worker = liveWorkers.removeValue(forKey: id) {
                worker.cancel()
                retiredWorkers[id, default: []].append(worker)
            }
        }
        let retiringWorkers = retiredWorkers.values.flatMap { $0 }
        retiredWorkers.removeAll()
        let directory = store.sessionDirectory(sessionID)
        activeSessionIDs.insert(sessionID)
        progress[sessionID] = automatic ? "自动恢复上次未完成的整理" : "准备处理（\(settings.analysisProvider == "api" ? "API 分析" : "本地分析")）"

        Task {
            for worker in retiringWorkers { await worker.waitForExit() }
            var lastFailure = ""
            var preparedCandidate = false
            var runnerStartedAt: Date?
            // One pass per requested job. Do not spend another full model run
            // merely because the first map could not be submitted. Durable
            // checkpoints still support a later explicit resume after failure.
            do {
                store.beginProcessingAttempt(sessionID: sessionID, resetBudget: !automatic, runLabel: runLabel, retranscribe: retranscribe)
                do {
                    var saved = asrOnly ? nil : (retranscribe
                        ? (resumingRelisten ? diskCheckpoint(for: sessionID, store: store, runLabel: runLabel) : nil)
                        : checkpoint(for: sessionID, store: store))
                    if reuseClassification {
                        saved = LocalProcessingResult(speakers: existing.speakers, spans: existing.transcript, candidates: [], warnings: [])
                    }
                    saved?.sessionTitle = existing.title
                    saved?.reuseTranscriptClassification = reuseClassification
                    if let saved, !saved.spans.isEmpty, store.database.sessions.first(where: { $0.id == sessionID })?.transcriptComplete != true {
                        // Adopt the durable Python checkpoint before the next run
                        // replaces its output file; another crash must not lose it.
                        store.completeLocalProcessing(saved, sessionID: sessionID, reportIssues: false)
                        store.setStatus(.processing, sessionID: sessionID)
                        store.flush()
                    }
                    if !asrOnly, let images = existing.images?.filter({ $0.deletedAt == nil }), !images.isEmpty {
                        let requiresASR = saved == nil && !audioPaths.isEmpty
                        if saved == nil { saved = LocalProcessingResult(speakers: existing.speakers, spans: [], candidates: [], warnings: []) }
                        saved?.imageInputs = images
                        saved?.imageContextNodes = existing.nodes
                        saved?.requiresAudioTranscription = requiresASR
                        saved?.sessionTitle = existing.title
                    }
                    let annotations = store.database.sessions.first { $0.id == sessionID }.map(AnnotationInput.from) ?? []
                    let previousCandidateID = store.database.sessions.first { $0.id == sessionID }?.candidateVersions?.last?.id
                    let startedAt = Date()
                    let logURL = directory.appendingPathComponent("Processing/\(runLabel == "final" ? "last-run" : runLabel).log")
                    let progressReader = Task { [weak self] in
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(1)) } catch { break }
                            guard !Task.isCancelled else { break }
                            if let line = Self.latestProgress(logURL: logURL, since: startedAt) {
                                self?.progress[sessionID] = line
                            }
                        }
                    }
                    defer { progressReader.cancel() }
                    runnerStartedAt = Date()
                    var result = try await runner(sessionID, audioPaths, settings, directory, asrOnly, runLabel, saved, annotations)
                    if let inputs = saved?.imageInputs, let current = store.database.sessions.first(where: { $0.id == sessionID }),
                       !Self.sameImageSources(current.images ?? [], inputs) {
                        result.candidates = []; result.processingError = "整理期间图片材料发生变化，请用当前材料重新整理。"
                    }
                    guard store.applyImageAnalyses(result.imageAnalyses ?? [], inputs: saved?.imageInputs ?? [], sessionID: sessionID) else {
                        result.candidates = []; result.processingError = "图片结果尚未保存或材料已变化，未采用新的导图。"
                        result.annotationInputs = annotations
                        _ = store.completeLocalProcessing(result, sessionID: sessionID, reportIssues: false)
                        throw LocalProcessingFailure.invalidResult(result.processingError!)
                    }
                    result.annotationInputs = annotations
                    if store.completeLocalProcessing(result, sessionID: sessionID, reportIssues: false) {
                        preparedCandidate = store.database.sessions.first { $0.id == sessionID }?.candidateVersions?.last?.id != previousCandidateID
                        progress[sessionID] = preparedCandidate ? "新版已准备好，当前版本未替换" : "处理完成"
                        lastFailure = ""
                    } else {
                        lastFailure = store.database.sessions.first { $0.id == sessionID }?.lastProcessingError
                            ?? result.processingError ?? "导图整理未完成，已有逐字稿和版本仍保留"
                        if !asrOnly && !retranscribe {
                            store.preserveProofreadingAfterFailure(result, matching: existing)
                        }
                    }
                } catch {
                    lastFailure = error.localizedDescription
                    store.recordImageFailure(lastFailure, inputs: existing.images ?? [], sessionID: sessionID)
                    // Read only an output produced by THIS failed attempt.
                    // Later retries use the database, never stale disk overlays
                    // that could resurrect a user's restored original text.
                    let output = directory.appendingPathComponent("Processing/result-\(runLabel).json")
                    if !asrOnly && !retranscribe, let runnerStartedAt,
                       let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
                       let modified = attributes[.modificationDate] as? Date, modified >= runnerStartedAt,
                       let bytes = try? Data(contentsOf: output),
                       let partial = try? LocalProcessingResult.decode(bytes) {
                        store.preserveProofreadingAfterFailure(partial, matching: existing)
                    }
                }
            }
            if !lastFailure.isEmpty {
                store.setStatus(existing.structureSaved ? .ready : .failed, sessionID: sessionID)
                store.recordProcessingFailure(lastFailure, sessionID: sessionID)
                progress[sessionID] = "本次处理未完成，已有内容保留"
                store.statusMessage = "本次整理未完成：" + lastFailure + "。已有录音和逐字稿仍保留，未反复重新分析。"
            }
            if !store.finishProcessingAttempts(sessionID: sessionID) {
                // CAS or disk errors must not be hidden by a success banner.
                let saveFailure = store.statusMessage ?? "处理结果未能写入数据库"
                lastFailure = [lastFailure, saveFailure].filter { !$0.isEmpty }.joined(separator: "；")
                progress[sessionID] = "整理结果尚未保存，请保留当前窗口"
                store.statusMessage = lastFailure + "。请勿丢弃当前窗口中的结果；处理检查点仍在本机。"
            }
            let title = store.database.sessions.first { $0.id == sessionID }?.title ?? "课程记录"
            let notificationTitle = lastFailure.isEmpty ? (preparedCandidate ? "新版稿件与导图已准备好" : "课程已整理好") : "课程整理需要注意"
            activeSessionIDs.remove(sessionID)
            while !pendingFinal.isEmpty && activeSessionIDs.isEmpty {
                let next = pendingFinal.removeFirst()
                process(sessionID: next.0, audioPaths: next.1, store: next.2, asrOnly: next.3, automatic: next.4, retranscribe: next.5, reuseTranscriptClassification: next.6, requestedSettings: next.7)
                if !activeSessionIDs.contains(next.0) { progress.removeValue(forKey: next.0) }
            }
            if activeSessionIDs.isEmpty {
                for id in Array(liveQueues.keys) { drainLiveQueue(sessionID: id, store: store) }
            }
            // Notification permission/delivery may await the OS indefinitely.
            // It must not hold a completed job, its retry button, or the queue.
            Task { await notifier(notificationTitle, title) }
        }
    }

    func processLiveSegment(sessionID: UUID, audioPath: String, timeOffset: TimeInterval, store: AppStore) {
        // A newly started lesson takes priority over optional note summaries.
        // Cancellation propagates into the actual child process below.
        annotationTask?.cancel()
        guard !isProcessing(sessionID) else { return }
        if liveQueues[sessionID, default: []].count >= 8 {
            liveQueues[sessionID]?.removeFirst()
            progress[sessionID] = "正在追赶最新讲话；全部录音会在结束后完整转写"
        }
        liveQueues[sessionID, default: []].append((audioPath, timeOffset))
        if !activeSessionIDs.isEmpty {
            progress[sessionID] = "录音已保存；等上一场整理释放内存后继续即时转写"
        }
        drainLiveQueue(sessionID: sessionID, store: store)
    }

    func cancelLive(sessionID: UUID) {
        liveGeneration[sessionID, default: 0] += 1
        liveQueues[sessionID] = []
        if let worker = liveWorkers.removeValue(forKey: sessionID) {
            worker.cancel()
            retiredWorkers[sessionID, default: []].append(worker)
        }
    }

    private func drainLiveQueue(sessionID: UUID, store: AppStore) {
        guard activeSessionIDs.isEmpty, !liveRunning.contains(sessionID),
              var queue = liveQueues[sessionID],
              !queue.isEmpty else { return }
        let segment = queue.removeFirst()
        liveQueues[sessionID] = queue
        liveRunning.insert(sessionID)
        let generation = liveGeneration[sessionID, default: 0]
        let settings = store.database.settings ?? AppSettings()
        let worker = liveWorkers[sessionID] ?? LiveTranscriptionWorker()
        liveWorkers[sessionID] = worker
        progress[sessionID] = "正在转写最近音频 · 等待 \(queue.count) 段"
        Task {
            do {
                let result = try await worker.transcribe(path: segment.path, settings: settings, timeOffset: segment.offset)
                if liveGeneration[sessionID, default: 0] == generation {
                    store.appendLiveTranscription(
                        result,
                        sessionID: sessionID,
                        timeOffset: segment.offset
                    )
                }
            } catch {
                if liveGeneration[sessionID, default: 0] == generation {
                    liveWorkers.removeValue(forKey: sessionID)?.cancel()
                    progress[sessionID] = "增量转写暂时失败；结束后仍会完整重试"
                }
            }
            liveRunning.remove(sessionID)
            drainLiveQueue(sessionID: sessionID, store: store)
        }
    }

    nonisolated private static func normalizedAPIConfiguration(_ settings: AppSettings) -> APIConfiguration? {
        guard var config = settings.apiConfiguration else { return nil }
        let approved = config.isApproved
        if let normalized = try? APIConfiguration.normalizedEndpoint(config.baseURL) {
            config.baseURL = normalized
            config.approvedEndpoint = approved ? normalized : nil
        }
        config.model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return config
    }

    nonisolated private static func sameImageSources(_ lhs: [ImageAttachment], _ rhs: [ImageAttachment]) -> Bool {
        func canonical(_ images: [ImageAttachment]) -> [ImageAttachment] {
            images.filter { $0.deletedAt == nil }.map { image in
                var copy = image; copy.analysis = nil; copy.analysisError = nil; copy.portableData = nil
                return copy
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        return canonical(lhs) == canonical(rhs)
    }

    nonisolated private static func normalizedImageConfiguration(_ settings: AppSettings) throws -> APIConfiguration {
        guard var config = settings.imageAPIConfiguration ?? settings.apiConfiguration,
              config.approvedImageEndpoint == config.baseURL, !config.baseURL.isEmpty else {
            throw LocalProcessingFailure.processFailed("请在模型与设置中配置图片分析模型，并确认向此服务发送图片。原图已经保存。")
        }
        config.baseURL = try APIConfiguration.normalizedEndpoint(config.baseURL)
        config.approvedImageEndpoint = config.baseURL
        config.model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !config.model.isEmpty else { throw LocalProcessingFailure.processFailed("请填写支持识图的模型名称。") }
        return config
    }

    func processImages(sessionID: UUID, store: AppStore) {
        guard imageTasks[sessionID] == nil,
              let record = store.database.sessions.first(where: { $0.id == sessionID && $0.deletedAt == nil }),
              record.images?.contains(where: { $0.deletedAt == nil }) == true else { return }
        let settings = store.database.settings ?? AppSettings()
        do { _ = try Self.normalizedImageConfiguration(settings) }
        catch { store.statusMessage = error.localizedDescription; return }
        progress[sessionID] = "等待图片分析，原图已保存"
        imageTasks[sessionID] = Task { [self] in
            while !activeSessionIDs.isEmpty {
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { imageTasks.removeValue(forKey: sessionID); return }
            }
            guard let current = store.database.sessions.first(where: { $0.id == sessionID && $0.deletedAt == nil }) else {
                imageTasks.removeValue(forKey: sessionID); return
            }
            activeSessionIDs.insert(sessionID)
            let inputs = current.images?.filter { $0.deletedAt == nil } ?? []
            var saved = LocalProcessingResult(speakers: current.speakers, spans: current.transcript, candidates: [], warnings: [])
            saved.imageInputs = inputs; saved.imageContextNodes = current.nodes; saved.sessionTitle = current.title
            let label = "images-\(UUID().uuidString)"
            let directory = store.sessionDirectory(sessionID)
            progress[sessionID] = "正在分析图片与相关讲解"
            let startedAt = Date()
            let progressReader = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    if let line = Self.latestProgress(logURL: directory.appendingPathComponent("Processing/\(label).log"), since: startedAt) {
                        self?.progress[sessionID] = line
                    }
                }
            }
            defer { progressReader.cancel() }
            do {
                let result = try await runner(sessionID, [], settings, directory, false, label, saved, [])
                guard store.applyImageAnalyses(result.imageAnalyses ?? [], inputs: inputs, sessionID: sessionID) else {
                    throw LocalProcessingFailure.invalidResult("图片材料已变化或结果未能保存。")
                }
                if let error = result.processingError { throw LocalProcessingFailure.processFailed(error) }
                guard result.imageAnalyses?.count == inputs.count else {
                    throw LocalProcessingFailure.invalidResult("图片结果不完整，原图保留")
                }
                progress[sessionID] = "图片分析已保存"
                store.statusMessage = "图片已分析；生成导图或专题整理时会综合图片与讲解，并保留原图来源。"
            } catch {
                store.recordImageFailure(error.localizedDescription, inputs: inputs, sessionID: sessionID)
                progress[sessionID] = "图片分析未完成，原图保留"
                store.statusMessage = "图片分析未完成：\(error.localizedDescription)"
            }
            activeSessionIDs.remove(sessionID); imageTasks.removeValue(forKey: sessionID)
            while !pendingFinal.isEmpty && activeSessionIDs.isEmpty {
                let next = pendingFinal.removeFirst()
                process(sessionID: next.0, audioPaths: next.1, store: next.2, asrOnly: next.3, automatic: next.4, retranscribe: next.5, reuseTranscriptClassification: next.6, requestedSettings: next.7)
            }
            if activeSessionIDs.isEmpty { for id in Array(liveQueues.keys) { drainLiveQueue(sessionID: id, store: store) } }
        }
    }

    func probeImageAPI(configuration: APIConfiguration) async throws -> String {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("knowledge-spine-image-probe-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory.appendingPathComponent("Images", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        // A fresh visual challenge prevents a text-only endpoint from passing a
        // fixed canned response. It contains no user materials.
        let digits = String(Int.random(in: 100_000...999_999))
        let picture = NSImage(size: NSSize(width: 720, height: 300))
        picture.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 720, height: 300).fill()
        (digits as NSString).draw(at: NSPoint(x: 100, y: 105), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 100, weight: .bold), .foregroundColor: NSColor.black])
        picture.unlockFocus()
        guard let tiff = picture.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw ImageFileFailure.invalid("无法创建识图检测图片。") }
        let image = try ImageFiles.metadata(png, title: "识图能力检测")
        try png.write(to: directory.appendingPathComponent(image.relativePath), options: .atomic)
        var settings = AppSettings(); settings.imageAPIConfiguration = configuration
        _ = try Self.normalizedImageConfiguration(settings)
        var saved = LocalProcessingResult(speakers: [], spans: [], candidates: [], warnings: [])
        saved.imageInputs = [image]
        let result = try await Self.run(sessionID: UUID(), audioPaths: [], settings: settings,
            sessionDirectory: directory, asrOnly: false, runLabel: "images-probe", checkpoint: saved)
        guard result.processingError == nil, let reading = result.imageAnalyses?.first,
              reading.extractedText.contains(digits) else {
            throw LocalProcessingFailure.invalidResult("模型没有正确读出测试图中的随机数字，尚未确认可用识图能力。")
        }
        return "实际识图检测通过：模型正确读取了测试图片中的随机数字。未发送课程图片。"
    }

    func testAPIConnection(settings: AppSettings) async -> String {
        await Task.detached(priority: .userInitiated) {
            do {
                guard let config = Self.normalizedAPIConfiguration(settings), config.isApproved else {
                    return "请先填写 API 配置并确认发送授权。"
                }
                guard let key = try APICredentials.load(endpoint: config.baseURL) else {
                    return "请先保存此服务地址的 API 密钥。"
                }
                let fm = FileManager.default
                let bundled = Bundle.main.resourceURL?.appendingPathComponent("Backend/local_pipeline.py")
                let development = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Backend/local_pipeline.py")
                guard let script = [bundled, development].compactMap({ $0 }).first(where: { fm.fileExists(atPath: $0.path) }) else {
                    return "找不到接口测试程序。"
                }
                let directory = fm.temporaryDirectory.appendingPathComponent("knowledge-spine-api-probe-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                defer { try? fm.removeItem(at: directory) }
                let manifest = directory.appendingPathComponent("manifest.json")
                let output = directory.appendingPathComponent("result.json")
                let payload: [String: Any] = ["analysis_provider": "api", "api_configuration":
                    try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))]
                try JSONSerialization.data(withJSONObject: payload).write(to: manifest, options: .atomic)
                var environment = ProcessInfo.processInfo.environment
                environment["KNOWLEDGE_SPINE_API_KEY"] = key
                environment["PYTHONDONTWRITEBYTECODE"] = "1"
                environment["PYTHONUNBUFFERED"] = "1"
                let result = try BoundedLocalProcess.run(executable: settings.pythonPath,
                    arguments: ["-B", script.path, "--manifest", manifest.path, "--output", output.path, "--api-probe"],
                    environment: environment, logURL: directory.appendingPathComponent("probe.log"), timeout: 140)
                guard result.status == 0 else {
                    let error = String(decoding: result.tail, as: UTF8.self).split(whereSeparator: \.isNewline)
                        .first(where: { $0.hasPrefix("ERROR: ") }).map { String($0.dropFirst(7)) }
                    return error ?? (result.timedOut ? "连接测试超时，已停止，未自动重试。" : "连接测试未成功，请检查配置。")
                }
                let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Bool]
                return value?["ok"] == true ? "接口短句测试通过。未发送课程内容；课程回答质量仍需实际验证。" : "接口没有返回预期测试结果。"
            } catch {
                return "连接测试未完成：\(error.localizedDescription)"
            }
        }.value
    }

    nonisolated private static func run(
        sessionID: UUID,
        audioPaths: [String],
        settings: AppSettings,
        sessionDirectory: URL,
        asrOnly: Bool,
        runLabel: String,
        checkpoint: LocalProcessingResult? = nil,
        annotations: [AnnotationInput] = []
    ) async throws -> LocalProcessingResult {
        let work = Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            guard fileManager.isExecutableFile(atPath: settings.pythonPath) else {
                throw LocalProcessingFailure.missingExecutable(settings.pythonPath)
            }
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("Backend/local_pipeline.py")
            let development = URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Backend/local_pipeline.py")
            guard let script = [bundled, development].compactMap({ $0 }).first(where: {
                fileManager.fileExists(atPath: $0.path)
            }) else { throw LocalProcessingFailure.missingScript }

            let processingDirectory = sessionDirectory.appendingPathComponent("Processing", isDirectory: true)
            try fileManager.createDirectory(at: processingDirectory, withIntermediateDirectories: true)
            let manifestURL = processingDirectory.appendingPathComponent("manifest-\(runLabel).json")
            let resultURL = processingDirectory.appendingPathComponent("result-\(runLabel).json")
            // A failed new invocation must never reuse a previous run's output.
            if fileManager.fileExists(atPath: resultURL.path) {
                try fileManager.removeItem(at: resultURL)
            }
            let logURL = processingDirectory.appendingPathComponent(runLabel == "final" ? "last-run.log" : "\(runLabel).log")
            var manifest: [String: Any] = [
                "session_id": sessionID.uuidString,
                "session_title": checkpoint?.sessionTitle ?? "课程知识导图",
                "audio_paths": audioPaths,
                "reuse_transcript_classification": Self.mayReuseClassification(requested: checkpoint?.reuseTranscriptClassification == true,
                    retranscribe: runLabel.hasPrefix("relisten-"), asrOnly: asrOnly, hasTranscript: checkpoint?.spans.isEmpty == false),
                "retranscribe": runLabel.hasPrefix("relisten-"),
                "reuse_existing_proofreading": !asrOnly && !runLabel.hasPrefix("relisten-") && Self.mayReuseProofreading(checkpoint),
                "language": "zh",
                "whisper_model_path": settings.whisperModelPath,
                "structure_model_path": settings.structureModelPath,
                "analysis_provider": asrOnly ? "local" : (settings.analysisProvider ?? "local"),
                "ffmpeg_path": settings.ffmpegPath,
                "asr_checkpoint_path": processingDirectory.appendingPathComponent(runLabel.hasPrefix("relisten-") ? "asr-checkpoint-\(runLabel).json" : "asr-checkpoint.json").path,
            ]
            if !asrOnly, settings.analysisProvider == "api", let config = Self.normalizedAPIConfiguration(settings) {
                manifest["api_configuration"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
            }
            if let helper = LiveTranscriptionWorker.appleSpeechPath { manifest["apple_speech_path"] = helper }
            if let question = checkpoint?.focusQuestion { manifest["focus_question"] = question }
            let imageInputs = asrOnly || runLabel == "annotations" ? [] : checkpoint?.imageInputs ?? []
            var imageRequests: [[String: Any]] = []
            var imageConfig: APIConfiguration?
            if !imageInputs.isEmpty {
                // Let the backend finish/checkpoint ASR before it rejects a
                // missing vision configuration. Pictures must not block saving
                // the spoken manuscript of a newly recorded course.
                let config = (try? Self.normalizedImageConfiguration(settings))
                    ?? settings.imageAPIConfiguration ?? settings.apiConfiguration ?? APIConfiguration()
                imageConfig = config
                let context = SessionRecord(id: sessionID, title: checkpoint?.sessionTitle ?? "图片材料", sourceName: "本地记录", sourceKind: "图文材料",
                    speakers: checkpoint?.speakers ?? [], transcript: checkpoint?.spans ?? [], nodes: checkpoint?.imageContextNodes ?? [])
                imageRequests = try imageInputs.map { image in
                    var request = try ImageFiles.request(image, session: context, configuration: config, directory: sessionDirectory)
                    if checkpoint?.requiresAudioTranscription == true {
                        request["sourceSpanIDs"] = [String]()
                        request.removeValue(forKey: "analysis")
                    }
                    return request
                }
                manifest["images"] = imageRequests
                manifest["image_api_configuration"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
                if runLabel.hasPrefix("images-") {
                    manifest["image_context_spans"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint?.spans ?? []))
                }
            }
            manifest["annotations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(annotations))
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try manifestData.write(to: manifestURL, options: .atomic)

            let expectedImages = Dictionary(uniqueKeysWithValues: imageRequests.compactMap { item -> (UUID, String)? in
                guard let text = item["id"] as? String, let id = UUID(uuidString: text), let fingerprint = item["fingerprint"] as? String else { return nil }
                return (id, fingerprint)
            })
            func checkedImageResults(_ result: LocalProcessingResult, complete: Bool) throws -> LocalProcessingResult {
                let answers = result.imageAnalyses ?? []
                guard Set(answers.map(\.id)).count == answers.count,
                      !complete || answers.count == expectedImages.count else {
                    throw LocalProcessingFailure.invalidResult("图片结果重复或不完整。")
                }
                for answer in answers {
                    guard expectedImages[answer.id] == answer.fingerprint, answer.model == imageConfig?.model else {
                        throw LocalProcessingFailure.invalidResult("图片分析与本次输入不匹配。")
                    }
                }
                return result
            }

            var arguments = [script.path, "--manifest", manifestURL.path, "--output", resultURL.path] + (asrOnly ? ["--asr-only"] : [])
            if runLabel == "annotations" { arguments.append("--annotations-only") }
            if runLabel.hasPrefix("images-") { arguments.append("--images-only") }
            if let checkpoint, !runLabel.hasPrefix("images-"), checkpoint.requiresAudioTranscription != true {
                let checkpointURL = processingDirectory.appendingPathComponent(runLabel.hasPrefix("focus-") ? "input-\(runLabel).json" : "structure-input.json")
                try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
                arguments += ["--structure-from", checkpointURL.path]
            }
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "KNOWLEDGE_SPINE_API_KEY")
            environment.removeValue(forKey: "KNOWLEDGE_SPINE_IMAGE_API_KEY")
            let needsImageRequest = imageRequests.contains { request in
                guard let cached = request["analysis"] as? [String: Any] else { return true }
                return cached["fingerprint"] as? String != request["fingerprint"] as? String || cached["model"] as? String != imageConfig?.model
            }
            if let imageConfig, imageConfig.isImageApproved, needsImageRequest, let key = try? APICredentials.load(endpoint: imageConfig.baseURL) {
                environment["KNOWLEDGE_SPINE_IMAGE_API_KEY"] = key
            }
            if !asrOnly, settings.analysisProvider == "api",
               let config = Self.normalizedAPIConfiguration(settings), config.isApproved,
               let key = try? APICredentials.load(endpoint: config.baseURL) {
                environment["KNOWLEDGE_SPINE_API_KEY"] = key
            }
            environment["PYTHONUNBUFFERED"] = "1"
            // Bundled scripts are signed resources; never create bytecode in the App.
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            environment["PATH"] = URL(fileURLWithPath: settings.ffmpegPath).deletingLastPathComponent().path
                + ":" + (environment["PATH"] ?? "")
            let outcome = try BoundedLocalProcess.run(
                executable: settings.pythonPath, arguments: arguments, environment: environment,
                logURL: logURL, timeout: processingTimeout(audioCount: audioPaths.count, checkpoint: checkpoint, asrOnly: asrOnly, runLabel: runLabel),
                cancelled: { Task.isCancelled }
            )
            let data = outcome.tail
            guard outcome.status == 0 else {
                let raw = String(data: data.suffix(8_000), encoding: .utf8) ?? ""
                let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
                let detail = lines.last(where: { $0.hasPrefix("ERROR:") })?.replacingOccurrences(of: "ERROR: ", with: "")
                    ?? lines.last(where: { $0.contains("Error") || $0.contains("RuntimeError") })
                    ?? (outcome.timedOut ? "处理超过时限，已停止；可以从已保存内容重新整理" : "处理程序退出码 \(outcome.status)")
                if let checkpoint = try? Data(contentsOf: resultURL),
                   let partial = try? LocalProcessingResult.decode(checkpoint),
                   (!partial.spans.isEmpty || partial.imageAnalyses?.isEmpty == false) {
                    // A failed process may have serialized an unfinished map.
                    // Keep its manuscript, but never publish those candidates.
                    return try checkedImageResults(partial, complete: false).failedCheckpoint(detail: detail, logPath: logURL.path)
                }
                throw LocalProcessingFailure.processFailed("\(detail)。完整日志保存在 \(logURL.path)")
            }
            do {
                let output = try Data(contentsOf: resultURL)
                return try checkedImageResults(LocalProcessingResult.decode(output), complete: true)
            } catch {
                throw LocalProcessingFailure.invalidResult(error.localizedDescription)
            }
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    nonisolated private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let value = attributes[.size] as? NSNumber else { return 0 }
        return value.int64Value
    }

    nonisolated private static func nativeSpeechAvailable(_ helper: String) async -> Bool {
        await Task.detached(priority: .utility) {
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeSpine-speech-check-\(UUID()).log")
            defer { try? FileManager.default.removeItem(at: log) }
            guard let result = try? BoundedLocalProcess.run(executable: helper, arguments: ["--probe"],
                environment: ProcessInfo.processInfo.environment, logURL: log, timeout: 45), result.status == 0,
                let info = try? JSONSerialization.jsonObject(with: result.tail) as? [String: Any] else { return false }
            return info["available"] as? Bool == true && info["installedChinese"] as? Bool == true
        }.value
    }

    nonisolated private static func validateWhisper(pythonPath: String, modelPath: String) async -> String? {
        await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: pythonPath) else { return "Python 不存在：\(pythonPath)" }
            guard fileSize(modelPath) >= 50_000_000 else { return "模型文件不完整：\(modelPath)" }
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeSpine-model-check-\(UUID()).log")
            defer { try? FileManager.default.removeItem(at: log) }
            do {
                let outcome = try BoundedLocalProcess.run(
                    executable: pythonPath,
                    arguments: ["-c", "import sys, whisper; whisper.load_model(sys.argv[1], device='cpu'); print('OK')", modelPath],
                    environment: ProcessInfo.processInfo.environment, logURL: log, timeout: 120
                )
                if outcome.timedOut { return "模型校验超时，已停止校验进程" }
                guard outcome.status == 0 else {
                    return String(data: outcome.tail.suffix(600), encoding: .utf8) ?? "模型载入失败"
                }
            } catch { return error.localizedDescription }
            return nil
        }.value
    }

    nonisolated static func notify(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}

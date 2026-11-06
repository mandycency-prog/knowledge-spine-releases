@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AudioToolbox
import Combine
import CoreMedia
import Foundation
import KnowledgeSpineCore

struct CaptureSource: Identifiable {
    enum Kind: String {
        case application = "应用"
        case window = "窗口"
        case system = "全系统"
    }

    let id = UUID()
    let name: String
    let detail: String
    let kind: Kind
    let filter: SCContentFilter
}

struct CaptureInterruption: Identifiable, Equatable, Sendable {
    let id: UUID
    let occurredAt: Date
    let urls: [URL]
    let message: String
    let sessionID: UUID

    init(sessionID: UUID, urls: [URL], message: String) {
        id = UUID()
        occurredAt = Date()
        self.urls = urls
        self.message = message
        self.sessionID = sessionID
    }
}

enum CaptureFailure: LocalizedError {
    case noDisplay
    case writerSetup(String)
    case noAudioReceived

    var errorDescription: String? {
        switch self {
        case .noDisplay: "没有找到可共享的显示器"
        case .writerSetup(let detail): "无法建立本地压缩音频文件：\(detail)"
        case .noAudioReceived: "没有收到系统音频，请检查“屏幕与系统音频录制”权限和所选来源"
        }
    }
}

final class CaptureService: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    @Published private(set) var sources: [CaptureSource] = []
    @Published private(set) var isLoadingSources = false
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var lastSampleAt: Date?
    @Published private(set) var segmentURLs: [URL] = []
    @Published private(set) var completedSegmentURLs: [URL] = []
    @Published private(set) var recordingSessionID: UUID?
    @Published private(set) var recordedDuration: TimeInterval = 0
    @Published private(set) var segmentOffsets: [String: TimeInterval] = [:]
    @Published private(set) var interruption: CaptureInterruption?
    @Published private(set) var signalWarning: String?
    @Published var errorMessage: String?

    private let sampleQueue = DispatchQueue(label: "com.knowledge-spine.capture.samples", qos: .userInitiated)
    private var stream: SCStream?
    private let targetLock = NSLock()
    private var recorder: AudioChunkRecorder?
    private var stoppingTask: Task<AudioDrainResult, Never>?
    nonisolated(unsafe) private var captureTarget: (ObjectIdentifier, AudioChunkRecorder)?
    private var watchdogTask: Task<Void, Never>?
    private var captureStartedAt: Date?
    private var lastAudibleAt: Date?

    @MainActor
    func refreshSources() async {
        isLoadingSources = true
        defer { isLoadingSources = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw CaptureFailure.noDisplay }
            var result: [CaptureSource] = [
                CaptureSource(
                    name: "全系统声音",
                    detail: "应用或窗口取音不稳定时使用",
                    kind: .system,
                    filter: SCContentFilter(display: display, excludingWindows: [])
                )
            ]

            let apps = content.applications
                .filter { $0.processID != ProcessInfo.processInfo.processIdentifier && $0.applicationName.isEmpty == false }
                .sorted { $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending }
            for app in apps.prefix(40) {
                let windows = content.windows.filter { $0.owningApplication?.processID == app.processID }
                guard !windows.isEmpty else { continue }
                result.append(
                    CaptureSource(
                        name: app.applicationName,
                        detail: "捕获这个应用的系统声音",
                        kind: .application,
                        filter: SCContentFilter(display: display, including: [app], exceptingWindows: [])
                    )
                )
            }

            for window in content.windows.filter({ $0.title?.isEmpty == false }).prefix(50) {
                result.append(
                    CaptureSource(
                        name: window.title ?? "未命名窗口",
                        detail: window.owningApplication?.applicationName ?? "窗口",
                        kind: .window,
                        filter: SCContentFilter(desktopIndependentWindow: window)
                    )
                )
            }
            sources = result
            errorMessage = nil
        } catch {
            sources = []
            errorMessage = "无法读取声音来源：\(error.localizedDescription)"
        }
    }

    @MainActor
    func start(source: CaptureSource, outputDirectory: URL, sessionID: UUID) async throws {
        guard !isRecording, recordingSessionID == nil, stoppingTask == nil else {
            throw CaptureFailure.writerSetup("上一场录音尚未结束")
        }
        segmentURLs = []; completedSegmentURLs = []; segmentOffsets = [:]
        recordedDuration = 0; isPaused = false; lastSampleAt = nil
        errorMessage = nil; interruption = nil; signalWarning = nil
        captureStartedAt = Date(); lastAudibleAt = nil
        recordingSessionID = sessionID
        do {
            let recorder = try AudioChunkRecorder(
                directory: outputDirectory,
                onChunk: { [weak self] url, offset in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.recordingSessionID == sessionID else { return }
                        self.segmentOffsets[url.path] = offset
                        self.segmentURLs = (self.segmentURLs + [url]).sorted { $0.path < $1.path }
                        self.completedSegmentURLs = self.segmentURLs
                    }
                },
                onDuration: { [weak self] duration in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.recordingSessionID == sessionID else { return }
                        self.recordedDuration = duration
                    }
                },
                onFailure: { [weak self] message in
                    Task { @MainActor [weak self] in
                        await self?.interruptRecording(sessionID: sessionID, message: message)
                    }
                }
            )
            self.recorder = recorder
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 44_100; configuration.channelCount = 1
            configuration.width = 2; configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            configuration.queueDepth = 3
            let newStream = SCStream(filter: source.filter, configuration: configuration, delegate: self)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            stream = newStream
            targetLock.withLock { captureTarget = (ObjectIdentifier(newStream), recorder) }
            try await newStream.startCapture()
            isRecording = true
            startWatchdog()
        } catch {
            _ = await finishRecording()
            throw error
        }
    }

    @MainActor
    func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()
        recorder?.setPaused(isPaused)
        lastSampleAt = nil; lastAudibleAt = nil; captureStartedAt = Date()
        signalWarning = nil
    }

    @MainActor
    func stop() async throws -> [URL] {
        let result = await finishRecording()
        if !result.errors.isEmpty { errorMessage = result.errors.joined(separator: "；") }
        guard !result.urls.isEmpty else {
            if !result.errors.isEmpty { throw CaptureFailure.writerSetup(result.errors.joined(separator: "；")) }
            throw CaptureFailure.noAudioReceived
        }
        return result.urls
    }

    @MainActor
    private func finishRecording() async -> AudioDrainResult {
        if let stoppingTask { return await stoppingTask.value }
        watchdogTask?.cancel(); watchdogTask = nil
        let source = stream, recorder = self.recorder
        stream = nil // late delegate errors belong to this closing source
        targetLock.withLock { captureTarget = nil }
        let task = Task { @MainActor in
            await CaptureShutdown.finish(
                stopSource: { if let source { try await source.stopCapture() } },
                drain: { if let recorder { return await recorder.finish() }
                    return AudioDrainResult(urls: [], errors: []) }
            )
        }
        stoppingTask = task
        let result = await task.value
        isRecording = false; isPaused = false; audioLevel = 0; signalWarning = nil
        segmentURLs = result.urls
        self.recorder = nil
        recordingSessionID = nil
        stoppingTask = nil
        return result
    }

    @MainActor
    private func interruptRecording(sessionID: UUID, message: String) async {
        guard recordingSessionID == sessionID, stoppingTask == nil else { return }
        let result = await finishRecording()
        let detail = "声音记录已中断，已保留能够封口的音频：" + message
            + (result.errors.isEmpty ? "" : "；" + result.errors.joined(separator: "；"))
        errorMessage = detail
        interruption = CaptureInterruption(sessionID: sessionID, urls: result.urls, message: detail)
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid else { return }
        let target = targetLock.withLock { captureTarget }
        guard let target, target.0 == ObjectIdentifier(stream) else { return }
        target.1.append(buffer)
        let level = Self.level(from: buffer)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream, self.isRecording, !self.isPaused else { return }
            self.audioLevel = level
            self.lastSampleAt = Date()
            if level > 0.01 { self.lastAudibleAt = Date(); self.signalWarning = nil }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, let id = self.recordingSessionID else { return }
            await self.interruptRecording(sessionID: id, message: error.localizedDescription)
        }
    }

    @MainActor
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.isRecording, !self.isPaused else { continue }
                self.signalWarning = CaptureSignalHealth.warning(
                    now: Date(), startedAt: self.captureStartedAt ?? Date(),
                    lastSampleAt: self.lastSampleAt, lastAudibleAt: self.lastAudibleAt
                )
            }
        }
    }

    nonisolated private static func level(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let format = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        let byteCount = CMBlockBufferGetDataLength(block)
        guard byteCount > 0 else { return 0 }
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return 0 }

        var rms = 0.0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let count = byteCount / MemoryLayout<Float>.size
            guard count > 0 else { return 0 }
            rms = data.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Float.self)
                return sqrt(values.prefix(count).reduce(0.0) { $0 + Double($1 * $1) } / Double(count))
            }
        } else {
            let count = byteCount / MemoryLayout<Int16>.size
            guard count > 0 else { return 0 }
            rms = data.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Int16.self)
                return sqrt(values.prefix(count).reduce(0.0) { partial, value in
                    let normalized = Double(value) / Double(Int16.max)
                    return partial + normalized * normalized
                } / Double(count))
            }
        }
        return min(1, max(0, rms * 5))
    }
}

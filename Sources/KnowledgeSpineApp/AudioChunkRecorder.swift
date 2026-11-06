@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

struct AudioDrainResult: Sendable {
    let urls: [URL]
    let errors: [String]
}

/// All encoder state is confined to one queue. finish waits for EVERY rotating
/// writer, and only successfully sealed files may reach ASR or the database.
final class AudioChunkRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "knowledge-spine.audio-writers")
    private let pending = DispatchGroup()
    private let directory: URL
    private let onChunk: @Sendable (URL, TimeInterval) -> Void
    private let onDuration: @Sendable (TimeInterval) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var accepting = true
    private var paused = false
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var start: CMTime?
    private var index = 0
    private var duration: TimeInterval = 0
    private var segmentDuration: TimeInterval = 0
    private var segmentOffset: TimeInterval = 0
    private var sealed: [(Int, URL)] = []
    private var errors: [String] = []

    init(directory: URL, onChunk: @escaping @Sendable (URL, TimeInterval) -> Void,
         onDuration: @escaping @Sendable (TimeInterval) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) throws {
        self.directory = directory
        self.onChunk = onChunk
        self.onDuration = onDuration
        self.onFailure = onFailure
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func setPaused(_ value: Bool) {
        queue.async { [self] in
            paused = value
            if value { sealCurrent() } // no wall-clock pause gap inside an AAC file
        }
    }

    func append(_ buffer: CMSampleBuffer) {
        let retained = RetainedAudioBuffer(value: buffer)
        queue.async { [self] in
            let buffer = retained.value
            guard accepting, !paused, buffer.isValid else { return }
            let timestamp = buffer.presentationTimeStamp
            if let start, CMTimeGetSeconds(timestamp - start) >= 15 { sealCurrent() }
            do {
                if writer == nil { try begin(at: timestamp) }
                guard let input, input.isReadyForMoreMediaData else {
                    throw CaptureFailure.writerSetup("音频编码器无法跟上输入，已停止并保留已录内容")
                }
                guard input.append(buffer), let format = buffer.formatDescription,
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      asbd.mSampleRate > 0 else {
                    throw CaptureFailure.writerSetup(writer?.error?.localizedDescription ?? "音频写入失败")
                }
                let end = max(0, CMTimeGetSeconds(timestamp - (start ?? timestamp)))
                    + Double(CMSampleBufferGetNumSamples(buffer)) / asbd.mSampleRate
                duration += max(0, end - segmentDuration)
                segmentDuration = end
                onDuration(duration)
            } catch { fail(error.localizedDescription) }
        }
    }

    func finish() async -> AudioDrainResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                accepting = false
                sealCurrent()
                pending.notify(queue: queue) { [self] in
                    continuation.resume(returning: AudioDrainResult(
                        urls: sealed.sorted { $0.0 < $1.0 }.map(\.1), errors: errors
                    ))
                }
            }
        }
    }

    private func begin(at timestamp: CMTime) throws {
        index += 1
        let url = directory.appendingPathComponent(String(format: "audio-%04d.m4a", index))
        // Never remove an existing file to make room for a new recording.
        let newWriter = try AVAssetWriter(url: url, fileType: .m4a)
        let newInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
        ])
        newInput.expectsMediaDataInRealTime = true
        guard newWriter.canAdd(newInput) else { throw CaptureFailure.writerSetup("编码器拒绝输入") }
        newWriter.add(newInput)
        guard newWriter.startWriting() else { throw CaptureFailure.writerSetup(newWriter.error?.localizedDescription ?? "无法开始编码") }
        newWriter.startSession(atSourceTime: timestamp)
        writer = newWriter
        input = newInput
        start = timestamp
        segmentOffset = duration
        segmentDuration = 0
    }

    private func sealCurrent() {
        guard let current = writer else { return }
        let ordinal = index, offset = segmentOffset
        input?.markAsFinished()
        writer = nil; input = nil; start = nil; segmentDuration = 0
        pending.enter()
        current.finishWriting { [self] in
            queue.async { [self] in
                if current.status == .completed {
                    sealed.append((ordinal, current.outputURL))
                    onChunk(current.outputURL, offset)
                } else {
                    fail(current.error?.localizedDescription ?? "音频分块封口失败，失败文件保留用于恢复")
                }
                pending.leave()
            }
        }
    }

    private func fail(_ message: String) {
        errors.append(message)
        if accepting { accepting = false; onFailure(message) }
    }
}

/// Always drains encoders, even when the platform stop operation throws.
enum CaptureShutdown {
    @MainActor
    static func finish(stopSource: () async throws -> Void,
                       drain: () async -> AudioDrainResult) async -> AudioDrainResult {
        var stopErrors: [String] = []
        do { try await stopSource() } catch { stopErrors = [error.localizedDescription] }
        let result = await drain()
        return AudioDrainResult(urls: result.urls, errors: stopErrors + result.errors)
    }
}

private struct RetainedAudioBuffer: @unchecked Sendable {
    // CMSampleBuffer is retained and only read on the encoder queue.
    let value: CMSampleBuffer
}

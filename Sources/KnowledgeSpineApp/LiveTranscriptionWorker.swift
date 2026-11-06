import Foundation
import Darwin
import KnowledgeSpineCore

// Requests are serialized by LocalProcessingService. Cancellation must remain
// callable while a background thread is blocked reading the child's response.
final class LiveTranscriptionWorker: @unchecked Sendable {
    static func protectPipeFromBrokenReader(_ handle: FileHandle) throws {
        // Cancellation can close the reader between checking the child and
        // writing a request. Return EPIPE to the request instead of letting
        // SIGPIPE terminate the entire recording app. Scope this to this fd.
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
    }

    static var appleSpeechPath: String? {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return nil }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/KnowledgeSpineAppleSpeech")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/arm64-apple-macosx/release/KnowledgeSpineAppleSpeech")
        return [bundled, development].first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }
    private let lock = NSLock()
    private let termination = DispatchGroup()
    private var process: Process?
    private var cancelled = false
    private var input: FileHandle?
    private var output: FileHandle?

    func cancel() {
        lock.lock()
        cancelled = true
        let child = process
        lock.unlock()
        if let child, child.isRunning {
            // This disposable preview worker owns no database or recording file.
            // Killing it releases the model before final processing starts.
            kill(child.processIdentifier, SIGKILL)
        }
    }

    func waitForExit() async {
        // A rapidly exited child can leave Foundation's waitUntilExit run loop
        // waiting on the wrong thread. The handler records completion exactly
        // once, even if it arrives before this caller starts awaiting it.
        await withCheckedContinuation { continuation in
            termination.notify(queue: .global()) { continuation.resume() }
        }
    }

    func transcribe(path: String, settings: AppSettings, timeOffset: TimeInterval? = nil) async throws -> LocalProcessingResult {
        try await Task.detached { [self] in
            try request(path: path, settings: settings, timeOffset: timeOffset)
        }.value
    }

    private func request(path: String, settings: AppSettings, timeOffset: TimeInterval?) throws -> LocalProcessingResult {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        if process == nil {
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("Backend/live_worker.py")
            let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Backend/live_worker.py")
            guard let script = [bundled, development].compactMap({ $0 }).first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) else { lock.unlock(); throw LocalProcessingFailure.missingScript }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: settings.pythonPath)
            child.arguments = ["-B", "-u", script.path]
            let incoming = Pipe(), outgoing = Pipe()
            do { try Self.protectPipeFromBrokenReader(incoming.fileHandleForWriting) }
            catch { lock.unlock(); throw error }
            child.standardInput = incoming
            child.standardOutput = outgoing
            child.standardError = FileHandle.nullDevice
            let completion = termination
            completion.enter()
            child.terminationHandler = { _ in completion.leave() }
            do { try child.run() }
            catch { completion.leave(); lock.unlock(); throw error }
            process = child
            input = incoming.fileHandleForWriting
            output = outgoing.fileHandleForReading
        }
        let writer = input!, reader = output!
        lock.unlock()
        // A stalled preview may be skipped; all audio is retained for final ASR.
        let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        defer { timeout.cancel() }
        var manifest: [String: Any] = ["audio_paths": [path], "language": "zh",
            "whisper_model_path": settings.whisperModelPath, "ffmpeg_path": settings.ffmpegPath]
        if let timeOffset { manifest["preview_time_offset"] = timeOffset }
        if let helper = Self.appleSpeechPath { manifest["apple_speech_path"] = helper }
        var request = try JSONSerialization.data(withJSONObject: manifest)
        request.append(10)
        try writer.write(contentsOf: request)
        var response = Data()
        while response.count < 4_000_000 {
            let byte = try reader.read(upToCount: 1) ?? Data()
            if byte.isEmpty { throw LocalProcessingFailure.processFailed("实时转写进程已结束") }
            if byte.first == 10 { break }
            response.append(byte)
        }
        if let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
           let error = object["error"] as? String {
            throw LocalProcessingFailure.processFailed(error)
        }
        return try JSONDecoder().decode(LocalProcessingResult.self, from: response)
    }

    deinit { cancel() }
}

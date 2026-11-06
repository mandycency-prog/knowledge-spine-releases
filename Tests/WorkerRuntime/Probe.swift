import Foundation
import KnowledgeSpineCore

// Wire types match the app; the worker implementation itself is compiled from
// the production source by check_worker_runtime.sh.
struct LocalProcessingResult: Codable, Sendable {
    let speakers: [Speaker]
    let spans: [TranscriptSpan]
    let candidates: [StructureCandidate]
    let warnings: [String]
}
enum LocalProcessingFailure: Error {
    case missingScript, processFailed(String)
}

@main struct Probe {
    static func main() async throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let audio = (manifest["audio_paths"] as! [String])[30]
        let settings = AppSettings(pythonPath: CommandLine.arguments[2], whisperModelPath: manifest["whisper_model_path"] as! String,
                                   structureModelPath: "unused", ffmpegPath: manifest["ffmpeg_path"] as! String)
        let worker = LiveTranscriptionWorker()
        let first = try await worker.transcribe(path: audio, settings: settings)
        let second = try await worker.transcribe(path: audio, settings: settings)
        precondition(!first.spans.isEmpty && !second.spans.isEmpty)
        worker.cancel()
        await worker.waitForExit()
        let cancelledWorker = LiveTranscriptionWorker()
        let pending = Task { try await cancelledWorker.transcribe(path: audio, settings: settings) }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        cancelledWorker.cancel()
        await cancelledWorker.waitForExit()
        do { _ = try await pending.value; fatalError("Cancelled worker returned success") }
        catch { }
        precondition(Date().timeIntervalSince(start) < 3)
        print("PASS: production Swift worker decoded two real chunks and cancelled an active process within 3 seconds")
    }
}

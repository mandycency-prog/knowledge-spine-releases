import Foundation
import Speech
import AVFoundation
import CoreMedia
import Darwin

// Protocol: NDJSON on stdout, and a single `complete` event plus exit 0 is the
// only success marker. Partial segments must never replace a saved transcript.
// No network recognition, authorization requests, asset reservation or download.
private enum Output {
    static let lock = NSLock()
    static func emit(_ value: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        } catch {
            // A closed consumer pipe must not leave an orphan doing recognition.
            exit(74)
        }
    }
}

private enum HelperError: Error {
    case unavailable, unreadableFile, invalidAudio, invalidTimestamp, cancelled
}

/// Synchronizes OS callbacks with asynchronous recognition. Graceful shutdown
/// receives at most two seconds before a hard exit, including stuck system APIs.
private final class Lifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    private var cancelAnalysis: (@Sendable () async -> Void)?
    private var sources: [any DispatchSourceProtocol] = []
    private let originalParent = getppid()

    func begin(timeout: Int) {
        signal(SIGPIPE, SIG_IGN)
        guard originalParent > 1 else {
            Output.emit(["event": "error", "error": "Parent process exited", "exitCode": 125])
            exit(125)
        }
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [self] in
                stop(code: 128 + signalNumber, reason: "Recognition cancelled")
            }
            sources.append(source)
            source.resume()
        }
        let parent = DispatchSource.makeTimerSource(queue: .global())
        parent.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        parent.setEventHandler { [self] in
            if getppid() != originalParent || (kill(originalParent, 0) != 0 && errno == ESRCH) {
                stop(code: 125, reason: "Parent process exited")
            }
        }
        sources.append(parent)
        parent.resume()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .seconds(timeout))
        timer.setEventHandler { [self] in
            stop(code: 124, reason: "Recognition exceeded \(timeout) seconds")
        }
        sources.append(timer)
        timer.resume()
    }

    func registerCancellation(_ action: @escaping @Sendable () async -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping else { throw HelperError.cancelled }
        cancelAnalysis = action
    }

    func checkRunning() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping else { throw HelperError.cancelled }
    }

    func stop(code: Int32, reason: String) {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        stopping = true
        let cancellation = cancelAnalysis
        lock.unlock()
        Output.emit(["event": "error", "error": reason, "exitCode": code])
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(code) }
        Task.detached {
            await cancellation?()
            exit(code)
        }
    }

    func complete(_ fields: [String: Any] = [:]) -> Never {
        lock.lock()
        guard !stopping else { lock.unlock(); exit(125) }
        guard getppid() == originalParent else {
            Output.emit(["event": "error", "error": "Parent process exited", "exitCode": 125])
            exit(125)
        }
        var value = fields
        value["event"] = "complete"
        Output.emit(value)
        exit(0)
    }
}

private enum AppleSpeechHelper {
    static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let probe = args == ["--probe"]
        var path: String?
        var timeout = probe ? 40 : 1800
        if !probe {
            guard (args.count == 2 || args.count == 4), args.first == "--transcribe" else {
                usage()
            }
            path = args[1]
            if args.count == 4 {
                guard args[2] == "--timeout-seconds", let seconds = Int(args[3]), (30...21600).contains(seconds) else {
                    usage()
                }
                timeout = seconds
            }
        }
        let lifetime = Lifetime()
        lifetime.begin(timeout: timeout)
        guard #available(macOS 26.0, *) else {
            lifetime.stop(code: 69, reason: "Apple SpeechTranscriber requires macOS 26 or newer")
            try? await Task.sleep(for: .seconds(3))
            return
        }
        if probe {
            let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }.sorted()
            lifetime.complete(["available": SpeechTranscriber.isAvailable,
                               "installedChinese": installed.contains("zh-CN"), "installedLocales": installed])
        }
        do {
            let count = try await transcribe(path!, lifetime: lifetime)
            lifetime.complete(["fileCount": 1, "segmentCount": count])
        } catch {
            lifetime.stop(code: 1, reason: String(describing: error))
            // Keep the process alive while stop() drains/cancels the analyzer.
            try? await Task.sleep(for: .seconds(3))
        }
    }

    static func usage() -> Never {
        Output.emit(["event": "error", "error": "Usage: --probe OR --transcribe FILE [--timeout-seconds 30...21600]"])
        exit(64)
    }

    @available(macOS 26.0, *)
    static func transcribe(_ path: String, lifetime: Lifetime) async throws -> Int {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")),
              await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw HelperError.unavailable
        }
        try lifetime.checkRunning()
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw HelperError.unreadableFile }
        let audioFile = try AVAudioFile(forReading: url)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw HelperError.invalidAudio }
        // No fastResults or etiquette replacements: preserve the actual result.
        // SpeechTranscriber has no punctuation option in the macOS 26.5 SDK.
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        try lifetime.registerCancellation { await analyzer.cancelAndFinishNow() }
        let began = Date()
        Output.emit(["event": "fileStarted", "path": url.path, "durationSeconds": duration,
                     "authorizationRequested": false, "assetDownloadRequested": false,
                     "engine": "Apple SpeechTranscriber", "locale": "zh-CN"])
        let consumer = Task {
            var count = 0
            var previousEnd = 0.0
            for try await result in module.results {
                try lifetime.checkRunning()
                guard result.isFinal else { continue }
                let start = CMTimeGetSeconds(result.range.start)
                let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                guard start.isFinite, end.isFinite, start >= 0, end >= start,
                      start >= previousEnd - 0.05, end <= duration + 0.1 else {
                    throw HelperError.invalidTimestamp
                }
                var words: [[String: Any]] = []
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let wordStart = CMTimeGetSeconds(range.start)
                    let wordEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                    guard wordStart.isFinite, wordEnd.isFinite, wordEnd >= wordStart,
                          wordStart >= start - 0.1, wordEnd <= end + 0.1 else {
                        throw HelperError.invalidTimestamp
                    }
                    words.append(["word": String(result.text[run.range].characters), "start": wordStart, "end": wordEnd])
                }
                var event: [String: Any] = ["event": "segment", "path": url.path, "start": start, "end": end,
                                            "text": String(result.text.characters)]
                if !words.isEmpty { event["words"] = words }
                Output.emit(event)
                previousEnd = end
                count += 1
            }
            return count
        }
        do {
            // AVAudioFile is streamed by the analyzer, not loaded into an array.
            // One input file means one continuous context, even across AAC cuts.
            try lifetime.checkRunning()
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let count = try await consumer.value
            try lifetime.checkRunning()
            Output.emit(["event": "fileComplete", "path": url.path, "segmentCount": count,
                         "elapsedSeconds": Date().timeIntervalSince(began)])
            return count
        } catch {
            consumer.cancel()
            // The caller handles cancellation under the bounded shutdown guard.
            throw error
        }
    }
}

await AppleSpeechHelper.run()

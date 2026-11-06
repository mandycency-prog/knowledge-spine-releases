import AppKit
import Foundation

@MainActor
enum CaptureExitCoordinator {
    static func finish(sessionID: UUID, store: AppStore,
                       stop: () async throws -> [URL], retained: () -> [URL]) async {
        do {
            let urls = try await stop()
            store.attachAudio(paths: urls.map(\.path), sessionID: sessionID)
        } catch {
            store.attachAudio(paths: retained().map(\.path), sessionID: sessionID)
        }
        // Persist the work to resume on the next launch; don't start a new
        // model process while this application is in its termination handshake.
        store.setStatus(.processing, sessionID: sessionID, endedAt: Date())
        store.flush()
    }
}

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    static var hasOpenCapture: (() -> Bool)?
    static var prepareExit: (() async -> Void)?
    static var flush: (() -> Bool)?
    private var exitInProgress = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.hasOpenCapture?() == true else {
            return Self.flush?() == true ? .terminateNow : .terminateCancel
        }
        if !exitInProgress {
            exitInProgress = true
            Task {
                await Self.prepareExit?()
                let saved = Self.flush?() == true
                exitInProgress = false
                sender.reply(toApplicationShouldTerminate: saved)
            }
        }
        return .terminateLater
    }
}

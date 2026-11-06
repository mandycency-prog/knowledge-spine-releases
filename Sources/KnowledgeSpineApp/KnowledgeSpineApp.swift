import SwiftUI
import AppKit
import KnowledgeSpineCore

@main
struct KnowledgeSpineDesktopApp: App {
    private let instanceLease: AppInstanceLease?
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var applicationDelegate
    @StateObject private var store: AppStore
    @StateObject private var capture: CaptureService
    @StateObject private var processor: LocalProcessingService
    @StateObject private var captureLifecycle: CaptureLifecycleCoordinator

    init() {
        DistributionSmokeTest.runIfRequested()
        let seedDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        // Acceptance builds have their own identity AND persistent test root;
        // unlike a visual demo, restart tests cannot touch the formal database.
        let isAcceptance = Bundle.main.bundleIdentifier == "com.local.knowledgespine.acceptance"
        let requestedRoot = Bundle.main.object(forInfoDictionaryKey: "KnowledgeSpineAcceptanceRoot") as? String
        let safeTestRoot = requestedRoot.flatMap { path -> URL? in
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let temporaryParent = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
            return url.deletingLastPathComponent() == temporaryParent && url.lastPathComponent.hasPrefix("KnowledgeSpine-Acceptance-") ? url : nil
        }
        let acceptanceRoot = isAcceptance ? (safeTestRoot ?? URL(fileURLWithPath: "/private/tmp/KnowledgeSpine-Acceptance-20260910", isDirectory: true)) : nil
        if seedDemo {
            instanceLease = nil
        } else {
            let root = acceptanceRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(PortableRuntime.dataDirectoryName, isDirectory: true)
            // Old installed versions do not hold application.lock yet. Detect
            // them as well, before opening the shared database.
            let peers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.local.knowledgespine")
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
            let legacyPeer = peers.first { peer in
                guard let url = peer.bundleURL,
                      let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return true }
                return version.compare("20260917.1", options: .numeric) == .orderedAscending
            }
            let lease = AppInstanceLease(root: root)
            // New versions arbitrate through flock, not mutual peer detection:
            // two simultaneous launches must not both decide to exit.
            if lease == nil || (!isAcceptance && legacyPeer != nil) {
                if let peer = legacyPeer ?? peers.first { peer.activate(options: [.activateAllWindows]) }
                else {
                    let alert = NSAlert()
                    alert.messageText = "知识骨架未能打开记录目录"
                    alert.informativeText = "目录正在由另一个实例使用，或当前无法写入。为保护记录，本次没有打开数据库。"
                    alert.runModal()
                }
                exit(0)
            }
            instanceLease = lease
        }
        let store = AppStore(inMemory: seedDemo, seedDemo: seedDemo, storageRoot: acceptanceRoot)
        let capture = CaptureService()
        let processor = LocalProcessingService()
        AppTerminationDelegate.hasOpenCapture = { capture.recordingSessionID != nil }
        AppTerminationDelegate.flush = { store.flush() }
        AppTerminationDelegate.prepareExit = {
            guard let id = capture.recordingSessionID else { store.flush(); return }
            processor.cancelLive(sessionID: id)
            await CaptureExitCoordinator.finish(sessionID: id, store: store,
                stop: { try await capture.stop() }, retained: { capture.segmentURLs })
        }
        _store = StateObject(wrappedValue: store)
        _capture = StateObject(wrappedValue: capture)
        _processor = StateObject(wrappedValue: processor)
        _captureLifecycle = StateObject(wrappedValue: CaptureLifecycleCoordinator(
            store: store, source: capture,
            enqueuePreview: { id, path, offset in processor.processLiveSegment(sessionID: id, audioPath: path, timeOffset: offset, store: store) },
            processInterrupted: { id, paths in processor.process(sessionID: id, audioPaths: paths, store: store) },
            notifyIssue: { message in Task { await LocalProcessingService.notify(title: "听课记录需要注意", body: message) } }
        ))
    }

    var body: some Scene {
        WindowGroup("直播与课程知识骨架", id: "main") {
            RootView()
                .environmentObject(captureLifecycle)
                .environmentObject(store)
                .environmentObject(capture)
                .environmentObject(processor)
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1320, height: 860)

        Window("正在记录和转写", id: "capture") {
            CaptureWindow()
                .environmentObject(store)
                .environmentObject(capture)
                .environmentObject(processor)
                .frame(minWidth: 520, idealWidth: 560, maxWidth: 640, minHeight: 550)
                .preferredColorScheme(.light)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(processor)
                .frame(width: 680, height: 700)
        }
    }
}

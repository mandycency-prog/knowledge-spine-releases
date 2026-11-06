import Combine
import Foundation

/// Capture events belong to the app, not to whichever window happens to be open.
@MainActor
protocol CaptureEventSource: AnyObject {
    var recordingSessionID: UUID? { get }
    var isRecording: Bool { get }
    var completedSegmentsPublisher: AnyPublisher<[URL], Never> { get }
    var interruptionPublisher: AnyPublisher<CaptureInterruption?, Never> { get }
    var warningPublisher: AnyPublisher<String?, Never> { get }
    var segmentOffsets: [String: TimeInterval] { get }
}

extension CaptureService: CaptureEventSource {
    @MainActor var completedSegmentsPublisher: AnyPublisher<[URL], Never> {
        $completedSegmentURLs.eraseToAnyPublisher()
    }
    @MainActor var interruptionPublisher: AnyPublisher<CaptureInterruption?, Never> {
        $interruption.eraseToAnyPublisher()
    }
    @MainActor var warningPublisher: AnyPublisher<String?, Never> {
        $signalWarning.eraseToAnyPublisher()
    }
}

@MainActor
final class CaptureLifecycleCoordinator: ObservableObject {
    private var subscriptions: Set<AnyCancellable> = []
    private var seenPaths: Set<String> = []

    init(
        store: AppStore,
        source: any CaptureEventSource,
        enqueuePreview: @escaping (UUID, String, TimeInterval) -> Void,
        processInterrupted: @escaping (UUID, [String]) -> Void,
        notifyIssue: @escaping (String) -> Void
    ) {
        // CaptureService publishes on the main actor. Use the incoming value:
        // @Published emits before its stored property has been updated.
        source.completedSegmentsPublisher.sink { [weak self, weak source] urls in
            guard let self else { return }
            if urls.isEmpty { self.seenPaths.removeAll(); return }
            guard let source, let id = source.recordingSessionID else { return }
            let paths = urls.map(\.path).sorted()
            store.attachAudio(paths: paths, sessionID: id)
            store.flush()
            guard source.isRecording else { return }
            for path in paths {
                // Missing timing must never silently place later speech at t=0.
                // The audio is already registered for complete final processing.
                guard let offset = source.segmentOffsets[path], self.seenPaths.insert(path).inserted else { continue }
                enqueuePreview(id, path, offset)
            }
        }.store(in: &subscriptions)

        source.interruptionPublisher.sink { interruption in
            guard let interruption, store.registerCaptureInterruption(interruption) else { return }
            store.flush()
            notifyIssue(interruption.message)
            let paths = interruption.urls.map(\.path)
            if !paths.isEmpty { processInterrupted(interruption.sessionID, paths) }
        }.store(in: &subscriptions)

        source.warningPublisher.removeDuplicates().sink { warning in
            if let warning { notifyIssue(warning) }
        }.store(in: &subscriptions)
    }
}

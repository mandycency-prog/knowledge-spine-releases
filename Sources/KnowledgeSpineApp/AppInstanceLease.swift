import Foundation
import Darwin

/// Held for the process lifetime, before any store, migration or worker starts.
/// Database CAS still protects external edits; this prevents duplicate UI writers.
final class AppInstanceLease {
    private var descriptor: Int32 = -1
    init?(root: URL) {
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { return nil }
        descriptor = open(root.appendingPathComponent("application.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            return nil
        }
    }
    deinit {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) }
    }
}

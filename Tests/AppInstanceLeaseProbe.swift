import Foundation

@main enum AppInstanceLeaseProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeSpine-lease-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var first = AppInstanceLease(root: root)
        precondition(first != nil)
        precondition(AppInstanceLease(root: root) == nil, "A second writer must not enter")
        let other = AppInstanceLease(root: root.appendingPathComponent("isolated"))
        precondition(other != nil, "Independent acceptance roots must coexist")
        first = nil
        let restarted = AppInstanceLease(root: root)
        precondition(restarted != nil, "A stale lock file must not block restart")
        withExtendedLifetime((other, restarted)) {}
        print("PASS: duplicate writer blocked; isolated root allowed; lock released on exit")
    }
}

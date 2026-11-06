import Foundation
import KnowledgeSpineCore

/// Read-only reproduction of the old vs correct source-version selection.
/// This does not instantiate VersionSheet or claim interactive UI acceptance.
@main struct VersionPresentationProbe {
    @MainActor static func main() throws {
        precondition(CommandLine.arguments.count == 2)
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let before = try Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let database = try decoder.decode(AppDatabase.self, from: before)
        let current = database.sessions[0]
        var candidate = current.candidateVersions!.last!
        // Quote-only nodes are legal: absence of AI summary must not remove
        // their content from the candidate preview.
        let index = candidate.nodes.firstIndex { $0.thoughtID == nil && $0.importantMarkID == nil && !$0.isSecondaryEdit }!
        candidate.nodes[index].aiSummary = nil
        let node = candidate.nodes[index]
        try IntegrityValidator.validateStoredNode(node, transcript: candidate.transcript!)
        precondition(Set(node.sourceSpanIDs).isDisjoint(with: Set(current.transcript.map(\.id))))
        let oldSignatures = Set(current.nodes.filter { !$0.isDeleted }.map(StructureVersionMerge.signature))
        let added = StructureVersionMerge.merge(current: current.nodes, candidate: candidate.nodes)
            .filter { !$0.isDeleted && !oldSignatures.contains(StructureVersionMerge.signature($0)) }
        precondition(added.contains { $0.id == node.id })
        let store = AppStore(inMemory: true)
        let actual = store.nodeText(node, in: current)
        var versionContext = current
        versionContext.transcript = candidate.transcript!
        let expected = store.nodeText(node, in: versionContext)
        precondition(actual.isEmpty && !expected.isEmpty)
        let after = try Data(contentsOf: url)
        precondition(after == before)
        print("REPRODUCED: valid quote-only added candidate renders empty with current transcript; candidate transcript renders its original text.")
        print("currentText=\(String(reflecting: actual))")
        print("candidateText=\(String(reflecting: expected))")
        print("Source fixture unchanged; no app, model or persistence started.")
        print("Scope: source-context reproduction only; VersionSheet rendering and interaction are NOT tested.")
    }
}

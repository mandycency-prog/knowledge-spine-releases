import Foundation

/// Preserve authored nodes by identity/content, never by broad source overlap:
/// one transcript span can legitimately support many different ideas.
public enum StructureVersionMerge {
    public static func signature(_ node: KnowledgeNode) -> String {
        let text = (node.userEditedText ?? node.aiSummary ?? node.userLabel ?? "").simplifiedChineseForDisplay
        let role = node.semanticRole.map { "::role=" + $0.rawValue } ?? ""
        return node.sourceSpanIDs.map(\.uuidString).sorted().joined(separator: "|")
            + "::images=" + (node.sourceImageIDs ?? []).map(\.uuidString).sorted().joined(separator: "|") + "::" + text + role
    }

    public static func merge(current: [KnowledgeNode], candidate: [KnowledgeNode]) -> [KnowledgeNode] {
        let active = current.filter { !$0.isDeleted }
        var merged = candidate.filter { !$0.isDeleted }
        let protected = active.filter { $0.manualRevisionAt != nil || $0.isSecondaryEdit || $0.kind == .thought || $0.importantMarkID != nil }
        let protectedIDs = Set(protected.map(\.id))
        let candidateIDs = Set(merged.map(\.id))
        var replacementIDs: [UUID: UUID] = [:]
        var matchedParents: [UUID: UUID] = [:]
        var consumed: Set<UUID> = []
        for node in protected {
            // Identity wins over text. Never consume another authored node, or
            // match two distinct thoughts merely because their wording agrees.
            let match = merged.firstIndex(where: { $0.id == node.id }) ?? merged.firstIndex(where: {
                guard candidateIDs.contains($0.id), !consumed.contains($0.id), !protectedIDs.contains($0.id) else { return false }
                if let thoughtID = node.thoughtID { return $0.thoughtID == thoughtID }
                if let markID = node.importantMarkID { return $0.importantMarkID == markID }
                guard node.kind != .thought, $0.kind != .thought, $0.thoughtID == nil, $0.importantMarkID == nil else { return false }
                return signature($0) == signature(node)
            })
            if let index = match {
                let proposed = merged[index]
                replacementIDs[proposed.id] = node.id
                if let parent = proposed.parentID { matchedParents[node.id] = parent }
                consumed.insert(node.id)
                consumed.insert(proposed.id)
                merged[index] = node
            } else {
                merged.append(node)
                consumed.insert(node.id)
            }
        }
        let present = Set(merged.map(\.id))
        let oldByID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        var oldToNew: [UUID: UUID] = [:]
        for node in active {
            if present.contains(node.id) { oldToNew[node.id] = node.id }
            else if let found = merged.first(where: { signature($0) == signature(node) }) { oldToNew[node.id] = found.id }
        }
        let primaryRoot = candidate.first(where: { !$0.isDeleted && $0.parentID == nil }).map { replacementIDs[$0.id] ?? $0.id }
        for index in merged.indices {
            let id = merged[index].id
            let isAnnotation = merged[index].kind == .thought || merged[index].thoughtID != nil || merged[index].importantMarkID != nil
            guard let originalParent = merged[index].parentID ?? (isAnnotation ? nil : matchedParents[id]) else { continue }
            var parent: UUID? = replacementIDs[originalParent] ?? originalParent
            var visited: Set<UUID> = [id]
            while let cursor = parent, !present.contains(cursor) {
                guard visited.insert(cursor).inserted else { parent = nil; break }
                if let mapped = oldToNew[cursor] { parent = mapped; break }
                parent = oldByID[cursor]?.parentID
            }
            if parent == nil {
                parent = matchedParents[id].map { replacementIDs[$0] ?? $0 } ?? primaryRoot
            }
            if parent == id || (parent != nil && !present.contains(parent!)) { parent = nil }
            merged[index].parentID = parent
            if parent == nil { merged[index].relation = .root }
            else if merged[index].relation == .root { merged[index].relation = .child }
        }
        // Manual reattachments can conflict with the proposed tree. Break only
        // a cyclic parent edge; never delete the authored node or its evidence.
        for index in merged.indices {
            let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
            var visited: Set<UUID> = [merged[index].id]
            var cursor = merged[index].parentID
            while let id = cursor {
                if !visited.insert(id).inserted {
                    merged[index].parentID = nil
                    merged[index].relation = .root
                    break
                }
                cursor = byID[id]?.parentID
            }
        }
        for index in merged.indices {
            let node = merged[index]
            if node.isSecondaryEdit || node.kind == .thought || node.thoughtID != nil || node.importantMarkID != nil ||
                (node.semanticRole == .topic && (node.parentID != nil || node.relation != .root)) {
                merged[index].semanticRole = nil
            }
        }
        return merged
    }
}

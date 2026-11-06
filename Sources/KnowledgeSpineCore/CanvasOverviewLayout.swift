import Foundation

/// A display-only layout of the visible tree. Hidden evidence must not leave
/// empty rows in the overview; explicit user positions remain authoritative.
public enum CanvasOverviewLayout {
    public static func arrange(_ source: [KnowledgeNode], cardHeights: [UUID: Double] = [:]) -> [KnowledgeNode] {
        var nodes = baseArrangement(source)
        guard !cardHeights.isEmpty else { return nodes }
        let columns = Dictionary(grouping: nodes.indices, by: { Int((nodes[$0].position.x / 320).rounded()) })
        for column in columns.values {
            var bottom = 20.0
            for index in column.sorted(by: { nodes[$0].position.y < nodes[$1].position.y }) {
                let height = max(180, cardHeights[nodes[index].id] ?? 180)
                let pinned = nodes[index].positionEditedAt != nil || nodes[index].positionIsAutomatic == false ||
                    (nodes[index].positionIsAutomatic == nil && nodes[index].manualRevisionAt != nil)
                if !pinned { nodes[index].position.y = max(nodes[index].position.y, bottom + height / 2) }
                bottom = max(bottom, nodes[index].position.y + height / 2 + 40)
            }
        }
        return nodes
    }

    private static func baseArrangement(_ source: [KnowledgeNode]) -> [KnowledgeNode] {
        var nodes = source
        func isPositioned(_ node: KnowledgeNode) -> Bool {
            node.positionEditedAt != nil || node.positionIsAutomatic == false ||
                (node.positionIsAutomatic == nil && node.manualRevisionAt != nil)
        }
        // Reserve authored positions first. New automatic nodes must not cover
        // a user's thought or a node dragged in a previous structure version.
        var occupied = source.filter(isPositioned).map(\.position)
        let indices = Dictionary(uniqueKeysWithValues: nodes.indices.map { (nodes[$0].id, $0) })
        var children: [UUID: [UUID]] = [:]
        for node in nodes {
            if let parent = node.parentID, indices[parent] != nil {
                children[parent, default: []].append(node.id)
            }
        }
        let roots = nodes.filter { $0.parentID == nil || indices[$0.parentID!] == nil }.map(\.id)
        // A fresh single-topic map should use the screen's width, not shrink a
        // long one-sided column into an unreadable corner. Once the user drags
        // a node, the app freezes visible positions and this path stays off.
        if roots.count == 1, let root = roots.first, (children[root]?.count ?? 0) >= 2,
           !source.contains(where: isPositioned),
           let positions = balancedPositions(root: root, children: children, count: nodes.count) {
            for index in nodes.indices { nodes[index].position = positions[nodes[index].id]! }
            return nodes
        }
        var nextY = 150.0
        var visited: Set<UUID> = []
        func place(_ id: UUID, depth: Int) -> Double {
            guard let index = indices[id], visited.insert(id).inserted else { return nextY }
            let descendants = (children[id] ?? []).filter { !visited.contains($0) }
            let y: Double
            if descendants.isEmpty {
                y = nextY
                nextY += 220
            } else {
                let rows = descendants.map { place($0, depth: depth + 1) }
                y = (rows.first! + rows.last!) / 2
            }
            // New authored thoughts distinguish creation from actual dragging.
            // Legacy manual edits are ambiguous: conservatively keep positions.
            if !isPositioned(nodes[index]) {
                var point = CanvasPoint(x: 190 + Double(depth) * 360, y: y)
                while let obstruction = occupied.first(where: { abs($0.x - point.x) < 320 && abs($0.y - point.y) < 220 }) {
                    point.y = obstruction.y + 220
                }
                nodes[index].position = point
                occupied.append(point)
                if descendants.isEmpty { nextY = max(nextY, point.y + 220) }
            }
            return nodes[index].position.y
        }
        for id in roots { _ = place(id, depth: 0); nextY += 80 }
        for node in source where !visited.contains(node.id) { _ = place(node.id, depth: 0) }
        return nodes
    }

    private static func balancedPositions(root: UUID, children: [UUID: [UUID]], count: Int) -> [UUID: CanvasPoint]? {
        func extent(_ id: UUID, path: Set<UUID>) -> (leaves: Int, depth: Int)? {
            guard !path.contains(id) else { return nil }
            let branches = children[id] ?? []
            if branches.isEmpty { return (1, 1) }
            let values = branches.compactMap { extent($0, path: path.union([id])) }
            guard values.count == branches.count else { return nil }
            return (values.reduce(0) { $0 + $1.leaves }, 1 + values.map(\.depth).max()!)
        }
        let branches = children[root] ?? []
        let sizes = branches.compactMap { extent($0, path: [root]) }
        guard sizes.count == branches.count, branches.count >= 2 else { return nil }
        let total = sizes.reduce(0) { $0 + $1.leaves }
        let split = (1..<branches.count).min { left, right in
            abs(2 * sizes.prefix(left).reduce(0) { $0 + $1.leaves } - total)
                < abs(2 * sizes.prefix(right).reduce(0) { $0 + $1.leaves } - total)
        }!
        let centerX = 190 + Double(sizes.prefix(split).map(\.depth).max()!) * 360
        var positions: [UUID: CanvasPoint] = [:]
        func place(_ id: UUID, depth: Int, side: Double, nextY: inout Double) {
            let descendants = children[id] ?? []
            let y: Double
            if descendants.isEmpty { y = nextY; nextY += 220 }
            else {
                for child in descendants { place(child, depth: depth + 1, side: side, nextY: &nextY) }
                y = (positions[descendants.first!]!.y + positions[descendants.last!]!.y) / 2
            }
            positions[id] = CanvasPoint(x: centerX + side * Double(depth) * 360, y: y)
        }
        var leftY = 150.0, rightY = 150.0
        for id in branches.prefix(split) { place(id, depth: 1, side: -1, nextY: &leftY) }
        for id in branches.dropFirst(split) { place(id, depth: 1, side: 1, nextY: &rightY) }
        positions[root] = CanvasPoint(x: centerX, y: (150 + max(leftY, rightY) - 220) / 2)
        return positions.count == count ? positions : nil
    }
}

import Foundation
import KnowledgeSpineCore

@main struct CanvasInteractionProbe {
    @MainActor static func main() throws {
        let speaker = Speaker(role: .host)
        let span = TranscriptSpan(sequence: 1, startTime: 0, endTime: 30, speakerID: speaker.id, originalText: "合成原话：先理解，再行动。")
        func node(_ kind: NodeKind, parent: UUID? = nil) -> KnowledgeNode {
            KnowledgeNode(sourceSpanIDs: [span.id], kind: kind, parentID: parent, relation: parent == nil ? .root : .child,
                          position: CanvasPoint(x: 800, y: 800), positionIsAutomatic: false)
        }
        var root = node(.main)
        let branch = node(.branch, parent: root.id)
        var hiddenEvidence = node(.evidence, parent: branch.id)
        let deep = node(.main, parent: hiddenEvidence.id)
        let thought = UserThought(text: "  我的合成思考\n“保持原样”。  ", attachedNodeID: deep.id, isSecondaryEdit: false, anchorTime: 12)
        let secondThought = UserThought(text: thought.text, attachedNodeID: deep.id, isSecondaryEdit: false, anchorTime: 15)
        var thoughtNode = node(.thought, parent: deep.id); thoughtNode.thoughtID = thought.id; thoughtNode.userEditedText = thought.text
        var secondThoughtNode = node(.thought, parent: deep.id); secondThoughtNode.thoughtID = secondThought.id; secondThoughtNode.userEditedText = secondThought.text
        let mark = ImportantMark(anchorSpanID: span.id, protectedSpanIDs: [span.id], anchorTime: 13)
        var markedNode = node(.evidence, parent: deep.id); markedNode.importantMarkID = mark.id
        var session = SessionRecord(title: "合成画布验收", sourceName: "合成", sourceKind: "test", speakers: [speaker], transcript: [span],
                                    nodes: [root, branch, hiddenEvidence, deep, thoughtNode, secondThoughtNode, markedNode], thoughts: [thought, secondThought], importantMarks: [mark])
        let overview = WorkspaceCanvasProjection.visibleNodes(in: session, showDetails: false)
        precondition(!overview.contains { $0.id == hiddenEvidence.id })
        precondition(overview.contains { $0.id == deep.id } && overview.contains { $0.id == thoughtNode.id } && overview.contains { $0.id == markedNode.id })
        precondition(WorkspaceCanvasProjection.visibleNodes(in: session, showDetails: true).count == 7)
        precondition(WorkspaceCanvasProjection.requiresDetails(for: hiddenEvidence.id, in: session))
        precondition(!WorkspaceCanvasProjection.requiresDetails(for: branch.id, in: session))
        root.isCollapsed = true; session.nodes[0] = root
        for details in [false, true] {
            let visible = WorkspaceCanvasProjection.visibleNodes(in: session, showDetails: details)
            precondition(Set(visible.map(\.id)) == Set([root.id, thoughtNode.id, secondThoughtNode.id]))
            precondition(visible.filter { $0.thoughtID != nil }.allSatisfy { $0.parentID == root.id }, "Collapsed methods never hide the user's thought text")
        }
        let foldedThoughts = WorkspaceCanvasProjection.thoughts(root, in: session)
        precondition(foldedThoughts.count == 2 && foldedThoughts.allSatisfy { $0.text == thought.text }, "Distinct same-text thoughts remain intact in the folded parent's source popover")
        precondition(WorkspaceCanvasProjection.markedNodes(root, in: session).map(\.id) == [markedNode.id])
        session.importantMarks = nil
        precondition(WorkspaceCanvasProjection.markedNodes(root, in: session).map(\.id) == [markedNode.id], "Legacy saved important nodes remain inspectable without a separate mark record")
        root.isCollapsed = false; session.nodes[0] = root
        hiddenEvidence.isCollapsed = true; session.nodes[2] = hiddenEvidence
        precondition(!WorkspaceCanvasProjection.visibleNodes(in: session, showDetails: false).contains { $0.id == deep.id }, "A filtered collapsed intermediate ancestor still hides deep descendants")
        precondition(WorkspaceCanvasProjection.visibleNodes(in: session, showDetails: true).contains { $0.id == thoughtNode.id })
        precondition(WorkspaceCanvasProjection.thoughts(hiddenEvidence, in: session).count == 2)
        // Screen-space delta is converted exactly once using frozen drag-start
        // zoom. Repeated events never use the previous moving position as origin.
        for zoom in [0.01, 0.2, 0.49, 0.5, 0.92, 1.0, 1.5] {
            let drag = WorkspaceDragSession(origin: CanvasPoint(x: 10_000, y: 10_000), zoom: zoom)
            let start = CGPoint(x: 440, y: 330)
            for delta in [CGPoint(x: 30, y: 18), CGPoint(x: -20, y: -10), .zero] {
                let end = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
                let position = drag.position(start: start, current: end)
                precondition(abs((position.x - drag.origin.x) * zoom - delta.x) < 0.00001)
                precondition(abs((position.y - drag.origin.y) * zoom - delta.y) < 0.00001)
                for _ in 0..<100 { precondition(drag.position(start: start, current: end) == position) }
                let live = [branch.id: CGPoint(x: position.x, y: position.y)]
                let edgeIn = WorkspaceCanvasProjection.connection(parent: root, child: branch, live: live)
                let edgeOut = WorkspaceCanvasProjection.connection(parent: branch, child: deep, live: live)
                let card = WorkspaceCanvasProjection.position(branch, live: live)
                precondition(edgeIn.end == CGPoint(x: card.x - 145, y: card.y))
                precondition(edgeOut.start == CGPoint(x: card.x - 145, y: card.y), "An edge to a child on the left exits the parent's left side")
                precondition(edgeOut.end == CGPoint(x: deep.position.x + 145, y: deep.position.y))
                precondition(WorkspaceCanvasProjection.position(root, live: live) == CGPoint(x: root.position.x, y: root.position.y))
            }
        }
        var freshRoot = node(.main); freshRoot.positionIsAutomatic = true
        let freshBranches = (0..<7).map { _ in
            var item = node(.branch, parent: freshRoot.id); item.positionIsAutomatic = true; return item
        }
        let fresh = [freshRoot] + freshBranches
        let balanced = CanvasOverviewLayout.arrange(fresh)
        let tall = CanvasOverviewLayout.arrange(fresh, cardHeights: [freshBranches[0].id: 700])
        let tallNode = tall.first { $0.id == freshBranches[0].id }!
        for other in tall where other.id != tallNode.id && abs(other.position.x - tallNode.position.x) < 320 {
            precondition(abs(other.position.y - tallNode.position.y) >= 440, "Full thought text cannot overlap the next automatic card")
        }
        let center = balanced[0].position
        precondition(balanced.dropFirst().contains { $0.position.x < center.x })
        precondition(balanced.dropFirst().contains { $0.position.x > center.x })
        precondition(balanced.map { $0.position.y }.max()! - balanced.map { $0.position.y }.min()! <= 660)
        for (index, item) in balanced.enumerated() {
            for other in balanced.dropFirst(index + 1) where abs(item.position.x - other.position.x) < 320 {
                precondition(abs(item.position.y - other.position.y) >= 220, "Fresh cards cannot overlap within a column")
            }
        }
        precondition(fresh.allSatisfy { $0.position == CanvasPoint(x: 800, y: 800) }, "Display layout does not mutate input positions")
        var frozen = balanced
        for index in frozen.indices { frozen[index].positionIsAutomatic = false }
        frozen[1].position = CanvasPoint(x: 1300, y: 900)
        precondition(CanvasOverviewLayout.arrange(frozen).map(\.position) == frozen.map(\.position), "A saved drag must not trigger rebalancing")
        var title = WorkspaceTitleDraft()
        let oldID = UUID(), newID = UUID()
        title.load(sessionID: oldID, title: "原记录")
        precondition(title.takeChange() == nil)
        title.text = "失焦前编辑的旧记录标题"
        let oldChange = title.takeChange()!
        precondition(oldChange.sessionID == oldID && oldChange.text == title.text)
        precondition(title.takeChange() == nil, "Blur, close and disappear must not resubmit an unchanged draft")
        title.load(sessionID: newID, title: "新记录")
        precondition(title.takeChange() == nil && title.text == "新记录")
        title.text = "新记录自己的标题"
        precondition(title.takeChange()?.sessionID == newID, "The old record's draft cannot be written to the newly selected record")
        for screen in [CGSize(width: 1600, height: 1000), CGSize(width: 1024, height: 600), CGSize(width: 320, height: 480)] {
            let fitted = WorkspacePopoverLayout.fittedSize(available: screen)
            precondition(fitted.width <= screen.width - 48 && fitted.height <= screen.height - 80)
            precondition(fitted.width <= 440 && fitted.height <= 560)
        }
        print("PASS: seven zoom levels, fixed-origin repeatability, both incident edges share live position; deep folding and hidden detail targets; thought text/identity and legacy marks; record-bound title drafts; small-screen popover bounds.")
        print("Scope: production view-helper logic plus SwiftUI compilation, NOT actual mouse/popover/UI acceptance. No app, model or database opened.")
    }
}

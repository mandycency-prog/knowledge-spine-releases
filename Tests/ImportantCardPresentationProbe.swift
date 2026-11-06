import Foundation
import KnowledgeSpineCore

@main struct ImportantCardPresentationProbe {
    @MainActor static func main() throws {
        let speaker = Speaker(role: .host)
        let span = TranscriptSpan(sequence: 1, startTime: 0, endTime: 10, speakerID: speaker.id, originalText: "合成原始证据，不用它冒充已经生成的重点概括。")
        let summary = "先通过具体问题确定学习目标，再用练习和反馈验证理解是否能迁移。\n• 先说清楚自己需要解决什么问题，不盲目堆积材料。\n• 选一个足够小的练习，用实际结果发现理解中的缺口。\n• 根据反馈调整方法，再把同样的方法用于新的问题。"
        precondition(summary.count <= 160)
        var root = KnowledgeNode(sourceSpanIDs: [span.id], kind: .main, relation: .root, position: CanvasPoint(x: 0, y: 0), positionIsAutomatic: true, aiSummary: "确定目标，练习反馈。")
        root.navigationLabel = "合成主题"; root.sourceBoundStatus = "summarized"
        let branchSummary = "把学习目标转成一个具体的小练习，先独立完成，再检查哪里出错；根据反馈补足理解，最后换一个新问题检验能否独立运用。"
        var branch = KnowledgeNode(sourceSpanIDs: [span.id], kind: .branch, parentID: root.id, relation: .child,
            position: CanvasPoint(x: 0, y: 0), positionIsAutomatic: true, aiSummary: branchSummary)
        branch.sourceBoundStatus = "summarized"
        var mark = KnowledgeNode(sourceSpanIDs: [span.id], kind: .evidence, parentID: branch.id, relation: .child,
            position: CanvasPoint(x: 0, y: 0), positionIsAutomatic: true, userLabel: "重点", importantMarkID: UUID(), aiSummary: summary)
        let rawEdit = "  我 的原文，\n還要保留。  "
        mark.isSecondaryEdit = true; mark.userEditedText = rawEdit
        for custom in [true, false] {
            let body = NodeCardBodyContent.resolve(node: mark, transcript: [span], hasCustomLabel: custom)
            precondition(body.text == summary && body.isAISummary && body.text.contains("• 根据反馈"))
            precondition(NodeCardBodyContent.lineLimit(mark, hasCustomLabel: custom) == nil)
            precondition(NodeCardBodyContent.lineLimit(branch, hasCustomLabel: custom) == nil)
            precondition(NodeCardBodyContent.lineLimit(root, hasCustomLabel: custom) == 2)
        }
        var missing = mark; missing.id = UUID(); missing.aiSummary = " \n "; missing.isSecondaryEdit = false
        let pending = NodeCardBodyContent.resolve(node: missing, transcript: [span], hasCustomLabel: false)
        precondition(pending.text == "重点概括待生成" && !pending.isAISummary)
        var session = SessionRecord(title: "合成重点卡片验收", sourceName: "test", sourceKind: "test", speakers: [speaker], transcript: [span], nodes: [root, branch, mark, missing])
        precondition(WorkspaceCanvasProjection.cardHeight(mark, in: session) > 250)
        precondition(WorkspaceCanvasProjection.cardHeight(branch, in: session) > 180)
        let suppliedHeights: [UUID: Double] = [root.id: 180, branch.id: 320, mark.id: 510, missing.id: 220]
        let arranged = WorkspaceCanvasProjection.visibleNodes(in: session, showDetails: true, measuredCardHeights: suppliedHeights)
        for (index, node) in arranged.enumerated() {
            for other in arranged.dropFirst(index + 1) where abs(node.position.x - other.position.x) < 320 {
                precondition(abs(node.position.y - other.position.y) >= (suppliedHeights[node.id]! + suppliedHeights[other.id]!) / 2 + 39.5,
                             "Actual measured multiline card heights must reserve nonoverlapping rows")
            }
        }
        let thought = UserThought(text: String(repeating: rawEdit, count: 8), isSecondaryEdit: false)
        var thoughtNode = mark; thoughtNode.id = UUID(); thoughtNode.kind = .thought; thoughtNode.thoughtID = thought.id
        thoughtNode.importantMarkID = nil; thoughtNode.userEditedText = thought.text
        session.thoughts = [thought]; session.nodes.append(thoughtNode)
        precondition(NodeCardBodyContent.lineLimit(thoughtNode, hasCustomLabel: true) == nil)
        precondition(WorkspaceCanvasProjection.thoughtCardHeight(thoughtNode, in: session) > 300)
        let exported = ExportService.makeKnowledgeMarkdown(session: session, speakerName: { _ in "讲师" })
        precondition(exported.contains(summary) && exported.contains(branchSummary))
        precondition(exported.contains("重点概括待生成") && exported.contains(rawEdit) && exported.contains(thought.text))
        precondition(exported.contains(span.simplifiedOriginalText), "Pending summary status does not remove the separately labelled source evidence")
        precondition(mark.userEditedText == rawEdit && span.originalText == session.transcript[0].originalText)
        print("PASS: important cards show complete multiline summary or explicit pending status; summarized branches/thoughts are untruncated; measured heights reserve full rows; export retains summary, raw edit and thought text.")
        print("Scope: pure view-helper/layout/export checks plus SwiftUI compilation. Native rendering, dragging and model quality are not tested; no app or formal data opened.")
    }
}

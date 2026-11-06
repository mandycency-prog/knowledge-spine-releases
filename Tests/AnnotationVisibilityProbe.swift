import Foundation
import KnowledgeSpineCore

@main struct AnnotationVisibilityProbe {
    static func main() throws {
        var session = SessionRecord(title: "合成展示验收", sourceName: "合成", sourceKind: "test")
        precondition(TranscriptAnnotationViewContent.showsEmptyState(session))
        let verbatim = "  我的原话\n“这一句不能改”。  "
        let thought = UserThought(text: verbatim, isSecondaryEdit: false, anchorTime: 12)
        session.thoughts = [thought]
        precondition(!TranscriptAnnotationViewContent.showsEmptyState(session))
        precondition(session.thoughts[0].text == verbatim)
        session.thoughts[0].isDeleted = true
        precondition(TranscriptAnnotationViewContent.showsEmptyState(session))
        let mark = ImportantMark(anchorSpanID: UUID(), protectedSpanIDs: [], anchorTime: 62)
        session.importantMarks = [mark]
        precondition(!TranscriptAnnotationViewContent.showsEmptyState(session))
        let pending = TranscriptAnnotationViewContent.pendingMarks(session)
        precondition(pending.count == 1 && pending[0].text.contains("01:02") && pending[0].text.contains("等待对应原话"))
        session.pendingImportantTimes = [62, 90]
        precondition(TranscriptAnnotationViewContent.pendingMarks(session).count == 2, "Do not duplicate a legacy pending time already represented by a mark")
        session.importantMarks = []
        precondition(!TranscriptAnnotationViewContent.showsEmptyState(session))
        session.pendingImportantTimes = []
        let speaker = Speaker(role: .host)
        let span = TranscriptSpan(sequence: 1, startTime: 60, endTime: 70, speakerID: speaker.id, originalText: "讲师的原话。", isImportant: true)
        session.transcript = [span]
        session.importantMarks = [ImportantMark(anchorSpanID: span.id, protectedSpanIDs: [span.id], anchorTime: 62)]
        precondition(TranscriptAnnotationViewContent.pendingMarks(session).isEmpty)
        var node = KnowledgeNode(sourceSpanIDs: [span.id], kind: .evidence, relation: .root, position: CanvasPoint(x: 0, y: 0),
                                 userLabel: "我改的重点标题", importantMarkID: session.importantMarks![0].id, aiSummary: "模型概括。")
        let renamedSummary = NodeCardBodyContent.resolve(node: node, transcript: [span], hasCustomLabel: true)
        precondition(renamedSummary.isAISummary && renamedSummary.text == "模型概括。")
        node.isSecondaryEdit = true; node.userEditedText = verbatim
        let authored = NodeCardBodyContent.resolve(node: node, transcript: [span], hasCustomLabel: true)
        precondition(authored.isAISummary && authored.text == "模型概括。" && node.userEditedText == verbatim,
                     "Important summary remains primary; the separate authored-text view keeps human edits verbatim")
        node.kind = .thought; node.isSecondaryEdit = false; node.thoughtID = thought.id
        let titledThought = NodeCardBodyContent.resolve(node: node, transcript: [], hasCustomLabel: true)
        precondition(!titledThought.isAISummary && titledThought.text == verbatim)
        let thoughtSummary = NodeCardBodyContent.resolve(node: node, transcript: [], hasCustomLabel: false)
        precondition(thoughtSummary.isAISummary && thoughtSummary.text == "模型概括。")
        node.kind = .evidence; node.thoughtID = nil; node.userEditedText = nil; node.aiSummary = "   "
        let original = NodeCardBodyContent.resolve(node: node, transcript: [span], hasCustomLabel: true)
        precondition(!original.isAISummary && original.text == "重点概括待生成")
        print("PASS: empty-transcript thoughts and pending marks remain displayable; pending status invents no quote; AI labels follow displayed summary, not user wording.")
        print("Scope: production presentation-helper regression only. Native SwiftUI rendering/interaction NOT tested; no database/model/app was opened.")
    }
}

import Foundation
import KnowledgeSpineCore

@main struct MergeSelectionProbe {
    @MainActor static func main() throws {
        let speaker = Speaker(role: .host)
        let spans = (0..<123).map { index in
            TranscriptSpan(sequence: index + 1, startTime: Double(index), endTime: Double(index + 1), speakerID: speaker.id, originalText: "合成验收原句 \(index + 1)，不是人工拟定的主题。")
        }
        var nodes = spans.map { KnowledgeNode(sourceSpanIDs: [$0.id], kind: .main, relation: .root, position: CanvasPoint(x: 200, y: 200)) }
        for index in 1..<nodes.count { nodes[index].parentID = nodes[0].id; nodes[index].relation = .child }
        var lesson = SessionRecord(title: "合成旧课程", sourceName: "test", sourceKind: "test", speakers: [speaker], transcript: spans, nodes: nodes)
        let original = lesson
        precondition(MergeCourseProjection.topicPreview(lesson).isEmpty, "Legacy 123 sentences must not masquerade as topics")
        for index in 0..<11 { precondition(MergeCourseProjection.page(lesson, index: index).count <= 12) }
        precondition(MergeCourseProjection.page(lesson, index: 10).count == 3)
        precondition(Set((0..<11).flatMap { MergeCourseProjection.page(lesson, index: $0).map(\.id) }) == Set(nodes.map(\.id)), "Pagination loses no selection target")

        var selection = MergeCourseSelection()
        selection.toggleWhole(lesson)
        precondition(selection.wholeSessionIDs == [lesson.id] && selection.topicNodeIDs.isEmpty)
        selection.toggleTopic(nodes[1].id, in: lesson)
        precondition(selection.wholeSessionIDs.isEmpty && selection.topicNodeIDs == [nodes[1].id], "Choosing a topic explicitly narrows whole-course selection")
        selection.toggleTopic(nodes[0].id, in: lesson)
        precondition(selection.topicNodeIDs.count == 123, "A root includes all descendants, not only displayed preview rows")
        selection.toggleTopic(nodes[0].id, in: lesson)
        precondition(selection.topicNodeIDs.isEmpty)

        for index in 0..<10 { lesson.nodes[index].aiSummary = "已有模型概括 \(index + 1)" }
        precondition(MergeCourseProjection.topicPreview(lesson).count == 6)
        lesson.nodes[1].kind = .thought
        lesson.nodes[2].importantMarkID = UUID()
        precondition(MergeCourseProjection.topicPreview(lesson).allSatisfy { $0.kind != .thought && $0.importantMarkID == nil }, "Annotations do not become course topics")
        lesson.nodes[3].parentID = lesson.nodes[4].id
        lesson.nodes[4].parentID = lesson.nodes[3].id
        precondition(MergeCourseProjection.subtree(lesson.nodes[3].id, in: lesson) == [lesson.nodes[3].id, lesson.nodes[4].id], "Malformed parent cycles terminate safely")
        lesson.nodes[4].isDeleted = true
        precondition(MergeCourseProjection.subtree(lesson.nodes[3].id, in: lesson) == [lesson.nodes[3].id])

        var second = original; second.id = UUID(); second.nodes = [KnowledgeNode(sourceSpanIDs: [spans[0].id], kind: .main, relation: .root, position: CanvasPoint(x: 200, y: 200))]
        selection.toggleWhole(original)
        selection.toggleTopic(second.nodes[0].id, in: second)
        let scope = selection.scope(in: [original, second])
        precondition(scope.whole == [original.id] && scope.topics == [second.nodes[0].id])
        precondition(selection.selectedCourseCount(in: [original, second]) == 2)
        precondition(selection.scope(in: [original]).topics.isEmpty, "Deleted courses cannot leak stale IDs into a request")
        precondition(original.nodes == nodes && original.transcript == spans, "Selection never mutates source content")
        print("PASS: legacy 123 sentences produce zero fake topics; previews <=6, pages <=12 with complete access; subtree expansion, whole/partial scope, stale/deleted IDs, cycles, source preservation.")
        print("Scope: production UI helper tests + SwiftUI compilation only. No model, App, formal database or actual UI interaction used.")
    }
}

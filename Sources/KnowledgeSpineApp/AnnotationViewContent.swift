import Foundation
import KnowledgeSpineCore

/// Shared by SwiftUI and the non-interactive presentation regression probe.
/// Pending marks describe user intent only; they never manufacture a quote.
enum TranscriptAnnotationViewContent {
    typealias PendingMark = AnnotationPresentation.PendingMark

    static func showsEmptyState(_ session: SessionRecord) -> Bool {
        session.transcript.isEmpty && !session.thoughts.contains { !$0.isDeleted } &&
        (session.importantMarks ?? []).isEmpty && (session.pendingImportantTimes ?? []).isEmpty
    }

    static func pendingMarks(_ session: SessionRecord) -> [PendingMark] {
        AnnotationPresentation.pendingMarks(session)
    }

    /// One unobtrusive status per reading paragraph, not a card per ASR unit.
    static func proofreadingLabel(_ spans: [TranscriptSpan]) -> String? {
        let corrected = spans.contains(where: \.hasAutomaticCorrection)
        let uncertain = spans.contains { !$0.validProofreadUncertainties.isEmpty }
        if uncertain { return corrected ? "AI 校订 · 有待确认处" : "有待确认处" }
        return corrected ? "AI 校订" : nil
    }
}

struct NodeCardBodyContent {
    let text: String
    let isAISummary: Bool

    static func resolve(node: KnowledgeNode, transcript: [TranscriptSpan], hasCustomLabel: Bool) -> Self {
        if node.importantMarkID != nil && node.thoughtID == nil && node.kind != .thought {
            if let summary = node.aiSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Self(text: summary.simplifiedChineseForDisplay, isAISummary: true)
            }
            return Self(text: "重点概括待生成", isAISummary: false)
        }
        // The titled layout uses visibleText, which prioritizes authored text.
        // The ordinary layout deliberately shows a separate AI précis when one
        // exists. Label the text actually displayed, not merely a stored field.
        let authoredBody = hasCustomLabel && (node.isSecondaryEdit || node.kind == .thought)
        if !authoredBody, let summary = node.aiSummary,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self(text: summary.simplifiedChineseForDisplay, isAISummary: true)
        }
        return Self(text: IntegrityValidator.visibleText(for: node, transcript: transcript), isAISummary: false)
    }

    static func expandsBody(_ node: KnowledgeNode) -> Bool {
        node.importantMarkID != nil || node.thoughtID != nil || node.kind == .thought ||
            (node.kind == .branch && node.sourceBoundStatus == "summarized")
    }

    static func lineLimit(_ node: KnowledgeNode, hasCustomLabel: Bool) -> Int? {
        if expandsBody(node) { return nil }
        return hasCustomLabel || node.sourceBoundStatus == "summarized" || node.isCollapsed ? 2 : 5
    }
}

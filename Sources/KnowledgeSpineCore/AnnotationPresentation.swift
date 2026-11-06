import Foundation

/// Both explicit attachments and automatically placed thought nodes refer to
/// the same immutable user text. Resolve by ID, never by matching the text.
public enum AnnotationPresentation {
    public struct PendingMark: Identifiable, Sendable {
        public let id: String
        public let anchorTime: TimeInterval?
        public var text: String {
            let location = anchorTime.map { value in
                let seconds = max(0, Int(value))
                return String(format: "%02d:%02d", seconds / 60, seconds % 60)
            } ?? "时间待定位"
            return "我的重点 · \(location) · 标记已保存，等待对应原话。"
        }
    }

    public static func pendingMarks(_ session: SessionRecord) -> [PendingMark] {
        let sourceIDs = Set(session.transcript.map(\.id))
        let marks = session.importantMarks ?? []
        let unresolved = marks.filter {
            !sourceIDs.contains($0.anchorSpanID) || Set($0.protectedSpanIDs).isDisjoint(with: sourceIDs)
        }.map { PendingMark(id: $0.id.uuidString, anchorTime: $0.anchorTime) }
        let legacy = (session.pendingImportantTimes ?? []).enumerated().filter { _, time in
            !marks.contains { $0.anchorTime == time }
        }.map { index, time in PendingMark(id: "pending-time-\(index)", anchorTime: time) }
        return unresolved + legacy
    }

    public struct Excerpt: Identifiable, Sendable {
        public var id: UUID { spans[0].id }
        public let spans: [TranscriptSpan]
        public var originalText: String { spans.map(\.simplifiedOriginalText).joined() }
        public var correctedText: String? {
            guard spans.contains(where: { $0.correctedText?.isEmpty == false && $0.correctedText != $0.originalText }) else { return nil }
            return spans.map(\.displayedText).joined()
        }
        public var isImportant: Bool { spans.contains(where: \.isImportant) }
    }

    /// Recognition units are an internal index, not manuscript paragraphs.
    /// Join adjacent quotes, but never pretend omitted source is continuous.
    public static func excerpts(_ sources: [TranscriptSpan]) -> [Excerpt] {
        var groups: [[TranscriptSpan]] = []
        for span in sources.sorted(by: { $0.sequence < $1.sequence }) {
            if let last = groups.last?.last, last.sequence + 1 == span.sequence,
               last.speakerID == span.speakerID, last.origin?.sessionID == span.origin?.sessionID,
               span.startTime - last.endTime <= 12 {
                groups[groups.count - 1].append(span)
            } else { groups.append([span]) }
        }
        return groups.map { Excerpt(spans: $0) }
    }

    public static func thoughts(for node: KnowledgeNode, in session: SessionRecord) -> [UserThought] {
        let linkedIDs = Set(session.nodes.filter {
            !$0.isDeleted && $0.parentID == node.id
        }.compactMap(\.thoughtID))
        return session.thoughts.filter {
            !$0.isDeleted && ($0.id == node.thoughtID || $0.attachedNodeID == node.id || linkedIDs.contains($0.id))
        }
    }
}

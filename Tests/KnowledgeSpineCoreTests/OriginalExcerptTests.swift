import Foundation

/// Standalone isolated Core probe, compiled with Sources/KnowledgeSpineCore/*.swift.
/// Does not load the app, a database, audio, or a model.
@main enum OriginalExcerptTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func main() throws {
        var checks = 0
        func accepts(_ name: String, _ action: () throws -> Void) throws {
            do { try action() } catch { throw Failure(description: "\(name): unexpectedly rejected: \(error)") }
            checks += 1
        }
        func rejects(_ name: String, _ action: () throws -> Void) throws {
            do { try action() } catch is IntegrityViolation { checks += 1; return }
            catch { throw Failure(description: "\(name): wrong error: \(error)") }
            throw Failure(description: "\(name): unexpectedly accepted")
        }
        let speaker = Speaker(role: .host)
        func span(_ text: String, _ sequence: Int = 1) -> TranscriptSpan {
            TranscriptSpan(sequence: sequence, startTime: Double(sequence * 10), endTime: Double(sequence * 10 + 9),
                           speakerID: speaker.id, originalText: text)
        }
        func excerpt(_ text: String, _ source: TranscriptSpan, start: Int = 0, end: Int? = nil) -> OriginalExcerpt {
            OriginalExcerpt(text: text, parts: [OriginalExcerptPart(sourceID: source.id, startOffset: start,
                endOffset: end ?? source.originalText.unicodeScalars.count)], origin: source.origin, time: nil)
        }
        func candidate(_ quotes: [OriginalExcerpt], _ sources: [TranscriptSpan]) -> StructureCandidate {
            var value = StructureCandidate(sourceSpanIDs: sources.map(\.id), kind: .main, relation: .root,
                                           confidence: 1, summary: quotes.map(\.text).joined(separator: "\n\n"))
            value.sourceBoundStatus = "extracted"; value.coreOriginals = quotes
            return value
        }
        func node(_ value: StructureCandidate) -> KnowledgeNode {
            var result = KnowledgeNode(sourceSpanIDs: value.sourceSpanIDs, kind: .main, relation: .root,
                                       position: CanvasPoint(x: 0, y: 0), aiSummary: value.summary)
            result.sourceBoundStatus = value.sourceBoundStatus; result.coreOriginals = value.coreOriginals
            result.conditionOriginals = value.conditionOriginals
            return result
        }
        let unicode = span("甲👩🏽‍💻e\u{301}乙。")
        let quote = excerpt("👩🏽‍💻e\u{301}", unicode, start: 1, end: 7)
        let good = candidate([quote], [unicode])
        try accepts("Unicode scalar offsets, not grapheme indexes") { try IntegrityValidator.validate(candidates: [good], transcript: [unicode]) }
        try accepts("stored uses identical quote gate") { try IntegrityValidator.validateStoredNode(node(good), transcript: [unicode]) }

        var forged = good
        forged.coreOriginals![0].text = "甲没有说过这句话。"
        forged.summary = forged.coreOriginals![0].text
        try rejects("candidate forged words") { try IntegrityValidator.validate(candidates: [forged], transcript: [unicode]) }
        try rejects("stored forged words") { try IntegrityValidator.validateStoredNode(node(forged), transcript: [unicode]) }
        for bounds in [(-1, 2), (1, 1), (2, 1), (0, Int.max)] {
            var value = good
            value.coreOriginals![0].parts[0].startOffset = bounds.0
            value.coreOriginals![0].parts[0].endOffset = bounds.1
            try rejects("invalid scalar range \(bounds)") { try IntegrityValidator.validate(candidates: [value], transcript: [unicode]) }
        }
        var unknown = good
        unknown.coreOriginals![0].parts[0].sourceID = UUID()
        try rejects("unknown source") { try IntegrityValidator.validateStoredNode(node(unknown), transcript: [unicode]) }
        let unrelated = span("旁证不等于节点选择的来源。", 2)
        var outside = good
        outside.coreOriginals = [excerpt(unrelated.originalText, unrelated)]; outside.summary = unrelated.originalText
        try rejects("known but outside node sources") { try IntegrityValidator.validate(candidates: [outside], transcript: [unicode, unrelated]) }
        var missing = good; missing.coreOriginals = []
        try rejects("extracted requires core") { try IntegrityValidator.validateStoredNode(node(missing), transcript: [unicode]) }
        var wrongSummary = good; wrongSummary.summary = "另一个摘要"
        try rejects("untouched extracted summary must match") { try IntegrityValidator.validateStoredNode(node(wrongSummary), transcript: [unicode]) }

        let original = span("只在实验阶段使用。")
        var corrected = original; corrected.correctedText = "绝不在生产阶段使用。"
        let originalNode = node(candidate([excerpt(original.originalText, original)], [original]))
        try rejects("new correction cannot reuse old offsets") { try IntegrityValidator.validateStoredNode(originalNode, transcript: [corrected]) }
        var archivedNode = originalNode; archivedNode.archivedSourceSpans = [original]
        try accepts("same-ID archive takes precedence over corrected current text") { try IntegrityValidator.validateStoredNode(archivedNode, transcript: [corrected]) }
        let replacement = span("重新识别后已经更换来源编号。")
        archivedNode.sourceSpanIDs = [replacement.id]
        try accepts("historical quote ID can differ from current timeline ID") { try IntegrityValidator.validateStoredNode(archivedNode, transcript: [replacement]) }
        let second = span("第二个完整原句。", 2)
        var partial = node(candidate([excerpt(original.originalText, original), excerpt(second.originalText, second)], [original, second]))
        partial.archivedSourceSpans = [original]
        try accepts("partial archive supplements current sources") { try IntegrityValidator.validateStoredNode(partial, transcript: [corrected, second]) }
        partial.archivedSourceSpans = [original, original]
        try rejects("duplicate archive IDs do not crash or choose arbitrary words") { try IntegrityValidator.validateStoredNode(partial, transcript: [corrected, second]) }

        var authored = node(wrongSummary); authored.isSecondaryEdit = true; authored.userEditedText = "用户另外写的话。"
        try accepts("authored body may differ, genuine attached quote remains") { try IntegrityValidator.validateStoredNode(authored, transcript: [unicode]) }
        authored.coreOriginals = forged.coreOriginals
        try rejects("authored status cannot launder a forged quote") { try IntegrityValidator.validateStoredNode(authored, transcript: [unicode]) }
        var unclassified = forged; unclassified.sourceBoundStatus = nil
        try rejects("missing status cannot launder candidate quotes") { try IntegrityValidator.validate(candidates: [unclassified], transcript: [unicode]) }
        var badCondition = good; badCondition.conditionOriginals = forged.coreOriginals
        try rejects("conditions must also be genuine quotes") { try IntegrityValidator.validateStoredNode(node(badCondition), transcript: [unicode]) }

        let denial = span("可以，不可以。")
        let splice = OriginalExcerpt(text: "可以，可以。", parts: [
            OriginalExcerptPart(sourceID: denial.id, startOffset: 0, endOffset: 3),
            OriginalExcerptPart(sourceID: denial.id, startOffset: 4, endOffset: 7)], origin: nil, time: nil)
        try rejects("cannot splice out a negation inside one span") { try IntegrityValidator.validate(candidates: [candidate([splice], [denial])], transcript: [denial]) }
        let first = span("如果符合条件，", 1), next = span("才可以使用。", 2)
        let continuous = OriginalExcerpt(text: first.originalText + next.originalText, parts: [
            OriginalExcerptPart(sourceID: first.id, startOffset: 0, endOffset: first.originalText.unicodeScalars.count),
            OriginalExcerptPart(sourceID: next.id, startOffset: 0, endOffset: next.originalText.unicodeScalars.count)], origin: nil, time: nil)
        try accepts("continuous multi-span quote") { try IntegrityValidator.validate(candidates: [candidate([continuous], [first, next])], transcript: [first, next]) }
        var gap = next; gap.sequence = 3
        try rejects("cannot join across a filtered sequence gap") { try IntegrityValidator.validate(candidates: [candidate([continuous], [first, gap])], transcript: [first, gap]) }
        var otherCourse = next
        otherCourse.origin = SourceReference(sessionID: UUID(), sessionTitle: "另一课程", itemID: UUID())
        try rejects("cannot join different courses") { try IntegrityValidator.validate(candidates: [candidate([continuous], [first, otherCourse])], transcript: [first, otherCourse]) }
        var attributed = original
        attributed.origin = SourceReference(sessionID: UUID(), sessionTitle: "实际课程", itemID: UUID(), startTime: 31)
        let originQuote = excerpt(attributed.originalText, attributed)
        try accepts("actual source origin") { try IntegrityValidator.validate(candidates: [candidate([originQuote], [attributed])], transcript: [attributed]) }
        var wrongOrigin = originQuote; wrongOrigin.origin!.itemID = UUID()
        try rejects("cannot point a quote at another source item") { try IntegrityValidator.validateStoredNode(node(candidate([wrongOrigin], [attributed])), transcript: [attributed]) }
        var falseOrigin = excerpt(original.originalText, original); falseOrigin.origin = attributed.origin
        try rejects("cannot invent origin where source has none") { try IntegrityValidator.validate(candidates: [candidate([falseOrigin], [original])], transcript: [original]) }
        for time in [[Double.nan, 2], [3, 2], [-1, 2], [1]] {
            var invalidTime = originQuote; invalidTime.time = time
            try rejects("invalid quote time") { try IntegrityValidator.validateStoredNode(node(candidate([invalidTime], [attributed])), transcript: [attributed]) }
        }
        print("PASS: \(checks) independent OriginalExcerpt checks; exact Unicode text, source scope, archives, conditions, continuity and provenance. No model or formal data used.")
    }
}

import Foundation
import KnowledgeSpineCore

@main struct ProofreadingPresentationProbe {
    static func main() throws {
        let speaker = Speaker(role: .host, displayName: "合成讲师")
        let raw = "這個複利的力息會繼續產生收益"
        var span = TranscriptSpan(sequence: 1, startTime: 12, endTime: 18, speakerID: speaker.id,
                                  originalText: raw, isImportant: true, punctuatedText: raw + "。",
                                  proofreadText: "这个复利的利息会继续产生收益。", proofreadBasis: raw,
                                  proofreadUncertainties: ["  专有名称待确认  ", ""], proofreadingVersion: "synthetic-v1")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let before = span
        precondition(span.displayedText == "这个复利的利息会继续产生收益。")
        precondition(span.hasAutomaticCorrection && !span.hasManualCorrection)
        precondition(span.validProofreadUncertainties == ["专有名称待确认"])
        precondition(span.originalText == raw && span.simplifiedOriginalText == "这个复利的力息会继续产生收益。")
        precondition(TranscriptAnnotationViewContent.proofreadingLabel([span]) == "AI 校订 · 有待确认处")
        let decoded = try decoder.decode(TranscriptSpan.self, from: encoder.encode(span))
        precondition(decoded == span)

        // Legacy JSON genuinely lacks every new key; synthesized optional decoding stays compatible.
        var legacyObject = try JSONSerialization.jsonObject(with: encoder.encode(span)) as! [String: Any]
        for key in ["proofreadText", "proofreadBasis", "proofreadUncertainties", "proofreadingVersion", "proofreadPunctuatedText"] { legacyObject.removeValue(forKey: key) }
        let legacy = try decoder.decode(TranscriptSpan.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        precondition(legacy.proofreadText == nil && legacy.proofreadBasis == nil && legacy.proofreadUncertainties == nil && legacy.proofreadingVersion == nil)
        precondition(legacy.proofreadPunctuatedText == nil)
        precondition(legacy.displayedText == legacy.simplifiedOriginalText)

        span.correctedText = "我的人工修正优先。"
        precondition(span.displayedText == "我的人工修正优先。" && !span.hasAutomaticCorrection)
        precondition(span.validProofreadUncertainties.isEmpty && TranscriptAnnotationViewContent.proofreadingLabel([span]) == nil)
        span.correctedText = "   "
        precondition(span.displayedText == before.displayedText && span.hasAutomaticCorrection)
        span = before; span.originalText += "新"
        precondition(span.validProofreadText == nil && !span.hasAutomaticCorrection && span.validProofreadUncertainties.isEmpty)
        precondition(span.displayedText == span.simplifiedOriginalText)
        span = before; span.proofreadBasis = nil
        precondition(span.validProofreadText == nil)
        span = before; span.proofreadText = " \n "
        precondition(span.validProofreadText == nil)
        span = before; span.originalText = "é"; span.proofreadBasis = "e\u{301}"
        precondition(span.validProofreadText == nil, "Basis binding is exact UTF-8, not merely Unicode-equivalent")
        span = before
        span.origin = SourceReference(sessionID: UUID(), sessionTitle: "用户笔记", itemID: UUID(), authoredByUser: true)
        precondition(span.validProofreadText == nil && !span.hasAutomaticCorrection && span.validProofreadUncertainties.isEmpty)
        precondition(span.displayedText == span.originalText, "User-authored text bypasses simplification and acoustic punctuation too")

        // Map and excerpt source validation still use saved evidence, never AI reading text.
        let node = KnowledgeNode(sourceSpanIDs: [before.id], kind: .main, relation: .root, position: CanvasPoint(x: 0, y: 0))
        precondition(IntegrityValidator.originalSourceText(for: node, transcript: [before]) == raw)
        precondition(IntegrityValidator.visibleText(for: node, transcript: [before]) == before.simplifiedOriginalText)
        let rawExcerpt = OriginalExcerpt(text: raw, parts: [.init(sourceID: before.id, startOffset: 0, endOffset: raw.count)])
        try IntegrityValidator.validateExcerpts([rawExcerpt], nodeID: node.id, sourceSpanIDs: [before.id], transcript: [before])
        let aiExcerpt = OriginalExcerpt(text: before.displayedText, parts: [.init(sourceID: before.id, startOffset: 0, endOffset: raw.count)])
        var refusedAI = false
        do { try IntegrityValidator.validateExcerpts([aiExcerpt], nodeID: node.id, sourceSpanIDs: [before.id], transcript: [before]) }
        catch { refusedAI = true }
        precondition(refusedAI, "AI reading text cannot impersonate original evidence")

        let thoughtText = "  我的思考：複利≠保證盈利！\n別替我改字。  "
        let thought = UserThought(text: thoughtText, isSecondaryEdit: false, anchorTime: 15)
        let session = SessionRecord(title: "合成校订验收", sourceName: "合成", sourceKind: "test", speakers: [speaker],
                                    transcript: [before], nodes: [node], thoughts: [thought])
        let rendered = ExportService.makeTranscript(session: session, speakerName: { _ in speaker.displayName })
        precondition(rendered.contains("【重点】" + before.displayedText))
        precondition(rendered.contains("AI 校订，不代表人工确认") && rendered.contains("待确认（00:12）"))
        precondition(rendered.contains("## 原始识别回查") && rendered.contains(raw) && rendered.contains(before.id.uuidString))
        precondition(rendered.contains(thoughtText), "User thoughts remain verbatim including whitespace and traditional characters")
        let map = ExportService.makeKnowledgeMarkdown(session: session, speakerName: { _ in speaker.displayName })
        precondition(map.contains(before.simplifiedOriginalText) && !map.contains(before.displayedText))
        precondition(session.transcript[0] == before && session.thoughts[0] == thought)
        var manualSession = session
        manualSession.transcript[0].correctedText = "人工确认的内容。"
        let manualExport = ExportService.makeTranscript(session: manualSession, speakerName: { _ in speaker.displayName })
        precondition(manualExport.contains("【重点】人工确认的内容。") && manualExport.contains("· 人工修正"))
        precondition(!manualExport.contains("AI 校订，不代表人工确认") && !manualExport.contains("专有名称待确认"))
        var unchanged = legacy
        unchanged.proofreadBasis = unchanged.originalText; unchanged.proofreadText = unchanged.originalText
        unchanged.proofreadUncertainties = ["数字待确认"]
        precondition(!unchanged.hasAutomaticCorrection && TranscriptAnnotationViewContent.proofreadingLabel([unchanged]) == "有待确认处")
        precondition(unchanged.displayedText == unchanged.simplifiedOriginalText, "An unchanged proofread result must preserve acoustic punctuation")
        var wordsOnly = before
        wordsOnly.proofreadText = "这个复利的利息会继续产生收益"
        precondition(wordsOnly.hasAutomaticCorrection && wordsOnly.displayedText == "这个复利的利息会继续产生收益。")
        wordsOnly.proofreadText = "这个复利的利息会继续产生收益？"
        precondition(wordsOnly.displayedText == "这个复利的利息会继续产生收益？", "Do not duplicate or replace AI's existing terminal punctuation")
        wordsOnly.correctedText = "我的修正没有末尾标点"
        precondition(wordsOnly.displayedText == "我的修正没有末尾标点" && !wordsOnly.hasAutomaticCorrection)
        wordsOnly.correctedText = nil; wordsOnly.proofreadText = "这个复利的利息会继续产生收益"
        wordsOnly.punctuatedText = "任意替换，不是合法声学标点。"
        precondition(wordsOnly.displayedText == "这个复利的利息会继续产生收益", "Unverified punctuation cannot leak into the reading layer")
        print("PASS: backward-compatible proofread fields, exact basis binding, manual priority, user-source exclusion, stale correction refusal, evidence immutability, excerpt rejection, paragraph labels, original-lookup export and verbatim thoughts.")
        print("PASS: unchanged/changed AI wording retains verified acoustic punctuation; unchanged raw is not labelled AI-corrected; existing terminal punctuation and manual wording remain untouched.")
        print("Scope: synthetic in-memory presentation/export tests only. No model, formal database, App or native UI interaction.")
    }
}

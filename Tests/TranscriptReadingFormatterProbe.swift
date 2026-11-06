import Foundation
import KnowledgeSpineCore

@main struct TranscriptReadingFormatterProbe {
    static func main() throws {
        let speaker = Speaker(role: .host)
        func span(_ text: String, _ sequence: Int, _ start: Double, _ end: Double) -> TranscriptSpan {
            TranscriptSpan(sequence: sequence, startTime: start, endTime: end, speakerID: speaker.id, originalText: text)
        }
        let messy = "这 是 AI 模型, ，，先 看 1,000 和 3.14，，。下一步"
        precondition(TranscriptReadingFormatter.normalized(messy) == "这是AI模型，先看1,000和3.14。下一步")
        precondition(TranscriptReadingFormatter.normalized("Open AI words, next https://example.com/a") == "Open AI words, next https://example.com/a")
        precondition(TranscriptReadingFormatter.normalized("真的！？！？") == "真的！？！？")
        var short = [span("这是", 1, 0, 0.3), span("一段", 2, 0.35, 0.6), span("完整的表达", 3, 0.65, 1.5)]
        for i in short.indices { short[i].punctuatedText = short[i].originalText + "。" }
        precondition(TranscriptReadingFormatter.text(for: short) == "这是一段完整的表达", "Small ASR units and the last unit do not imply a sentence boundary")
        var pauses = short
        pauses[1].startTime = 0.65; pauses[1].endTime = 1
        pauses[2].startTime = 2; pauses[2].endTime = 3
        precondition(TranscriptReadingFormatter.text(for: pauses) == "这是，一段。完整的表达")
        var punctuated = span("数字3.14先看证据再下结论", 1, 0, 2)
        punctuated.proofreadBasis = punctuated.originalText
        punctuated.proofreadText = punctuated.originalText
        punctuated.proofreadPunctuatedText = "数字3.14，先看证据，再下结论。"
        precondition(punctuated.validProofreadPunctuatedText != nil)
        precondition(punctuated.displayedText == "数字3.14，先看证据，再下结论。")
        let original = punctuated.originalText
        punctuated.proofreadPunctuatedText = "数字314，先看证据，再下结论。"
        precondition(punctuated.validProofreadPunctuatedText == nil, "A decimal point is not removable punctuation")
        punctuated.proofreadPunctuatedText = "数字3.14，别看证据，再下结论。"
        precondition(punctuated.validProofreadPunctuatedText == nil, "Word changes are not punctuation")
        punctuated.proofreadPunctuatedText = "数字3.14，先看证据，再下结论。"
        punctuated.proofreadText = "完全不同的校订稿"
        precondition(punctuated.validProofreadPunctuatedText == nil, "Punctuation is bound to the current validated proofreading text")
        precondition(punctuated.originalText == original && punctuated.simplifiedOriginalText == original)
        var intentional = pauses
        for i in intentional.indices {
            intentional[i].proofreadBasis = intentional[i].originalText
            intentional[i].proofreadText = intentional[i].originalText
            intentional[i].proofreadPunctuatedText = intentional[i].originalText
        }
        precondition(TranscriptReadingFormatter.text(for: intentional) == "这是一段完整的表达", "A validated model punctuation pass takes precedence even when it deliberately inserts no mark at a long pause")
        let verbatim = "  我  的 AI 想法, ，不改字。\n還有第二行  "
        var manual = short[0]; manual.correctedText = verbatim
        var authored = short[1]; authored.originalText = verbatim
        authored.origin = SourceReference(sessionID: UUID(), sessionTitle: "我的笔记", itemID: UUID(), authoredByUser: true)
        precondition(manual.displayedText == verbatim && authored.displayedText == verbatim)
        precondition(TranscriptReadingFormatter.fragments(for: [manual, authored]) == [verbatim, verbatim])
        let thought = UserThought(text: verbatim, isSecondaryEdit: false)
        let session = SessionRecord(title: "合成标点验收", sourceName: "test", sourceKind: "test", speakers: [speaker], transcript: short, thoughts: [thought])
        let exported = ExportService.makeTranscript(session: session, speakerName: { _ in "讲师" })
        precondition(exported.contains(TranscriptReadingFormatter.text(for: short)))
        precondition(!exported.contains("这是。一段。"))
        precondition(exported.contains(verbatim) && session.transcript == short)
        let decoded = try JSONDecoder().decode(TranscriptSpan.self, from: JSONEncoder().encode(intentional[0]))
        precondition(decoded.proofreadPunctuatedText == intentional[0].proofreadPunctuatedText)
        print("PASS: shared manuscript/export formatting; short-unit boundaries are not full stops; real pauses only; punctuation-only model binding rejects word/decimal changes; manual/user/thought text remains verbatim.")
        print("Scope: synthetic deterministic formatting and export only. No model, audio, formal database or native UI. Semantic sentence accuracy is not established by these rules.")
    }
}

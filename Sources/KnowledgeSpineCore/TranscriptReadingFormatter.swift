import Foundation

/// A display-only manuscript layer. It never writes recognition, citations or
/// authored text, and makes no claim to infer semantic sentence boundaries.
public enum TranscriptReadingFormatter {
    private static let punctuation = Set("，。！？；：、,.!?;:…")

    public static func isPunctuationOnlyRewrite(_ text: String, of basis: String) -> Bool {
        func content(_ value: String) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.filter {
                !"，。！？；：、".unicodeScalars.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
            }))
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && content(text).utf8.elementsEqual(content(basis).utf8)
    }

    /// Standalone display retains an already verified acoustic suffix. Full
    /// manuscripts use fragments so ASR unit boundaries never imply stops.
    public static func text(for span: TranscriptSpan) -> String {
        let body = baseText(for: span)
        guard !isAuthored(span), span.validProofreadPunctuatedText == nil,
              let last = body.last, !punctuation.contains(last),
              span.readableOriginal != span.originalText,
              let suffix = span.readableOriginal.last else { return body }
        return normalized(body + String(suffix))
    }

    /// One string per input span retains highlighting and precise source IDs.
    /// Only a real adjacent pause is used when text contains no punctuation.
    public static func fragments(for spans: [TranscriptSpan]) -> [String] {
        var result = spans.map(baseText)
        for index in spans.indices.dropLast() {
            let span = spans[index], next = spans[index + 1]
            guard !isAuthored(span), !isAuthored(next), span.validProofreadPunctuatedText == nil,
                  span.sequence < Int.max, next.sequence == span.sequence + 1,
                  span.speakerID == next.speakerID,
                  span.origin?.sessionID == next.origin?.sessionID,
                  let last = result[index].last, !punctuation.contains(last),
                  let first = result[index + 1].first, !punctuation.contains(first) else { continue }
            let gap = next.startTime - span.endTime
            guard gap.isFinite, gap >= 0 else { continue }
            if gap >= 0.8 { result[index] += "。" }
            else if gap >= 0.25 { result[index] += "，" }
            else if isLatinLetter(last) && isLatinLetter(first) { result[index] += " " }
        }
        return result
    }

    public static func text(for spans: [TranscriptSpan]) -> String { fragments(for: spans).joined() }

    private static func isAuthored(_ span: TranscriptSpan) -> Bool {
        span.hasManualCorrection || span.origin?.authoredByUser == true
    }

    private static func baseText(for span: TranscriptSpan) -> String {
        if span.hasManualCorrection { return span.correctedText! }
        if span.origin?.authoredByUser == true { return span.originalText }
        return normalized((span.validProofreadPunctuatedText ?? span.validProofreadText ?? span.originalText).simplifiedChineseForDisplay)
    }

    /// Conservative typography only: retain English word spacing, decimals,
    /// numeric separators, URLs and mixed !? punctuation. Never drop words.
    public static func normalized(_ text: String) -> String {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let hasChinese = chars.contains(where: isChinese)
        var result: [Character] = []
        for (index, original) in chars.enumerated() {
            if original.isWhitespace {
                let previous = result.last
                let next = chars.dropFirst(index + 1).first { !$0.isWhitespace }
                if let previous, let next, !previous.isWhitespace,
                   !isChinese(previous), !isChinese(next),
                   !"，。！？；：、".contains(previous), !punctuation.contains(next) {
                    result.append(" ")
                }
                continue
            }
            var char = original
            if hasChinese && char == "," {
                let before = index > 0 ? chars[index - 1] : nil
                let after = index + 1 < chars.count ? chars[index + 1] : nil
                if !(before?.isNumber == true && after?.isNumber == true) { char = "，" }
            }
            if let previous = result.last {
                if previous == char && "，。！？；：、,!?;:".contains(char) { continue }
                if previous == "，" && "。！？；：".contains(char) { result.removeLast() }
                else if "。！？；：".contains(previous) && char == "，" { continue }
            }
            result.append(char)
        }
        return String(result)
    }

    private static func isChinese(_ char: Character) -> Bool {
        char.unicodeScalars.contains { (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) }
    }

    private static func isLatinLetter(_ char: Character) -> Bool {
        char.unicodeScalars.count == 1 && char.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
    }
}

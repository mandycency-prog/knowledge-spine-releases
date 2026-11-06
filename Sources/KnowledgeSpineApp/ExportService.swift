import AppKit
import CoreText
import Foundation
import KnowledgeSpineCore
import ImageIO

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown = "Markdown"
    case pdf = "PDF"
    case both = "两者都要"

    var id: String { rawValue }
}

struct ExportOptions {
    var format: ExportFormat
    var includeTranscript: Bool
}

enum ExportService {
    static func export(
        session: SessionRecord,
        to directory: URL,
        options: ExportOptions,
        speakerName: (UUID) -> String,
        imageURL: ((ImageAttachment) -> URL?)? = nil
    ) throws -> [URL] {
        let base = sanitizedFilename(session.title.simplifiedChineseForDisplay)
        // One exclusive directory per export keeps all formats together and
        // never silently replaces an older export with the same lesson title.
        let batch = directory.appendingPathComponent("\(base)-导出-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: false)
        var complete = false
        defer {
            if !complete { try? FileManager.default.removeItem(at: batch) }
        }
        let markdown = makeKnowledgeMarkdown(session: session, speakerName: speakerName)
        var outputs: [URL] = []
        let images = exportImages(session)
        var imagePages: [(String, URL)] = []
        if !images.isEmpty {
            let assets = batch.appendingPathComponent("Images", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
            for image in images {
                guard let original = imageURL?(image) else { throw ImageFileFailure.invalid("导出缺少原图：\(image.title)") }
                let data = try Data(contentsOf: original, options: .mappedIfSafe)
                guard data.count <= ImageFiles.maximumBytes, ImageFiles.digest(data) == image.sha256 else {
                    throw ImageFileFailure.invalid("导出图片校验失败：\(image.title)")
                }
                let target = batch.appendingPathComponent(imageLink(image))
                try data.write(to: target, options: .atomic)
                imagePages.append((image.title, target))
            }
        }

        if options.format == .markdown || options.format == .both {
            let url = batch.appendingPathComponent("\(base)-知识骨架.md")
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            outputs.append(url)
        }

        if options.format == .pdf || options.format == .both {
            let url = batch.appendingPathComponent("\(base)-知识骨架.pdf")
            try makePDF(text: markdown, title: session.title.simplifiedChineseForDisplay, outputURL: url, images: imagePages)
            outputs.append(url)
        }

        if options.includeTranscript {
            let transcript = makeTranscript(session: session, speakerName: speakerName)
            let url = batch.appendingPathComponent("\(base)-逐字稿.md")
            try transcript.write(to: url, atomically: true, encoding: .utf8)
            outputs.append(url)
        }

        complete = true
        return outputs
    }

    static func makeKnowledgeMarkdown(
        session: SessionRecord,
        speakerName: (UUID) -> String
    ) -> String {
        let spans = Dictionary(uniqueKeysWithValues: session.transcript.map { ($0.id, $0) })
        let nodes = IntegrityValidator.presentationNodes(session.nodes, transcript: session.transcript, images: session.images ?? [])
        let nodesByParent = Dictionary(grouping: nodes.filter { $0.parentID != nil }, by: { $0.parentID! })
        let roots = nodes.filter { $0.parentID == nil }

        var lines = ["# \(session.title)", "", "> 来源：\(session.sourceName) · \(session.sourceKind)", ""]
        for warning in session.analysisWarnings ?? [] {
            lines.append("> 整理说明：\(warning)")
        }
        if session.analysisWarnings?.isEmpty == false { lines.append("") }

        var emitted: Set<UUID> = []
        func appendNode(_ node: KnowledgeNode, depth: Int) {
            guard emitted.insert(node.id).inserted else { return }
            let isImportantCard = node.importantMarkID != nil && node.thoughtID == nil && node.kind != .thought
            let text: String
            if isImportantCard {
                text = node.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? node.aiSummary!.simplifiedChineseForDisplay : "重点概括待生成"
            } else { text = IntegrityValidator.visibleText(for: node, transcript: session.transcript, images: session.images ?? []) }
            let speaker = node.sourceSpanIDs.first
                .flatMap { spans[$0] }
                .map { speakerName($0.speakerID) } ?? "我"
            let editMark = node.isSecondaryEdit ? " · 二次编辑" : ""
            let synthesisMark = (isImportantCard && node.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                || (node.sourceBoundStatus == "summarized" && !node.isSecondaryEdit) ? " · AI概括" : ""
            if let label = node.userLabel, !label.isEmpty {
                lines.append("\(String(repeating: "  ", count: depth))- **人工标题：\(label)**")
            }
            lines.append("\(String(repeating: "  ", count: depth))- **\(node.kind.rawValue)｜\(speaker)\(editMark)\(synthesisMark)**：\(text)")
            if isImportantCard, node.isSecondaryEdit, let authored = node.userEditedText, !authored.isEmpty {
                lines.append("\(String(repeating: "  ", count: depth + 1))我的修改：\(authored)")
            }
            if let origin = node.origin {
                lines.append("\(String(repeating: "  ", count: depth + 1))来源记录：\(origin.sessionTitle)")
            }
            for id in node.sourceImageIDs ?? [] {
                if let image = session.images?.first(where: { $0.id == id }) {
                    lines.append("\(String(repeating: "  ", count: depth + 1))图片依据：[\(image.title)](\(imageLink(image)))（图片解读由 AI 生成，可回看原图）")
                }
            }
            for excerpt in node.coreOriginals ?? [] {
                let originLabel = excerpt.origin.map { "（\($0.sessionTitle)）" } ?? ""
                lines.append("\(String(repeating: "  ", count: depth + 1))> 核心依据·原话\(originLabel)：\(excerpt.text.simplifiedChineseForDisplay)")
            }
            for excerpt in node.conditionOriginals ?? [] {
                let originLabel = excerpt.origin.map { "（\($0.sessionTitle)）" } ?? ""
                lines.append("\(String(repeating: "  ", count: depth + 1))> 条件与说明\(originLabel)：\(excerpt.text.simplifiedChineseForDisplay)")
            }
            if let argument = node.argumentSummary, !argument.isEmpty {
                let argumentLabel = node.sourceBoundStatus == "extracted" ? "相关条件与说明（原话）" : "讲述思路（AI）"
                lines.append("\(String(repeating: "  ", count: depth + 1))\(argumentLabel)：\(argument.simplifiedChineseForDisplay)")
            }
            if let relation = node.relationToPrevious, !relation.isEmpty {
                lines.append("\(String(repeating: "  ", count: depth + 1))承接：\(relation.simplifiedChineseForDisplay)")
            }
            if node.thoughtID != nil, let summary = node.aiSummary, !summary.isEmpty {
                lines.append("\(String(repeating: "  ", count: depth + 1))思考概括（AI）：\(summary.simplifiedChineseForDisplay)")
            }
            if let archived = node.archivedSourceSpans, node.hasHistoricalEvidence(comparedTo: session.transcript) {
                for excerpt in AnnotationPresentation.excerpts(archived) {
                    lines.append("\(String(repeating: "  ", count: depth + 1))> 编辑时的原话（旧转写）｜\(timestamp(excerpt.spans[0].startTime))：\(excerpt.originalText)")
                    if let corrected = excerpt.correctedText {
                        lines.append("\(String(repeating: "  ", count: depth + 1))> 当时的人工修正：\(corrected)")
                    }
                }
            }
            if isImportantCard || node.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                let quotes = node.sourceSpanIDs.compactMap { spans[$0]?.simplifiedOriginalText }.joined(separator: " ")
                let label = node.hasHistoricalEvidence(comparedTo: session.transcript) ? "本版附近原话（仅时间定位）" : "原话依据"
                if !quotes.isEmpty { lines.append("\(String(repeating: "  ", count: depth + 1))> \(label)：\(quotes)") }
            }
            for child in (nodesByParent[node.id] ?? []).sorted(by: nodeSort) {
                appendNode(child, depth: depth + 1)
            }
        }

        for root in roots.sorted(by: nodeSort) { appendNode(root, depth: 0) }
        for node in nodes where !emitted.contains(node.id) { appendNode(node, depth: 0) }

        let visibleThoughtIDs = Set(nodes.compactMap(\.thoughtID))
        let unattachedThoughts = session.thoughts.filter {
            !$0.isDeleted && !visibleThoughtIDs.contains($0.id)
        }
        if !unattachedThoughts.isEmpty {
            lines.append(contentsOf: ["", "## 未归类的我的思考", ""])
            for thought in unattachedThoughts {
                lines.append("- \(thought.text)\(thought.isSecondaryEdit ? "（二次编辑）" : "")")
            }
        }
        appendImages(exportImages(session), to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    static func makeTranscript(
        session: SessionRecord,
        speakerName: (UUID) -> String
    ) -> String {
        let filteredCount = session.transcript.filter(\.isFilteredBackground).count
        var lines = ["# \(session.title)｜逐字稿", "", "> 连续稿件；重点和我的思考按当时位置保留。已隐藏 \(filteredCount) 条背景音乐或无效识别。", ""]
        let spans = session.transcript.filter { !$0.isFilteredBackground }.sorted { $0.startTime < $1.startTime }
        let correctedSpans = spans.filter { $0.hasAutomaticCorrection || $0.hasManualCorrection || !$0.validProofreadUncertainties.isEmpty }
        if spans.contains(where: \.hasAutomaticCorrection) {
            lines += ["> 正文采用 AI 校订稿；AI 校订不是原始识别，相关原始识别保留在文末供回查。人工修正始终优先。", ""]
        }
        let thoughts = session.thoughts.filter { !$0.isDeleted }.sorted {
            ($0.anchorTime ?? .greatestFiniteMagnitude) < ($1.anchorTime ?? .greatestFiniteMagnitude)
        }
        var thoughtIndex = 0
        var paragraph: [TranscriptSpan] = []
        for mark in AnnotationPresentation.pendingMarks(session) {
            lines.append("> \(mark.text)")
        }

        func flushParagraph() {
            guard let first = paragraph.first else { return }
            let time = first.origin != nil && first.origin?.startTime == nil ? "导图原文" : (session.sourceKind == "文本导入（无音频时间）" ? "文本段落" : timestamp(first.origin?.startTime ?? first.startTime))
            let source = first.origin.map { " · \($0.sessionTitle)" } ?? ""
            lines.append("### \(time) · \(speakerName(first.speakerID))\(source)")
            lines.append("")
            lines.append(zip(paragraph, TranscriptReadingFormatter.fragments(for: paragraph)).map { span, text in
                let prefix = span.isImportant ? "【重点】" : ""
                return prefix + text
            }.joined())
            lines.append("")
            if paragraph.contains(where: \.hasAutomaticCorrection) {
                lines.append("> 本段含 AI 校订，不代表人工确认。")
            }
            for span in paragraph where !span.validProofreadUncertainties.isEmpty {
                lines.append("> 待确认（\(timestamp(span.origin?.startTime ?? span.startTime))）：\(span.validProofreadUncertainties.joined(separator: "；"))")
            }
            if paragraph.contains(where: { $0.hasAutomaticCorrection || !$0.validProofreadUncertainties.isEmpty }) { lines.append("") }
            paragraph.removeAll(keepingCapacity: true)
        }
        func appendThought(_ thought: UserThought) {
            let time = thought.anchorTime.map { " · \(timestamp($0))" } ?? ""
            lines.append("### 我的思考\(time)")
            lines.append("")
            lines.append(thought.text)
            lines.append("")
        }

        for span in spans {
            while thoughtIndex < thoughts.count,
                  let anchor = thoughts[thoughtIndex].anchorTime,
                  anchor <= span.startTime {
                flushParagraph()
                appendThought(thoughts[thoughtIndex])
                thoughtIndex += 1
            }
            if let last = paragraph.last,
               (last.speakerID != span.speakerID || last.origin?.sessionID != span.origin?.sessionID || span.startTime - last.endTime > 12 || paragraph.reduce(0, { $0 + $1.displayedText.count }) > 650) {
                flushParagraph()
            }
            paragraph.append(span)
        }
        flushParagraph()
        while thoughtIndex < thoughts.count {
            appendThought(thoughts[thoughtIndex])
            thoughtIndex += 1
        }
        if !correctedSpans.isEmpty {
            lines += ["", "## 原始识别回查", "", "> 以下为校订或人工修正前保存的原始识别，未用 AI 文字替换。", ""]
            for span in correctedSpans {
                let kind = span.hasManualCorrection ? "人工修正" : (span.hasAutomaticCorrection ? "AI 校订" : "待确认")
                let source = span.origin.map { " · \($0.sessionTitle)" } ?? ""
                lines += ["### \(timestamp(span.origin?.startTime ?? span.startTime)) · \(speakerName(span.speakerID))\(source) · \(kind)", "",
                          "来源 ID：\(span.id.uuidString)", "", span.originalText, ""]
            }
        }
        appendImages(exportImages(session), to: &lines)
        return lines.joined(separator: "\n")
    }

    private static func imageLink(_ image: ImageAttachment) -> String {
        "Images/\(image.id.uuidString).\(ImageAttachmentValidation.fileExtension(for: image.mimeType) ?? "png")"
    }

    private static func exportImages(_ session: SessionRecord) -> [ImageAttachment] {
        let cited = Set(session.nodes.filter { !$0.isDeleted }.flatMap { ($0.sourceImageIDs ?? []) + ($0.coveredSourceImageIDs ?? []) })
        return (session.images ?? []).filter { $0.deletedAt == nil || cited.contains($0.id) }
    }

    private static func appendImages(_ images: [ImageAttachment], to lines: inout [String]) {
        guard !images.isEmpty else { return }
        lines += ["", "## 图片材料与解读", "", "> 原图随导出保留；下面的图片文字与解释是模型分析，不是讲者原话。", ""]
        for image in images {
            lines += ["### \(image.title)", "", "![图片原图](\(imageLink(image)))", "", "图片来源 ID：\(image.id.uuidString)", ""]
            if let origin = image.origin { lines += ["来源记录：\(origin.sessionTitle)", ""] }
            if let time = image.anchorTime { lines += ["关联录音时间：\(timestamp(time))", ""] }
            if !image.note.isEmpty { lines += ["我的图片说明：\(image.note)", ""] }
            if let analysis = image.analysis {
                if !analysis.extractedText.isEmpty { lines += ["图中文字（AI 识别）：", analysis.extractedText.simplifiedChineseForDisplay, ""] }
                lines += ["图片解读（AI）：", analysis.explanation.simplifiedChineseForDisplay, ""]
                for issue in analysis.uncertainties { lines.append("> 图片待确认：\(issue.simplifiedChineseForDisplay)") }
            } else { lines += ["图片尚未分析。", ""] }
        }
    }

    private static func makePDF(text: String, title: String, outputURL: URL, images: [(String, URL)] = []) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: outputURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let attributed = formattedPDFText(text)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = 0
        let bodyRect = CGRect(x: 54, y: 64, width: mediaBox.width - 108, height: mediaBox.height - 118)
        var page = 0

        while location < attributed.length {
            context.beginPDFPage(nil)
            page += 1
            context.saveGState()
            context.textMatrix = .identity
            let path = CGPath(rect: bodyRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                context.restoreGState()
                context.endPDFPage()
                break
            }
            location += visible.length
            let footer = NSAttributedString(string: "直播与课程知识骨架 · 第 \(page) 页", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor
            ])
            context.textPosition = CGPoint(x: 54, y: 34)
            CTLineDraw(CTLineCreateWithAttributedString(footer), context)
            context.restoreGState()
            context.endPDFPage()
        }
        for (caption, url) in images {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else {
                throw ImageFileFailure.invalid("PDF 无法读取图片：\(caption)")
            }
            context.beginPDFPage(nil)
            context.saveGState()
            context.textMatrix = .identity
            let heading = NSAttributedString(string: String(caption.prefix(70)), attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            context.textPosition = CGPoint(x: 54, y: 795)
            CTLineDraw(CTLineCreateWithAttributedString(heading), context)
            let scale = min(487 / CGFloat(image.width), 700 / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.draw(image, in: CGRect(x: (595 - size.width) / 2, y: 70 + (700 - size.height) / 2, width: size.width, height: size.height))
            context.restoreGState(); context.endPDFPage()
        }
        context.closePDF()
    }

    /// Render the export's structural markers as typography, not raw Markdown
    /// punctuation. User wording inside the generated block is not rewritten.
    private static func formattedPDFText(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let ink = NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.18, alpha: 1)
        for line in markdown.components(separatedBy: "\n") {
            var body = line
            var size: CGFloat = 11
            var weight: NSFont.Weight = .regular
            var color = ink
            let leading = line.prefix { $0 == " " }.count
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            style.paragraphSpacing = 7
            style.headIndent = CGFloat(min(leading, 20)) * 6
            style.firstLineHeadIndent = style.headIndent
            if body.hasPrefix("# ") {
                body.removeFirst(2); size = 22; weight = .bold; style.paragraphSpacing = 18
            } else if body.hasPrefix("## ") {
                body.removeFirst(3); size = 15; weight = .semibold; style.paragraphSpacingBefore = 10
            } else {
                body = String(body.dropFirst(leading))
                if body.hasPrefix("- **"), let end = body.dropFirst(4).range(of: "**") {
                    let prefix = String(body[body.index(body.startIndex, offsetBy: 4)..<end.lowerBound])
                    body = "• " + prefix + String(body[end.upperBound...])
                    weight = .medium
                } else if body.hasPrefix("> ") {
                    body.removeFirst(2)
                    color = NSColor(calibratedRed: 0.27, green: 0.39, blue: 0.42, alpha: 1)
                    style.headIndent += 10; style.firstLineHeadIndent += 10
                    size = 10
                } else if body.hasPrefix("- ") { body = "• " + body.dropFirst(2) }
            }
            if body.isEmpty { size = 4; style.paragraphSpacing = 0; style.lineSpacing = 0 }
            result.append(NSAttributedString(string: body + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style
            ]))
        }
        return result
    }

    private static func nodeSort(_ lhs: KnowledgeNode, _ rhs: KnowledgeNode) -> Bool {
        if lhs.position.y == rhs.position.y { return lhs.position.x < rhs.position.x }
        return lhs.position.y < rhs.position.y
    }

    private static func sanitizedFilename(_ text: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let parts = text.components(separatedBy: forbidden)
        let value = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未命名记录" : String(value.prefix(60))
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

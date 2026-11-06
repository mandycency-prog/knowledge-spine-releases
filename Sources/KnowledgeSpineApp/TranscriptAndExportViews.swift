import AppKit
import KnowledgeSpineCore
import SwiftUI

struct TranscriptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let sessionID: UUID
    let focusedSpanID: UUID?
    @State private var showingImporter = false
    @State private var showFilteredBackground = false
    @State private var showingImages = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("逐字稿")
                        .font(.title2.bold())
                    Text("连续稿件·重点和我的思考已按当时位置写入")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Toggle("显示已过滤的背景声音", isOn: $showFilteredBackground)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if let session = store.database.sessions.first(where: { $0.id == sessionID }) {
                    Button("复制全文", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copyText(for: session), forType: .string)
                        store.statusMessage = "已复制连续逐字稿。"
                    }
                }
                Button("导入文本（已有内容另建记录）", systemImage: "doc.badge.plus") { showingImporter = true }
                Button("图片", systemImage: "photo.on.rectangle") { showingImages = true }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)
            Divider()

            if let session = store.database.sessions.first(where: { $0.id == sessionID }) {
                if TranscriptAnnotationViewContent.showsEmptyState(session) {
                    ContentUnavailableView(
                        "还没有逐字稿",
                        systemImage: "text.alignleft",
                        description: Text("可以导入本地文本。稿件连续显示，内部保留可回查的位置。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 22) {
                                if session.transcript.isEmpty {
                                    Text("逐字稿尚未生成；已写下的思考和重点标记保留在这里。")
                                        .font(.callout).foregroundStyle(AppTheme.muted)
                                }
                                ForEach(TranscriptAnnotationViewContent.pendingMarks(session)) { mark in
                                    Label(mark.text, systemImage: "bookmark.fill")
                                        .font(.callout).foregroundStyle(AppTheme.amber)
                                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(AppTheme.amberSoft, in: RoundedRectangle(cornerRadius: 8))
                                }
                                ImageEvidenceStrip(sessionID: session.id, imageIDs: (session.images ?? []).filter { $0.deletedAt == nil && $0.anchorSpanID == nil && $0.anchorTime == nil }.map(\.id))
                                let items = documentItems(for: session)
                                ForEach(items) { item in
                                    TranscriptDocumentRow(item: item, session: session, focusedSpanID: focusedSpanID)
                                        .id(item.id)
                                }
                            }
                            .padding(.horizontal, 42)
                            .padding(.vertical, 30)
                            .frame(maxWidth: 940, alignment: .leading)
                            .frame(maxWidth: .infinity)
                        }
                        .background(AppTheme.canvas)
                        .onAppear {
                            if let focusedSpanID,
                               let item = documentItems(for: session).first(where: { $0.spanIDs.contains(focusedSpanID) }) {
                                proxy.scrollTo(item.id, anchor: .center)
                            }
                        }
                        .onChange(of: focusedSpanID) { _, id in
                            if let id, let item = documentItems(for: session).first(where: { $0.spanIDs.contains(id) }) {
                                proxy.scrollTo(item.id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .acceptSessionImages(sessionID: sessionID, anchorSpanID: focusedSpanID)
        .sheet(isPresented: $showingImages) { ImageAttachmentsSheet(sessionID: sessionID, anchorSpanID: focusedSpanID) }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.plainText]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let text = try String(contentsOf: url, encoding: .utf8)
                if let id = store.importTranscriptText(text, sessionID: sessionID), id != sessionID { dismiss() }
            } catch {
                store.statusMessage = "导入逐字稿失败：\(error.localizedDescription)"
            }
        }
    }

    private func documentItems(for session: SessionRecord) -> [TranscriptDocumentItem] {
        let spans = session.transcript
            .filter { showFilteredBackground || !$0.isFilteredBackground || $0.id == focusedSpanID }
            .sorted { $0.startTime < $1.startTime }
        let thoughts = session.thoughts.filter { !$0.isDeleted }.sorted {
            ($0.anchorTime ?? .greatestFiniteMagnitude) < ($1.anchorTime ?? .greatestFiniteMagnitude)
        }
        var items: [TranscriptDocumentItem] = []
        var paragraph: [TranscriptSpan] = []
        var thoughtIndex = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            items.append(.paragraph(paragraph))
            paragraph.removeAll(keepingCapacity: true)
        }
        for span in spans {
            while thoughtIndex < thoughts.count,
                  let anchor = thoughts[thoughtIndex].anchorTime,
                  anchor <= span.startTime {
                flushParagraph()
                items.append(.thought(thoughts[thoughtIndex]))
                thoughtIndex += 1
            }
            if let last = paragraph.last,
               (last.speakerID != span.speakerID || last.origin?.sessionID != span.origin?.sessionID || span.startTime - last.endTime > 12 || paragraphTextLength(paragraph) > 650) {
                flushParagraph()
            }
            paragraph.append(span)
        }
        flushParagraph()
        while thoughtIndex < thoughts.count {
            items.append(.thought(thoughts[thoughtIndex]))
            thoughtIndex += 1
        }
        return items
    }

    private func paragraphTextLength(_ spans: [TranscriptSpan]) -> Int {
        spans.reduce(0) { $0 + $1.displayedText.count }
    }

    private func copyText(for session: SessionRecord) -> String {
        let pending = TranscriptAnnotationViewContent.pendingMarks(session).map(\.text)
        let body = documentItems(for: session).map { item in
            switch item.kind {
            case .paragraph(let spans):
                guard let first = spans.first else { return "" }
                let speaker = store.speakerName(first.speakerID, in: session)
                let body = zip(spans, TranscriptReadingFormatter.fragments(for: spans))
                    .map { span, text in (span.isImportant ? "【重点】" : "") + text }.joined()
                return "\(speaker)：\(body)"
            case .thought(let thought):
                return "【我的思考】\(thought.text)"
            }
        }
        return (pending + body).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

private struct TranscriptDocumentItem: Identifiable {
    enum Kind {
        case paragraph([TranscriptSpan])
        case thought(UserThought)
    }

    let id: String
    let kind: Kind
    let spanIDs: Set<UUID>

    static func paragraph(_ spans: [TranscriptSpan]) -> Self {
        let first = spans.first?.id.uuidString ?? UUID().uuidString
        return Self(id: "paragraph-\(first)", kind: .paragraph(spans), spanIDs: Set(spans.map(\.id)))
    }

    static func thought(_ thought: UserThought) -> Self {
        Self(id: "thought-\(thought.id.uuidString)", kind: .thought(thought), spanIDs: [])
    }
}

private struct TranscriptDocumentRow: View {
    @EnvironmentObject private var store: AppStore
    let item: TranscriptDocumentItem
    let session: SessionRecord
    let focusedSpanID: UUID?
    @State private var editingSpanID: UUID?

    var body: some View {
        switch item.kind {
        case .paragraph(let spans):
            if let first = spans.first {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        Text(store.speakerName(first.speakerID, in: session))
                            .font(.callout.bold())
                            .foregroundStyle(AppTheme.teal)
                        Text(first.origin != nil && first.origin?.startTime == nil ? "导图原文" : (session.sourceKind == "文本导入（无音频时间）" ? "文本段落" : timecode(first.origin?.startTime ?? first.startTime)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.muted)
                        if spans.contains(where: \.isImportant) {
                            Label("含重点标记", systemImage: "bookmark.fill")
                                .font(.caption.bold())
                                .foregroundStyle(AppTheme.amber)
                        }
                        if let label = TranscriptAnnotationViewContent.proofreadingLabel(spans) {
                            Text(label).font(.caption).foregroundStyle(AppTheme.muted)
                        }
                        Spacer()
                        Button("原始识别 / 修正 / 标注") { editingSpanID = focusedSpanID.flatMap { id in spans.contains { $0.id == id } ? id : nil } ?? first.id }
                            .buttonStyle(.link)
                            .popover(isPresented: Binding(get: { editingSpanID != nil }, set: { if !$0 { editingSpanID = nil } }), arrowEdge: .trailing) {
                                if let editingSpanID {
                                    TranscriptEvidenceEditor(sessionID: session.id, spanIDs: spans.map(\.id), initialSpanID: editingSpanID)
                                }
                            }
                    }
                    if let origin = first.origin {
                        Button("\(origin.authoredByUser == true ? "用户文字 · 来自：" : "来自：")\(origin.sessionTitle)") { store.openOrigin(origin) }.buttonStyle(.link).font(.caption)
                    }
                    paragraphText(spans)
                        .font(.system(size: 16))
                        .foregroundStyle(AppTheme.ink)
                        .lineSpacing(7)
                        .textSelection(.enabled)
                    ImageEvidenceStrip(sessionID: session.id, imageIDs: (session.images ?? []).filter { image in
                        guard image.deletedAt == nil else { return false }
                        if let anchor = image.anchorSpanID { return spans.contains { $0.id == anchor } }
                        guard let time = image.anchorTime, let last = spans.last else { return false }
                        return time >= first.startTime && time <= last.endTime
                    }.map(\.id))
                    ForEach((session.importantMarks ?? []).filter { mark in spans.contains { $0.id == mark.anchorSpanID } }) { mark in
                        if let summary = session.nodes.first(where: { !$0.isDeleted && $0.importantMarkID == mark.id })?.aiSummary, !summary.isEmpty {
                            Label("重点概括（AI）：" + summary.simplifiedChineseForDisplay, systemImage: "bookmark.fill")
                                .font(.callout).foregroundStyle(AppTheme.amber)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppTheme.amberSoft, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(10)
                .background(item.spanIDs.contains(focusedSpanID ?? UUID()) ? AppTheme.tealSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                .acceptSessionImages(sessionID: session.id, anchorSpanID: first.id)
            }
        case .thought(let thought):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("我的思考", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.callout.bold())
                        .foregroundStyle(AppTheme.blue)
                    if let anchor = thought.anchorTime {
                        Text(timecode(anchor))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.muted)
                    }
                }
                if let summary = session.nodes.first(where: { !$0.isDeleted && $0.thoughtID == thought.id })?.aiSummary, !summary.isEmpty {
                    Text("AI 概括：" + summary.simplifiedChineseForDisplay)
                        .font(.caption).foregroundStyle(AppTheme.blue)
                }
                Text(verbatim: thought.text)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.ink)
                    .lineSpacing(6)
                    .textSelection(.enabled)
            }
            .padding(16)
            .background(AppTheme.blueSoft, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).stroke(AppTheme.blue.opacity(0.35), lineWidth: 1)
            }
        }
    }

    private func paragraphText(_ spans: [TranscriptSpan]) -> Text {
        zip(spans, TranscriptReadingFormatter.fragments(for: spans)).reduce(Text("")) { result, pair in
            let (span, readingText) = pair
            let prefix = span.isImportant ? Text("【重点】").bold().foregroundColor(AppTheme.amber) : Text("")
            let body = Text(verbatim: readingText)
                .foregroundColor(span.isImportant ? AppTheme.amber : (span.isFilteredBackground ? AppTheme.muted : AppTheme.ink))
                .fontWeight(span.isImportant ? .semibold : .regular)
            return result + prefix + body
        }
    }

    private func timecode(_ value: TimeInterval) -> String {
        let total = Int(value)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Recognition units are only exposed when editing a precise source. The
/// reading surface remains a continuous manuscript, not a stack of cards.
private struct TranscriptEvidenceEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    let spanIDs: [UUID]
    let initialSpanID: UUID
    @State private var selectedID: UUID?
    @State private var corrected = ""
    @State private var speakerName = ""
    @State private var thought = ""
    private var session: SessionRecord? { store.database.sessions.first { $0.id == sessionID } }
    private var span: TranscriptSpan? { session?.transcript.first { $0.id == (selectedID ?? initialSpanID) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("编辑对应原文").font(.headline); Spacer(); Button("完成") { dismiss() } }
            if let session, let span {
                if spanIDs.count > 1 {
                    Picker("定位文字", selection: Binding(get: { selectedID ?? initialSpanID }, set: { saveCorrection(); selectedID = $0; load($0) })) {
                        ForEach(session.transcript.filter { spanIDs.contains($0.id) }) { item in
                            Text(String(item.displayedText.prefix(34))).tag(item.id)
                        }
                    }
                }
                Text("原始识别（保留不覆盖）").font(.caption.bold()).foregroundStyle(AppTheme.muted)
                ScrollView { Text(verbatim: span.originalText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 110)
                if let proofread = span.validProofreadText {
                    Text(span.hasManualCorrection ? "AI 校订参考（当前以你的修正为准）" : "AI 校订（不是原始识别）")
                        .font(.caption.bold()).foregroundStyle(AppTheme.muted)
                    ScrollView {
                        Text(verbatim: proofread.simplifiedChineseForDisplay)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 85)
                }
                if !span.validProofreadUncertainties.isEmpty {
                    Text("待确认：" + span.validProofreadUncertainties.joined(separator: "；"))
                        .font(.caption).foregroundStyle(AppTheme.amber)
                }
                TextField("说话人", text: $speakerName).textFieldStyle(.roundedBorder)
                Text("人工修正").font(.caption.bold())
                TextEditor(text: $corrected).font(.body).frame(height: 100).overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.line))
                HStack {
                    Button("保存修正") { saveCorrection() }
                    Button("恢复原始识别") {
                        store.clearCorrectedText(spanID: span.id, sessionID: sessionID)
                        load(span.id)
                    }
                    Spacer()
                    Button(span.isImportant ? "取消重点" : "标为重点") { store.toggleImportant(spanID: span.id, sessionID: sessionID) }
                }
                Menu("把这段原文加入导图") {
                    Button("作为独立节点") { store.addSourceNode(spanID: span.id, kind: .main, parentID: nil, sessionID: sessionID) }
                    ForEach(session.nodes.filter { !$0.isDeleted && $0.kind != .thought }) { node in
                        Button("挂到：" + String((node.userLabel ?? store.nodeText(node, in: session)).prefix(26))) {
                            store.addSourceNode(spanID: span.id, kind: .evidence, parentID: node.id, sessionID: sessionID)
                        }
                    }
                }
                Divider()
                TextField("写下这段引发的思考（原文保留）", text: $thought, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                Button("保存我的思考") {
                    let parent = session.nodes.first { !$0.isDeleted && $0.sourceSpanIDs.contains(span.id) }?.id
                    store.addThought(thought, sessionID: sessionID, attachedNodeID: parent, live: false, anchorTime: span.startTime)
                    thought = ""
                }.disabled(thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(width: 500)
            .onAppear { selectedID = initialSpanID; load(initialSpanID) }
            .onDisappear { saveCorrection() }
    }
    private func load(_ id: UUID) {
        guard let session, let span = session.transcript.first(where: { $0.id == id }) else { return }
        corrected = span.displayedText
        speakerName = store.speakerName(span.speakerID, in: session)
    }
    private func saveCorrection() {
        guard let session, let span else { return }
        if !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && corrected != span.displayedText {
            store.updateCorrectedText(corrected, spanID: span.id, sessionID: sessionID)
        }
        if speakerName != store.speakerName(span.speakerID, in: session) { store.renameSpeaker(span.speakerID, to: speakerName, sessionID: sessionID) }
    }
}

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let sessionID: UUID
    @State private var format: ExportFormat = .markdown
    @State private var includeTranscript = true
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("导出这场记录")
                    .font(.title2.bold())
                Text("知识骨架和逐字稿始终是独立文件。")
                    .foregroundStyle(AppTheme.muted)
            }
            Picker("格式", selection: $format) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("同时导出独立逐字稿（Markdown）", isOn: $includeTranscript)
            Label("AI 概括关联原话或图片；导出时同时保留依据。", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(AppTheme.teal)
                .padding(12)
                .background(AppTheme.tealSoft, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("选择文件夹并导出") { export() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.teal)
                    .disabled(isExporting)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func export() {
        guard let session = store.database.sessions.first(where: { $0.id == sessionID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "选择导出文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        isExporting = true
        do {
            let outputs = try ExportService.export(
                session: session,
                to: directory,
                options: ExportOptions(format: format, includeTranscript: includeTranscript),
                speakerName: { store.speakerName($0, in: session) },
                imageURL: { store.imageURL($0, sessionID: session.id) }
            )
            store.statusMessage = "已导出 \(outputs.count) 个独立文件。"
            dismiss()
        } catch {
            store.statusMessage = "导出失败：\(error.localizedDescription)"
        }
        isExporting = false
    }
}

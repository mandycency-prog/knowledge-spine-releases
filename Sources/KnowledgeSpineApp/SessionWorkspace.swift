import AppKit
import KnowledgeSpineCore
import SwiftUI

struct SessionWorkspace: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var processor: LocalProcessingService
    @EnvironmentObject private var capture: CaptureService
    @Environment(\.openWindow) private var openWindow
    let session: SessionRecord
    let close: () -> Void

    @State private var titleDraft = WorkspaceTitleDraft()
    @FocusState private var titleFocused: Bool
    @State private var showingTranscript = false
    @State private var showingExport = false
    @State private var showingAddNode = false
    @State private var showingVersions = false
    @State private var showingAnalysisNotes = false
    @State private var showingFocusedStudy = false
    @State private var showingImages = false
    @State private var focusedQuestion = ""

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider().overlay(AppTheme.line)
            focusedStudyBar
            Divider().overlay(AppTheme.line)
            if let candidate = session.candidateVersions?.last {
                HStack {
                    Text("新导图已准备好 · \(candidate.nodes.filter { !$0.isDeleted && $0.thoughtID == nil && $0.importantMarkID == nil }.count) 个导图节点（含中心）")
                    Text("思考、重点和原图版本会保留").foregroundStyle(AppTheme.muted)
                    Spacer()
                    Button("采用新导图") { store.acceptLatestCandidate(sessionID: session.id, arrangeAsNewMap: true) }
                        .buttonStyle(.borderedProminent).tint(AppTheme.teal)
                    Button("比较版本") { showingVersions = true }
                }.font(.callout).padding(12).background(AppTheme.paper)
            }
            if processor.isProcessing(session.id) && !session.structureSaved {
                VStack(spacing: 18) {
                    ProgressView()
                    Text(session.isMergedRecord ? "正在把课程材料整理成专题导图" : "正在提炼可复用的方法与条件").font(.title2.bold())
                    Text("提炼关键观点、合并重复解释，原文和思考完整保留。完成后会自动显示新图。")
                        .foregroundStyle(AppTheme.muted)
                    Button("先看原文材料") { showingTranscript = true }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.nodes.filter({ !$0.isDeleted }).isEmpty {
                emptyWorkspace
            } else {
                KnowledgeCanvas(session: session)
            }
        }
        .background(AppTheme.canvas)
        .acceptSessionImages(sessionID: session.id, anchorTime: capture.recordingSessionID == session.id ? capture.recordedDuration : nil)
        .onAppear {
            titleDraft.load(sessionID: session.id, title: session.title)
            focusedQuestion = session.focusedStudyQuestion ?? ""
        }
        .onAppear {
            if store.selectedTranscriptSpanID != nil { showingTranscript = true }
            openSelectedImage()
        }
        .onChange(of: session.title) { _, value in
            if titleDraft.sessionID == session.id && !titleDraft.isDirty { titleDraft.load(sessionID: session.id, title: value) }
        }
        .onChange(of: session.id) { _, _ in
            saveTitleDraft()
            titleDraft.load(sessionID: session.id, title: session.title)
            focusedQuestion = session.focusedStudyQuestion ?? ""
            openSelectedImage()
        }
        .onChange(of: titleFocused) { _, focused in if !focused { saveTitleDraft() } }
        .onDisappear { saveTitleDraft() }
        .onChange(of: store.selectedTranscriptSpanID) { _, spanID in
            if spanID != nil { showingTranscript = true }
        }
        .onChange(of: store.selectedImageID) { _, _ in openSelectedImage() }
        .sheet(isPresented: $showingTranscript) {
            TranscriptSheet(sessionID: session.id, focusedSpanID: selectedSpanID)
        }
        .onChange(of: showingTranscript) { _, shown in
            if !shown { store.selectedTranscriptSpanID = nil }
        }
        .sheet(isPresented: $showingExport) {
            ExportSheet(sessionID: session.id)
        }
        .sheet(isPresented: $showingAddNode) {
            AddNodeSheet(sessionID: session.id, parentID: store.selectedNodeID)
        }
        .sheet(isPresented: $showingVersions) {
            VersionSheet(sessionID: session.id)
        }
        .sheet(isPresented: $showingFocusedStudy) {
            FocusedStudyView(sessionID: session.id, question: $focusedQuestion)
        }
        .sheet(isPresented: $showingImages, onDismiss: { store.selectedImageID = nil }) {
            ImageAttachmentsSheet(sessionID: session.id)
        }
    }

    private var focusedStudyBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(AppTheme.teal)
                TextField("你想重点弄清什么？例如：第二课堂和志愿服务的学分怎么获得、认定", text: $focusedQuestion, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(9)
                    .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                Button(processor.isFocusing(session.id) ? "查看整理进度" : "围绕这个问题整理") {
                    if !processor.isFocusing(session.id) {
                        processor.processFocus(question: focusedQuestion, sessionID: session.id, store: store)
                    }
                    showingFocusedStudy = true
                }
                .buttonStyle(.borderedProminent).tint(AppTheme.teal)
                .disabled(!processor.isFocusing(session.id) && !FocusedStudyAvailability.canSubmit(question: focusedQuestion, session: session, store: store, processor: processor))
                if let reports = session.focusedStudyReports, !reports.isEmpty {
                    Button("专题整理 \(reports.count)") { showingFocusedStudy = true }
                        .buttonStyle(.bordered)
                }
            }
            Text("依据本条逐字稿与图片整理；原导图保留")
                .font(.caption).foregroundStyle(AppTheme.muted).padding(.leading, 30)
            if focusedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).count > 600 {
                Text("问题请控制在 600 字以内。")
                    .font(.caption).foregroundStyle(AppTheme.coral).padding(.leading, 30)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(AppTheme.paper)
    }

    private var selectedSpanID: UUID? {
        if let focused = store.selectedTranscriptSpanID { return focused }
        guard let nodeID = store.selectedNodeID,
              let node = session.nodes.first(where: { $0.id == nodeID }) else { return nil }
        return node.sourceSpanIDs.first
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Button { saveTitleDraft(); close() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .background(AppTheme.paper, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                TextField("记录标题", text: $titleDraft.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .focused($titleFocused)
                    .onSubmit(saveTitleDraft)
                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(session.status.rawValue)
                    Text("·")
                    Text(session.sourceName)
                    if let warnings = session.analysisWarnings, !warnings.isEmpty {
                        Button("整理说明") { showingAnalysisNotes = true }
                            .popover(isPresented: $showingAnalysisNotes) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("本次整理说明").font(.headline)
                                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                            Text(warning).textSelection(.enabled)
                                        }
                                    }.padding(18)
                                }.frame(width: 400, height: 280)
                            }
                    }
                }
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            }
            Spacer()
            if processor.isProcessing(session.id) {
                ProgressView()
                    .controlSize(.small)
                Text(processor.progress[session.id] ?? "本地处理中")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            } else if session.status == .failed && (!session.audioRelativePaths.isEmpty || !session.transcript.isEmpty) {
                Button("继续本地处理", systemImage: "arrow.clockwise") {
                    processor.process(sessionID: session.id, audioPaths: session.audioRelativePaths, store: store)
                }
            }
            Button("录制浮窗", systemImage: "waveform") { openWindow(id: "capture") }
            Button("逐字稿", systemImage: "text.alignleft") { showingTranscript = true }
            Button("图片 \((session.images ?? []).filter { $0.deletedAt == nil }.count)", systemImage: "photo.on.rectangle") { showingImages = true }
            Button("新增节点", systemImage: "plus") { showingAddNode = true }
            Button("撤回", systemImage: "arrow.uturn.backward") { store.restoreLatestVersion(sessionID: session.id) }
                .disabled(session.versions.isEmpty)
            Button("版本", systemImage: "clock.arrow.circlepath") { showingVersions = true }
                .overlay(alignment: .topTrailing) {
                    if let count = session.candidateVersions?.count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(AppTheme.coral, in: Circle())
                            .offset(x: 7, y: -7)
                    }
                }
            Button("导出", systemImage: "square.and.arrow.up") { showingExport = true }
            Menu {
                Button("用现有材料重新整理主线", systemImage: "arrow.clockwise") {
                    processor.process(sessionID: session.id, audioPaths: [], store: store, reuseTranscriptClassification: true)
                }.disabled((session.transcript.isEmpty && !(session.images ?? []).contains { $0.deletedAt == nil }) || processor.isProcessing(session.id))
                Divider()
                if session.audioState == .recoverableTrash {
                    Button("恢复 7 天回收区音频") { store.restoreRecoverableAudio(sessionID: session.id) }
                    Divider()
                }
                Button("移到最近删除", role: .destructive) { store.moveSessionToTrash(session.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18)
        .frame(height: 66)
        .background(AppTheme.paper.opacity(0.96))
    }

    private func saveTitleDraft() {
        guard let change = titleDraft.takeChange() else { return }
        store.updateTitle(change.text, sessionID: change.sessionID)
    }

    private func openSelectedImage() {
        guard let imageID = store.selectedImageID,
              (session.images ?? []).contains(where: { $0.id == imageID && $0.deletedAt == nil }) else { return }
        showingTranscript = false
        store.selectedTranscriptSpanID = nil
        showingImages = true
    }

    private var statusColor: Color {
        switch session.status {
        case .ready: AppTheme.teal
        case .recording: AppTheme.coral
        case .paused, .processing: AppTheme.amber
        case .failed: AppTheme.coral
        case .draft: AppTheme.muted
        }
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 17) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(AppTheme.paper)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 38))
                    .foregroundStyle(AppTheme.teal)
            }
            .frame(width: 90, height: 90)
            Text("骨架还没有形成")
                .font(.title2.bold())
            Text(emptyDescription)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.muted)
                .frame(maxWidth: 500)
            HStack {
                if session.transcript.isEmpty && !(session.images ?? []).contains(where: { $0.deletedAt == nil }) {
                    Button("打开录制浮窗") { openWindow(id: "capture") }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.teal)
                    Button("导入逐字稿") { showingTranscript = true }
                        .buttonStyle(.bordered)
                } else {
                    Button("用已保存的材料继续整理") {
                        processor.process(sessionID: session.id, audioPaths: [], store: store, reuseTranscriptClassification: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.teal)
                    .disabled(processor.isProcessing(session.id))
                    Button("查看逐字稿") { showingTranscript = true }
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDescription: String {
        if (session.images ?? []).contains(where: { $0.deletedAt == nil }) && session.transcript.isEmpty {
            "图片已保存在本条记录中，可以直接用图片整理知识骨架，也可以继续加入录音和逐字稿。"
        } else if session.transcript.isEmpty {
            "开始录制，或导入已有音频。录制时会在本机持续转写，保留完整稿件。"
        } else if processor.isProcessing(session.id) {
            "逐字稿已经保存。\(processor.progress[session.id] ?? "正在整理导图，请稍候。")"
        } else if let error = session.lastProcessingError, !error.isEmpty {
            "逐字稿已经保存，导图整理未完成。\n\(error)\n可以直接用已保存的逐字稿继续，不需要重新录音。"
        } else {
            "逐字稿已经保存，导图尚未生成。可以直接用现有逐字稿整理，不需要重新录音。"
        }
    }
}

/// Pure view-state rules used by the canvas and the isolated interaction probe.
enum WorkspaceCanvasProjection {
    static func visibleNodes(in session: SessionRecord, showDetails: Bool, measuredCardHeights: [UUID: Double] = [:]) -> [KnowledgeNode] {
        let active = IntegrityValidator.presentationNodes(session.nodes, transcript: session.transcript, images: session.images ?? [], overviewOnly: !showDetails)
        // Overview filtering can remove an intermediate evidence node. Its
        // collapsed state still governs descendants in the original tree.
        let byID = Dictionary(uniqueKeysWithValues: session.nodes.filter { !$0.isDeleted }.map { ($0.id, $0) })
        var visible = active.filter { node in
            if node.thoughtID != nil || node.kind == .thought { return true }
            var cursor = byID[node.id]?.parentID
            var visited: Set<UUID> = []
            while let id = cursor, let ancestor = byID[id], visited.insert(id).inserted {
                if ancestor.isCollapsed { return false }
                cursor = ancestor.parentID
            }
            return true
        }
        let visibleIDs = Set(visible.map(\.id))
        for index in visible.indices where visible[index].thoughtID != nil || visible[index].kind == .thought {
            var cursor = visible[index].parentID
            var visited: Set<UUID> = []
            while let id = cursor, !visibleIDs.contains(id), visited.insert(id).inserted { cursor = byID[id]?.parentID }
            visible[index].parentID = cursor
        }
        let heights = Dictionary(uniqueKeysWithValues: visible.map {
            ($0.id, measuredCardHeights[$0.id] ?? cardHeight($0, in: session))
        })
        return CanvasOverviewLayout.arrange(visible, cardHeights: heights)
    }

    static func thoughtCardHeight(_ node: KnowledgeNode, in session: SessionRecord) -> Double {
        let text = session.thoughts.first { $0.id == node.thoughtID }?.text ?? node.userEditedText ?? ""
        let measured = (text as NSString).boundingRect(with: CGSize(width: 252, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium)])
        return max(180, ceil(measured.height * 1.25) + 100)
    }

    /// Pre-layout estimate; SwiftUI's actual unscaled card height replaces it
    /// after rendering, including titles, badges, multiline summaries and notes.
    static func cardHeight(_ node: KnowledgeNode, in session: SessionRecord) -> Double {
        if node.thoughtID != nil || node.kind == .thought { return thoughtCardHeight(node, in: session) }
        guard NodeCardBodyContent.expandsBody(node) else { return 180 }
        let hasLabel = node.userLabel?.isEmpty == false && !(node.importantMarkID != nil && node.userLabel == "重点")
        let body = NodeCardBodyContent.resolve(node: node, transcript: session.transcript, hasCustomLabel: hasLabel).text
        func measured(_ text: String, size: CGFloat = 14) -> Double {
            let rect = (text as NSString).boundingRect(with: CGSize(width: 252, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)])
            return ceil(rect.height * 1.25)
        }
        var height = 110 + measured(body)
        if hasLabel { height += measured(node.userLabel ?? "", size: 15) + 10 }
        if let label = node.navigationLabel, !label.isEmpty { height += min(44, measured(label, size: 16)) + 10 }
        if let relation = node.relationToPrevious, !relation.isEmpty { height += measured(relation, size: 11) + 10 }
        if node.importantMarkID != nil, node.isSecondaryEdit, let authored = node.userEditedText, !authored.isEmpty {
            height += measured(authored) + 30
        }
        return max(180, height)
    }

    static func position(_ node: KnowledgeNode, live: [UUID: CGPoint]) -> CGPoint {
        live[node.id] ?? CGPoint(x: node.position.x, y: node.position.y)
    }

    static func requiresDetails(for target: UUID, in session: SessionRecord) -> Bool {
        session.nodes.contains { $0.id == target && !$0.isDeleted } &&
        !IntegrityValidator.presentationNodes(session.nodes, transcript: session.transcript, images: session.images ?? [], overviewOnly: true).contains { $0.id == target }
    }

    static func connection(parent: KnowledgeNode, child: KnowledgeNode, live: [UUID: CGPoint]) -> (start: CGPoint, end: CGPoint) {
        let from = position(parent, live: live), to = position(child, live: live)
        let direction = to.x < from.x ? -1.0 : 1.0
        return (CGPoint(x: from.x + direction * 145, y: from.y), CGPoint(x: to.x - direction * 145, y: to.y))
    }

    static func annotationScope(_ node: KnowledgeNode, in session: SessionRecord) -> Set<UUID> {
        var ids: Set<UUID> = [node.id]
        guard node.isCollapsed else { return ids }
        var pending = [node.id]
        while let parent = pending.popLast() {
            for child in session.nodes where !child.isDeleted && child.parentID == parent {
                if ids.insert(child.id).inserted { pending.append(child.id) }
            }
        }
        return ids
    }

    static func thoughts(_ node: KnowledgeNode, in session: SessionRecord) -> [UserThought] {
        let scope = annotationScope(node, in: session)
        let direct = Set(AnnotationPresentation.thoughts(for: node, in: session).map(\.id))
        let nested = Set(session.nodes.filter { !$0.isDeleted && scope.contains($0.id) }.compactMap(\.thoughtID))
        return session.thoughts.filter {
            !$0.isDeleted && (direct.contains($0.id) || nested.contains($0.id) || $0.attachedNodeID.map(scope.contains) == true)
        }
    }

    static func markedNodes(_ node: KnowledgeNode, in session: SessionRecord) -> [KnowledgeNode] {
        let scope = annotationScope(node, in: session)
        return session.nodes.filter {
            !$0.isDeleted && $0.id != node.id && $0.importantMarkID != nil &&
            (scope.contains($0.id) || $0.parentID.map(scope.contains) == true)
        }
    }
}

struct WorkspaceTitleDraft {
    private(set) var sessionID: UUID?
    var text = ""
    private var baseline = ""
    var isDirty: Bool { text != baseline }
    mutating func load(sessionID: UUID, title: String) {
        self.sessionID = sessionID; text = title; baseline = title
    }
    mutating func takeChange() -> (sessionID: UUID, text: String)? {
        guard let sessionID, isDirty else { return nil }
        baseline = text
        return (sessionID, text)
    }
}

enum WorkspacePopoverLayout {
    static func fittedSize(available: CGSize) -> CGSize {
        CGSize(width: min(440, max(1, available.width - 48)), height: min(560, max(1, available.height - 80)))
    }
}

struct WorkspaceDragSession {
    let origin: CanvasPoint
    let zoom: Double
    func position(start: CGPoint, current: CGPoint) -> CanvasPoint {
        CanvasDragGeometry.position(origin: origin, dx: current.x - start.x, dy: current.y - start.y, zoom: zoom)
    }
}

private struct NodeCardHeightPreference: PreferenceKey {
    static let defaultValue: [UUID: Double] = [:]
    static func reduce(value: inout [UUID: Double], nextValue: () -> [UUID: Double]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct KnowledgeCanvas: View {
    @EnvironmentObject private var store: AppStore
    let session: SessionRecord
    @State private var zoom: CGFloat = 0.92
    @State private var lastZoom: CGFloat = 0.92
    @State private var viewportSize: CGSize = CGSize(width: 1000, height: 650)
    @State private var hasFittedInitialViewport = false
    @State private var liveDragPositions: [UUID: CGPoint] = [:]
    @State private var dragSessions: [UUID: WorkspaceDragSession] = [:]
    @State private var showDetails = false
    @State private var pendingHighlightID: UUID?
    @State private var measuredCardHeights: [UUID: Double] = [:]

    private var canvasSize: CGSize {
        let maxX = visibleNodes.map(\.position.x).max() ?? 0
        let maxY = visibleNodes.map { node in
            node.position.y + (measuredCardHeights[node.id] ?? WorkspaceCanvasProjection.cardHeight(node, in: session)) / 2
        }.max() ?? 0
        return CGSize(width: max(720, maxX + 220), height: max(420, maxY + 150))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Label(showDetails ? "完整知识骨架" : "主线与重点", systemImage: "viewfinder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text("拖动节点 · 双指平移 · 捏合缩放")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                Spacer()
                Toggle("展开细节", isOn: $showDetails)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button { zoom = max(0.01, zoom - 0.1); lastZoom = zoom } label: { Image(systemName: "minus") }
                Text("\(Int(zoom * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 42)
                Button { zoom = min(1.5, zoom + 0.1); lastZoom = zoom } label: { Image(systemName: "plus") }
                Button("适合窗口", systemImage: "arrow.down.right.and.arrow.up.left") {
                    fitToWindow()
                }
            }
            .buttonStyle(.borderless)
            .disabled(!liveDragPositions.isEmpty)
            .padding(.horizontal, 18)
            .frame(height: 42)
            .background(AppTheme.paper.opacity(0.8))

            ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    graphPaper
                    Canvas { context, _ in
                        drawEdges(context: &context)
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)

                    ForEach(visibleNodes) { node in
                        NodeCard(
                            session: session,
                            node: node,
                            selected: store.selectedNodeID == node.id,
                            highlighted: store.highlightedNodeID == node.id,
                            onDragChanged: { startLocation, location in
                                let drag = dragSessions[node.id] ?? WorkspaceDragSession(origin: node.position, zoom: zoom)
                                dragSessions[node.id] = drag
                                let point = drag.position(start: startLocation, current: location)
                                liveDragPositions[node.id] = CGPoint(x: point.x, y: point.y)
                            },
                            onDragEnded: { startLocation, location in
                                let drag = dragSessions[node.id] ?? WorkspaceDragSession(origin: node.position, zoom: zoom)
                                let finalPosition = drag.position(start: startLocation, current: location)
                                liveDragPositions[node.id] = nil
                                dragSessions[node.id] = nil
                                store.updateNodePosition(
                                    node.id,
                                    point: CanvasPoint(
                                        x: finalPosition.x,
                                        y: finalPosition.y
                                    ),
                                    sessionID: session.id,
                                    displayedPositions: Dictionary(uniqueKeysWithValues: visibleNodes.map { ($0.id, $0.position) })
                                )
                            }
                        )
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: NodeCardHeightPreference.self, value: [node.id: Double(geometry.size.height)])
                            }
                        }
                        .position(livePosition(for: node))
                        .id(node.id)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .coordinateSpace(name: "knowledgeCanvas")
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: canvasSize.width * zoom, height: canvasSize.height * zoom, alignment: .topLeading)
                // A small ScrollView child is otherwise centered again whenever
                // a drag changes its bounds, shifting the whole map on release.
                .frame(minWidth: viewportSize.width, minHeight: viewportSize.height, alignment: .topLeading)
                .onPreferenceChange(NodeCardHeightPreference.self) { values in
                    guard liveDragPositions.isEmpty else { return }
                    let changed = values.filter { $0.value.isFinite && $0.value > 0 && abs((measuredCardHeights[$0.key] ?? 0) - $0.value) > 0.5 }
                    if !changed.isEmpty { measuredCardHeights.merge(changed, uniquingKeysWith: { _, next in next }) }
                }
            }
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        if liveDragPositions.isEmpty { zoom = min(1.5, max(0.01, lastZoom * value)) }
                    }
                    .onEnded { _ in lastZoom = zoom }
            )
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { updateViewport(geometry.size) }
                        .onChange(of: geometry.size) { _, size in updateViewport(size) }
                }
            }
            .onAppear { queueHighlight(store.highlightedNodeID) }
            .onChange(of: store.highlightedNodeID) { _, target in queueHighlight(target) }
            .onChange(of: session.id) { _, _ in measuredCardHeights = [:]; queueHighlight(store.highlightedNodeID) }
            .task(id: pendingHighlightID) {
                guard let target = pendingHighlightID else { return }
                // Wait for automatic detail expansion to produce its view.
                await Task.yield()
                guard !Task.isCancelled, store.highlightedNodeID == target,
                      store.selectedSessionID == session.id, liveDragPositions.isEmpty,
                      visibleNodes.contains(where: { $0.id == target }) else { return }
                proxy.scrollTo(target, anchor: .center)
                pendingHighlightID = nil
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: showDetails) { _, _ in fitToWindow() }
        .onChange(of: store.canvasFitRevisions[session.id, default: 0]) { _, _ in fitToWindow() }
        .onChange(of: session.structureSaved) { wasSaved, isSaved in
            if !wasSaved && isSaved { fitToWindow() }
        }
        .onChange(of: session.nodes.filter { !$0.isDeleted && $0.parentID == nil }.map(\.id)) { _, _ in
            if liveDragPositions.isEmpty { fitToWindow() }
        }
    }

    private var visibleNodes: [KnowledgeNode] {
        WorkspaceCanvasProjection.visibleNodes(in: session, showDetails: showDetails, measuredCardHeights: measuredCardHeights)
    }

    private func queueHighlight(_ target: UUID?) {
        guard let target, session.nodes.contains(where: { $0.id == target && !$0.isDeleted }) else { pendingHighlightID = nil; return }
        if WorkspaceCanvasProjection.requiresDetails(for: target, in: session) {
            showDetails = true
        }
        pendingHighlightID = target
    }

    private func fitToWindow() {
        guard viewportSize.width > 100, viewportSize.height > 100 else { return }
        zoom = max(0.01, min(1, min(viewportSize.width / canvasSize.width, viewportSize.height / canvasSize.height)))
        lastZoom = zoom
    }

    private func updateViewport(_ size: CGSize) {
        viewportSize = size
        guard !hasFittedInitialViewport, size.width > 100, size.height > 100 else { return }
        hasFittedInitialViewport = true
        fitToWindow()
        zoom = max(0.8, zoom)
        lastZoom = zoom
    }

    private var graphPaper: some View {
        Canvas { context, size in
            let spacing: CGFloat = 28
            var path = Path()
            stride(from: 0, through: size.width, by: spacing).forEach { x in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: 0, through: size.height, by: spacing).forEach { y in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(AppTheme.ink.opacity(0.045)), lineWidth: 0.7)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .background(AppTheme.canvas)
    }

    private func drawEdges(context: inout GraphicsContext) {
        let nodes = Dictionary(uniqueKeysWithValues: visibleNodes.map { ($0.id, $0) })
        for node in visibleNodes {
            guard let parentID = node.parentID, let parent = nodes[parentID] else { continue }
            var path = Path()
            let (start, end) = WorkspaceCanvasProjection.connection(parent: parent, child: node, live: liveDragPositions)
            path.move(to: start)
            let midX = (start.x + end.x) / 2
            path.addCurve(
                to: end,
                control1: CGPoint(x: midX, y: start.y),
                control2: CGPoint(x: midX, y: end.y)
            )
            let color = node.kind == .branch ? AppTheme.coral.opacity(0.55) : AppTheme.teal.opacity(0.46)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: node.kind == .branch ? 2.4 : 1.8, lineCap: .round))
        }
    }

    private func livePosition(for node: KnowledgeNode) -> CGPoint {
        WorkspaceCanvasProjection.position(node, live: liveDragPositions)
    }
}

private struct NodeCard: View {
    @EnvironmentObject private var store: AppStore
    let session: SessionRecord
    let node: KnowledgeNode
    let selected: Bool
    let highlighted: Bool
    let onDragChanged: (CGPoint, CGPoint) -> Void
    let onDragEnded: (CGPoint, CGPoint) -> Void
    @State private var showingRename = false
    @State private var renameDraft = ""
    @State private var showingSourcePopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
              HStack(spacing: 7) {
                Circle().fill(accent).frame(width: 8, height: 8)
                Text(node.thoughtID != nil ? "我的思考" : (node.importantMarkID != nil ? "我的重点" : node.kind.rawValue))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)
                Text("·")
                    .foregroundStyle(AppTheme.muted)
                Text(speakerLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.muted)
                Spacer()
                if isImportant {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.amber)
                }
                if node.isSecondaryEdit {
                    Text("二次编辑")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppTheme.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(AppTheme.blueSoft, in: Capsule())
                }
              }
              .contentShape(Rectangle())
              .gesture(nodeDrag)
                Button {
                    store.toggleNodeCollapsed(node.id, sessionID: session.id)
                } label: {
                    Image(systemName: node.isCollapsed ? "chevron.right" : "chevron.down")
                }
                .buttonStyle(.plain)
                .help(node.isCollapsed ? "展开分支" : "折叠分支")
            }
            VStack(alignment: .leading, spacing: 10) {
            if let role = node.navigationLabel, !role.isEmpty {
                Text(role.simplifiedChineseForDisplay)
                    .font(node.sourceBoundStatus == "summarized" ? .system(size: 16, weight: .bold) : .caption.weight(.semibold))
                    .foregroundStyle(AppTheme.teal)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let relation = node.relationToPrevious, !relation.isEmpty {
                Text(relation.simplifiedChineseForDisplay)
                    .font(.caption2).foregroundStyle(AppTheme.muted)
            }
            if hasCustomLabel, let label = node.userLabel {
                Text(label)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.blue)
                if bodyContent.isAISummary {
                    Label(summaryCaption, systemImage: "sparkles")
                        .font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.teal)
                }
                if bodyContent.text != label {
                    Text(bodyContent.text)
                        .font(NodeCardBodyContent.expandsBody(node) ? .system(size: isThoughtCard ? 16 : 14, weight: .medium) : .caption)
                        .foregroundStyle(AppTheme.muted)
                        .lineSpacing(3)
                        .lineLimit(NodeCardBodyContent.lineLimit(node, hasCustomLabel: true))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                if bodyContent.isAISummary {
                    Label(summaryCaption, systemImage: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.teal)
                }
                Text(bodyContent.text.isEmpty ? "未命名节点" : bodyContent.text)
                    .font(.system(size: isThoughtCard ? 16 : 14, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .lineSpacing(3)
                    .lineLimit(NodeCardBodyContent.lineLimit(node, hasCustomLabel: false))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if node.importantMarkID != nil, node.isSecondaryEdit,
               let authored = node.userEditedText, !authored.isEmpty, authored != bodyContent.text {
                Text("我的修改").font(.caption.bold()).foregroundStyle(AppTheme.blue)
                Text(verbatim: authored).font(.system(size: 14)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !relatedThoughts.isEmpty || hasAttachedMark {
                HStack(spacing: 10) {
                    if hasAttachedMark {
                        Label("我标过重点", systemImage: "bookmark.fill").foregroundStyle(AppTheme.amber)
                    }
                    if !relatedThoughts.isEmpty {
                        Label("我的思考 \(relatedThoughts.count)", systemImage: "quote.bubble.fill").foregroundStyle(AppTheme.blue)
                    }
                }.font(.caption2.weight(.semibold))
            }
            }
            .contentShape(Rectangle())
            .gesture(nodeDrag)
            HStack {
                if !node.sourceSpanIDs.isEmpty || node.sourceImageIDs?.isEmpty == false {
                    Label("原文可回查", systemImage: "link")
                } else {
                    Label("用户新增", systemImage: "person.crop.circle")
                }
                Spacer()
                Button {
                    store.selectedNodeID = node.id
                    showingSourcePopover = true
                } label: {
                    Text("查看原文").underline()
                }
                .buttonStyle(.link)
                .foregroundStyle(AppTheme.teal)
                .help("在此链接旁查看对应原话、重点和我的思考")
                .accessibilityIdentifier("node-source-link-\(node.id.uuidString)")
                .popover(isPresented: $showingSourcePopover, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
                    NodeDetailPanel(sessionID: session.id, nodeID: node.id, close: { showingSourcePopover = false })
                        .environmentObject(store)
                }
            }
            .font(.caption2)
            .foregroundStyle(AppTheme.muted)
        }
        .padding(14)
        .frame(width: 290, alignment: .topLeading)
        .frame(minHeight: 132, alignment: .topLeading)
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor, lineWidth: selected || highlighted ? 2.5 : 1)
        }
        .shadow(color: AppTheme.ink.opacity(selected ? 0.18 : 0.09), radius: selected ? 18 : 10, y: 6)
        .acceptSessionImages(sessionID: session.id, attachedNodeID: node.id)
        .onTapGesture { store.selectedNodeID = node.id }
        .onChange(of: store.selectedNodeID) { _, selectedID in
            if selectedID != node.id { showingSourcePopover = false }
        }
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("人工命名") {
                renameDraft = node.userLabel ?? ""
                showingRename = true
            }
            Menu("节点类型") {
                ForEach(NodeKind.allCases, id: \.self) { kind in
                    Button(kind.rawValue) { store.setNodeKind(node.id, kind: kind, sessionID: session.id) }
                }
            }
            Menu("重新连线") {
                Button("设为根节点") { store.reparentNode(node.id, to: nil, sessionID: session.id) }
                Divider()
                ForEach(session.nodes.filter { !$0.isDeleted && $0.id != node.id }) { candidate in
                    Button(String(store.nodeText(candidate, in: session).prefix(24)) + (store.nodeText(candidate, in: session).count > 24 ? "…" : "")) {
                        store.reparentNode(node.id, to: candidate.id, sessionID: session.id)
                    }
                }
            }
            if let selectedID = store.selectedNodeID,
               selectedID != node.id,
               !node.isSecondaryEdit,
               session.nodes.first(where: { $0.id == selectedID })?.isSecondaryEdit == false {
                Button("并入当前所选节点") {
                    store.mergeSourceNodes(primaryID: selectedID, secondaryID: node.id, sessionID: session.id)
                }
            }
            Button("按来源片段拆分") { store.splitNodeBySource(node.id, sessionID: session.id) }
                .disabled(node.isSecondaryEdit || node.sourceSpanIDs.count < 2)
            Divider()
            Button("移到最近删除", role: .destructive) { store.softDeleteNode(node.id, sessionID: session.id) }
        }
        .alert("人工命名节点", isPresented: $showingRename) {
            TextField("名称；原话仍会保留", text: $renameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") { store.renameNode(node.id, label: renameDraft, sessionID: session.id) }
        } message: {
            Text("这个名称会明确作为人工编辑显示，不会替换或改写节点所引用的原话。")
        }
    }

    private var nodeDrag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                showingSourcePopover = false
                store.selectedNodeID = node.id
                onDragChanged(value.startLocation, value.location)
            }
            .onEnded { value in onDragEnded(value.startLocation, value.location) }
    }

    private var accent: Color {
        switch node.kind {
        case .main: AppTheme.teal
        case .branch: AppTheme.coral
        case .evidence: AppTheme.amber
        case .thought: AppTheme.blue
        }
    }

    private var cardFill: Color {
        if node.importantMarkID != nil || hasAttachedMark { return AppTheme.amberSoft }
        switch node.kind {
        case .main: return AppTheme.paper
        case .branch: return AppTheme.coralSoft
        case .evidence: return AppTheme.amberSoft
        case .thought: return AppTheme.blueSoft
        }
    }

    private var borderColor: Color {
        if highlighted || hasAttachedMark || node.importantMarkID != nil { return AppTheme.amber }
        if selected { return accent }
        return accent.opacity(0.3)
    }

    private var sourceSpans: [TranscriptSpan] {
        session.transcript.filter { node.sourceSpanIDs.contains($0.id) }
    }

    private var speakerLabel: String {
        guard let id = sourceSpans.first?.speakerID else { return "我" }
        return store.speakerName(id, in: session)
    }

    private var isThoughtCard: Bool { node.thoughtID != nil || node.kind == .thought }
    private var isImportant: Bool { node.importantMarkID != nil || hasAttachedMark }

    private var hasCustomLabel: Bool {
        guard let label = node.userLabel, !label.isEmpty else { return false }
        return node.importantMarkID == nil || label != "重点"
    }

    private var bodyContent: NodeCardBodyContent {
        if isThoughtCard {
            return NodeCardBodyContent(text: session.thoughts.first { $0.id == node.thoughtID }?.text ?? node.userEditedText ?? "", isAISummary: false)
        }
        return NodeCardBodyContent.resolve(node: node, transcript: session.transcript, hasCustomLabel: hasCustomLabel)
    }

    private var summaryCaption: String {
        if node.importantMarkID != nil { return "AI 重点概括与要点" }
        return node.sourceBoundStatus == "extracted" ? (node.conditionOriginals?.isEmpty == false ? "原话要点 · 含说明与条件，点开查看" : "原话要点 · 模型选取") : "AI 概括 · 点击查看原文"
    }

    private var relatedThoughts: [UserThought] {
        WorkspaceCanvasProjection.thoughts(node, in: session).filter { $0.id != node.thoughtID }
    }

    private var hasAttachedMark: Bool {
        !WorkspaceCanvasProjection.markedNodes(node, in: session).isEmpty
    }
}

private struct NodeDetailPanel: View {
    @EnvironmentObject private var store: AppStore
    let sessionID: UUID
    let nodeID: UUID
    let close: () -> Void
    @State private var thought = ""
    @State private var originMessage: String?

    private var session: SessionRecord? { store.database.sessions.first { $0.id == sessionID } }
    private var node: KnowledgeNode? { session?.nodes.first { $0.id == nodeID && !$0.isDeleted } }

    var body: some View {
        if let session, let node {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(node.thoughtID != nil ? "我的思考" : (node.importantMarkID != nil ? "我的重点" : "这一段的思路"), systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭节点详情")
                    .keyboardShortcut(.cancelAction)
            }
            if let originMessage {
                Text(originMessage).font(.caption).foregroundStyle(AppTheme.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let origin = node.origin { originLink(origin) }
                    if node.importantMarkID != nil, node.thoughtID == nil, node.kind != .thought {
                        let content = NodeCardBodyContent.resolve(node: node, transcript: session.transcript, hasCustomLabel: false)
                        DetailQuote(label: content.isAISummary ? "AI 重点概括与要点 · 原文保持不变" : "我的重点",
                                    text: content.text, tint: AppTheme.amber)
                    } else if node.sourceBoundStatus == "extracted", let excerpts = node.coreOriginals {
                        ForEach(Array(excerpts.enumerated()), id: \.offset) { _, excerpt in
                            if let origin = excerpt.origin { originLink(origin) }
                            DetailQuote(label: "原话要点 · 模型选取", text: excerpt.text.simplifiedChineseForDisplay, tint: AppTheme.teal)
                        }
                    } else if let summary = node.aiSummary, !summary.isEmpty {
                        DetailQuote(label: node.sourceBoundStatus == "extracted" ? "原话要点 · 模型选取" : "AI 概括 · 原文保持不变", text: summary.simplifiedChineseForDisplay, tint: AppTheme.teal)
                    }
                    if node.sourceBoundStatus != "extracted", let excerpts = node.coreOriginals, !excerpts.isEmpty {
                        Text("核心依据 · 原话").font(.caption.bold())
                        ForEach(Array(excerpts.enumerated()), id: \.offset) { _, excerpt in
                            if let origin = excerpt.origin { originLink(origin) }
                            DetailQuote(label: "原话摘录", text: excerpt.text.simplifiedChineseForDisplay, tint: AppTheme.teal)
                        }
                    }
                    if let conditions = node.conditionOriginals, !conditions.isEmpty {
                        Text("补充论述与条件 · 原话").font(.caption.bold())
                        ForEach(Array(conditions.enumerated()), id: \.offset) { _, excerpt in
                            if let origin = excerpt.origin { originLink(origin) }
                            DetailQuote(label: "条件与说明", text: excerpt.text.simplifiedChineseForDisplay, tint: AppTheme.amber)
                        }
                    }
                    if let argument = node.argumentSummary, !argument.isEmpty {
                        DetailQuote(label: node.sourceBoundStatus == "extracted" ? "补充论述与条件 · 原话" : "方法展开 · AI 概括", text: argument.simplifiedChineseForDisplay, tint: AppTheme.teal)
                    }
                    if let relation = node.relationToPrevious, !relation.isEmpty {
                        Label(relation.simplifiedChineseForDisplay, systemImage: "arrow.turn.down.right")
                            .font(.caption).foregroundStyle(AppTheme.muted)
                    }
                    if (node.isSecondaryEdit || node.kind == .thought) && node.thoughtID == nil {
                        DetailQuote(label: node.kind == .thought ? "我的思考 · 原文" : "二次编辑", text: node.userEditedText ?? "", tint: AppTheme.blue)
                    }
                    if let archived = node.archivedSourceSpans, node.hasHistoricalEvidence(comparedTo: session.transcript) {
                        Text("编辑时的原话（旧转写）").font(.caption.bold())
                        Text("保留你当时编辑所依据的原文；下方本版附近原话仅用于定位，不替换旧依据。")
                            .font(.caption).foregroundStyle(AppTheme.muted)
                        ForEach(AnnotationPresentation.excerpts(archived)) { excerpt in
                            if let origin = excerpt.spans.first?.origin { originLink(origin) }
                            DetailQuote(label: "\(timestamp(excerpt.spans[0].startTime)) · 旧原始识别（简体）", text: excerpt.originalText, tint: AppTheme.blue, collapsible: true)
                            if let corrected = excerpt.correctedText {
                                DetailQuote(label: "当时的人工修正", text: corrected, tint: AppTheme.blue)
                            }
                        }
                    }
                    let sources = sourceSpans(node, session)
                    ImageEvidenceStrip(sessionID: session.id, imageIDs: Array(Set((node.sourceImageIDs ?? []) + (session.images ?? []).filter { $0.deletedAt == nil && $0.attachedNodeID == node.id }.map(\.id))))
                    if !sources.isEmpty {
                        Text(node.hasHistoricalEvidence(comparedTo: session.transcript) ? "本版附近原话（时间定位）" : (node.thoughtID != nil ? "思考时附近原话" : "对应原话")).font(.caption.bold())
                        ForEach(AnnotationPresentation.excerpts(sources)) { excerpt in
                        VStack(alignment: .leading, spacing: 8) {
                            let span = excerpt.spans[0]
                            if let origin = span.origin { originLink(origin) }
                            DetailQuote(
                                label: "\(excerpt.isImportant ? "★ 我的重点 · " : "")\(store.speakerName(span.speakerID, in: session)) · \(span.origin != nil && span.origin?.startTime == nil ? "导图原文" : timestamp(span.origin?.startTime ?? span.startTime)) · 原文（简体）",
                                text: excerpt.originalText,
                                tint: excerpt.isImportant ? AppTheme.amber : AppTheme.teal,
                                collapsible: true
                            )
                            if let corrected = excerpt.correctedText {
                                DetailQuote(label: "人工修正｜原文仍保留", text: corrected, tint: AppTheme.blue)
                            }
                            if excerpt.spans.contains(where: \.hasAutomaticCorrection) {
                                DetailQuote(label: "AI 校订参考｜不是原始引文", text: excerpt.spans.map(\.displayedText).joined(), tint: AppTheme.teal)
                            }
                            let uncertainties = excerpt.spans.flatMap(\.validProofreadUncertainties)
                            if !uncertainties.isEmpty {
                                Text("待确认：" + Array(Set(uncertainties)).sorted().joined(separator: "；"))
                                    .font(.caption).foregroundStyle(AppTheme.amber)
                            }
                            Button("在完整逐字稿中看这一段", systemImage: "text.magnifyingglass") {
                                close()
                                store.selectedTranscriptSpanID = span.id
                            }.buttonStyle(.link)
                        }
                        }
                    }
                    if node.isCollapsed && !WorkspaceCanvasProjection.thoughts(node, in: session).isEmpty {
                        Text("折叠分支中的思考 · 原文仍保留").font(.caption.bold()).foregroundStyle(AppTheme.blue)
                    }
                    ForEach(WorkspaceCanvasProjection.thoughts(node, in: session)) { item in
                        VStack(alignment: .trailing, spacing: 4) {
                            if item.id != node.thoughtID,
                               let origin = session.nodes.first(where: { !$0.isDeleted && $0.thoughtID == item.id })?.origin { originLink(origin) }
                            if item.id != node.thoughtID,
                               let summary = session.nodes.first(where: { !$0.isDeleted && $0.thoughtID == item.id })?.aiSummary, !summary.isEmpty {
                                DetailQuote(label: "思考概括（AI）", text: summary.simplifiedChineseForDisplay, tint: AppTheme.teal)
                            }
                            DetailQuote(label: item.isSecondaryEdit ? "我的思考 · 原文 · 二次编辑" : "我的思考 · 原文 · 听课时", text: item.text, tint: AppTheme.blue)
                            Menu("重新挂接") {
                                Button("取消挂接") { store.reattachThought(item.id, to: nil, sessionID: session.id) }
                                ForEach(session.nodes.filter { !$0.isDeleted && $0.id != node.id }) { target in
                                    Button(String(store.nodeText(target, in: session).prefix(24))) {
                                        store.reattachThought(item.id, to: target.id, sessionID: session.id)
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }
                    ForEach(WorkspaceCanvasProjection.markedNodes(node, in: session)) { markedNode in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("我的重点\(node.isCollapsed ? " · 折叠分支中" : "")").font(.caption.bold()).foregroundStyle(AppTheme.amber)
                            if let origin = markedNode.origin { originLink(origin) }
                            if let label = markedNode.userLabel, !label.isEmpty && label != "重点" {
                                DetailQuote(label: "我的标注", text: label, tint: AppTheme.blue)
                            }
                            if let summary = markedNode.aiSummary, !summary.isEmpty {
                                DetailQuote(label: "重点概括（AI）", text: summary.simplifiedChineseForDisplay, tint: AppTheme.amber)
                            }
                            let evidence = markedNode.archivedSourceSpans?.isEmpty == false ? markedNode.archivedSourceSpans! : sourceSpans(markedNode, session)
                            ForEach(AnnotationPresentation.excerpts(evidence)) { excerpt in
                                DetailQuote(label: markedNode.archivedSourceSpans?.isEmpty == false ? "标注时的原话（旧转写）" : "重点对应原话",
                                            text: excerpt.originalText, tint: AppTheme.amber, collapsible: true)
                                if let corrected = excerpt.correctedText {
                                    DetailQuote(label: "人工修正｜原文仍保留", text: corrected, tint: AppTheme.blue)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                TextField("写下我的思考，原文保留在这里", text: $thought, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addThought)
                HStack {
                Button("保存我的思考") { addThought() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.blue)
                    .disabled(thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Menu("挂接已有思考") {
                    ForEach(session.thoughts.filter { !$0.isDeleted && $0.attachedNodeID != node.id }) { item in
                        Button(String(item.text.prefix(30))) {
                            store.reattachThought(item.id, to: node.id, sessionID: session.id)
                        }
                    }
                }
                .disabled(session.thoughts.allSatisfy { $0.isDeleted || $0.attachedNodeID == node.id })
                }
            }
        }
        .padding(16)
        .background(AppTheme.paper)
        .frame(width: popoverSize.width, height: popoverSize.height)
        }
    }

    private var popoverSize: CGSize {
        let available = NSApp.keyWindow?.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        return WorkspacePopoverLayout.fittedSize(available: available)
    }

    private func sourceSpans(_ node: KnowledgeNode, _ session: SessionRecord) -> [TranscriptSpan] {
        let sources = node.sourceSpanIDs.compactMap { id in session.transcript.first(where: { $0.id == id }) }
        if !sources.isEmpty { return sources }
        guard let thought = session.thoughts.first(where: { $0.id == node.thoughtID }), let time = thought.anchorTime,
              let nearest = session.transcript.filter({ !$0.isFilteredBackground }).min(by: {
                  max($0.startTime - time, time - $0.endTime, 0) < max($1.startTime - time, time - $1.endTime, 0)
              }) else { return [] }
        return [nearest]
    }

    private func originLink(_ reference: SourceReference) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: (reference.authoredByUser == true ? "用户文字 · 来自：" : "来自：") + reference.sessionTitle).font(.caption).foregroundStyle(AppTheme.muted)
            Button("打开原记录", systemImage: "arrow.up.forward.app") {
                originMessage = nil
                store.openOrigin(reference)
                if store.activeSessions.contains(where: { $0.id == reference.sessionID }) {
                    close()
                } else {
                    originMessage = store.statusMessage
                }
            }.buttonStyle(.link)
        }
    }

    private func addThought() {
        store.addThought(thought, sessionID: sessionID, attachedNodeID: nodeID, live: false)
        thought = ""
    }

    private func timestamp(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct VersionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var processor: LocalProcessingService
    let sessionID: UUID
    @State private var candidateError: String?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("结构版本")
                .font(.title2.bold())
            if let session = store.database.sessions.first(where: { $0.id == sessionID }) {
                Button("重新整理已有材料", systemImage: "arrow.clockwise") {
                    processor.process(sessionID: sessionID, audioPaths: session.audioRelativePaths, store: store)
                    dismiss()
                }
                .disabled(processor.isProcessing(sessionID) || (session.audioRelativePaths.isEmpty && session.transcript.isEmpty && !(session.images ?? []).contains { $0.deletedAt == nil }))
                Button("重新听录音并整理", systemImage: "waveform") {
                    processor.process(sessionID: sessionID, audioPaths: session.audioRelativePaths, store: store, retranscribe: true)
                    dismiss()
                }
                .disabled(processor.isProcessing(sessionID) || session.audioRelativePaths.isEmpty)
                Text("转写有误时可重新听录音。新稿和导图先存为候选，接受前不改旧版本。")
                    .font(.caption).foregroundStyle(AppTheme.muted)
                Text("当前版本：\(session.nodes.filter { !$0.isDeleted }.count) 个节点；人工修改会在接受候选时继续保留。")
                    .foregroundStyle(AppTheme.muted)
                if let candidate = session.candidateVersions?.last {
                    GroupBox("最新候选 · \(candidate.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("候选 \(candidate.nodes.filter { !$0.isDeleted }.count) 个节点；当前 \(session.nodes.filter { !$0.isDeleted }.count) 个节点。")
                            if let warnings = candidate.analysisWarnings, !warnings.isEmpty {
                                Text(warnings.joined(separator: "\n"))
                                    .font(.caption).foregroundStyle(AppTheme.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8).background(AppTheme.amberSoft, in: RoundedRectangle(cornerRadius: 8))
                            }
                            Text("重点、思考和人工编辑内容都会保留。采用新导图会重新排版；旧图和原位置可撤回。也可以保留原位置合并。")
                                .font(.caption)
                                .foregroundStyle(AppTheme.muted)
                            if let candidateError {
                                Text(candidateError).font(.callout).foregroundStyle(AppTheme.coral)
                            }
                            let added = addedNodes(candidate: candidate, current: session.nodes)
                            let removed = removedNodes(candidate: candidate, current: session.nodes)
                            let changed = changedKindNodes(candidate: candidate, current: session.nodes)
                            if added.isEmpty && removed.isEmpty && changed.isEmpty {
                                Text("内容和节点类型没有差异。")
                                    .font(.caption)
                            } else {
                                HStack(alignment: .top, spacing: 12) {
                                    differenceColumn("候选新增", nodes: added, transcript: candidate.transcript ?? session.transcript, images: candidate.images ?? session.images ?? [], tint: AppTheme.teal)
                                    differenceColumn("当前将移除", nodes: removed, transcript: session.transcript, images: session.images ?? [], tint: AppTheme.coral)
                                    differenceColumn("类型变化", nodes: changed, transcript: candidate.transcript ?? session.transcript, images: candidate.images ?? session.images ?? [], tint: AppTheme.amber)
                                }
                            }
                            HStack {
                                Button("放弃候选") { candidateError = nil; store.discardLatestCandidate(sessionID: sessionID) }
                                Spacer()
                                Button("保留原位置合并") { acceptCandidate(candidate.id, arrangeAsNewMap: false) }
                                Button("采用新讲述导图") {
                                    acceptCandidate(candidate.id, arrangeAsNewMap: true)
                                }
                                    .buttonStyle(.borderedProminent)
                                    .tint(AppTheme.teal)
                            }
                        }
                        .padding(6)
                    }
                } else {
                    ContentUnavailableView("没有待确认候选", systemImage: "checkmark.seal")
                }
                if !session.versions.isEmpty {
                    Divider()
                    Text("可撤回历史")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(session.versions.reversed()) { version in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(version.reason)
                                Text("\(version.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(version.nodes.filter { !$0.isDeleted }.count) 个节点")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        }
        .frame(width: 620, height: 600)
    }

    private func acceptCandidate(_ candidateID: UUID, arrangeAsNewMap: Bool) {
        candidateError = nil
        store.acceptLatestCandidate(sessionID: sessionID, arrangeAsNewMap: arrangeAsNewMap)
        let remains = store.database.sessions.first { $0.id == sessionID }?.candidateVersions?.contains { $0.id == candidateID } == true
        if remains {
            candidateError = store.statusMessage ?? "候选未能应用；当前版本和原文没有被替换。"
        } else if arrangeAsNewMap {
            dismiss()
        }
    }

    private func signature(_ node: KnowledgeNode) -> String {
        StructureVersionMerge.signature(node)
    }

    private func addedNodes(candidate: StructureSnapshot, current: [KnowledgeNode]) -> [KnowledgeNode] {
        let currentSignatures = Set(current.filter { !$0.isDeleted }.map(signature))
        return StructureVersionMerge.merge(current: current, candidate: candidate.nodes)
            .filter { !$0.isDeleted && !currentSignatures.contains(signature($0)) }
    }

    private func removedNodes(candidate: StructureSnapshot, current: [KnowledgeNode]) -> [KnowledgeNode] {
        let candidateSignatures = Set(StructureVersionMerge.merge(current: current, candidate: candidate.nodes).map(signature))
        return current.filter { !$0.isDeleted && !candidateSignatures.contains(signature($0)) }
    }

    private func changedKindNodes(candidate: StructureSnapshot, current: [KnowledgeNode]) -> [KnowledgeNode] {
        var currentKinds: [String: NodeKind] = [:]
        for node in current where !node.isDeleted { currentKinds[signature(node)] = node.kind }
        return StructureVersionMerge.merge(current: current, candidate: candidate.nodes).filter { node in
            guard !node.isDeleted, let kind = currentKinds[signature(node)] else { return false }
            return kind != node.kind
        }
    }

    private func differenceColumn(_ title: String, nodes: [KnowledgeNode], transcript: [TranscriptSpan], images: [ImageAttachment], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(title) · \(nodes.count)")
                .font(.caption.bold())
                .foregroundStyle(tint)
            ForEach(nodes.prefix(4)) { node in
                Text(IntegrityValidator.visibleText(for: node, transcript: transcript, images: images))
                    .font(.caption2)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DetailQuote: View {
    let label: String
    let text: String
    let tint: Color
    var collapsible = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            if collapsible && text.count > 600 && !expanded {
                Text("原文开头预览 · 非完整原话").font(.caption2).foregroundStyle(AppTheme.muted)
            }
            Text(verbatim: collapsible && text.count > 600 && !expanded ? String(text.prefix(360)) + "…" : text)
                .font(.callout)
                .foregroundStyle(AppTheme.ink)
                .lineSpacing(3)
                .textSelection(.enabled)
            if collapsible && text.count > 600 {
                Button(expanded ? "收起长原文" : "展开完整原文") { expanded.toggle() }
                    .buttonStyle(.link)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: 96, alignment: .topLeading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.18)) }
    }
}

private struct AddNodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let sessionID: UUID
    let parentID: UUID?
    @State private var text = ""
    @State private var kind: NodeKind = .main

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新增节点")
                .font(.title2.bold())
            Text("这是用户在直播结束后的新内容，保存后会明确标记“二次编辑”。")
                .foregroundStyle(AppTheme.muted)
            Picker("类型", selection: $kind) {
                ForEach(NodeKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 130)
                .padding(8)
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(AppTheme.line) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存二次编辑") {
                    store.addUserNode(text, kind: kind, parentID: parentID, sessionID: sessionID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.blue)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

import KnowledgeSpineCore
import SwiftUI

/// Selection expands a branch without expanding its sentences on screen.
/// This only projects existing course content; it never invents topic names.
enum MergeCourseProjection {
    static let previewLimit = 6
    static let pageSize = 12

    static func activeNodes(_ session: SessionRecord) -> [KnowledgeNode] {
        session.nodes.filter { !$0.isDeleted }
    }

    static func topicPreview(_ session: SessionRecord) -> [KnowledgeNode] {
        let active = activeNodes(session)
        let roots = Set(active.filter { $0.parentID == nil }.map(\.id))
        return Array(active.filter {
            ($0.parentID == nil || roots.contains($0.parentID!)) &&
            $0.kind != .thought && $0.thoughtID == nil && $0.importantMarkID == nil &&
            !($0.aiSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.prefix(previewLimit))
    }

    static func subtree(_ nodeID: UUID, in session: SessionRecord) -> Set<UUID> {
        let active = activeNodes(session)
        guard active.contains(where: { $0.id == nodeID }) else { return [] }
        let children = Dictionary(grouping: active.compactMap { node in node.parentID.map { ($0, node.id) } }, by: { $0.0 })
        var result = Set<UUID>(), pending = [nodeID]
        while let id = pending.popLast() {
            guard result.insert(id).inserted else { continue }
            pending.append(contentsOf: (children[id] ?? []).map { $0.1 })
        }
        return result
    }

    static func page(_ session: SessionRecord, index: Int) -> [KnowledgeNode] {
        Array(activeNodes(session).dropFirst(max(0, index) * pageSize).prefix(pageSize))
    }
}

struct MergeCourseSelection {
    var wholeSessionIDs = Set<UUID>()
    var topicNodeIDs = Set<UUID>()

    mutating func toggleWhole(_ session: SessionRecord) {
        if wholeSessionIDs.contains(session.id) { wholeSessionIDs.remove(session.id) }
        else { wholeSessionIDs.insert(session.id) }
        topicNodeIDs.subtract(MergeCourseProjection.activeNodes(session).map(\.id))
    }

    mutating func toggleTopic(_ nodeID: UUID, in session: SessionRecord) {
        let subtree = MergeCourseProjection.subtree(nodeID, in: session)
        guard !subtree.isEmpty else { return }
        wholeSessionIDs.remove(session.id)
        if subtree.isSubset(of: topicNodeIDs) { topicNodeIDs.subtract(subtree) }
        else { topicNodeIDs.formUnion(subtree) }
    }

    func selectedCourseCount(in sessions: [SessionRecord]) -> Int {
        sessions.filter { wholeSessionIDs.contains($0.id) || !topicNodeIDs.isDisjoint(with: MergeCourseProjection.activeNodes($0).map(\.id)) }.count
    }

    func scope(in sessions: [SessionRecord]) -> (whole: Set<UUID>, topics: Set<UUID>) {
        let whole = wholeSessionIDs.intersection(sessions.map(\.id))
        let partial = sessions.filter { !whole.contains($0.id) }.flatMap { MergeCourseProjection.activeNodes($0).map(\.id) }
        return (whole, topicNodeIDs.intersection(partial))
    }
}

struct MergeAreaView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection = MergeCourseSelection()
    @State private var expandedCourses = Set<UUID>()
    @State private var detailSessionID: UUID?
    @State private var title = ""
    @State private var submissionMessage: String?
    var onCombine: ((String, Set<UUID>, Set<UUID>) -> UUID?)? = nil
    let open: (UUID) -> Void

    private var selectedCount: Int { selection.selectedCourseCount(in: store.activeSessions) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("整合知识").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("选课程或已有主题，让本地模型整理成一张专题导图。原课、原图和原话都会保留。")
                    .foregroundStyle(AppTheme.muted)
            }
            HStack(spacing: 12) {
                TextField("专题名称（可选）", text: $title).textFieldStyle(.roundedBorder)
                Text("已选 \(selectedCount) 份记录").font(.callout).foregroundStyle(AppTheme.muted)
                Button("整理成专题导图", action: combine)
                    .buttonStyle(.borderedProminent).tint(AppTheme.teal)
                    .disabled(selectedCount == 0 || onCombine == nil)
            }
            if onCombine == nil {
                Text("整合处理入口暂不可用；现有记录不会改变。")
                    .font(.caption).foregroundStyle(AppTheme.muted)
            }
            if let submissionMessage { Text(submissionMessage).font(.callout).foregroundStyle(AppTheme.coral) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.activeSessions.isEmpty {
                        ContentUnavailableView("还没有可整合的课程", systemImage: "books.vertical")
                    }
                    ForEach(store.activeSessions) { session in courseCard(session) }
                }
            }
        }
        .padding(28)
        .sheet(isPresented: Binding(get: { detailSessionID != nil }, set: { if !$0 { detailSessionID = nil } })) {
            if let id = detailSessionID, let session = store.activeSessions.first(where: { $0.id == id }) {
                MergeDetailSelectionSheet(session: session, selection: $selection)
            }
        }
    }

    private func courseCard(_ session: SessionRecord) -> some View {
        let whole = selection.wholeSessionIDs.contains(session.id)
        let partial = !selection.topicNodeIDs.isDisjoint(with: MergeCourseProjection.activeNodes(session).map(\.id))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button { selection.toggleWhole(session) } label: {
                    Image(systemName: whole ? "checkmark.circle.fill" : (partial ? "minus.circle.fill" : "circle"))
                        .font(.title2).foregroundStyle(whole || partial ? AppTheme.teal : AppTheme.muted)
                }.buttonStyle(.plain).help("选择或取消整课")
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.headline).lineLimit(2)
                    Text(whole ? "已选整课 · 包含原稿、重点和思考" : (partial ? "已选部分内容 · 自动包含所选分支的后代与引用" : "可选整课，也可选择已有主题"))
                        .font(.caption).foregroundStyle(AppTheme.muted)
                }
                Spacer(minLength: 8)
                Button(whole ? "取消整课" : "选择整课") { selection.toggleWhole(session) }
                Button(expandedCourses.contains(session.id) ? "收起主题" : "选择主题") {
                    if !expandedCourses.insert(session.id).inserted { expandedCourses.remove(session.id) }
                }.buttonStyle(.borderless)
            }
            if expandedCourses.contains(session.id) {
                Divider()
                let topics = MergeCourseProjection.topicPreview(session)
                if topics.isEmpty {
                    Text("尚未整理为主题，可先选整课。不会把旧版逐句节点当作主题铺开。")
                        .font(.callout).foregroundStyle(AppTheme.muted)
                } else {
                    Text("已有主题预览 · 最多显示 \(MergeCourseProjection.previewLimit) 项")
                        .font(.caption).foregroundStyle(AppTheme.muted)
                    ForEach(topics) { node in
                        MergeTopicSelectionRow(session: session, node: node, selection: $selection)
                    }
                }
                Button("展开选择细节…") { detailSessionID = session.id }
                    .buttonStyle(.link)
                Text("选中主题会包含全部下级内容；只有主动展开细节才逐项选择。")
                    .font(.caption).foregroundStyle(AppTheme.muted)
            }
        }
        .padding(16)
        .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(whole || partial ? AppTheme.teal.opacity(0.5) : AppTheme.line))
    }

    private func combine() {
        submissionMessage = nil
        let scope = selection.scope(in: store.activeSessions)
        guard let onCombine, !scope.whole.isEmpty || !scope.topics.isEmpty else { return }
        if let id = onCombine(title, scope.whole, scope.topics) { open(id) }
        else { submissionMessage = store.statusMessage ?? "尚未创建专题导图；所选内容仍保留，请稍后重试。" }
    }
}

private struct MergeTopicSelectionRow: View {
    let session: SessionRecord
    let node: KnowledgeNode
    @Binding var selection: MergeCourseSelection

    var body: some View {
        let subtree = MergeCourseProjection.subtree(node.id, in: session)
        let whole = selection.wholeSessionIDs.contains(session.id)
        let selected = whole || subtree.isSubset(of: selection.topicNodeIDs)
        let partial = !subtree.isDisjoint(with: selection.topicNodeIDs)
        Button { selection.toggleTopic(node.id, in: session) } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : (partial ? "minus.square.fill" : "square"))
                    .foregroundStyle(selected || partial ? AppTheme.teal : AppTheme.muted)
                Text(IntegrityValidator.visibleText(for: node, transcript: session.transcript))
                    .font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if subtree.count > 1 { Text("含下级").font(.caption).foregroundStyle(AppTheme.muted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .help(whole ? "当前已选整课；点击后改为仅选此项及全部下级" : "选择此项及全部下级内容")
    }
}

private struct MergeDetailSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: SessionRecord
    @Binding var selection: MergeCourseSelection
    @State private var page = 0

    private var pageCount: Int { max(1, (MergeCourseProjection.activeNodes(session).count + MergeCourseProjection.pageSize - 1) / MergeCourseProjection.pageSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选择细节").font(.title2.bold())
            Text(session.title).font(.headline)
            Text("这里是原图中的内容，不代表已经归纳好的主题。每次只显示 \(MergeCourseProjection.pageSize) 项；选择分支仍包含全部下级。")
                .font(.caption).foregroundStyle(AppTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(MergeCourseProjection.page(session, index: page)) { node in
                        MergeTopicSelectionRow(session: session, node: node, selection: $selection)
                        Divider()
                    }
                }
            }
            HStack {
                Button("上一页") { page -= 1 }.disabled(page == 0)
                Text("\(page + 1) / \(pageCount)").font(.caption).foregroundStyle(AppTheme.muted)
                Button("下一页") { page += 1 }.disabled(page + 1 >= pageCount)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 580, height: 580)
    }
}

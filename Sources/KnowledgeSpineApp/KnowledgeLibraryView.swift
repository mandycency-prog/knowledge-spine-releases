import AppKit
import KnowledgeSpineCore
import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeLibraryBrowser: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var processor: LocalProcessingService
    @Binding var showingNewSession: Bool
    let openSession: (UUID) -> Void
    @State private var naming: LibraryNameRequest?
    @State private var selection = Set<UUID>()
    @State private var isSelecting = false

    private var selectedRecords: [SessionRecord] { store.activeSessions.filter { selection.contains($0.id) } }
    private var currentCollection: KnowledgeCollection? { store.collections.first { $0.id == store.selectedCollectionID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("知识库").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("一张图是一场积累。按主题收纳，原文、重点和思考一起留下。")
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Button("导入导图", systemImage: "square.and.arrow.down") { importMaps() }
                Menu {
                    Button("录制一场课程") { showingNewSession = true }
                    Button("新建空白导图") { naming = .init(kind: .map, title: "新建空白导图", value: "") }
                } label: { Label("新建", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .padding(9).background(AppTheme.tealSoft, in: RoundedRectangle(cornerRadius: 9))
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.muted)
                TextField("全库搜索：标题、节点、我的思考、逐字稿", text: $store.searchText)
                    .textFieldStyle(.plain)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }
            }.padding(13).appCard(radius: 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    themeButton("全部 · \(store.activeSessions.count)", id: nil)
                    ForEach(store.collections) { collection in
                        let count = store.activeSessions.filter { collection.sessionIDs.contains($0.id) }.count
                        themeButton("\(collection.name) · \(count)", id: collection.id)
                            .contextMenu {
                                Button("重命名主题") { naming = .init(kind: .rename(collection.id), title: "重命名主题", value: collection.name) }
                                Button("移除主题（保留所有记录）") { store.removeCollection(collection.id) }
                            }
                    }
                    Button("新建主题", systemImage: "folder.badge.plus") { naming = .init(kind: .collection, title: "新建主题", value: "") }
                        .buttonStyle(.borderless)
                }
            }
            if !store.searchText.isEmpty {
                Text("正在搜索整个知识库，不受主题筛选限制。")
                    .font(.caption).foregroundStyle(AppTheme.muted)
                SearchResultsView(openSession: openSession)
            } else {
                libraryActions
                if store.librarySessions.isEmpty {
                    ContentUnavailableView(currentCollection == nil ? "从第一张导图开始" : "这个主题还没有导图",
                        systemImage: "books.vertical", description: Text("录制课程、创建空白图，或导入 .kspine 导图包、Markdown 层级提纲。所有内容留在本机。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 18)], spacing: 18) {
                            ForEach(store.librarySessions) { session in
                                SessionCard(session: session) {
                                    if isSelecting {
                                        if selection.contains(session.id) { selection.remove(session.id) }
                                        else { selection.insert(session.id) }
                                    } else { openSession(session.id) }
                                }
                                .overlay(alignment: .topTrailing) {
                                    if isSelecting {
                                        Image(systemName: selection.contains(session.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title2).foregroundStyle(AppTheme.blue).padding(12).allowsHitTesting(false)
                                    }
                                }
                                .contextMenu { LibraryRecordMenu(session: session, requestNewTheme: {
                                    naming = .init(kind: .collectionFor(session.id), title: "收纳到新主题", value: "")
                                }) }
                            }
                        }.padding(3)
                    }
                }
            }
        }
        .padding(28)
        .sheet(item: $naming) { request in
            LibraryNameSheet(title: request.title, initialValue: request.value) { name in handleName(name, request: request) }
        }
        .onChange(of: store.selectedCollectionID) { _, _ in selection.removeAll() }
        .onChange(of: store.activeSessions.map(\.id)) { _, ids in selection.formIntersection(ids) }
    }

    private var libraryActions: some View {
        HStack {
            Text(isSelecting ? "已选择 \(selection.count) 张图" : "\(currentCollection?.name ?? "全部记录") · \(store.librarySessions.count) 张图")
                .font(.callout.weight(.medium))
            Spacer()
            if isSelecting {
                Button("全选") { selection = Set(store.librarySessions.map(\.id)) }
                Menu("收纳到主题") {
                    ForEach(store.collections) { collection in
                        Button(collection.name) {
                            for id in selection { store.setCollectionMembership(sessionID: id, collectionID: collection.id, included: true) }
                        }
                    }
                }.disabled(selection.isEmpty || store.collections.isEmpty)
                Button("整合成专题图") { naming = .init(kind: .combine, title: "给专题导图命名", value: "") }
                    .disabled(selection.count < 2)
                Button("导出所选导图包") { LibraryFileActions.exportMaps(selectedRecords, store: store) }.disabled(selection.isEmpty)
            } else {
                Button(currentCollection == nil ? "导出全部导图" : "导出此主题导图") {
                    LibraryFileActions.exportMaps(store.librarySessions, store: store)
                }.disabled(store.librarySessions.isEmpty)
            }
            Button(isSelecting ? "完成选择" : "选择多张") { isSelecting.toggle(); selection.removeAll() }
        }.controlSize(.small)
    }

    private func themeButton(_ name: String, id: UUID?) -> some View {
        Button { store.selectedCollectionID = id } label: {
            Text(name).font(.callout).padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(store.selectedCollectionID == id ? AppTheme.teal : AppTheme.muted)
                .background(store.selectedCollectionID == id ? AppTheme.tealSoft : AppTheme.paper, in: Capsule())
        }.buttonStyle(.plain)
    }

    private func handleName(_ name: String, request: LibraryNameRequest) {
        switch request.kind {
        case .collection: _ = store.createCollection(named: name)
        case .collectionFor(let sessionID):
            if let id = store.createCollection(named: name) { store.setCollectionMembership(sessionID: sessionID, collectionID: id, included: true) }
        case .rename(let id): store.renameCollection(id, to: name)
        case .map:
            let id = store.createSession(title: name, sourceName: "我的知识整理", sourceKind: "手工导图")
            openSession(id)
        case .combine:
            if let id = store.createIntegrationRecord(title: name, wholeSessionIDs: selection, topicNodeIDs: []) {
                processor.process(sessionID: id, audioPaths: [], store: store)
                openSession(id)
            }
        }
    }

    private func importMaps() {
        let panel = NSOpenPanel()
        panel.title = "导入导图：.kspine 导图包或 Markdown 提纲"
        panel.message = "导入为新的独立记录，不覆盖现有内容。导图包包含原文、标注和版本，不包含录音。"
        panel.allowedContentTypes = [.data, .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        do {
            var imported: [SessionRecord] = []
            var packages: [Data] = []
            var outlines: [(String, String)] = []
            var bytes = 0
            for url in panel.urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= PortableMindMap.maximumBytes, bytes <= 64 * 1024 * 1024 - size else {
                    throw LibraryFileError.message("本次导入过大，请分批导入；单个导图包不超过 32 MB。")
                }
                let data = try Data(contentsOf: url)
                bytes += data.count
                switch url.pathExtension.lowercased() {
                case PortableMindMap.fileExtension:
                    packages.append(data)
                case "md", "markdown", "txt":
                    guard let text = String(data: data, encoding: .utf8) else { throw LibraryFileError.message("文本必须使用 UTF-8 编码。") }
                    outlines.append((text, url.deletingPathExtension().lastPathComponent))
                default: throw LibraryFileError.message("暂支持 .kspine 导图包和 Markdown 层级提纲；不把图片或 PDF 冒充可编辑导图。")
                }
            }
            if !packages.isEmpty { imported = try PortableMindMap.importBatch(packages, existingSessions: store.database.sessions) }
            for (text, title) in outlines {
                imported.append(try PortableMindMap.importMarkdown(text, title: title, existingSessions: store.database.sessions + imported))
            }
            let ids = store.addLibraryRecords(imported, collectionID: store.selectedCollectionID)
            if !ids.isEmpty { store.statusMessage = "已导入 \(ids.count) 张导图，原知识库未被覆盖。" }
        } catch { store.statusMessage = "导入未完成，原知识库未改变：\(error)" }
    }
}

struct LibraryRecordMenu: View {
    @EnvironmentObject private var store: AppStore
    let session: SessionRecord
    let requestNewTheme: () -> Void
    var body: some View {
        Menu("收纳到主题") {
            ForEach(store.collections) { collection in
                let included = collection.sessionIDs.contains(session.id)
                Button(included ? "✓ \(collection.name)（移出）" : collection.name) {
                    store.setCollectionMembership(sessionID: session.id, collectionID: collection.id, included: !included)
                }
            }
            Button("新建主题…", action: requestNewTheme)
        }
        Button("导出可编辑导图包") { LibraryFileActions.exportMaps([session], store: store) }
    }
}

@MainActor enum LibraryFileActions {
    static func exportMaps(_ sessions: [SessionRecord], store: AppStore) {
        guard !sessions.isEmpty else { return }
        do {
            let prepared = try store.preparePortableSessions(sessions)
            let data = try PortableMindMap.exportData(sessions: prepared)
            let panel = NSSavePanel()
            panel.title = "导出可继续编辑的导图包"
            panel.message = "包括逐字稿、原图、思考、重点和版本；不包含音频或本机模型设置。"
            panel.nameFieldStringValue = (sessions.count == 1 ? String(sessions[0].title.prefix(60)).replacingOccurrences(of: "/", with: "-") : "知识库-\(sessions.count)张导图") + ".kspine"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            store.statusMessage = "已导出 \(sessions.count) 张可编辑导图。导入时会创建独立副本，不覆盖原记录。"
        } catch { store.statusMessage = "导图包导出失败：\(error)" }
    }
}

private enum LibraryFileError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private struct LibraryNameRequest: Identifiable {
    enum Kind { case collection, collectionFor(UUID), rename(UUID), map, combine }
    let id = UUID()
    let kind: Kind
    let title: String
    let value: String
}

private struct LibraryNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initialValue: String
    let save: (String) -> Void
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.bold())
            TextField("名称", text: $value).textFieldStyle(.roundedBorder).onSubmit(submit)
            HStack { Button("取消") { dismiss() }; Spacer(); Button("确定", action: submit).keyboardShortcut(.defaultAction).disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 410).onAppear { value = initialValue }
    }
    private func submit() {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismiss()
        save(value)
    }
}

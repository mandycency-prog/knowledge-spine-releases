import AppKit
import KnowledgeSpineCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var capture: CaptureService
    @EnvironmentObject private var processor: LocalProcessingService
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingNewSession = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(showingNewSession: $showingNewSession)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if capture.isRecording, let warning = capture.signalWarning {
                    HStack {
                        Label(warning, systemImage: "speaker.slash.fill")
                        Spacer()
                        Button("查看声音来源") { openWindow(id: "capture") }
                    }
                    .font(.callout)
                    .padding(12)
                    .background(AppTheme.amberSoft)
                    .accessibilityElement(children: .contain)
                }
                if let session = store.selectedSession, session.deletedAt == nil {
                    SessionWorkspace(session: session) {
                        store.selectedSessionID = nil
                        store.selectedNodeID = nil
                        columnVisibility = .all
                    }
                    .id(session.id)
                    .onAppear { columnVisibility = .detailOnly }
                } else {
                    sectionView
                }
            }
            .background(AppTheme.canvas)
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionSheet { id in
                store.selectedSessionID = id
                columnVisibility = .detailOnly
                openWindow(id: "capture")
            }
        }
        .alert("本地状态", isPresented: Binding(
            get: { store.statusMessage != nil },
            set: { if !$0 { store.statusMessage = nil } }
        )) {
            Button("知道了") { store.statusMessage = nil }
        } message: {
            Text(store.statusMessage ?? "")
        }
        .task {
            // UI acceptance never starts inference just because a fixture has
            // a pending annotation or recovery flag. Production is unchanged.
            if Bundle.main.bundleIdentifier != "com.local.knowledgespine.acceptance" {
                await processor.validateModelsAndRecoverIfNeeded(store: store)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.flush()
        }
    }

    @ViewBuilder
    private var sectionView: some View {
        switch store.selectedSection {
        case .library:
            LibraryView(showingNewSession: $showingNewSession) { id in
                store.selectSession(id)
                columnVisibility = .detailOnly
            }
        case .merge:
            MergeAreaView(onCombine: { title, whole, topics in
                guard let id = store.createIntegrationRecord(title: title, wholeSessionIDs: whole, topicNodeIDs: topics) else { return nil }
                processor.process(sessionID: id, audioPaths: [], store: store)
                return id
            }) { id in
                store.selectSession(id)
                columnVisibility = .detailOnly
            }
        case .trash:
            TrashView()
        case .settings:
            SettingsView()
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showingNewSession: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.ink)
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("知识骨架")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("概括可回查原话")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
            }
            .padding(16)

            Button {
                showingNewSession = true
            } label: {
                Label("新建记录", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.teal)
            .controlSize(.large)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            List(selection: $store.selectedSection) {
                Section {
                    ForEach(AppSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.symbol)
                            .tag(section)
                    }
                }
                Section("最近记录") {
                    ForEach(store.activeSessions.prefix(7)) { session in
                        Button {
                            store.selectSession(session.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title)
                                    .lineLimit(1)
                                Text(session.status.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.muted)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct LibraryView: View {
    @Binding var showingNewSession: Bool
    let openSession: (UUID) -> Void
    var body: some View {
        KnowledgeLibraryBrowser(showingNewSession: $showingNewSession, openSession: openSession)
    }
}

struct SearchResultsView: View {
    @EnvironmentObject private var store: AppStore
    let openSession: (UUID) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if store.searchHits.isEmpty {
                    ContentUnavailableView("没有找到", systemImage: "magnifyingglass", description: Text("换一个词试试。"))
                        .padding(.top, 80)
                }
                ForEach(store.searchHits) { hit in
                    Button {
                        openSession(hit.sessionID)
                        store.selectSearchHit(hit)
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Text(hit.kind.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.teal)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AppTheme.tealSoft, in: Capsule())
                            VStack(alignment: .leading, spacing: 5) {
                                Text(hit.title).font(.headline).foregroundStyle(AppTheme.ink)
                                Text(hit.excerpt)
                                    .lineLimit(2)
                                    .foregroundStyle(AppTheme.muted)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(AppTheme.muted)
                        }
                        .padding(15)
                        .appCard(radius: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 30)
        }
    }
}

struct SessionCard: View {
    let session: SessionRecord
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(session.isMergedRecord ? "综合记录" : session.sourceKind, systemImage: session.isMergedRecord ? "point.3.connected.trianglepath.dotted" : "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(session.isMergedRecord ? AppTheme.blue : AppTheme.teal)
                    Spacer()
                    Text(session.status.rawValue)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.muted)
                }
                Text(session.title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                HStack(spacing: 14) {
                    Label("\(session.nodes.filter { !$0.isDeleted }.count) 节点", systemImage: "circle.grid.cross")
                    let effectiveCount = session.transcript.filter { !$0.isFilteredBackground }.count
                    let filteredCount = session.transcript.count - effectiveCount
                    Label(
                        filteredCount > 0 ? "\(effectiveCount) 有效 · \(filteredCount) 已过滤" : "\(effectiveCount) 片段",
                        systemImage: filteredCount > 0 ? "waveform.badge.checkmark" : "text.alignleft"
                    )
                    let imageCount = (session.images ?? []).filter { $0.deletedAt == nil }.count
                    if imageCount > 0 { Label("\(imageCount) 图片", systemImage: "photo") }
                }
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
                Divider()
                HStack {
                    Text(session.sourceName).lineLimit(1)
                    Spacer()
                    Text(session.updatedAt, format: .dateTime.month().day())
                }
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .appCard(radius: 18)
        }
        .buttonStyle(.plain)
    }
}

private struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var title = ""
    let created: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("新建一场记录")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("下一步在录制浮窗里选择应用、窗口或全系统声音。")
                    .foregroundStyle(AppTheme.muted)
            }
            TextField("标题可以稍后再改", text: $title)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
            HStack {
                Label(store.analysisProvider == "api" ? "本地录音 · API 整理" : "全程本地", systemImage: "lock.fill")
                Spacer()
                Text(store.analysisProvider == "api" ? "音频不上传，整理文字发送至所选服务商" : "不调用云端 API")
            }
            .font(.callout)
            .foregroundStyle(AppTheme.teal)
            .padding(14)
            .background(AppTheme.tealSoft, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("创建并选择声音") {
                    let id = store.createSession(title: title, sourceName: "尚未选择", sourceKind: "系统声音")
                    dismiss()
                    created(id)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.teal)
            }
        }
        .padding(26)
        .frame(width: 480)
    }
}

struct TrashView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("最近删除")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("知识骨架和我的思考保留 30 天。这里不做无提示的立即永久删除。")
                .foregroundStyle(AppTheme.muted)
            if store.deletedSessions.isEmpty {
                ContentUnavailableView("最近没有删除的记录", systemImage: "trash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.deletedSessions) { session in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(session.title)
                            if let deletedAt = session.deletedAt {
                                Text("删除于 \(deletedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(AppTheme.muted)
                            }
                        }
                        Spacer()
                        Button("恢复") { store.restoreSession(session.id) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(32)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var processor: LocalProcessingService
    @State private var newAPIKey = ""
    @State private var keySaved = false
    @State private var credentialMessage: String?
    @State private var testingAPI = false
    @State private var connectionMessage: String?
    @FocusState private var apiKeyFocused: Bool

    var body: some View {
        Form {
            Section("分析方式") {
                Picker("整理与分析", selection: $store.analysisProvider) {
                    Text("本地模型").tag("local")
                    Text("API 服务").tag("api")
                }.pickerStyle(.segmented)
                Text("本地模式不发送课程内容到云端；API 模式使用你指定的服务商。调用失败不会自动切换服务或改用另一种模式。")
                    .font(.caption).foregroundStyle(AppTheme.muted)
            }
            Section("自定义 API") {
                Text("可连接兼容 Chat Completions 协议的服务")
                HStack {
                    Button("填入 DeepSeek") {
                        store.apiConfiguration = APIConfiguration(
                            baseURL: "https://api.deepseek.com",
                            model: "deepseek-flash",
                            contextWindow: 1_000_000,
                            maxOutputTokens: 16384,
                            tokenLimitField: "max_tokens",
                            thinkingMode: "enabled"
                        )
                        apiKeyFocused = true
                    }
                    Button("填入小米 MiMo") {
                        var config = APIConfiguration(baseURL: "https://api.xiaomimimo.com/v1", model: "mimo-v2.6-pro", contextWindow: 131072, maxOutputTokens: 8192, tokenLimitField: "max_completion_tokens")
                        config.thinkingMode = "enabled"
                        store.apiConfiguration = config
                    }
                    Spacer()
                    Link("获取 DeepSeek 密钥", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                }
                Text("填写你选择的服务商的地址、密钥和模型名即可。快捷填入仅供方便，不绑定厂商、不切换模式、不自动同意发送。")
                    .font(.caption).foregroundStyle(AppTheme.muted)
                TextField("API 地址（服务商提供的 Base URL 或完整 chat/completions 地址）", text: apiBinding(\.baseURL))
                TextField("模型名称", text: apiBinding(\.model))
                if let issue = endpointIssue {
                    Text(issue).font(.caption).foregroundStyle(AppTheme.coral)
                }
                HStack {
                    SecureField("输入新 API 密钥（不会显示已保存密钥）", text: $newAPIKey)
                        .focused($apiKeyFocused)
                    Button("保存密钥") {
                        do {
                            try APICredentials.save(newAPIKey, endpoint: store.apiConfiguration.baseURL)
                            newAPIKey = ""
                            refreshCredentialStatus()
                            credentialMessage = "密钥已保存到本机钥匙串；尚未测试连接。"
                        } catch { credentialMessage = error.localizedDescription }
                    }.disabled(newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpointIssue != nil || store.apiConfiguration.baseURL.isEmpty)
                    Button("删除密钥", role: .destructive) {
                        do {
                            try APICredentials.delete(endpoint: store.apiConfiguration.baseURL)
                            keySaved = false
                            newAPIKey = ""
                            credentialMessage = "已删除此服务地址的密钥。"
                        } catch { credentialMessage = error.localizedDescription }
                    }.disabled(!keySaved)
                }
                Text(keySaved ? "此地址已有密钥（仅表示已保存，不代表连接成功）" : "此地址尚未保存密钥")
                    .font(.caption).foregroundStyle(AppTheme.muted)
                if let credentialMessage {
                    Text(credentialMessage).font(.caption).textSelection(.enabled)
                }
                DisclosureGroup("高级参数") {
                    TextField("上下文窗口（tokens）", value: apiBinding(\.contextWindow), format: .number)
                    TextField("最大输出预算（含模型思考，tokens）", value: apiBinding(\.maxOutputTokens), format: .number)
                    Picker("输出上限参数", selection: apiBinding(\.tokenLimitField)) {
                        Text("max_tokens").tag("max_tokens")
                        Text("max_completion_tokens").tag("max_completion_tokens")
                    }
                    Toggle("请求 JSON 输出模式", isOn: apiBinding(\.jsonMode))
                    Picker("思考模式", selection: Binding(get: { store.apiConfiguration.thinkingMode ?? "" }, set: { value in
                        var config = store.apiConfiguration
                        config.thinkingMode = value.isEmpty ? nil : value
                        store.apiConfiguration = config
                    })) {
                        Text("不指定（服务商默认）").tag("")
                        Text("启用").tag("enabled")
                        Text("关闭").tag("disabled")
                    }
                    Text("参数需与你的服务商和模型一致；上下文与输出预算不是实际用量或费用上限。")
                        .font(.caption).foregroundStyle(AppTheme.muted)
                }
                Toggle(isOn: Binding(get: { store.apiConfiguration.isApproved }, set: { approved in
                    var config = store.apiConfiguration
                    config.approvedEndpoint = approved ? config.baseURL : nil
                    store.apiConfiguration = config
                })) {
                    Text("我同意在 API 模式下，将我发起的整理任务所需的逐字稿、问题及相关思考发送给以上服务商，并了解可能产生费用。")
                }.disabled(endpointIssue != nil || store.apiConfiguration.baseURL.isEmpty)
                Text("文字分析只发送任务所需文字，不上传音频；图片分析另需在下方配置和授权。修改地址后需重新同意。设置切换用于之后发起的任务，已启动任务保留原设置；不会自动补发旧课程。密钥仅存钥匙串。")
                    .font(.caption).foregroundStyle(AppTheme.muted)
                HStack {
                    Button(testingAPI ? "正在测试…" : "测试连接") {
                        let settings = store.database.settings ?? AppSettings()
                        testingAPI = true
                        connectionMessage = nil
                        Task {
                            let message = await processor.testAPIConnection(settings: settings)
                            if settings.apiConfiguration == store.database.settings?.apiConfiguration {
                                connectionMessage = message
                            }
                            testingAPI = false
                        }
                    }.disabled(testingAPI || !keySaved || !store.apiConfiguration.isApproved || store.apiConfiguration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("只发送固定测试短句，不发送课程内容；可能产生少量费用。")
                        .font(.caption).foregroundStyle(AppTheme.muted)
                }
                if let connectionMessage {
                    Text(connectionMessage).font(.caption).textSelection(.enabled)
                }
            }
            ImageModelSettingsSection()
            Section("本地模型") {
                LabeledContent("Python") {
                    TextField("Python 可执行文件", text: $store.asrCommandPath)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("备用转写") {
                    TextField("已有 Whisper 模型路径", text: $store.whisperModelPath)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("结构模型") {
                    TextField("本地模型路径", text: $store.structureCommandPath)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("FFmpeg") {
                    TextField("FFmpeg 可执行文件", text: $store.ffmpegPath)
                        .multilineTextAlignment(.trailing)
                }
                Text("语音转写仍在本机完成：优先使用 Mac 已安装的中文语音资源；不可用时使用已有 Whisper，不自动下载。本地模式下由千问整理，转写与整理分阶段运行以节省内存。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                LabeledContent("启动校验", value: processor.modelHealth)
            }
            Section("数据") {
                LabeledContent("保存位置", value: store.dataRoot.path)
                Label("音频、逐字稿、骨架、思考与版本均保存在本机", systemImage: "internaldrive")
                Label("文字与图片是否发送到服务商，分别由上面的设置与授权决定", systemImage: "hand.raised")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshCredentialStatus() }
        .onChange(of: store.apiConfiguration.baseURL) { _, _ in
            newAPIKey = ""
            credentialMessage = nil
            connectionMessage = nil
            refreshCredentialStatus()
        }
    }

    private var endpointIssue: String? {
        guard !store.apiConfiguration.baseURL.isEmpty else { return nil }
        do { _ = try APIConfiguration.normalizedEndpoint(store.apiConfiguration.baseURL); return nil }
        catch { return error.localizedDescription }
    }

    private func apiBinding<Value>(_ path: WritableKeyPath<APIConfiguration, Value>) -> Binding<Value> {
        Binding(get: { store.apiConfiguration[keyPath: path] }, set: { value in
            var config = store.apiConfiguration
            config[keyPath: path] = value
            store.apiConfiguration = config
        })
    }

    private func refreshCredentialStatus() {
        keySaved = false
        guard !store.apiConfiguration.baseURL.isEmpty, endpointIssue == nil else { return }
        do { keySaved = try APICredentials.contains(endpoint: store.apiConfiguration.baseURL) }
        catch { credentialMessage = error.localizedDescription }
    }
}

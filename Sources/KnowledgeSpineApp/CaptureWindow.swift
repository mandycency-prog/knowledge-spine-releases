import AppKit
import KnowledgeSpineCore
import SwiftUI
import UniformTypeIdentifiers

struct CaptureWindow: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var capture: CaptureService
    @EnvironmentObject private var processor: LocalProcessingService
    @State private var selectedSourceID: UUID?
    @State private var thought = ""
    @State private var isStopping = false
    @State private var isStarting = false
    @State private var showingMediaImporter = false
    @State private var savedFeedback = ""
    @State private var showingImages = false

    private var captureSession: SessionRecord? {
        if let id = capture.recordingSessionID {
            return store.database.sessions.first { $0.id == id }
        }
        return store.selectedSession
    }

    var body: some View {
        Group {
            if let session = captureSession {
                VStack(spacing: 0) {
                    captureHeader(session)
                    Divider()
                    if capture.isRecording {
                        recordingBody(session)
                    } else {
                        sourcePicker(session)
                    }
                }
                .background(AppTheme.paper)
                .acceptSessionImages(sessionID: session.id, anchorTime: capture.recordingSessionID == session.id ? capture.recordedDuration : nil)
            } else {
                ContentUnavailableView(
                    "先创建一场记录",
                    systemImage: "waveform.badge.plus",
                    description: Text("回到知识库新建记录，再从这里选择声音来源。")
                )
                .padding(40)
            }
        }
        .task {
            if !capture.isRecording { await capture.refreshSources() }
        }
        .fileImporter(
            isPresented: $showingMediaImporter,
            allowedContentTypes: [.audio, .movie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            guard let session = store.selectedSession else { return }
            importMedia(result, session: session)
        }
        .sheet(isPresented: $showingImages) {
            if let session = captureSession { ImageAttachmentsSheet(sessionID: session.id) }
        }
    }

    private func captureHeader(_ session: SessionRecord) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(capture.isRecording ? AppTheme.coralSoft : AppTheme.tealSoft)
                Image(systemName: capture.isRecording ? "waveform" : "waveform.badge.magnifyingglass")
                    .foregroundStyle(capture.isRecording ? AppTheme.coral : AppTheme.teal)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(capture.isRecording ? (capture.isPaused ? "已暂停，内容仍保留" : "正在接收和保存系统声音") : "选择 macOS 允许共享的来源")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer()
            Button { showingImages = true } label: { Image(systemName: "photo.badge.plus") }
                .buttonStyle(.borderless).help("添加课件与截图")
            if capture.isRecording {
                Text(durationText)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(AppTheme.coral)
            }
        }
        .padding(16)
    }

    private func sourcePicker(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("声音来源")
                        .font(.title3.bold())
                    Text("只处理系统合法允许捕获的声音，不绕过 DRM 或权限。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Button { Task { await capture.refreshSources() } } label: {
                    if capture.isLoadingSources { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
            }

            if let error = capture.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.coral)
                    Spacer()
                    if error.localizedCaseInsensitiveContains("TCC") || error.contains("权限") {
                        Button("打开系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.coralSoft, in: RoundedRectangle(cornerRadius: 10))
            }
            if let warning = capture.signalWarning {
                Label(warning, systemImage: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.amber)
                    .padding(10)
                    .background(AppTheme.amberSoft, in: RoundedRectangle(cornerRadius: 10))
            }
            if let progress = processor.progress[session.id] {
                Label(progress, systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(AppTheme.teal)
            }

            List(selection: $selectedSourceID) {
                ForEach(capture.sources) { source in
                    HStack(spacing: 11) {
                        Image(systemName: sourceIcon(source.kind))
                            .frame(width: 24)
                            .foregroundStyle(source.kind == .system ? AppTheme.amber : AppTheme.teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name).lineLimit(1)
                            Text("\(source.kind.rawValue) · \(source.detail)")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.muted)
                                .lineLimit(1)
                        }
                    }
                    .tag(source.id)
                }
            }
            .listStyle(.inset)
            .frame(height: 310)

            HStack {
                Button("导入本地音频／视频", systemImage: "square.and.arrow.down") {
                    showingMediaImporter = true
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("录制时每 15 秒安全落盘并增量转写")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                Button("开始记录") { Task { await startCapture(session) } }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.coral)
                    .controlSize(.large)
                    .disabled(selectedSourceID == nil || isStarting)
            }
        }
        .padding(18)
    }

    private func recordingBody(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("真实声音反馈")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if let last = capture.lastSampleAt {
                        Text("最后收到 \(last.formatted(date: .omitted, time: .standard))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AppTheme.muted)
                    } else {
                        Text("等待第一段声音")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.amber)
                    }
                }
                WaveformLevel(level: capture.isPaused ? 0 : capture.audioLevel)
                    .frame(height: 46)
            }
            .padding(13)
            .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近转写")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("只显示最近 2–3 行")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.muted)
                }
                if session.transcript.isEmpty {
                    Label("正在本机转写，第一段文字稍后出现。可以收起浮窗，继续听课。", systemImage: "cpu")
                        .font(.callout)
                        .foregroundStyle(AppTheme.amber)
                        .padding(.vertical, 8)
                } else {
                    ForEach(session.transcript.suffix(3)) { span in
                        HStack(alignment: .top, spacing: 7) {
                            Text(store.speakerName(span.speakerID, in: session))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.teal)
                            Text(span.displayedText)
                                .font(.callout)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(13)
            .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 7) {
                Text("我的思考")
                    .font(.caption.weight(.semibold))
                HStack(alignment: .bottom) {
                    TextField("可手打，也可点击后使用已有 Say It 长按 Fn", text: $thought, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .onSubmit { saveThought(session) }
                    Button("保存") { saveThought(session) }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.blue)
                        .disabled(thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack(spacing: 10) {
                Button(capture.isPaused ? "继续" : "暂停", systemImage: capture.isPaused ? "play.fill" : "pause.fill") {
                    capture.togglePause()
                    store.setStatus(capture.isPaused ? .paused : .recording, sessionID: session.id)
                }
                .buttonStyle(.bordered)
                Button("标记附近重点", systemImage: "bookmark") {
                    store.markNearbyImportant(
                        sessionID: session.id,
                        elapsedTime: capture.recordedDuration
                    )
                    savedFeedback = "重点已记下 · \(durationText)"
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("结束", systemImage: "stop.fill", role: .destructive) {
                    Task { await stopCapture(session) }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.coral)
                .disabled(isStopping)
            }

            if !savedFeedback.isEmpty {
                Label(savedFeedback, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.teal)
            }
            Text("可以关闭这个浮窗，录音和转写会继续；声音来源异常时会提醒。")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)

            if let error = capture.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.coral)
            }
            if let warning = capture.signalWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.amber)
            }
        }
        .padding(16)
    }

    private func startCapture(_ session: SessionRecord) async {
        guard !isStarting, !capture.isRecording, let id = selectedSourceID,
              let source = capture.sources.first(where: { $0.id == id }) else { return }
        isStarting = true
        defer { isStarting = false }
        let sessionID = store.sessionForNewRecording(from: session.id)
        let directory = store.sessionDirectory(sessionID)
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try await capture.start(source: source, outputDirectory: directory, sessionID: sessionID)
            savedFeedback = ""
            store.setStatus(.recording, sessionID: sessionID)
            store.updateSource(name: source.name, kind: source.kind.rawValue, sessionID: sessionID)
        } catch {
            capture.errorMessage = error.localizedDescription
            store.setStatus(.failed, sessionID: sessionID)
        }
    }

    private func stopCapture(_ session: SessionRecord) async {
        let sessionID = capture.recordingSessionID ?? session.id
        isStopping = true
        defer { isStopping = false }
        processor.cancelLive(sessionID: sessionID)
        do {
            let urls = try await capture.stop()
            store.attachAudio(paths: urls.map(\.path), sessionID: sessionID)
            store.setStatus(.processing, sessionID: sessionID, endedAt: Date())
            processor.process(sessionID: sessionID, audioPaths: urls.map(\.path), store: store)
        } catch {
            store.attachAudio(paths: capture.segmentURLs.map(\.path), sessionID: sessionID)
            store.setStatus(.failed, sessionID: sessionID, endedAt: Date())
            store.statusMessage = error.localizedDescription
        }
    }

    private func saveThought(_ session: SessionRecord) {
        guard !thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.addThought(
            thought,
            sessionID: session.id,
            attachedNodeID: nil,
            live: true,
            anchorTime: capture.recordedDuration
        )
        savedFeedback = "思考已原文保存 · \(durationText)"
        thought = ""
    }

    private func importMedia(_ result: Result<[URL], Error>, session: SessionRecord) {
        do {
            guard let sourceURL = try result.get().first else { return }
            let access = sourceURL.startAccessingSecurityScopedResource()
            defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
            let directory = store.sessionDirectory(session.id).appendingPathComponent("Imports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(sourceURL.lastPathComponent)")
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            store.attachAudio(paths: [destination.path], sessionID: session.id)
            store.updateSource(name: sourceURL.lastPathComponent, kind: "本地文件", sessionID: session.id)
            store.setStatus(.processing, sessionID: session.id, endedAt: Date())
            processor.process(sessionID: session.id, audioPaths: [destination.path], store: store)
        } catch {
            store.statusMessage = "导入本地音视频失败：\(error.localizedDescription)"
        }
    }

    private var durationText: String {
        let total = Int(capture.recordedDuration)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private func sourceIcon(_ kind: CaptureSource.Kind) -> String {
        switch kind {
        case .application: "app.dashed"
        case .window: "macwindow"
        case .system: "display"
        }
    }
}

private struct WaveformLevel: View {
    let level: Double
    private let factors: [Double] = [0.35, 0.55, 0.42, 0.72, 0.6, 0.88, 0.48, 1, 0.66, 0.84, 0.52, 0.93, 0.57, 0.76, 0.44, 0.62, 0.38, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(factors.enumerated()), id: \.offset) { _, factor in
                Capsule()
                    .fill(level > 0.015 ? AppTheme.teal : AppTheme.line)
                    .frame(width: 5, height: max(3, 42 * level * factor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.linear(duration: 0.12), value: level)
        .accessibilityLabel("真实系统音频电平")
        .accessibilityValue("\(Int(level * 100))%")
    }
}

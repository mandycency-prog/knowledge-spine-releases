import AppKit
import ImageIO
import KnowledgeSpineCore
import SwiftUI
import UniformTypeIdentifiers

/// The same attachment controls are used during capture and when reviewing a record.
struct ImageAttachmentsSheet: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var processor: LocalProcessingService
    @EnvironmentObject private var capture: CaptureService
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    var anchorSpanID: UUID? = nil
    var attachedNodeID: UUID? = nil
    @State private var showingImporter = false
    @State private var showingDeleted = false
    @State private var selectedImage: ImageAttachment?

    private var session: SessionRecord? { store.database.sessions.first { $0.id == sessionID } }
    private var images: [ImageAttachment] {
        (session?.images ?? []).filter { showingDeleted ? $0.deletedAt != nil : $0.deletedAt == nil }
    }
    private var anchorTime: Double? { capture.recordingSessionID == sessionID ? capture.recordedDuration : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("课件与图片").font(.title2.bold())
                    Text(anchorTime == nil ? "拖入图片或粘贴截图；原图会随本条记录保存。" : "录制中加入的图片会关联当前录音时间。")
                        .font(.caption).foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Button("添加图片", systemImage: "photo.badge.plus") { showingImporter = true }
                    .disabled(processor.isProcessing(sessionID))
                Button("粘贴截图", systemImage: "doc.on.clipboard") { pasteImage() }
                    .disabled(processor.isProcessing(sessionID))
                Toggle("最近删除", isOn: $showingDeleted).toggleStyle(.button)
                Spacer()
                if processor.isProcessing(sessionID) {
                    ProgressView().controlSize(.small)
                    Text(processor.progress[sessionID] ?? "正在处理图片与课程材料")
                        .font(.caption).foregroundStyle(AppTheme.muted)
                }
                Button("分析图片", systemImage: "sparkles") { processor.processImages(sessionID: sessionID, store: store) }
                    .disabled(processor.isProcessing(sessionID) || !(session?.images ?? []).contains { $0.deletedAt == nil })
            }
            Text("图片分析使用设置中的识图模型；分析结果会供后续导图和专题整理使用。")
                .font(.caption).foregroundStyle(AppTheme.muted)
            SettingsLink { Label("配置识图模型", systemImage: "gearshape") }.font(.caption)
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                if images.isEmpty {
                    ContentUnavailableView(showingDeleted ? "没有已删除的图片" : "把截图拖到这里", systemImage: "photo.on.rectangle.angled", description: Text(showingDeleted ? "删除的图片可在此恢复。" : "支持图片文件与复制的截图；可在图片详情中补充说明和关联位置。"))
                        .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(images) { image in
                            Button { selectedImage = image } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    AttachmentThumbnail(url: store.imageURL(image, sessionID: sessionID))
                                        .frame(height: 120).frame(maxWidth: .infinity)
                                        .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                                    Text(image.title).font(.callout.bold()).lineLimit(2)
                                    Text(imageStatus(image)).font(.caption).foregroundStyle(image.analysisError == nil ? AppTheme.muted : AppTheme.coral)
                                    if let anchor = image.anchorTime { Text("关联录音 \(imageTime(anchor))").font(.caption2).foregroundStyle(AppTheme.muted) }
                                    if !image.note.isEmpty { Text(image.note).font(.caption).lineLimit(2).foregroundStyle(AppTheme.blue) }
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(AppTheme.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                                .id(image.id)
                                .overlay {
                                    if store.selectedImageID == image.id { RoundedRectangle(cornerRadius: 10).stroke(AppTheme.teal, lineWidth: 2) }
                                }
                        }
                    }
                }
            }
            .task(id: store.selectedImageID) {
                guard let imageID = store.selectedImageID, images.contains(where: { $0.id == imageID }) else { return }
                await Task.yield()
                proxy.scrollTo(imageID, anchor: .center)
                if selectedImage == nil { selectedImage = images.first { $0.id == imageID } }
            }
            }
            if let message = store.statusMessage, !message.isEmpty { Text(message).font(.caption).foregroundStyle(AppTheme.muted).textSelection(.enabled) }
        }
        .padding(22).frame(minWidth: 760, idealWidth: 900, minHeight: 540, idealHeight: 660)
        .background(AppTheme.paper)
        .acceptSessionImages(sessionID: sessionID, anchorTime: anchorTime, anchorSpanID: anchorSpanID, attachedNodeID: attachedNodeID)
        .onPasteCommand(of: [.image, .fileURL]) { _ in pasteImage() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard !processor.isProcessing(sessionID) else { store.statusMessage = "正在处理本条记录，请完成后再添加图片。"; return }
            do { try store.importImages(urls: result.get(), sessionID: sessionID, anchorTime: anchorTime, anchorSpanID: anchorSpanID, attachedNodeID: attachedNodeID) }
            catch { store.statusMessage = "添加图片失败：\(error.localizedDescription)" }
        }
        .sheet(item: $selectedImage) { image in ImageAttachmentDetail(sessionID: sessionID, imageID: image.id) }
    }

    private func pasteImage() {
        guard !processor.isProcessing(sessionID) else { return }
        do {
            if try !store.importPastedImage(sessionID: sessionID, anchorTime: anchorTime, anchorSpanID: anchorSpanID, attachedNodeID: attachedNodeID) {
                store.statusMessage = "剪贴板中没有可添加的图片，请先复制截图或图片文件。"
            }
        } catch { store.statusMessage = "粘贴图片失败：\(error.localizedDescription)" }
    }
}

struct ImageAttachmentDetail: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var processor: LocalProcessingService
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    let imageID: UUID
    @State private var note = ""
    @State private var spanID: UUID?
    @State private var nodeID: UUID?
    @State private var showingOriginal = false
    private var session: SessionRecord? { store.database.sessions.first { $0.id == sessionID } }
    private var image: ImageAttachment? { session?.images?.first { $0.id == imageID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(image?.title ?? "图片").font(.title2.bold())
                Spacer()
                Button("完成") { save(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let image, let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Button { showingOriginal = true } label: {
                            AttachmentThumbnail(url: store.imageURL(image, sessionID: sessionID), maxPixelSize: 1400)
                                .frame(maxWidth: .infinity).frame(height: 260)
                                .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).help("放大查看原图")
                        HStack {
                            Text("\(image.width) × \(image.height) · \(imageStatus(image))").font(.caption).foregroundStyle(AppTheme.muted)
                            Spacer()
                            Button("放大原图", systemImage: "arrow.up.left.and.arrow.down.right") { showingOriginal = true }
                        }
                        if let anchor = image.anchorTime { Text("录音时间：\(imageTime(anchor))").font(.caption).foregroundStyle(AppTheme.muted) }
                        if let origin = image.origin {
                            HStack {
                                Text("来自：\(origin.sessionTitle)").font(.caption).foregroundStyle(AppTheme.muted)
                                Button("打开原记录") { store.openOrigin(origin) }.buttonStyle(.link)
                            }
                        }
                        Text("我的说明").font(.headline)
                        TextEditor(text: $note).frame(minHeight: 72).disabled(image.deletedAt != nil || processor.isProcessing(sessionID))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppTheme.line))
                        Picker("关联原文", selection: $spanID) {
                            Text("整场记录 / 录音时间").tag(Optional<UUID>.none)
                            ForEach(session.transcript) { span in
                                Text("\(imageTime(span.startTime)) · \(String(span.displayedText.prefix(48)))").tag(Optional(span.id))
                            }
                        }.disabled(image.deletedAt != nil || processor.isProcessing(sessionID))
                        Picker("关联节点", selection: $nodeID) {
                            Text("暂不指定节点").tag(Optional<UUID>.none)
                            ForEach(session.nodes.filter { !$0.isDeleted }) { node in
                                Text(String(store.nodeText(node, in: session).prefix(48))).tag(Optional(node.id))
                            }
                        }.disabled(image.deletedAt != nil || processor.isProcessing(sessionID))
                        HStack {
                            Button("保存说明与关联") { save() }.disabled(image.deletedAt != nil || processor.isProcessing(sessionID))
                            Spacer()
                            if image.deletedAt != nil {
                                Button("恢复图片", systemImage: "arrow.uturn.backward") { store.restoreImage(id: image.id, sessionID: sessionID); dismiss() }
                                    .disabled(processor.isProcessing(sessionID))
                            } else {
                                Button("移到最近删除", role: .destructive) { store.removeImage(id: image.id, sessionID: sessionID); dismiss() }
                                    .disabled(processor.isProcessing(sessionID))
                            }
                        }
                        if let error = image.analysisError {
                            Text(error).font(.callout).foregroundStyle(AppTheme.coral).textSelection(.enabled)
                        }
                        if let analysis = image.analysis {
                            Divider()
                            Label("图片解读 · AI", systemImage: "sparkles").font(.headline)
                            Text(analysis.explanation.simplifiedChineseForDisplay).textSelection(.enabled).lineSpacing(5)
                            if !analysis.extractedText.isEmpty {
                                DisclosureGroup("图片中文字 · AI 识别") { Text(analysis.extractedText.simplifiedChineseForDisplay).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                            if !analysis.uncertainties.isEmpty {
                                Text("待确认：" + analysis.uncertainties.joined(separator: "；")).font(.callout).foregroundStyle(AppTheme.amber).textSelection(.enabled)
                            }
                            Text("模型：\(analysis.model)").font(.caption).foregroundStyle(AppTheme.muted)
                        }
                    }.padding(.trailing, 6)
                }
            }
        }.padding(22).frame(minWidth: 680, idealWidth: 760, minHeight: 580, idealHeight: 740).background(AppTheme.paper)
            .onAppear { if let image { note = image.note; spanID = image.anchorSpanID; nodeID = image.attachedNodeID } }
            .sheet(isPresented: $showingOriginal) {
                if let image { ImageOriginalView(url: store.imageURL(image, sessionID: sessionID), title: image.title) }
            }
    }
    private func save() {
        guard image?.deletedAt == nil, !processor.isProcessing(sessionID) else { return }
        store.updateImage(id: imageID, sessionID: sessionID, note: note, anchorSpanID: spanID, attachedNodeID: nodeID)
    }
}

struct ImageEvidenceStrip: View {
    @EnvironmentObject private var store: AppStore
    let sessionID: UUID
    let imageIDs: [UUID]
    @State private var selectedImage: ImageAttachment?
    private var images: [ImageAttachment] {
        let ids = Set(imageIDs)
        return (store.database.sessions.first { $0.id == sessionID }?.images ?? []).filter { ids.contains($0.id) && $0.deletedAt == nil }
    }
    var body: some View {
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("对应课件与图片", systemImage: "photo.on.rectangle").font(.caption.bold()).foregroundStyle(AppTheme.teal)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(images) { image in
                            Button { selectedImage = image } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    AttachmentThumbnail(url: store.imageURL(image, sessionID: sessionID)).frame(width: 130, height: 85)
                                        .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 6))
                                    Text(image.title).font(.caption).lineLimit(2).frame(width: 130, alignment: .leading)
                                }
                            }.buttonStyle(.plain).help("打开图片来源")
                        }
                    }
                }
            }.sheet(item: $selectedImage) { image in ImageAttachmentDetail(sessionID: sessionID, imageID: image.id) }
        }
    }
}

private struct ImageOriginalView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL?
    let title: String
    @State private var scale: Double = 1
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("缩放").font(.caption)
                Slider(value: $scale, in: 0.25...3).frame(width: 140)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    if let url, let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: max(1, min(image.size.width, geometry.size.width) * scale))
                    } else { ContentUnavailableView("原图不可用", systemImage: "photo") }
                }
            }
        }.padding(18).frame(minWidth: 720, minHeight: 560).background(AppTheme.paper)
    }
}

private struct AttachmentThumbnail: View {
    let url: URL?
    var maxPixelSize: Int = 500
    var body: some View {
        if let url, let thumbnail = AttachmentThumbnailCache.image(url: url, maxPixelSize: maxPixelSize) {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
        } else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(AppTheme.muted) }
    }
}

@MainActor
private enum AttachmentThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let value = NSCache<NSString, NSImage>()
        value.totalCostLimit = 40 * 1024 * 1024
        value.countLimit = 80
        return value
    }()
    static func image(url: URL, maxPixelSize: Int) -> NSImage? {
        let key = "\(url.path)::\(maxPixelSize)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}

private struct SessionImageDrop: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var processor: LocalProcessingService
    @EnvironmentObject private var capture: CaptureService
    let sessionID: UUID
    let anchorTime: Double?
    let anchorSpanID: UUID?
    let attachedNodeID: UUID?
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .overlay { if targeted { RoundedRectangle(cornerRadius: 10).stroke(AppTheme.teal, lineWidth: 3).allowsHitTesting(false) } }
            .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $targeted) { providers in
                guard !processor.isProcessing(sessionID) else { store.statusMessage = "正在处理本条记录，请完成后再添加图片。"; return false }
                let currentAnchor = anchorTime ?? (capture.recordingSessionID == sessionID ? capture.recordedDuration : nil)
                let candidates = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) || $0.canLoadObject(ofClass: NSImage.self) }
                for provider in candidates {
                    guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                        loadImageProvider(provider, anchor: currentAnchor)
                        continue
                    }
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        Task { @MainActor in
                            do {
                                guard !processor.isProcessing(sessionID) else { store.statusMessage = "正在处理本条记录，请完成后再添加图片。"; return }
                                if let error { throw error }
                                guard let url, url.isFileURL else { throw ImageFileFailure.invalid("拖入的图片文件地址不可读取，请复制图片后粘贴或保存为文件。") }
                                try store.importImages(urls: [url], sessionID: sessionID, anchorTime: currentAnchor, anchorSpanID: anchorSpanID, attachedNodeID: attachedNodeID)
                            } catch { store.statusMessage = "添加图片失败：\(error.localizedDescription)" }
                        }
                    }
                }
                return !candidates.isEmpty
            }
    }

    private func loadImageProvider(_ provider: NSItemProvider, anchor: Double?) {
        let preferred = [UTType.png.identifier, UTType.jpeg.identifier, "org.webmproject.webp", UTType.tiff.identifier]
        let type = preferred.first { provider.hasItemConformingToTypeIdentifier($0) }
            ?? provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
        let title = provider.suggestedName.flatMap { $0.isEmpty ? nil : $0 } ?? "拖入的截图"
        if let type {
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                do {
                    if let error { throw error }
                    guard let data else { throw ImageFileFailure.invalid("拖入的图片没有可读取内容。") }
                    let normalized = try DroppedImageDecoder.normalized(data)
                    Task { @MainActor in importData(normalized, title: title, anchor: anchor) }
                } catch {
                    Task { @MainActor in store.statusMessage = "添加图片失败：\(error.localizedDescription)" }
                }
            }
        } else if provider.canLoadObject(ofClass: NSImage.self) {
            provider.loadObject(ofClass: NSImage.self) { object, error in
                do {
                    if let error { throw error }
                    guard let image = object as? NSImage else { throw ImageFileFailure.invalid("拖入的图片无法读取。") }
                    let data = try DroppedImageDecoder.png(image)
                    Task { @MainActor in importData(data, title: title, anchor: anchor) }
                } catch {
                    Task { @MainActor in store.statusMessage = "添加图片失败：\(error.localizedDescription)" }
                }
            }
        }
    }

    @MainActor private func importData(_ data: Data, title: String, anchor: Double?) {
        guard !processor.isProcessing(sessionID) else { store.statusMessage = "正在处理本条记录，请完成后再添加图片。"; return }
        do { try store.importImageData(data, title: title, sessionID: sessionID, anchorTime: anchor, anchorSpanID: anchorSpanID, attachedNodeID: attachedNodeID) }
        catch { store.statusMessage = "添加图片失败：\(error.localizedDescription)" }
    }
}

/// Inspect compressed dimensions before decoding a provider's TIFF or NSImage.
/// Clipboard contents are never changed while importing a drag representation.
private enum DroppedImageDecoder {
    static func normalized(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000, Int64(width) * Int64(height) <= 50_000_000 else {
            throw ImageFileFailure.invalid("图片过大或格式无效；单张最多 5000 万像素。")
        }
        if let type = CGImageSourceGetType(source), [UTType.png.identifier, UTType.jpeg.identifier, "org.webmproject.webp"].contains(type as String) {
            _ = try ImageFiles.metadata(data, title: "图片")
            return data
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageFileFailure.invalid("无法读取拖入的图片。")
        }
        let output = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageFileFailure.invalid("无法转换拖入的图片。")
        }
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: properties[kCGImagePropertyOrientation] ?? 1] as CFDictionary)
        guard CGImageDestinationFinalize(writer), output.length <= ImageFiles.maximumBytes else {
            throw ImageFileFailure.invalid("截图转换后超过 20 MB，请缩小截图范围。")
        }
        return output as Data
    }

    static func png(_ image: NSImage) throws -> Data {
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0,
              image.size.width <= 20_000, image.size.height <= 20_000,
              image.size.width * image.size.height <= 50_000_000,
              image.representations.allSatisfy({ $0.pixelsWide <= 20_000 && $0.pixelsHigh <= 20_000 && Int64(max(0, $0.pixelsWide)) * Int64(max(0, $0.pixelsHigh)) <= 50_000_000 }),
              let data = image.tiffRepresentation else {
            throw ImageFileFailure.invalid("拖入的图片尺寸过大或无法转换。")
        }
        return try normalized(data)
    }
}

extension View {
    func acceptSessionImages(sessionID: UUID, anchorTime: Double? = nil, anchorSpanID: UUID? = nil, attachedNodeID: UUID? = nil) -> some View {
        modifier(SessionImageDrop(sessionID: sessionID, anchorTime: anchorTime, anchorSpanID: anchorSpanID, attachedNodeID: attachedNodeID))
    }
}

private func imageStatus(_ image: ImageAttachment) -> String {
    if image.deletedAt != nil { return "已删除 · 可恢复" }
    if image.analysisError != nil { return "分析未完成 · 原图已保存" }
    return image.analysis == nil ? "原图已保存 · 待分析" : "已分析 · 原图保留"
}

private func imageTime(_ value: Double) -> String {
    let seconds = Int(max(0, value))
    return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
}

struct ImageModelSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var processor: LocalProcessingService
    @State private var newKey = ""
    @State private var keySaved = false
    @State private var message: String?
    @State private var testing = false

    var body: some View {
        Section("图片分析模型") {
            Text("选择支持图片输入、兼容 Chat Completions 图文格式的模型。可与文字分析使用同一服务，也可以单独配置。")
                .font(.caption).foregroundStyle(AppTheme.muted)
            Button("复制文字 API 的地址与模型") {
                var configuration = store.apiConfiguration
                configuration.approvedImageEndpoint = nil
                store.imageAPIConfiguration = configuration
                refreshKey()
            }
            TextField("图片 API 地址", text: binding(\.baseURL))
            TextField("识图模型名称", text: binding(\.model))
            if let endpointIssue { Text(endpointIssue).font(.caption).foregroundStyle(AppTheme.coral) }
            HStack {
                SecureField("输入新密钥（相同地址可使用已保存密钥）", text: $newKey)
                Button("保存密钥") {
                    do {
                        try APICredentials.save(newKey, endpoint: store.imageAPIConfiguration.baseURL)
                        newKey = ""
                        refreshKey()
                        message = "图片服务密钥已保存到本机钥匙串。"
                    } catch { message = error.localizedDescription }
                }.disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpointIssue != nil || store.imageAPIConfiguration.baseURL.isEmpty)
            }
            Text(keySaved ? "此地址已有密钥；是否支持图片需通过下面的识图检测确认。" : "此地址尚未保存密钥。")
                .font(.caption).foregroundStyle(AppTheme.muted)
            DisclosureGroup("图片请求高级参数") {
                TextField("上下文窗口（tokens）", value: binding(\.contextWindow), format: .number)
                TextField("最大输出预算（tokens）", value: binding(\.maxOutputTokens), format: .number)
                Picker("输出上限参数", selection: binding(\.tokenLimitField)) {
                    Text("max_tokens").tag("max_tokens")
                    Text("max_completion_tokens").tag("max_completion_tokens")
                }
                Toggle("请求 JSON 输出模式", isOn: binding(\.jsonMode))
                Picker("思考模式", selection: Binding(get: { store.imageAPIConfiguration.thinkingMode ?? "" }, set: { value in
                    var configuration = store.imageAPIConfiguration
                    configuration.thinkingMode = value.isEmpty ? nil : value
                    store.imageAPIConfiguration = configuration
                })) {
                    Text("服务商默认").tag("")
                    Text("启用").tag("enabled")
                    Text("关闭").tag("disabled")
                }
            }
            Toggle(isOn: Binding(get: { approved }, set: { value in
                var configuration = store.imageAPIConfiguration
                configuration.approvedImageEndpoint = value ? configuration.baseURL : nil
                store.imageAPIConfiguration = configuration
            })) {
                Text("我同意将主动发起的任务所需图片、图片说明及相关文字发送给此服务商，并了解可能产生费用。")
            }.disabled(endpointIssue != nil || store.imageAPIConfiguration.baseURL.isEmpty)
            Text("图片授权独立于文字分析授权；修改服务地址后需重新同意。图片 API 会收到实际图片，不上传音频。")
                .font(.caption).foregroundStyle(AppTheme.muted)
            HStack {
                Button(testing ? "正在检测识图…" : "检测实际识图能力") {
                    let configuration = store.imageAPIConfiguration
                    testing = true
                    message = nil
                    Task {
                        do {
                            let result = try await processor.probeImageAPI(configuration: configuration)
                            if configuration == store.imageAPIConfiguration { message = result }
                        } catch {
                            if configuration == store.imageAPIConfiguration { message = "识图检测失败：\(error.localizedDescription)" }
                        }
                        testing = false
                    }
                }.disabled(testing || !approved || !keySaved || endpointIssue != nil || store.imageAPIConfiguration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("只发送一张程序生成的测试图；可能产生少量费用。")
                    .font(.caption).foregroundStyle(AppTheme.muted)
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        }
        .onAppear { refreshKey() }
        .onChange(of: store.imageAPIConfiguration.baseURL) { _, _ in
            newKey = ""
            message = nil
            refreshKey()
        }
    }

    private var approved: Bool {
        guard let endpoint = try? APIConfiguration.normalizedEndpoint(store.imageAPIConfiguration.baseURL),
              let approval = store.imageAPIConfiguration.approvedImageEndpoint,
              let approvedEndpoint = try? APIConfiguration.normalizedEndpoint(approval) else { return false }
        return endpoint == approvedEndpoint
    }
    private var endpointIssue: String? {
        guard !store.imageAPIConfiguration.baseURL.isEmpty else { return nil }
        do { _ = try APIConfiguration.normalizedEndpoint(store.imageAPIConfiguration.baseURL); return nil }
        catch { return error.localizedDescription }
    }
    private func binding<Value>(_ keyPath: WritableKeyPath<APIConfiguration, Value>) -> Binding<Value> {
        Binding(get: { store.imageAPIConfiguration[keyPath: keyPath] }, set: { value in
            var configuration = store.imageAPIConfiguration
            configuration[keyPath: keyPath] = value
            store.imageAPIConfiguration = configuration
        })
    }
    private func refreshKey() {
        keySaved = false
        guard !store.imageAPIConfiguration.baseURL.isEmpty, endpointIssue == nil else { return }
        do { keySaved = try APICredentials.contains(endpoint: store.imageAPIConfiguration.baseURL) }
        catch { message = error.localizedDescription }
    }
}

import AppKit
import Combine
import Foundation
import KnowledgeSpineCore

enum AppSection: String, CaseIterable, Identifiable {
    case library = "知识库"
    case merge = "整合知识"
    case trash = "最近删除"
    case settings = "模型与设置"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .library: "rectangle.stack"
        case .merge: "point.3.connected.trianglepath.dotted"
        case .trash: "trash"
        case .settings: "gearshape"
        }
    }
}

struct SearchHit: Identifiable, Equatable {
    enum Kind: String {
        case title = "标题"
        case node = "骨架"
        case thought = "我的思考"
        case transcript = "逐字稿"
        case image = "课件与图片"
    }

    let id = UUID()
    let sessionID: UUID
    let nodeID: UUID?
    let spanID: UUID?
    let kind: Kind
    let title: String
    let excerpt: String
    var imageID: UUID? = nil
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var database = AppDatabase()
    @Published var selectedSection: AppSection = .library
    @Published var selectedSessionID: UUID?
    @Published var selectedNodeID: UUID?
    @Published var highlightedNodeID: UUID?
    @Published var selectedTranscriptSpanID: UUID?
    @Published var selectedImageID: UUID?
    @Published var searchText = ""
    @Published var selectedCollectionID: UUID?
    @Published var statusMessage: String?
    // One-shot viewport requests, independent of node positions and dragging.
    @Published private(set) var canvasFitRevisions: [UUID: Int] = [:]
    var asrCommandPath: String {
        get { database.settings?.pythonPath ?? AppSettings().pythonPath }
        set { updateSettings { $0.pythonPath = newValue } }
    }

    var whisperModelPath: String {
        get { database.settings?.whisperModelPath ?? AppSettings().whisperModelPath }
        set { updateSettings { $0.whisperModelPath = newValue } }
    }

    var structureCommandPath: String {
        get { database.settings?.structureModelPath ?? AppSettings().structureModelPath }
        set { updateSettings { $0.structureModelPath = newValue } }
    }

    var ffmpegPath: String {
        get { database.settings?.ffmpegPath ?? AppSettings().ffmpegPath }
        set { updateSettings { $0.ffmpegPath = newValue } }
    }

    var analysisProvider: String {
        get { database.settings?.analysisProvider ?? "local" }
        set { updateSettings { $0.analysisProvider = newValue } }
    }

    var apiConfiguration: APIConfiguration {
        get { database.settings?.apiConfiguration ?? APIConfiguration() }
        set {
            updateSettings {
                var configuration = newValue
                if configuration.baseURL != $0.apiConfiguration?.baseURL {
                    configuration.approvedEndpoint = nil
                    configuration.approvedImageEndpoint = nil
                }
                $0.apiConfiguration = configuration
            }
        }
    }

    var imageAPIConfiguration: APIConfiguration {
        get { database.settings?.imageAPIConfiguration ?? APIConfiguration() }
        set {
            updateSettings {
                var configuration = newValue
                if configuration.baseURL != $0.imageAPIConfiguration?.baseURL {
                    configuration.approvedEndpoint = nil
                    configuration.approvedImageEndpoint = nil
                }
                $0.imageAPIConfiguration = configuration
            }
        }
    }

    let dataRoot: URL
    private let inMemory: Bool
    private var saveWorkItem: DispatchWorkItem?
    private var protectedFile: ProtectedDatabaseFile?
    private var databaseReadFailed = false
    private var handledCaptureInterruptionIDs: Set<UUID> = []

    init(inMemory: Bool = false, seedDemo: Bool = false, storageRoot: URL? = nil) {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let storagePlan = AppDataStoragePlan(
            requestedInMemory: inMemory,
            seedDemo: seedDemo,
            applicationSupportRoot: base,
            temporaryRoot: fm.temporaryDirectory,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        self.inMemory = storagePlan.inMemory
        dataRoot = storageRoot ?? (Bundle.main.object(forInfoDictionaryKey: "KnowledgeSpineDistributionPreview") as? Bool == true && !storagePlan.inMemory
            ? base.appendingPathComponent(PortableRuntime.dataDirectoryName, isDirectory: true) : storagePlan.dataRoot)

        if seedDemo {
            database = AppDatabase(sessions: [Self.demoSession()])
            selectedSessionID = database.sessions.first?.id
        } else {
            load()
        }
        runRetentionAudit()
    }

    var activeSessions: [SessionRecord] {
        database.sessions
            .filter { $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var deletedSessions: [SessionRecord] {
        database.sessions
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    var collections: [KnowledgeCollection] { database.collections ?? [] }

    var librarySessions: [SessionRecord] {
        guard let selectedCollectionID,
              let collection = collections.first(where: { $0.id == selectedCollectionID }) else { return activeSessions }
        let ids = Set(collection.sessionIDs)
        return activeSessions.filter { ids.contains($0.id) }
    }

    @discardableResult
    func createCollection(named name: String) -> UUID? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let existing = collections.first(where: { $0.name == clean }) {
            selectedCollectionID = existing.id
            return existing.id
        }
        let collection = KnowledgeCollection(name: clean)
        let before = database
        database.collections = collections + [collection]
        guard persistNow() else { database = before; return nil }
        selectedCollectionID = collection.id
        return collection.id
    }

    func renameCollection(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = database.collections?.firstIndex(where: { $0.id == id }) else { return }
        let before = database
        database.collections?[index].name = clean
        if !persistNow() { database = before }
    }

    func removeCollection(_ id: UUID) {
        let before = database
        database.collections?.removeAll { $0.id == id }
        guard persistNow() else { database = before; return }
        if selectedCollectionID == id { selectedCollectionID = nil }
    }

    func setCollectionMembership(sessionID: UUID, collectionID: UUID, included: Bool) {
        guard database.sessions.contains(where: { $0.id == sessionID && $0.deletedAt == nil }),
              let index = database.collections?.firstIndex(where: { $0.id == collectionID }) else { return }
        let before = database
        database.collections?[index].sessionIDs.removeAll { $0 == sessionID }
        if included { database.collections?[index].sessionIDs.append(sessionID) }
        if !persistNow() { database = before }
    }

    /// Import commits all records together. A storage conflict leaves no
    /// half-imported entries in either the UI or the database.
    @discardableResult
    func addLibraryRecords(_ records: [SessionRecord], collectionID: UUID?) -> [UUID] {
        let ids = records.map(\.id)
        guard !records.isEmpty, Set(ids).count == ids.count,
              Set(ids).isDisjoint(with: database.sessions.map(\.id)) else {
            statusMessage = "导入未执行：记录身份重复，原知识库未改变。"
            return []
        }
        let before = database
        var createdDirectories: [URL] = []
        do {
            for var record in records {
                let hasImages = !(record.images ?? []).isEmpty || (record.versions + (record.candidateVersions ?? [])).contains { $0.images?.isEmpty == false }
                if hasImages {
                    let directory = sessionDirectory(record.id)
                    guard !FileManager.default.fileExists(atPath: directory.path) else {
                        throw ImageFileFailure.invalid("导入目标目录已存在，未覆盖其中任何文件。")
                    }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    createdDirectories.append(directory)
                    try materializeImages(in: &record)
                }
                Self.ensureUserArtifacts(in: &record)
                Self.reconcileImageLinks(in: &record)
                database.sessions.append(record)
            }
        } catch {
            database = before
            for directory in createdDirectories.reversed() { try? FileManager.default.removeItem(at: directory) }
            statusMessage = "导入图片资料失败，原知识库未改变：\(error.localizedDescription)"
            return []
        }
        if let collectionID, let index = database.collections?.firstIndex(where: { $0.id == collectionID }) {
            database.collections?[index].sessionIDs.append(contentsOf: ids)
        }
        guard persistNow() else {
            database = before
            for directory in createdDirectories.reversed() { try? FileManager.default.removeItem(at: directory) }
            return []
        }
        return ids
    }

    func imageURL(_ image: ImageAttachment, sessionID: UUID) -> URL? {
        ImageFiles.resolve(image, directory: sessionDirectory(sessionID))
    }

    func importImages(urls: [URL], sessionID: UUID, anchorTime: Double? = nil,
                      anchorSpanID: UUID? = nil, attachedNodeID: UUID? = nil) throws {
        guard !urls.isEmpty else { return }
        guard urls.count <= ImageFiles.maximumCount else { throw ImageFileFailure.invalid("一次最多添加 50 张图片。") }
        let inputs: [(Data, String)] = try urls.map { url in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= ImageFiles.maximumBytes else {
                throw ImageFileFailure.invalid("请选择不超过 20 MB 的图片文件：\(url.lastPathComponent)")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= ImageFiles.maximumBytes else { throw ImageFileFailure.invalid("图片文件超过 20 MB。") }
            return (data, url.deletingPathExtension().lastPathComponent)
        }
        try importImageData(inputs, sessionID: sessionID, anchorTime: anchorTime, anchorSpanID: anchorSpanID, attachedNodeID: attachedNodeID)
    }

    func importImageData(_ data: Data, title: String, sessionID: UUID, anchorTime: Double? = nil,
                         anchorSpanID: UUID? = nil, attachedNodeID: UUID? = nil) throws {
        try importImageData([(data, title)], sessionID: sessionID, anchorTime: anchorTime, anchorSpanID: anchorSpanID, attachedNodeID: attachedNodeID)
    }

    @discardableResult
    func importPastedImage(sessionID: UUID, anchorTime: Double? = nil,
                           anchorSpanID: UUID? = nil, attachedNodeID: UUID? = nil) throws -> Bool {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            try importImages(urls: urls, sessionID: sessionID, anchorTime: anchorTime, anchorSpanID: anchorSpanID, attachedNodeID: attachedNodeID)
            return true
        }
        guard let data = try ImageFiles.pastedPNG() else { return false }
        try importImageData([(data, "截图")], sessionID: sessionID, anchorTime: anchorTime, anchorSpanID: anchorSpanID, attachedNodeID: attachedNodeID)
        return true
    }

    private func importImageData(_ inputs: [(Data, String)], sessionID: UUID, anchorTime: Double?,
                                 anchorSpanID: UUID?, attachedNodeID: UUID?) throws {
        guard let index = database.sessions.firstIndex(where: { $0.id == sessionID && $0.deletedAt == nil }) else {
            throw ImageFileFailure.invalid("请先选择有效的记录。")
        }
        let session = database.sessions[index]
        guard (session.images?.count ?? 0) + inputs.count <= ImageFiles.maximumCount else {
            throw ImageFileFailure.invalid("单场最多保存 50 张图片（含可恢复图片），请分场整理。")
        }
        try Self.validateImageAssociation(anchorTime: anchorTime, anchorSpanID: anchorSpanID, attachedNodeID: attachedNodeID, session: session)
        var attachments: [(ImageAttachment, Data)] = []
        for (data, title) in inputs {
            var image = try ImageFiles.metadata(data, title: title)
            image.anchorSpanID = anchorSpanID; image.attachedNodeID = attachedNodeID
            image.anchorTime = anchorTime ?? anchorSpanID.flatMap { id in session.transcript.first { $0.id == id }.map { ($0.startTime + $0.endTime) / 2 } }
            if image.anchorTime == nil, let nodeID = attachedNodeID, let node = session.nodes.first(where: { $0.id == nodeID }) {
                let times = session.transcript.filter { (node.sourceSpanIDs + (node.coveredSourceSpanIDs ?? [])).contains($0.id) }
                    .map { ($0.startTime + $0.endTime) / 2 }
                if !times.isEmpty { image.anchorTime = times.reduce(0, +) / Double(times.count) }
            }
            image.portableData = data
            try ImageAttachmentValidation.validate(image, requireData: true)
            image.portableData = nil
            attachments.append((image, data))
        }
        let before = database
        var created: [URL] = []
        do {
            let directory = try prepareImageDirectory(sessionID)
            for (image, data) in attachments {
                guard let url = ImageFiles.resolve(image, directory: directory), !FileManager.default.fileExists(atPath: url.path) else {
                    throw ImageFileFailure.invalid("图片保存路径已被占用，未覆盖已有文件。")
                }
                try data.write(to: url, options: .atomic)
                created.append(url)
            }
            database.sessions[index].images = (session.images ?? []) + attachments.map(\.0)
            database.sessions[index].updatedAt = Date()
            guard persistNow() else { throw ImageFileFailure.invalid(statusMessage ?? "图片资料未能保存。") }
            statusMessage = "已保存 \(attachments.count) 张原图，可在“课件与图片”中查看和分析。"
        } catch {
            database = before
            for url in created.reversed() { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func validateImageAssociation(anchorTime: Double?, anchorSpanID: UUID?, attachedNodeID: UUID?, session: SessionRecord) throws {
        if let time = anchorTime, !time.isFinite || time < 0 || time > 315_576_000 { throw ImageFileFailure.invalid("图片关联时间无效。") }
        if let id = anchorSpanID, !session.transcript.contains(where: { $0.id == id }) { throw ImageFileFailure.invalid("关联原文已经变化，请重新选择。") }
        if let id = attachedNodeID, !session.nodes.contains(where: { $0.id == id && !$0.isDeleted }) { throw ImageFileFailure.invalid("关联节点已经变化，请重新选择。") }
    }

    private func prepareImageDirectory(_ sessionID: UUID) throws -> URL {
        let fm = FileManager.default
        let directory = sessionDirectory(sessionID)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent() == directory.deletingLastPathComponent().resolvingSymlinksInPath() else {
            throw ImageFileFailure.invalid("记录目录被重定向，已停止写入图片。")
        }
        try fm.createDirectory(at: directory.appendingPathComponent("Images", isDirectory: true), withIntermediateDirectories: true)
        return directory
    }

    func updateImage(id: UUID, sessionID: UUID, note: String, anchorSpanID: UUID?, attachedNodeID: UUID?) {
        guard let sessionIndex = database.sessions.firstIndex(where: { $0.id == sessionID && $0.deletedAt == nil }),
              let imageIndex = database.sessions[sessionIndex].images?.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        let session = database.sessions[sessionIndex]
        guard let image = session.images?[imageIndex], image.note != note || image.anchorSpanID != anchorSpanID || image.attachedNodeID != attachedNodeID else { return }
        do { try Self.validateImageAssociation(anchorTime: image.anchorTime, anchorSpanID: anchorSpanID, attachedNodeID: attachedNodeID, session: session) }
        catch { statusMessage = error.localizedDescription; return }
        let before = database
        database.sessions[sessionIndex].images?[imageIndex].note = note
        database.sessions[sessionIndex].images?[imageIndex].anchorSpanID = anchorSpanID
        database.sessions[sessionIndex].images?[imageIndex].attachedNodeID = attachedNodeID
        if image.anchorSpanID != anchorSpanID || image.attachedNodeID != attachedNodeID {
            if let spanID = anchorSpanID, let span = session.transcript.first(where: { $0.id == spanID }) {
                database.sessions[sessionIndex].images?[imageIndex].anchorTime = (span.startTime + span.endTime) / 2
            } else if let nodeID = attachedNodeID, let node = session.nodes.first(where: { $0.id == nodeID }) {
                let sources = session.transcript.filter { (node.sourceSpanIDs + (node.coveredSourceSpanIDs ?? [])).contains($0.id) }
                if !sources.isEmpty {
                    database.sessions[sessionIndex].images?[imageIndex].anchorTime = sources.map { ($0.startTime + $0.endTime) / 2 }.reduce(0, +) / Double(sources.count)
                }
            }
        }
        database.sessions[sessionIndex].images?[imageIndex].analysis = nil
        database.sessions[sessionIndex].images?[imageIndex].analysisError = nil
        database.sessions[sessionIndex].updatedAt = Date()
        if !persistNow() { database = before }
    }

    func removeImage(id: UUID, sessionID: UUID) {
        setImageDeleted(id: id, sessionID: sessionID, deleted: true)
    }

    func restoreImage(id: UUID, sessionID: UUID) {
        setImageDeleted(id: id, sessionID: sessionID, deleted: false)
    }

    private func setImageDeleted(id: UUID, sessionID: UUID, deleted: Bool) {
        guard let sessionIndex = database.sessions.firstIndex(where: { $0.id == sessionID && $0.deletedAt == nil }),
              let imageIndex = database.sessions[sessionIndex].images?.firstIndex(where: { $0.id == id }),
              let image = database.sessions[sessionIndex].images?[imageIndex], (image.deletedAt != nil) != deleted else { return }
        let before = database
        database.sessions[sessionIndex].images?[imageIndex].deletedAt = deleted ? Date() : nil
        database.sessions[sessionIndex].updatedAt = Date()
        guard persistNow() else { database = before; return }
        if deleted && selectedImageID == id { selectedImageID = nil }
    }

    private static func imageInputMatches(_ current: ImageAttachment, _ baseline: ImageAttachment) -> Bool {
        current.id == baseline.id && current.sha256 == baseline.sha256 && current.relativePath == baseline.relativePath &&
        current.mimeType == baseline.mimeType && current.width == baseline.width && current.height == baseline.height &&
        current.title == baseline.title && current.note == baseline.note && current.anchorTime == baseline.anchorTime &&
        current.anchorSpanID == baseline.anchorSpanID && current.attachedNodeID == baseline.attachedNodeID &&
        current.deletedAt == baseline.deletedAt
    }

    @discardableResult
    func applyImageAnalyses(_ results: [ImageAnalysisResult], inputs: [ImageAttachment], sessionID: UUID) -> Bool {
        guard !results.isEmpty else { return true }
        guard let sessionIndex = database.sessions.firstIndex(where: { $0.id == sessionID && $0.deletedAt == nil }),
              Set(results.map(\.id)).count == results.count, Set(inputs.map(\.id)).count == inputs.count else { return false }
        // A stale or malformed response rejects the whole result set; it must
        // not be reported as saved after silently skipping affected images.
        for result in results {
            guard !result.fingerprint.isEmpty, result.fingerprint.count <= 256, !result.model.isEmpty,
                  result.model.count <= 256, result.extractedText.count <= 100_000,
                  !result.explanation.isEmpty, result.explanation.count <= 100_000,
                  result.uncertainties.count <= 100, result.uncertainties.allSatisfy({ $0.count <= 4000 }),
                  let baseline = inputs.first(where: { $0.id == result.id && $0.deletedAt == nil }),
                  let current = database.sessions[sessionIndex].images?.first(where: { $0.id == result.id }),
                  Self.imageInputMatches(current, baseline) else { return false }
        }
        let before = database
        var changed = false
        for result in results {
            guard let index = database.sessions[sessionIndex].images?.firstIndex(where: { $0.id == result.id }),
                  let current = database.sessions[sessionIndex].images?[index] else { database = before; return false }
            if current.analysis != result.analysis || current.analysisError != nil {
                database.sessions[sessionIndex].images?[index].analysis = result.analysis
                database.sessions[sessionIndex].images?[index].analysisError = nil
                changed = true
            }
        }
        guard changed else { return true }
        database.sessions[sessionIndex].updatedAt = Date()
        guard persistNow() else { database = before; return false }
        return true
    }

    func recordImageFailure(_ detail: String, inputs: [ImageAttachment], sessionID: UUID) {
        guard let sessionIndex = database.sessions.firstIndex(where: { $0.id == sessionID && $0.deletedAt == nil }) else { return }
        let before = database
        var changed = false
        for baseline in inputs where baseline.deletedAt == nil {
            guard let index = database.sessions[sessionIndex].images?.firstIndex(where: { $0.id == baseline.id }),
                  let current = database.sessions[sessionIndex].images?[index], Self.imageInputMatches(current, baseline),
                  current.analysisError != detail else { continue }
            database.sessions[sessionIndex].images?[index].analysisError = detail
            changed = true
        }
        guard changed else { return }
        database.sessions[sessionIndex].updatedAt = Date()
        if !persistNow() { database = before }
    }

    func preparePortableSessions(_ records: [SessionRecord]) throws -> [SessionRecord] {
        var dataByHash: [String: Data] = [:]
        func hydrate(_ image: ImageAttachment, sessionID: UUID) throws -> ImageAttachment {
            var copy = image
            if let cached = dataByHash[image.sha256] { copy.portableData = cached }
            else {
                copy.portableData = try imageData(image, preferredSessionID: sessionID)
                dataByHash[image.sha256] = copy.portableData
            }
            try ImageAttachmentValidation.validate(copy, requireData: true)
            return copy
        }
        return try records.map { record in
            var copy = record
            copy.images = try record.images?.map { try hydrate($0, sessionID: record.id) }
            copy.versions = try record.versions.map { version in
                var value = version; value.images = try version.images?.map { try hydrate($0, sessionID: record.id) }; return value
            }
            copy.candidateVersions = try record.candidateVersions?.map { version in
                var value = version; value.images = try version.images?.map { try hydrate($0, sessionID: record.id) }; return value
            }
            return copy
        }
    }

    private func imageData(_ image: ImageAttachment, preferredSessionID: UUID) throws -> Data {
        if let data = image.portableData { return data }
        if let data = try? ImageFiles.verifiedData(image, directory: sessionDirectory(preferredSessionID)) { return data }
        if let origin = image.origin,
           let source = database.sessions.first(where: { $0.id == origin.sessionID }),
           let original = (source.images ?? []).first(where: { $0.id == origin.itemID && $0.sha256 == image.sha256 }),
           let data = try? ImageFiles.verifiedData(original, directory: sessionDirectory(source.id)) { return data }
        for source in database.sessions {
            let images = (source.images ?? []) + (source.versions + (source.candidateVersions ?? [])).flatMap { $0.images ?? [] }
            if let original = images.first(where: { $0.sha256 == image.sha256 && $0.relativePath == image.relativePath }),
               let data = try? ImageFiles.verifiedData(original, directory: sessionDirectory(source.id)) { return data }
        }
        throw ImageFileFailure.invalid("找不到通过校验的原图：\(image.title)")
    }

    private func materializeImages(in record: inout SessionRecord) throws {
        let recordID = record.id
        let directory = try prepareImageDirectory(recordID)
        var persisted: [String: String] = [:]
        var identities = Set<UUID>()
        func materialize(_ image: ImageAttachment) throws -> ImageAttachment {
            var copy = image
            identities.insert(image.id)
            guard identities.count <= ImageFiles.maximumCount else { throw ImageFileFailure.invalid("单场最多保存 50 张图片。") }
            let data = try imageData(image, preferredSessionID: recordID)
            copy.portableData = data
            try ImageAttachmentValidation.validate(copy, requireData: true)
            guard let path = ImageAttachmentValidation.portablePath(id: image.id, mimeType: image.mimeType) else {
                throw ImageFileFailure.invalid("图片格式不支持。")
            }
            copy.relativePath = path
            guard let url = ImageFiles.resolve(copy, directory: directory) else { throw ImageFileFailure.invalid("图片保存路径无效。") }
            if let existing = persisted[path] {
                guard existing == image.sha256 else { throw ImageFileFailure.invalid("同一张图片在版本中出现冲突，未覆盖原图。") }
            } else {
                guard !FileManager.default.fileExists(atPath: url.path) else { throw ImageFileFailure.invalid("图片目标已存在，未覆盖。") }
                try data.write(to: url, options: .atomic)
                persisted[path] = image.sha256
            }
            copy.portableData = nil
            return copy
        }
        let originals = record.images
        let versions = record.versions
        let candidates = record.candidateVersions
        record.images = try originals?.map(materialize)
        record.versions = try versions.map { value in
            var copy = value; copy.images = try value.images?.map(materialize); return copy
        }
        record.candidateVersions = try candidates?.map { value in
            var copy = value; copy.images = try value.images?.map(materialize); return copy
        }
    }

    func openOrigin(_ reference: SourceReference) {
        guard let original = activeSessions.first(where: { $0.id == reference.sessionID }) else {
            statusMessage = "原记录“\(reference.sessionTitle)”当前不在知识库中，可能在最近删除中或来自另一台电脑。本图保存的原文仍可查看。"
            return
        }
        if original.nodes.contains(where: { $0.id == reference.itemID && !$0.isDeleted }) {
            selectSession(original.id, highlight: reference.itemID)
        } else if original.transcript.contains(where: { $0.id == reference.itemID }) {
            selectSession(original.id)
            selectedTranscriptSpanID = reference.itemID
        } else if (original.images ?? []).contains(where: { $0.id == reference.itemID }) {
            selectSession(original.id)
            selectedImageID = reference.itemID
        } else {
            selectSession(original.id)
            statusMessage = "已打开原记录；该节点或原稿版本已变化，本图仍保留组合时的原文。"
        }
    }

    var selectedSession: SessionRecord? {
        guard let selectedSessionID else { return nil }
        return database.sessions.first(where: { $0.id == selectedSessionID })
    }

    var searchHits: [SearchHit] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return search(query)
    }

    @discardableResult
    func createSession(title: String, sourceName: String, sourceKind: String) -> UUID {
        let host = Speaker(role: .host)
        let session = SessionRecord(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名记录" : title,
            sourceName: sourceName,
            sourceKind: sourceKind,
            speakers: [host]
        )
        database.sessions.append(session)
        if let collectionID = selectedCollectionID,
           let index = database.collections?.firstIndex(where: { $0.id == collectionID }) {
            database.collections?[index].sessionIDs.append(session.id)
        }
        selectedSessionID = session.id
        selectedNodeID = nil
        persistSoon()
        return session.id
    }

    func selectSession(_ id: UUID, highlight nodeID: UUID? = nil) {
        selectedTranscriptSpanID = nil
        selectedImageID = nil
        selectedSessionID = id
        selectedNodeID = nodeID
        highlightedNodeID = nodeID
        if let nodeID {
            mutateSession(id) { session in
                var next = session.nodes.first(where: { $0.id == nodeID })?.parentID
                var visited = Set<UUID>()
                while let ancestor = next, visited.insert(ancestor).inserted,
                      let index = session.nodes.firstIndex(where: { $0.id == ancestor && !$0.isDeleted }) {
                    session.nodes[index].isCollapsed = false
                    next = session.nodes[index].parentID
                }
            }
        }
        if nodeID != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if self.highlightedNodeID == nodeID { self.highlightedNodeID = nil }
            }
        }
    }

    /// Starting again from a completed record is a new listening session, never
    /// permission to overwrite its audio, transcript or hand-edited outline.
    func sessionForNewRecording(from id: UUID) -> UUID {
        guard let session = database.sessions.first(where: { $0.id == id }) else { return id }
        guard !session.audioRelativePaths.isEmpty || !session.transcript.isEmpty || session.structureSaved || session.images?.isEmpty == false else { return id }
        return createSession(title: session.title, sourceName: session.sourceName, sourceKind: session.sourceKind)
    }

    func selectSearchHit(_ hit: SearchHit) {
        selectSession(hit.sessionID, highlight: hit.nodeID)
        selectedTranscriptSpanID = hit.kind == .transcript ? hit.spanID : nil
        selectedImageID = hit.kind == .image ? hit.imageID : nil
    }

    func updateTitle(_ title: String, sessionID: UUID) {
        mutateSession(sessionID) { session in
            session.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名记录" : title
        }
    }

    func setStatus(_ status: SessionStatus, sessionID: UUID, endedAt: Date? = nil) {
        mutateSession(sessionID) { session in
            session.status = status
            if status == .recording || status == .processing { session.recoveryPending = true }
            if status == .ready { session.recoveryPending = false }
            if let endedAt { session.endedAt = endedAt }
        }
    }

    var isEphemeral: Bool { inMemory }

    @discardableResult
    func prepareFocusedStudy(_ question: String, sessionID: UUID) -> Bool {
        mutateSession(sessionID) { session in
            session.focusedStudyQuestion = question
            session.focusedStudyError = nil
        }
        return flush()
    }

    func failFocusedStudy(_ message: String, sessionID: UUID) {
        mutateSession(sessionID) { $0.focusedStudyError = message }
        flush()
    }

    @discardableResult
    func saveFocusedStudy(_ report: FocusedStudyReport, sessionID: UUID, baseline: [TranscriptSpan], imageBaseline: [ImageAttachment]? = nil) -> Bool {
        guard let session = database.sessions.first(where: { $0.id == sessionID }), session.deletedAt == nil,
              session.transcript == baseline else {
            failFocusedStudy("整理期间原稿有变化，本次结果没有写入；请用最新稿件重新整理。", sessionID: sessionID)
            return false
        }
        if let imageBaseline {
            let active = (session.images ?? []).filter { $0.deletedAt == nil }
            let expected = imageBaseline.filter { $0.deletedAt == nil }
            guard active.count == expected.count, expected.allSatisfy({ image in
                active.contains { Self.imageInputMatches($0, image) }
            }) else {
                failFocusedStudy("整理期间图片或关联有变化，本次结果没有写入；请用最新材料重新整理。", sessionID: sessionID)
                return false
            }
        }
        let known = Set(baseline.map(\.id))
        let knownImages = Set((session.images ?? []).filter { $0.deletedAt == nil }.map(\.id))
        guard !report.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              report.question == session.focusedStudyQuestion,
              report.sections.count <= 1024,
              Set(report.sections.map(\.id)).count == report.sections.count,
              !report.sections.isEmpty || !report.gaps.isEmpty,
              report.gaps.allSatisfy({ !$0.isEmpty && $0.count <= 4000 }),
              report.sections.allSatisfy({
                  !$0.heading.isEmpty && $0.heading.count <= 100 && !$0.explanation.isEmpty && $0.explanation.count <= 100_000
                  && (!$0.sourceSpanIDs.isEmpty || $0.sourceImageIDs?.isEmpty == false)
                  && Set($0.sourceSpanIDs).isSubset(of: known)
                  && Set($0.sourceImageIDs ?? []).isSubset(of: knownImages)
                  && Set($0.sourceSpanIDs).count == $0.sourceSpanIDs.count
                  && Set($0.sourceImageIDs ?? []).count == ($0.sourceImageIDs?.count ?? 0)
              }) else {
            failFocusedStudy("专题结果缺少有效原文依据，未替换任何已有内容。", sessionID: sessionID)
            return false
        }
        mutateSession(sessionID) { record in
            var reports = record.focusedStudyReports ?? []
            if !reports.contains(where: { $0.id == report.id }) { reports.append(report) }
            record.focusedStudyReports = reports
            record.focusedStudyError = nil
        }
        let saved = flush()
        if !saved {
            mutateSession(sessionID) { $0.focusedStudyError = "专题已生成，但尚未成功保存。请保留应用打开，处理首页显示的保存问题。" }
        }
        return saved
    }

    func recordProcessingFailure(_ detail: String, sessionID: UUID) {
        mutateSession(sessionID) { $0.lastProcessingError = detail }
    }

    func prepareProcessingJob(sessionID: UUID, runLabel: String, retranscribe: Bool, resetBudget: Bool) {
        mutateSession(sessionID) { session in
            session.processingRunLabel = runLabel
            session.processingRetranscribe = retranscribe
            session.recoveryPending = true
            session.status = .processing
            if resetBudget { session.automaticRecoveryAttempts = 0 }
        }
        flush()
    }

    func beginProcessingAttempt(sessionID: UUID, resetBudget: Bool, runLabel: String? = nil, retranscribe: Bool = false) {
        mutateSession(sessionID) { session in
            session.automaticRecoveryAttempts = resetBudget ? 1 : (session.automaticRecoveryAttempts ?? 0) + 1
            session.recoveryPending = true
            session.status = .processing
            session.processingRunLabel = runLabel
            session.processingRetranscribe = retranscribe
        }
        flush()
    }

    @discardableResult
    func finishProcessingAttempts(sessionID: UUID) -> Bool {
        mutateSession(sessionID) {
            $0.recoveryPending = false
            $0.processingRunLabel = nil
            $0.processingRetranscribe = nil
        }
        return flush()
    }

    func attachAudio(paths: [String], sessionID: UUID) {
        mutateSession(sessionID) { session in
            session.audioRelativePaths = paths
            session.audioState = paths.isEmpty ? .none : .retained
            session.audioTrashedAt = nil
            session.audioRestoredAt = nil
        }
    }

    @discardableResult
    func registerCaptureInterruption(_ interruption: CaptureInterruption) -> Bool {
        guard !handledCaptureInterruptionIDs.contains(interruption.id),
              database.sessions.contains(where: { $0.id == interruption.sessionID }) else { return false }
        handledCaptureInterruptionIDs.insert(interruption.id)
        let paths = interruption.urls.map(\.path)
        attachAudio(paths: paths, sessionID: interruption.sessionID)
        setStatus(paths.isEmpty ? .failed : .processing, sessionID: interruption.sessionID, endedAt: interruption.occurredAt)
        statusMessage = paths.isEmpty
            ? "声音来源异常中断，编码器已安全结束，但本次没有收到可保存的音频。"
            : interruption.message
        return true
    }

    func restoreRecoverableAudio(sessionID: UUID) {
        guard let index = database.sessions.firstIndex(where: { $0.id == sessionID }),
              database.sessions[index].audioState == .recoverableTrash else { return }
        let fileManager = FileManager.default
        let root = sessionDirectory(sessionID).standardizedFileURL
        let destinationDirectory = root.appendingPathComponent("AudioRecovered", isDirectory: true)
        var performedMoves: [(from: URL, to: URL)] = []
        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            var restored: [String] = []
            for rawPath in database.sessions[index].audioRelativePaths {
                let source = URL(fileURLWithPath: rawPath).standardizedFileURL
                guard isWithinSession(source, root: root) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                var destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) {
                    destination = destinationDirectory.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)")
                }
                try fileManager.moveItem(at: source, to: destination)
                performedMoves.append((from: source, to: destination))
                restored.append(destination.path)
            }
            database.sessions[index].audioRelativePaths = restored
            database.sessions[index].audioState = .retained
            database.sessions[index].audioTrashedAt = nil
            database.sessions[index].audioRestoredAt = Date()
            database.sessions[index].updatedAt = Date()
            persistSoon()
            statusMessage = "音频已从可恢复区移回会话，并重新获得 14 天本机保留期。"
        } catch {
            for move in performedMoves.reversed() where fileManager.fileExists(atPath: move.to.path) {
                try? fileManager.moveItem(at: move.to, to: move.from)
            }
            statusMessage = "音频恢复失败，原文件不会被永久清理：\(error.localizedDescription)"
        }
    }

    func updateSource(name: String, kind: String, sessionID: UUID) {
        mutateSession(sessionID) { session in
            session.sourceName = name
            session.sourceKind = kind
        }
    }

    func appendTranscript(_ spans: [TranscriptSpan], sessionID: UUID) {
        guard !spans.isEmpty else { return }
        mutateSession(sessionID) { session in
            let known = Set(session.transcript.map(\.id))
            session.transcript.append(contentsOf: spans.filter { !known.contains($0.id) })
            session.transcript.sort { $0.sequence < $1.sequence }
        }
    }

    func appendLiveTranscription(_ result: LocalProcessingResult, sessionID: UUID, timeOffset: TimeInterval) {
        guard !result.spans.isEmpty else { return }
        mutateSession(sessionID) { session in
            let stableSpeaker: Speaker
            if let existing = session.speakers.first {
                stableSpeaker = existing
            } else if let incoming = result.speakers.first {
                stableSpeaker = incoming
                session.speakers = [incoming]
            } else {
                stableSpeaker = Speaker(role: .unknown, displayName: "说话人 1")
                session.speakers = [stableSpeaker]
            }
            let startingSequence = session.transcript.count
            for (index, incoming) in result.spans.enumerated() {
                session.transcript.append(
                    TranscriptSpan(
                        sequence: startingSequence + index + 1,
                        startTime: timeOffset + incoming.startTime,
                        endTime: timeOffset + incoming.endTime,
                        speakerID: stableSpeaker.id,
                        originalText: incoming.originalText,
                        isImportant: false,
                        isBackgroundAudio: incoming.isBackgroundAudio,
                        punctuatedText: incoming.punctuatedText
                    )
                )
            }
            Self.resolveTimedMarks(in: &session)
            Self.ensureUserArtifacts(in: &session)
            session.status = .recording
        }
    }

    @discardableResult
    func completeLocalProcessing(_ result: LocalProcessingResult, sessionID: UUID, reportIssues: Bool = true) -> Bool {
        // A new recognizer may completely change segmentation and source IDs.
        // Build its manuscript and map together off to the side: presenting
        // old nodes against the new manuscript would silently destroy evidence.
        if let existing = database.sessions.first(where: { $0.id == sessionID }),
           existing.structureSaved || existing.nodes.contains(where: {
               !$0.isDeleted && $0.kind != .thought && $0.thoughtID == nil && $0.importantMarkID == nil
           }) {
            let staging = AppStore(inMemory: true)
            var draft = existing
            draft.nodes = draft.nodes.filter { $0.kind == .thought || $0.thoughtID != nil || $0.importantMarkID != nil }
            draft.structureSaved = false
            draft.versions = []
            draft.candidateVersions = []
            draft.audioRelativePaths = []
            draft.audioState = .none
            staging.database = AppDatabase(sessions: [draft], settings: database.settings)
            staging.completeLocalProcessingDirect(result, sessionID: sessionID, reportIssues: true)
            guard let completed = staging.database.sessions.first,
                  completed.status == .ready, completed.structureSaved else {
                mutateSession(sessionID) {
                    $0.status = existing.structureSaved ? .ready : existing.status
                    $0.lastProcessingError = staging.database.sessions.first?.lastProcessingError
                        ?? "新结构整理未完成，当前逐字稿和导图未替换。"
                }
                if reportIssues { statusMessage = "新分析未完成，当前逐字稿、人工修正和导图保持不变。\(staging.statusMessage ?? "")" }
                return false
            }
            mutateSession(sessionID) { session in
                var versions = session.candidateVersions ?? []
                versions.append(Self.snapshot(completed, reason: "本地重新转写与导图候选"))
                if versions.count > 20 { versions.removeFirst(versions.count - 20) }
                session.candidateVersions = versions
                session.status = .ready
                session.lastProcessingError = nil
            }
            if reportIssues { statusMessage = "新逐字稿与导图已一起保存为候选；接受前不会改动当前原文、人工修正和编辑。" }
            return true
        }
        return completeLocalProcessingDirect(result, sessionID: sessionID, reportIssues: reportIssues)
    }

    /// Preserve a completed reading-aid attempt when map generation failed.
    /// No manuscript, map, annotation, or historical version is replaced.
    @discardableResult
    func preserveProofreadingAfterFailure(_ result: LocalProcessingResult, matching baseline: SessionRecord) -> Bool {
        guard result.candidates.isEmpty, !result.spans.isEmpty,
              let index = database.sessions.firstIndex(where: { $0.id == baseline.id }),
              database.sessions[index].deletedAt == nil,
              database.sessions[index].transcript == baseline.transcript,
              database.sessions[index].speakers == baseline.speakers,
              database.sessions[index].versions == baseline.versions,
              result.speakers == baseline.speakers,
              result.spans.count == baseline.transcript.count else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func withoutProofreading(_ span: TranscriptSpan) -> TranscriptSpan {
            var copy = span
            copy.proofreadText = nil; copy.proofreadBasis = nil
            copy.proofreadUncertainties = nil; copy.proofreadingVersion = nil
            copy.proofreadPunctuatedText = nil
            return copy
        }
        // Compare encoded source fields as bytes, including wording, manual
        // corrections, origin, speaker, timestamps, importance and filtering.
        guard let expected = try? encoder.encode(baseline.transcript.map(withoutProofreading)),
              let actual = try? encoder.encode(result.spans.map(withoutProofreading)),
              expected == actual,
              let current = try? encoder.encode(database.sessions[index].transcript),
              let original = try? encoder.encode(baseline.transcript),
              current == original else { return false }
        var spans = baseline.transcript
        for i in spans.indices where !spans[i].hasManualCorrection && spans[i].origin?.authoredByUser != true {
            let attempt = result.spans[i]
            guard attempt.validProofreadText != nil, attempt.proofreadUncertainties != nil else { continue }
            spans[i].proofreadText = attempt.proofreadText
            spans[i].proofreadBasis = attempt.proofreadBasis
            spans[i].proofreadUncertainties = attempt.proofreadUncertainties
            spans[i].proofreadingVersion = attempt.proofreadingVersion
            spans[i].proofreadPunctuatedText = attempt.proofreadPunctuatedText
        }
        guard spans != baseline.transcript else { return false }
        database.sessions[index].transcript = spans
        database.sessions[index].updatedAt = Date()
        persistSoon()
        return flush()
    }

    @discardableResult
    private func completeLocalProcessingDirect(_ result: LocalProcessingResult, sessionID: UUID, reportIssues: Bool) -> Bool {
        let previousMessage = statusMessage
        defer { if !reportIssues { statusMessage = previousMessage } }
        var incomingSpans = result.spans.sorted { $0.sequence < $1.sequence }
        var remappedCandidates = result.candidates
        let existingSession = database.sessions.first(where: { $0.id == sessionID })
        var resolvedSpeakers = result.speakers
        if let existing = existingSession {
            for index in resolvedSpeakers.indices where existing.speakers.indices.contains(index) {
                resolvedSpeakers[index].displayName = existing.speakers[index].displayName
                resolvedSpeakers[index].role = existing.speakers[index].role
            }
        }
        if let existing = existingSession, !existing.transcript.isEmpty {
            var idMap: [UUID: UUID] = [:]
            for index in incomingSpans.indices {
                guard let old = existing.transcript.first(where: {
                    $0.originalText == incomingSpans[index].originalText
                        && abs($0.startTime - incomingSpans[index].startTime) < 0.05
                        && abs($0.endTime - incomingSpans[index].endTime) < 0.05
                }) else { continue }
                idMap[incomingSpans[index].id] = old.id
                incomingSpans[index].id = old.id
                incomingSpans[index].correctedText = old.correctedText
                incomingSpans[index].isImportant = old.isImportant
            }
            for index in remappedCandidates.indices {
                remappedCandidates[index].sourceSpanIDs = remappedCandidates[index].sourceSpanIDs.map { idMap[$0] ?? $0 }
                remappedCandidates[index].coveredSourceSpanIDs = remappedCandidates[index].coveredSourceSpanIDs?.map { idMap[$0] ?? $0 }
                func remapExcerpt(_ excerpt: OriginalExcerpt) -> OriginalExcerpt {
                    var excerpt = excerpt
                    excerpt.parts = excerpt.parts.map { part in
                        var part = part; part.sourceID = idMap[part.sourceID] ?? part.sourceID; return part
                    }
                    return excerpt
                }
                remappedCandidates[index].coreOriginals = remappedCandidates[index].coreOriginals?.map(remapExcerpt)
                remappedCandidates[index].conditionOriginals = remappedCandidates[index].conditionOriginals?.map(remapExcerpt)
            }
        }
        mutateSession(sessionID, snapshotReason: "本地转写完成前") { session in
            session.analysisWarnings = result.warnings
            // Legacy marks did not carry a time anchor. Resolve one while the
            // old transcript is still available, before switching source IDs.
            Self.anchorLegacyMarks(in: &session)
            session.nodes = Self.migrateAuthoredEvidence(session.nodes, from: session.transcript, to: incomingSpans)
            session.speakers = resolvedSpeakers
            session.transcript = incomingSpans
            var marks = session.importantMarks ?? []
            for timestamp in session.pendingImportantTimes ?? [] {
                guard let anchorIndex = session.transcript.indices.min(by: {
                    abs((session.transcript[$0].startTime + session.transcript[$0].endTime) / 2 - timestamp)
                        < abs((session.transcript[$1].startTime + session.transcript[$1].endTime) / 2 - timestamp)
                }) else { continue }
                let lower = max(session.transcript.startIndex, anchorIndex - 2)
                let upper = min(session.transcript.index(before: session.transcript.endIndex), anchorIndex + 2)
                let protectedIDs = (lower...upper).map { session.transcript[$0].id }
                for index in lower...upper { session.transcript[index].isImportant = true }
                marks.append(ImportantMark(anchorSpanID: session.transcript[anchorIndex].id, protectedSpanIDs: protectedIDs, anchorTime: timestamp))
            }
            session.importantMarks = marks
            session.pendingImportantTimes = []
            Self.resolveTimedMarks(in: &session)
            Self.ensureUserArtifacts(in: &session)
            for summary in result.annotationSummaries ?? [] where !summary.summary.isEmpty && summary.summary.count <= 160 {
                if let inputs = result.annotationInputs {
                    guard let originalInput = inputs.first(where: { $0.id == summary.id }),
                          existingSession.map(AnnotationInput.from)?.contains(originalInput) == true else { continue }
                }
                if let index = session.nodes.firstIndex(where: { $0.thoughtID == summary.id || $0.importantMarkID == summary.id }) {
                    session.nodes[index].aiSummary = summary.summary
                    session.nodes[index].annotationInputFingerprint = AnnotationInput.from(session).first { $0.id == summary.id }?.fingerprint
                }
            }
            session.transcriptComplete = true
            session.status = .processing
        }
        do {
            if remappedCandidates.isEmpty {
                setStatus(.failed, sessionID: sessionID)
                let detail = result.processingError ?? "结构模型没有生成可用的导图；逐字稿已经保存。"
                recordProcessingFailure(detail, sessionID: sessionID)
                statusMessage = "逐字稿已在本机完成并保存，但知识结构尚未完成。\(detail)"
            } else {
                try applyStructureCandidates(remappedCandidates, sessionID: sessionID)
                mutateSession(sessionID) { $0.lastProcessingError = nil }
                if let warning = result.warnings.first, !warning.isEmpty {
                    statusMessage = "逐字稿和骨架已保存。\(warning)"
                }
            }
        } catch {
            setStatus(.failed, sessionID: sessionID)
            recordProcessingFailure("结构候选被来源校验拒绝：\(error.localizedDescription)", sessionID: sessionID)
            statusMessage = "逐字稿已保存，但结构候选被来源校验拒绝：\(error.localizedDescription)"
        }
        return database.sessions.first(where: { $0.id == sessionID })?.status == .ready
    }

    @discardableResult
    func importTranscriptText(_ text: String, sessionID: UUID) -> UUID? {
        let lines = text.split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            statusMessage = "文件没有可导入的文字，现有记录未改变。"
            return nil
        }
        guard let original = database.sessions.first(where: { $0.id == sessionID }) else { return nil }
        // Imported prose has no verified timing relationship with the current
        // audio. Do not remap existing authored work using invented timestamps.
        let hasContent = !original.transcript.isEmpty || !original.nodes.isEmpty ||
            !original.thoughts.isEmpty || !(original.importantMarks ?? []).isEmpty ||
            !(original.pendingImportantTimes ?? []).isEmpty || !original.audioRelativePaths.isEmpty ||
            original.images?.isEmpty == false ||
            [.recording, .paused, .processing].contains(original.status)
        var imported = SessionRecord(
            title: hasContent ? original.title + " · 导入稿" : original.title,
            sourceName: "本地文本", sourceKind: "文本导入（无音频时间）", status: .failed,
            transcriptComplete: true
        )
        var speakerIDs: [String: UUID] = [:]
        for (index, line) in lines.enumerated() {
            let parsed = Self.parseSpeakerPrefix(line)
            let speakerID: UUID
            if let existing = speakerIDs[parsed.name] { speakerID = existing }
            else {
                let speaker = Speaker(role: parsed.role, displayName: parsed.name)
                imported.speakers.append(speaker)
                speakerIDs[parsed.name] = speaker.id
                speakerID = speaker.id
            }
            imported.transcript.append(TranscriptSpan(
                sequence: index + 1, startTime: Double(index), endTime: Double(index + 1),
                speakerID: speakerID, originalText: parsed.text
            ))
        }
        if hasContent {
            let ids = addLibraryRecords([imported], collectionID: selectedCollectionID)
            guard let id = ids.first else { return nil }
            // Also keep the imported copy in any themes containing the source.
            for collection in collections where collection.sessionIDs.contains(original.id) {
                setCollectionMembership(sessionID: id, collectionID: collection.id, included: true)
            }
            selectSession(id)
            statusMessage = "已导入为新的记录，原来的逐字稿、导图和标注保持不变。"
            return id
        }
        imported.id = original.id
        imported.createdAt = original.createdAt
        let before = database
        if let index = database.sessions.firstIndex(where: { $0.id == original.id }) { database.sessions[index] = imported }
        guard persistNow() else { database = before; return nil }
        return original.id
    }

    func addSourceNode(spanID: UUID, kind: NodeKind, parentID: UUID?, sessionID: UUID) {
        mutateSession(sessionID, snapshotReason: "把原话加入骨架前") { session in
            guard session.transcript.contains(where: { $0.id == spanID }),
                  !session.nodes.contains(where: { !$0.isDeleted && $0.sourceSpanIDs.contains(spanID) }) else { return }
            let active = session.nodes.filter { !$0.isDeleted }
            let resolvedParent = parentID.flatMap { id in active.contains { $0.id == id } ? id : nil }
            let index = active.count
            session.nodes.append(
                KnowledgeNode(
                    sourceSpanIDs: [spanID],
                    kind: kind,
                    parentID: resolvedParent,
                    relation: resolvedParent == nil ? .root : (kind == .branch ? .parallel : .child),
                    position: Self.layoutPoint(index: index, kind: kind)
                )
            )
            session.structureSaved = true
            session.status = .ready
        }
    }

    func addThought(
        _ text: String,
        sessionID: UUID,
        attachedNodeID: UUID? = nil,
        live: Bool,
        anchorTime: TimeInterval? = nil
    ) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        mutateSession(sessionID, snapshotReason: live ? nil : "新增二次编辑前") { session in
            let resolvedAnchor = anchorTime ?? attachedNodeID.flatMap { nodeID -> TimeInterval? in
                guard let node = session.nodes.first(where: { $0.id == nodeID }) else { return nil }
                let times = node.sourceSpanIDs.compactMap { spanID -> TimeInterval? in
                    guard let span = session.transcript.first(where: { $0.id == spanID }) else { return nil }
                    return (span.startTime + span.endTime) / 2
                }
                guard !times.isEmpty else { return nil }
                return times.reduce(0, +) / Double(times.count)
            }
            session.thoughts.append(
                UserThought(
                    text: text,
                    attachedNodeID: attachedNodeID,
                    isSecondaryEdit: !live,
                    anchorTime: resolvedAnchor
                )
            )
            Self.ensureUserArtifacts(in: &session)
        }
    }

    func addUserNode(_ text: String, kind: NodeKind, parentID: UUID?, sessionID: UUID) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        mutateSession(sessionID, snapshotReason: "新增二次编辑节点前") { session in
            let index = session.nodes.filter { !$0.isDeleted }.count
            session.nodes.append(
                KnowledgeNode(
                    sourceSpanIDs: [],
                    kind: kind,
                    parentID: parentID,
                    relation: parentID == nil ? .root : .child,
                    position: CanvasPoint(x: 220 + Double(index % 4) * 330, y: 180 + Double(index / 4) * 210),
                    userEditedText: cleaned,
                    isSecondaryEdit: true
                )
            )
        }
    }

    func updateNodePosition(_ nodeID: UUID, point: CanvasPoint, sessionID: UUID, displayedPositions: [UUID: CanvasPoint] = [:]) {
        guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 100_000, abs(point.y) <= 100_000 else {
            statusMessage = "本次拖动坐标异常，已保留原位置。"
            return
        }
        mutateSession(sessionID, persistDebounced: true) { session in
            guard let index = session.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            // Commit the displayed overview once before a manual move. Otherwise
            // its collision-avoidance layout moves unrelated nodes on release.
            // These peers are positioned, not marked as manually edited content.
            for peer in session.nodes.indices {
                guard let displayed = displayedPositions[session.nodes[peer].id],
                      displayed.x.isFinite, displayed.y.isFinite,
                      abs(displayed.x) <= 100_000, abs(displayed.y) <= 100_000 else { continue }
                session.nodes[peer].position = displayed
                session.nodes[peer].positionIsAutomatic = false
            }
            session.nodes[index].position = point
            session.nodes[index].manualRevisionAt = Date()
            session.nodes[index].positionEditedAt = Date()
            session.nodes[index].positionIsAutomatic = false
        }
    }

    func toggleNodeCollapsed(_ nodeID: UUID, sessionID: UUID) {
        mutateSession(sessionID) { session in
            guard let index = session.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            session.nodes[index].isCollapsed.toggle()
        }
    }

    func setNodeKind(_ nodeID: UUID, kind: NodeKind, sessionID: UUID) {
        mutateSession(sessionID, snapshotReason: "改变节点类型前") { session in
            guard let index = session.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            session.nodes[index].kind = kind
            session.nodes[index].manualRevisionAt = Date()
            if session.nodes[index].parentID != nil {
                session.nodes[index].relation = kind == .branch ? .parallel : .child
            }
        }
    }

    func renameNode(_ nodeID: UUID, label: String, sessionID: UUID) {
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        mutateSession(sessionID, snapshotReason: "人工命名节点前") { session in
            guard let index = session.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            session.nodes[index].userLabel = cleaned.isEmpty ? nil : cleaned
            session.nodes[index].semanticRole = nil
            session.nodes[index].manualRevisionAt = Date()
        }
    }

    func reparentNode(_ nodeID: UUID, to parentID: UUID?, sessionID: UUID) {
        mutateSession(sessionID, snapshotReason: "重新连线前") { session in
            guard nodeID != parentID,
                  let index = session.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            if let parentID {
                let descendants = Self.descendantIDs(of: nodeID, nodes: session.nodes)
                guard !descendants.contains(parentID) else { return }
            }
            session.nodes[index].parentID = parentID
            session.nodes[index].relation = parentID == nil ? .root : (session.nodes[index].kind == .branch ? .parallel : .child)
            session.nodes[index].manualRevisionAt = Date()
        }
    }

    func softDeleteNode(_ nodeID: UUID, sessionID: UUID) {
        mutateSession(sessionID, snapshotReason: "删除节点前") { session in
            guard let index = session.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            let oldParent = session.nodes[index].parentID
            session.nodes[index].isDeleted = true
            session.nodes[index].manualRevisionAt = Date()
            for childIndex in session.nodes.indices where session.nodes[childIndex].parentID == nodeID {
                session.nodes[childIndex].parentID = oldParent
                session.nodes[childIndex].relation = oldParent == nil ? .root : .child
            }
        }
        if selectedNodeID == nodeID { selectedNodeID = nil }
    }

    func mergeSourceNodes(primaryID: UUID, secondaryID: UUID, sessionID: UUID) {
        guard primaryID != secondaryID else { return }
        if let session = database.sessions.first(where: { $0.id == sessionID }),
           let primary = session.nodes.first(where: { $0.id == primaryID }),
           let secondary = session.nodes.first(where: { $0.id == secondaryID }) {
            let archives = Dictionary(uniqueKeysWithValues: (primary.archivedSourceSpans ?? []).map { ($0.id, $0) })
            if (secondary.archivedSourceSpans ?? []).contains(where: { archives[$0.id] != nil && archives[$0.id] != $0 }) {
                statusMessage = "这两个节点引用了同一句原话的不同修正版，暂不能直接合并；两份节点和原文均已保留。"
                return
            }
        }
        mutateSession(sessionID, snapshotReason: "合并节点前") { session in
            guard let primaryIndex = session.nodes.firstIndex(where: { $0.id == primaryID && !$0.isDeleted }),
                  let secondaryIndex = session.nodes.firstIndex(where: { $0.id == secondaryID && !$0.isDeleted }),
                  !session.nodes[primaryIndex].isSecondaryEdit,
                  !session.nodes[secondaryIndex].isSecondaryEdit else { return }
            let additions = session.nodes[secondaryIndex].sourceSpanIDs.filter {
                !session.nodes[primaryIndex].sourceSpanIDs.contains($0)
            }
            session.nodes[primaryIndex].sourceSpanIDs.append(contentsOf: additions)
            let secondary = session.nodes[secondaryIndex]
            session.nodes[primaryIndex].sourceImageIDs = Array(Set((session.nodes[primaryIndex].sourceImageIDs ?? []) + (secondary.sourceImageIDs ?? [])))
            session.nodes[primaryIndex].coveredSourceImageIDs = Array(Set((session.nodes[primaryIndex].coveredSourceImageIDs ?? []) + (secondary.coveredSourceImageIDs ?? [])))
            let primaryText = IntegrityValidator.visibleText(for: session.nodes[primaryIndex], transcript: session.transcript, images: session.images ?? [])
            let secondaryText = IntegrityValidator.visibleText(for: secondary, transcript: session.transcript, images: session.images ?? [])
            let bothExtracted = session.nodes[primaryIndex].sourceBoundStatus == "extracted" && secondary.sourceBoundStatus == "extracted"
            let cores = (session.nodes[primaryIndex].coreOriginals ?? []) + (secondary.coreOriginals ?? [])
            let conditions = (session.nodes[primaryIndex].conditionOriginals ?? []) + (secondary.conditionOriginals ?? [])
            if !cores.isEmpty {
                session.nodes[primaryIndex].coreOriginals = cores
                session.nodes[primaryIndex].conditionOriginals = conditions
                session.nodes[primaryIndex].aiSummary = bothExtracted ? cores.map(\.text).joined(separator: "\n\n") : [primaryText, secondaryText].joined(separator: "\n\n")
                session.nodes[primaryIndex].sourceBoundStatus = bothExtracted ? "extracted" : nil
                var archives = session.nodes[primaryIndex].archivedSourceSpans ?? []
                archives.append(contentsOf: (secondary.archivedSourceSpans ?? []).filter { span in !archives.contains { $0.id == span.id } })
                session.nodes[primaryIndex].archivedSourceSpans = archives
            } else if session.nodes[primaryIndex].sourceImageIDs?.isEmpty == false {
                session.nodes[primaryIndex].aiSummary = [primaryText, secondaryText].filter { !$0.isEmpty }.joined(separator: "\n\n")
                session.nodes[primaryIndex].sourceBoundStatus = nil
            }
            let coverage = (session.nodes[primaryIndex].coveredSourceSpanIDs ?? []) + (secondary.coveredSourceSpanIDs ?? [])
            session.nodes[primaryIndex].coveredSourceSpanIDs = Array(Set(coverage))
            // Combining evidence is a human operation, not a newly verified
            // model assertion. Keep every word but remove its old role claim.
            session.nodes[primaryIndex].semanticRole = nil
            session.nodes[primaryIndex].manualRevisionAt = Date()
            session.nodes[secondaryIndex].isDeleted = true
            session.nodes[secondaryIndex].manualRevisionAt = Date()
            for childIndex in session.nodes.indices where session.nodes[childIndex].parentID == secondaryID {
                session.nodes[childIndex].parentID = primaryID
            }
        }
        selectedNodeID = primaryID
    }

    func splitNodeBySource(_ nodeID: UUID, sessionID: UUID) {
        mutateSession(sessionID, snapshotReason: "拆分节点前") { session in
            guard let index = session.nodes.firstIndex(where: { $0.id == nodeID && !$0.isDeleted }),
                  !session.nodes[index].isSecondaryEdit,
                  session.nodes[index].sourceSpanIDs.count > 1 else { return }
            let original = session.nodes[index]
            let sourceIDs = original.sourceSpanIDs
            let originalChildIDs = Set(session.nodes.filter { $0.parentID == nodeID }.map(\.id))
            session.nodes[index].sourceSpanIDs = [sourceIDs[0]]
            // Explicit split-by-source returns source text, not the old
            // multi-source extracted point under one remaining source ID.
            session.nodes[index].aiSummary = nil
            session.nodes[index].argumentSummary = nil
            session.nodes[index].coreOriginals = nil
            session.nodes[index].conditionOriginals = nil
            session.nodes[index].sourceBoundStatus = nil
            session.nodes[index].navigationLabel = nil
            session.nodes[index].coveredSourceSpanIDs = [sourceIDs[0]]
            session.nodes[index].archivedSourceSpans = nil
            session.nodes[index].semanticRole = nil
            session.nodes[index].manualRevisionAt = Date()
            var previousID = original.id
            for (offset, spanID) in sourceIDs.dropFirst().enumerated() {
                let copy = KnowledgeNode(
                    sourceSpanIDs: [spanID],
                    kind: original.kind,
                    parentID: previousID,
                    relation: .child,
                    position: CanvasPoint(
                        x: original.position.x + Double(offset + 1) * 320,
                        y: original.position.y + Double(offset % 2) * 70
                    ),
                    manualRevisionAt: Date()
                )
                session.nodes.append(copy)
                previousID = copy.id
            }
            for childIndex in session.nodes.indices where originalChildIDs.contains(session.nodes[childIndex].id) {
                session.nodes[childIndex].parentID = previousID
            }
        }
    }

    func updateCorrectedText(_ corrected: String, spanID: UUID, sessionID: UUID) {
        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        mutateSession(sessionID, snapshotReason: "修正逐字稿前") { session in
            guard let index = session.transcript.firstIndex(where: { $0.id == spanID }) else { return }
            session.transcript[index].correctedText = corrected
            for nodeIndex in session.nodes.indices where session.nodes[nodeIndex].importantMarkID != nil
                && session.nodes[nodeIndex].sourceSpanIDs.contains(spanID) {
                session.nodes[nodeIndex].aiSummary = nil
                session.nodes[nodeIndex].annotationInputFingerprint = nil
            }
        }
    }

    func clearCorrectedText(spanID: UUID, sessionID: UUID) {
        mutateSession(sessionID, snapshotReason: "恢复原始识别前") { session in
            guard let index = session.transcript.firstIndex(where: { $0.id == spanID }) else { return }
            session.transcript[index].correctedText = nil
            session.transcript[index].proofreadText = nil
            session.transcript[index].proofreadBasis = nil
            session.transcript[index].proofreadUncertainties = nil
            session.transcript[index].proofreadingVersion = nil
            session.transcript[index].proofreadPunctuatedText = nil
            for index in session.nodes.indices where session.nodes[index].importantMarkID != nil && session.nodes[index].sourceSpanIDs.contains(spanID) {
                session.nodes[index].aiSummary = nil
                session.nodes[index].annotationInputFingerprint = nil
            }
        }
    }

    func renameSpeaker(_ speakerID: UUID, to newName: String, sessionID: UUID) {
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        mutateSession(sessionID) { session in
            guard let index = session.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
            session.speakers[index].displayName = cleaned
        }
    }

    func toggleImportant(spanID: UUID, sessionID: UUID) {
        mutateSession(sessionID) { session in
            guard let index = session.transcript.firstIndex(where: { $0.id == spanID }) else { return }
            session.transcript[index].isImportant.toggle()
            var marks = session.importantMarks ?? []
            if session.transcript[index].isImportant {
                if !marks.contains(where: { $0.protectedSpanIDs.contains(spanID) }) {
                    marks.append(ImportantMark(anchorSpanID: spanID, protectedSpanIDs: [spanID]))
                }
            } else {
                // Removing a time-based bookmark cancels that bookmark, rather
                // than leaving a timer that silently recreates the highlight.
                let removed = marks.filter { $0.protectedSpanIDs.contains(spanID) }
                let removedIDs = Set(removed.map(\.id))
                let affected = Set(removed.flatMap(\.protectedSpanIDs))
                marks.removeAll { removedIDs.contains($0.id) }
                for i in session.transcript.indices where affected.contains(session.transcript[i].id) {
                    session.transcript[i].isImportant = marks.contains { $0.protectedSpanIDs.contains(session.transcript[i].id) }
                }
                session.nodes.removeAll { $0.importantMarkID.map(removedIDs.contains) == true }
            }
            session.importantMarks = marks
            Self.ensureUserArtifacts(in: &session)
        }
    }

    func markLatestImportant(sessionID: UUID) {
        mutateSession(sessionID) { session in
            guard let anchorIndex = session.transcript.indices.last else { return }
            let range = max(session.transcript.startIndex, anchorIndex - 2)...anchorIndex
            let protectedIDs = range.map { session.transcript[$0].id }
            for index in range { session.transcript[index].isImportant = true }
            var marks = session.importantMarks ?? []
            marks.append(ImportantMark(anchorSpanID: session.transcript[anchorIndex].id, protectedSpanIDs: protectedIDs))
            session.importantMarks = marks
            Self.ensureUserArtifacts(in: &session)
        }
    }

    func markNearbyImportant(sessionID: UUID, elapsedTime: TimeInterval) {
        mutateSession(sessionID) { session in
            var marks = session.importantMarks ?? []
            marks.append(ImportantMark(anchorSpanID: UUID(), protectedSpanIDs: [], anchorTime: max(0, elapsedTime)))
            session.importantMarks = marks
            Self.resolveTimedMarks(in: &session)
            Self.ensureUserArtifacts(in: &session)
        }
    }

    func applyStructureCandidates(_ candidates: [StructureCandidate], sessionID: UUID) throws {
        guard let session = database.sessions.first(where: { $0.id == sessionID }) else { return }
        try IntegrityValidator.validate(candidates: candidates, transcript: session.transcript, images: session.images ?? [])
        let proposedNodes = candidates.enumerated().map { index, candidate in
            var node = KnowledgeNode(
                id: candidate.nodeID,
                sourceSpanIDs: candidate.sourceSpanIDs,
                kind: candidate.kind,
                parentID: candidate.parentID,
                relation: candidate.relation,
                confidence: candidate.confidence,
                position: Self.layoutPoint(index: index, kind: candidate.kind),
                aiSummary: candidate.summary,
                argumentSummary: candidate.argumentSummary,
                relationToPrevious: candidate.relationToPrevious,
                coveredSourceSpanIDs: candidate.coveredSourceSpanIDs,
                semanticRole: candidate.semanticRole,
                sourceImageIDs: candidate.sourceImageIDs,
                coveredSourceImageIDs: candidate.coveredSourceImageIDs
            )
            node.sourceBoundStatus = candidate.sourceBoundStatus
            node.navigationLabel = candidate.navigationLabel
            node.coreOriginals = candidate.coreOriginals
            node.conditionOriginals = candidate.conditionOriginals
            if candidate.sourceBoundStatus == "summarized" {
                // The synopsis uses the entire assigned passage, not just the
                // highlighted quotations. Preserve that full original basis.
                let sourceIDs = Set(candidate.sourceSpanIDs + (candidate.coveredSourceSpanIDs ?? []))
                node.archivedSourceSpans = session.transcript.filter { sourceIDs.contains($0.id) }
            } else if candidate.sourceBoundStatus == "extracted" {
                let excerptIDs = Set(((candidate.coreOriginals ?? []) + (candidate.conditionOriginals ?? [])).flatMap { $0.parts.map(\.sourceID) })
                node.archivedSourceSpans = session.transcript.filter { excerptIDs.contains($0.id) }
            }
            if candidate.navigationRoot == true, candidate.parentID == nil {
                node.aiSummary = nil
                node.userLabel = session.title
            }
            if candidate.sourceBoundStatus == "sourceOnly", candidate.kind == .main {
                node.aiSummary = nil
                node.userLabel = "此段原文 · 概括待确认"
            }
            return node
        }
        let nodes = Self.layoutMindMap(proposedNodes)
        for node in nodes { try IntegrityValidator.validateStoredNode(node, transcript: session.transcript, images: session.images ?? []) }
        // Listening-time annotations are not a pre-existing outline. They must
        // not turn the first automatic result into a manual approval workflow.
        let hasExistingOutline = session.structureSaved || session.nodes.contains {
            !$0.isDeleted && $0.thoughtID == nil && $0.kind != .thought && $0.importantMarkID == nil
        }
        if !hasExistingOutline {
            mutateSession(sessionID, snapshotReason: "首次生成本地结构前") { mutable in
                let annotations = mutable.nodes.filter { $0.thoughtID != nil || $0.kind == .thought || $0.importantMarkID != nil }
                mutable.nodes = nodes + annotations
                Self.ensureUserArtifacts(in: &mutable, reattachOrphans: true)
                mutable.nodes = Self.layoutMindMap(mutable.nodes)
                mutable.structureSaved = true
                mutable.status = .ready
            }
        } else {
            mutateSession(sessionID) { mutable in
                var candidates = mutable.candidateVersions ?? []
                var snapshot = Self.snapshot(mutable, reason: "本地重新分析候选")
                snapshot.nodes = nodes
                snapshot.images = Self.reconciledImages(snapshot.images, nodes: nodes, transcript: snapshot.transcript ?? mutable.transcript)
                candidates.append(snapshot)
                if candidates.count > 20 { candidates.removeFirst(candidates.count - 20) }
                mutable.candidateVersions = candidates
                mutable.status = .ready
            }
            statusMessage = "新的结构已保存为候选版本，当前人工布局和编辑没有被覆盖。"
        }
    }

    func applyAnnotationSummaries(_ summaries: [AnnotationSummary], inputs: [AnnotationInput], sessionID: UUID) {
        mutateSession(sessionID) { session in
            let current = AnnotationInput.from(session)
            for summary in summaries where !summary.summary.isEmpty && summary.summary.count <= 160 {
                guard let input = inputs.first(where: { $0.id == summary.id }),
                      current.contains(input),
                      let index = session.nodes.firstIndex(where: { !$0.isDeleted && ($0.thoughtID == summary.id || $0.importantMarkID == summary.id) }) else { continue }
                session.nodes[index].aiSummary = summary.summary
                session.nodes[index].annotationInputFingerprint = input.fingerprint
            }
        }
    }

    func acceptLatestCandidate(sessionID: UUID, arrangeAsNewMap: Bool = false) {
        guard let current = database.sessions.first(where: { $0.id == sessionID }),
              let latest = current.candidateVersions?.last else { return }
        // Legacy candidates have no manuscript of their own. After a newer
        // transcription was accepted they must not reintroduce missing IDs.
        do {
            let available = Set((latest.transcript ?? current.transcript).map(\.id))
            for node in latest.nodes where !node.isDeleted {
                if let missing = (node.sourceSpanIDs + (node.coveredSourceSpanIDs ?? [])).first(where: { !available.contains($0) }) {
                    throw IntegrityViolation.unknownSource(missing)
                }
                try IntegrityValidator.validateStoredNode(node, transcript: latest.transcript ?? current.transcript,
                                                          images: latest.images ?? current.images ?? [])
            }
        } catch {
            statusMessage = "这个旧候选不再匹配当前逐字稿，未应用任何改动。请重新分析生成完整候选。"
            return
        }
        mutateSession(sessionID, snapshotReason: "接受候选版本前") { session in
            guard var candidates = session.candidateVersions,
                  let candidate = candidates.popLast() else { return }
            if let warnings = candidate.analysisWarnings { session.analysisWarnings = warnings }
            if let candidateImages = candidate.images {
                var retained = session.images ?? []
                retained.append(contentsOf: candidateImages.filter { image in !retained.contains { $0.id == image.id } })
                session.images = retained
            }
            let oldParents = Dictionary(uniqueKeysWithValues: session.nodes.filter { $0.thoughtID != nil || $0.importantMarkID != nil }.map { ($0.id, $0.parentID) })
            if var transcript = candidate.transcript {
                for index in transcript.indices {
                    // Candidate-time highlights are stale if the user removes
                    // a mark while analysis is running. Rebuild from current
                    // marks below rather than resurrecting snapshot flags.
                    transcript[index].isImportant = false
                    if let old = session.transcript.first(where: {
                        $0.originalText == transcript[index].originalText &&
                        abs($0.startTime - transcript[index].startTime) < 0.05 &&
                        abs($0.endTime - transcript[index].endTime) < 0.05
                    }) { transcript[index].correctedText = old.correctedText }
                }
                Self.anchorLegacyMarks(in: &session)
                session.nodes = Self.migrateAuthoredEvidence(session.nodes, from: session.transcript, to: transcript)
                session.transcript = transcript
                if var speakers = candidate.speakers {
                    for index in speakers.indices where session.speakers.indices.contains(index) {
                        speakers[index].displayName = session.speakers[index].displayName
                        speakers[index].role = session.speakers[index].role
                    }
                    session.speakers = speakers
                }
                // Preserve marks/thoughts made after analysis started. Their
                // time anchors are reconciled against the accepted manuscript.
                var marks = session.importantMarks ?? []
                for time in session.pendingImportantTimes ?? [] where !marks.contains(where: { $0.anchorTime == time }) {
                    let captured = candidate.importantMarks?.first { $0.anchorTime == time }
                    marks.append(captured ?? ImportantMark(anchorSpanID: UUID(), protectedSpanIDs: [], anchorTime: time))
                }
                session.importantMarks = marks
                session.pendingImportantTimes = []
                Self.resolveTimedMarks(in: &session)
                session.transcriptComplete = candidate.transcriptComplete ?? true
            }
            let thoughtIDs = Set(session.thoughts.filter { !$0.isDeleted }.map(\.id))
            let markIDs = Set((session.importantMarks ?? []).map(\.id))
            let proposed = candidate.nodes.filter {
                ($0.thoughtID == nil || thoughtIDs.contains($0.thoughtID!)) &&
                ($0.importantMarkID == nil || markIDs.contains($0.importantMarkID!))
            }
            session.nodes = StructureVersionMerge.merge(current: session.nodes, candidate: proposed)
            let present = Set(session.nodes.map(\.id))
            for index in session.nodes.indices {
                if let oldParent = oldParents[session.nodes[index].id] ?? nil, !present.contains(oldParent) {
                    session.nodes[index].parentID = nil
                }
            }
            for index in session.thoughts.indices {
                if let old = session.thoughts[index].attachedNodeID, !present.contains(old) { session.thoughts[index].attachedNodeID = nil }
            }
            Self.ensureUserArtifacts(in: &session, reattachOrphans: true)
            // Persist the resolved link too; otherwise artifact reconciliation
            // (including after restart) can restore a removed old parent ID.
            for index in session.thoughts.indices {
                if let node = session.nodes.first(where: { $0.thoughtID == session.thoughts[index].id && !$0.isDeleted }) {
                    session.thoughts[index].attachedNodeID = node.parentID
                }
            }
            Self.ensureUserArtifacts(in: &session)
            let annotationInputs = AnnotationInput.from(session)
            for index in session.nodes.indices {
                guard let annotationID = session.nodes[index].thoughtID ?? session.nodes[index].importantMarkID,
                      let input = annotationInputs.first(where: { $0.id == annotationID }) else { continue }
                if session.nodes[index].annotationInputFingerprint != input.fingerprint {
                    session.nodes[index].aiSummary = nil
                    session.nodes[index].annotationInputFingerprint = nil
                }
                if let updated = proposed.first(where: {
                    ($0.thoughtID == annotationID || $0.importantMarkID == annotationID) &&
                    $0.annotationInputFingerprint == input.fingerprint
                }), updated.aiSummary?.isEmpty == false {
                    session.nodes[index].aiSummary = updated.aiSummary
                    session.nodes[index].annotationInputFingerprint = input.fingerprint
                }
            }
            if arrangeAsNewMap {
                let proposalRoot = candidate.nodes.first { $0.parentID == nil }
                let primaryRoot = proposalRoot.flatMap { proposal in
                    session.nodes.first { $0.id == proposal.id }?.id ??
                    session.nodes.first { StructureVersionMerge.signature($0) == StructureVersionMerge.signature(proposal) }?.id
                } ?? session.nodes.first { $0.parentID == nil && $0.thoughtID == nil && $0.importantMarkID == nil }?.id
                for index in session.nodes.indices {
                    session.nodes[index].positionEditedAt = nil
                    session.nodes[index].positionIsAutomatic = true
                    if session.nodes[index].id == primaryRoot {
                        session.nodes[index].parentID = nil
                        session.nodes[index].relation = .root
                    } else if session.nodes[index].parentID == nil, let primaryRoot {
                        session.nodes[index].parentID = primaryRoot
                        session.nodes[index].relation = .child
                    }
                }
                session.nodes = Self.layoutMindMap(session.nodes)
            }
            session.candidateVersions = candidates
            session.structureSaved = true
            session.status = .ready
        }
        if arrangeAsNewMap { canvasFitRevisions[sessionID, default: 0] += 1 }
    }

    func discardLatestCandidate(sessionID: UUID) {
        mutateSession(sessionID) { session in
            guard var candidates = session.candidateVersions, !candidates.isEmpty else { return }
            candidates.removeLast()
            session.candidateVersions = candidates
        }
    }

    func reattachThought(_ thoughtID: UUID, to nodeID: UUID?, sessionID: UUID) {
        mutateSession(sessionID, snapshotReason: "重新挂接思考前") { session in
            guard let index = session.thoughts.firstIndex(where: { $0.id == thoughtID }) else { return }
            session.thoughts[index].attachedNodeID = nodeID
            session.thoughts[index].isSecondaryEdit = true
            if let nodeID, let target = session.nodes.first(where: { $0.id == nodeID }) {
                let times = target.sourceSpanIDs.compactMap { spanID -> TimeInterval? in
                    guard let span = session.transcript.first(where: { $0.id == spanID }) else { return nil }
                    return (span.startTime + span.endTime) / 2
                }
                if !times.isEmpty {
                    session.thoughts[index].anchorTime = times.reduce(0, +) / Double(times.count)
                }
            }
            if let nodeIndex = session.nodes.firstIndex(where: { $0.thoughtID == thoughtID }) {
                session.nodes[nodeIndex].parentID = nodeID
                session.nodes[nodeIndex].relation = .userThought
            }
            Self.ensureUserArtifacts(in: &session)
        }
    }

    func moveSessionToTrash(_ id: UUID) {
        mutateSession(id) { $0.deletedAt = Date() }
        if selectedSessionID == id {
            selectedSessionID = nil
            selectedNodeID = nil
        }
    }

    func restoreSession(_ id: UUID) {
        mutateSession(id) { $0.deletedAt = nil }
    }

    func restoreLatestVersion(sessionID: UUID) {
        guard database.sessions.first(where: { $0.id == sessionID })?.versions.isEmpty == false else { return }
        mutateSession(sessionID) { session in
            guard let snapshot = session.versions.popLast() else { return }
            session.nodes = snapshot.nodes
            session.thoughts = snapshot.thoughts
            if let transcript = snapshot.transcript { session.transcript = transcript }
            if let speakers = snapshot.speakers { session.speakers = speakers }
            if let marks = snapshot.importantMarks { session.importantMarks = marks }
            if let pending = snapshot.pendingImportantTimes { session.pendingImportantTimes = pending }
            if let complete = snapshot.transcriptComplete { session.transcriptComplete = complete }
            if let saved = snapshot.structureSaved { session.structureSaved = saved }
            if let warnings = snapshot.analysisWarnings { session.analysisWarnings = warnings }
            if let images = snapshot.images {
                let laterAdditions = (session.images ?? []).filter { current in !images.contains { $0.id == current.id } }
                session.images = images + laterAdditions
            }
            session.status = session.structureSaved ? .ready : (session.transcriptComplete ? .failed : .draft)
        }
        canvasFitRevisions[sessionID, default: 0] += 1
    }

    @discardableResult
    func createMergedRecord(title: String, sourceSessionIDs: Set<UUID>) -> UUID? {
        let sources = activeSessions.filter { sourceSessionIDs.contains($0.id) }
        return createMergedRecord(title: title, sources: sources, sourceNodeIDs: nil)
    }

    @discardableResult
    func createMergedRecord(title: String, sourceNodeIDs: Set<UUID>) -> UUID? {
        let sources = activeSessions.filter { session in
            session.nodes.contains { sourceNodeIDs.contains($0.id) && !$0.isDeleted }
        }
        guard sourceNodeIDs.count >= 2 else { return nil }
        return createMergedRecord(title: title, sources: sources, sourceNodeIDs: sourceNodeIDs)
    }

    private func createMergedRecord(title: String, sources: [SessionRecord], sourceNodeIDs: Set<UUID>?) -> UUID? {
        guard var combined = KnowledgeRecordMerger.combine(title: title, sources: sources, selectedNodeIDs: sourceNodeIDs) else { return nil }
        Self.ensureUserArtifacts(in: &combined)
        let ids = addLibraryRecords([combined], collectionID: selectedCollectionID)
        guard let id = ids.first else { return nil }
        selectSession(id)
        return id
    }

    /// The knowledge-library integration flow, distinct from literal copying.
    /// Material is collected with provenance, then the local model creates the
    /// first outline. Original maps remain both at their own IDs and in a local
    /// pre-analysis snapshot; they are not spread across the new canvas.
    @discardableResult
    func createIntegrationRecord(title: String, wholeSessionIDs: Set<UUID>, topicNodeIDs: Set<UUID>) -> UUID? {
        let sources = activeSessions.filter { session in
            wholeSessionIDs.contains(session.id) || session.nodes.contains { !$0.isDeleted && topicNodeIDs.contains($0.id) }
        }
        guard var combined = KnowledgeRecordMerger.combine(title: title, sources: sources,
            selectedNodeIDs: topicNodeIDs, wholeSessionIDs: wholeSessionIDs, includeAuthoredSourceText: true),
              !combined.transcript.isEmpty || (combined.images ?? []).contains(where: { $0.deletedAt == nil }) else {
            statusMessage = "这些导图还没有可整理的原文或用户文字，未创建空的专题图。"
            return nil
        }
        combined.versions.append(Self.snapshot(combined, reason: "知识库整合前的原始材料图"))
        combined.nodes = combined.nodes.filter { $0.kind == .thought || $0.thoughtID != nil || $0.importantMarkID != nil }
        for index in combined.nodes.indices {
            combined.nodes[index].parentID = nil
            // Original layout is retained in the snapshot above. A new topic
            // needs its own layout; old dragged annotation coordinates must
            // not force the whole new canvas to zoom down to a distant note.
            combined.nodes[index].positionEditedAt = nil
            combined.nodes[index].positionIsAutomatic = true
        }
        for index in combined.thoughts.indices { combined.thoughts[index].attachedNodeID = nil }
        Self.reconcileImageLinks(in: &combined)
        combined.sourceKind = "专题整合"
        combined.structureSaved = false
        combined.status = .draft
        combined.analysisWarnings = ["正在按课程原文整合主题、重复观点与不同条件。原课程保留，新图完成后会保存到知识库。"]
        Self.ensureUserArtifacts(in: &combined)
        let ids = addLibraryRecords([combined], collectionID: selectedCollectionID)
        guard let id = ids.first else { return nil }
        // The resulting topic is also immediately discoverable as a library
        // collection, containing the integrated map and its source courses.
        if let collection = createCollection(named: title) {
            for member in sources.map(\.id) + [id] { setCollectionMembership(sessionID: member, collectionID: collection, included: true) }
        }
        selectSession(id)
        return id
    }

    func speakerName(_ id: UUID, in session: SessionRecord) -> String {
        session.speakers.first(where: { $0.id == id })?.displayName ?? "说话人"
    }

    func nodeText(_ node: KnowledgeNode, in session: SessionRecord) -> String {
        IntegrityValidator.visibleText(for: node, transcript: session.transcript, images: session.images ?? [])
    }

    func sessionDirectory(_ id: UUID) -> URL {
        dataRoot.appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func runRetentionAudit(now: Date = Date()) {
        let calendar = Calendar.current
        var changed = false
        for index in database.sessions.indices {
            guard let endedAt = database.sessions[index].endedAt,
                  database.sessions[index].audioState != .none,
                  database.sessions[index].audioState != .permanentlyDeleted else { continue }
            let retentionReference = database.sessions[index].audioRestoredAt ?? endedAt
            let days = calendar.dateComponents([.day], from: retentionReference, to: now).day ?? 0
            if database.sessions[index].audioState == .recoverableTrash,
               let trashedAt = database.sessions[index].audioTrashedAt,
               (calendar.dateComponents([.day], from: trashedAt, to: now).day ?? 0) >= 7 {
                guard IntegrityValidator.canPermanentlyDeleteAudio(from: database.sessions[index]) else { continue }
                if permanentlyDeleteAudio(for: database.sessions[index]) {
                    database.sessions[index].audioState = .permanentlyDeleted
                    database.sessions[index].audioRelativePaths = []
                    database.sessions[index].audioTrashedAt = nil
                    changed = true
                }
            } else if days >= 14, database.sessions[index].audioState == .retained {
                if let movedPaths = moveAudioToRecoverableTrash(for: database.sessions[index]) {
                    database.sessions[index].audioRelativePaths = movedPaths
                    database.sessions[index].audioState = .recoverableTrash
                    database.sessions[index].audioTrashedAt = now
                    database.sessions[index].audioRestoredAt = nil
                    changed = true
                }
            }
        }

        let expiredSessionIDs = database.sessions.compactMap { session -> UUID? in
            guard let deletedAt = session.deletedAt,
                  (calendar.dateComponents([.day], from: deletedAt, to: now).day ?? 0) >= 30 else { return nil }
            return session.id
        }
        for id in expiredSessionIDs {
            let directory = sessionDirectory(id).standardizedFileURL
            if FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    statusMessage = "记录已到 30 天清理期，但本地文件未能删除：\(error.localizedDescription)"
                    continue
                }
            }
            database.sessions.removeAll { $0.id == id }
            changed = true
        }
        if changed { persistSoon() }
    }

    @discardableResult
    func flush() -> Bool {
        saveWorkItem?.cancel()
        return persistNow()
    }

    private func search(_ query: String) -> [SearchHit] {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var hits: [SearchHit] = []
        for session in activeSessions {
            if session.title.range(of: query, options: options) != nil {
                hits.append(SearchHit(sessionID: session.id, nodeID: nil, spanID: nil, kind: .title, title: session.title, excerpt: session.sourceName))
            }
            for node in session.nodes where !node.isDeleted {
                let text = nodeText(node, in: session)
                let searchable = [node.userLabel, text, node.argumentSummary, node.relationToPrevious].compactMap { $0 }.joined(separator: "\n")
                if searchable.simplifiedChineseForDisplay.range(of: query.simplifiedChineseForDisplay, options: options) != nil {
                    hits.append(SearchHit(sessionID: session.id, nodeID: node.id, spanID: node.sourceSpanIDs.first, kind: .node, title: session.title, excerpt: searchable))
                }
            }
            for thought in session.thoughts where !thought.isDeleted {
                if thought.text.range(of: query, options: options) != nil {
                    let thoughtNode = session.nodes.first { !$0.isDeleted && $0.thoughtID == thought.id }
                    hits.append(SearchHit(sessionID: session.id, nodeID: thoughtNode?.id ?? thought.attachedNodeID, spanID: nil, kind: .thought, title: session.title, excerpt: thought.text))
                }
            }
            for span in session.transcript where !span.isFilteredBackground {
                if span.displayedText.range(of: query, options: options) != nil {
                    let nodeID = session.nodes.first(where: { !$0.isDeleted && ($0.sourceSpanIDs + ($0.coveredSourceSpanIDs ?? [])).contains(span.id) })?.id
                    hits.append(SearchHit(sessionID: session.id, nodeID: nodeID, spanID: span.id, kind: .transcript, title: session.title, excerpt: span.displayedText))
                }
            }
            for image in session.images ?? [] where image.deletedAt == nil {
                let searchable = [image.title, image.note, image.analysis?.extractedText ?? "", image.analysis?.explanation ?? "",
                                  image.analysis?.uncertainties.joined(separator: "；") ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
                if searchable.simplifiedChineseForDisplay.range(of: query.simplifiedChineseForDisplay, options: options) != nil {
                    hits.append(SearchHit(sessionID: session.id, nodeID: image.attachedNodeID, spanID: image.anchorSpanID,
                                          kind: .image, title: session.title, excerpt: searchable, imageID: image.id))
                }
            }
        }
        return Array(hits.prefix(80))
    }

    private static func snapshot(_ session: SessionRecord, reason: String) -> StructureSnapshot {
        StructureSnapshot(reason: reason, nodes: session.nodes, thoughts: session.thoughts,
                          transcript: session.transcript, speakers: session.speakers,
                          importantMarks: session.importantMarks ?? [],
                          pendingImportantTimes: session.pendingImportantTimes ?? [],
                          transcriptComplete: session.transcriptComplete, structureSaved: session.structureSaved,
                          analysisWarnings: session.analysisWarnings ?? [], images: session.images)
    }

    private static func reconciledImages(_ images: [ImageAttachment]?, nodes: [KnowledgeNode], transcript: [TranscriptSpan]) -> [ImageAttachment]? {
        let nodeIDs = Set(nodes.filter { !$0.isDeleted }.map(\.id)), spanIDs = Set(transcript.map(\.id))
        return images?.map { original in
            var image = original
            if let attached = image.attachedNodeID, !nodeIDs.contains(attached) {
                image.attachedNodeID = nodes.first {
                    !$0.isDeleted && (($0.sourceImageIDs ?? []) + ($0.coveredSourceImageIDs ?? [])).contains(image.id)
                }?.id
            }
            if let anchor = image.anchorSpanID, !spanIDs.contains(anchor) {
                image.anchorSpanID = image.anchorTime.flatMap { time in
                    transcript.min {
                        max($0.startTime - time, time - $0.endTime, 0) < max($1.startTime - time, time - $1.endTime, 0)
                    }?.id
                }
            }
            if image.anchorTime == nil, let span = transcript.first(where: { $0.id == image.anchorSpanID }) {
                image.anchorTime = (span.startTime + span.endTime) / 2
            }
            return image
        }
    }

    private static func reconcileImageLinks(in session: inout SessionRecord) {
        session.images = reconciledImages(session.images, nodes: session.nodes, transcript: session.transcript)
    }

    private static func anchorLegacyMarks(in session: inout SessionRecord) {
        guard var marks = session.importantMarks else { return }
        for index in marks.indices where marks[index].anchorTime == nil {
            if let span = session.transcript.first(where: { $0.id == marks[index].anchorSpanID }) {
                marks[index].anchorTime = (span.startTime + span.endTime) / 2
            }
        }
        session.importantMarks = marks
    }

    /// Re-segmentation changes timeline links, never the quotation a person
    /// actually edited. Historical evidence is stored on the authored node and
    /// rendered separately from the new manuscript, which remains single-copy.
    private static func migrateAuthoredEvidence(_ nodes: [KnowledgeNode], from old: [TranscriptSpan], to new: [TranscriptSpan]) -> [KnowledgeNode] {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        func mapped(_ ids: [UUID]) -> [UUID] {
            var result: [UUID] = []
            for id in ids {
                if newByID[id] != nil { if !result.contains(id) { result.append(id) }; continue }
                guard let span = oldByID[id], let nearest = new.min(by: {
                    let time = (span.startTime + span.endTime) / 2
                    return max($0.startTime - time, time - $0.endTime, 0) < max($1.startTime - time, time - $1.endTime, 0)
                }) else { continue }
                if !result.contains(nearest.id) { result.append(nearest.id) }
            }
            return result
        }
        return nodes.map { original in
            var node = original
            let sources = original.sourceSpanIDs.compactMap { oldByID[$0] }
            let changed = sources.contains { newByID[$0.id] != $0 }
            let authored = node.manualRevisionAt != nil || node.isSecondaryEdit || node.kind == .thought || node.thoughtID != nil || node.importantMarkID != nil
            if authored && changed && !sources.isEmpty && node.archivedSourceSpans?.isEmpty != false {
                node.archivedSourceSpans = sources
            }
            node.sourceSpanIDs = mapped(original.sourceSpanIDs)
            node.coveredSourceSpanIDs = original.coveredSourceSpanIDs.map(mapped)
            if changed && node.importantMarkID != nil {
                node.aiSummary = nil
                node.annotationInputFingerprint = nil
            }
            return node
        }
    }

    private func mutateSession(
        _ id: UUID,
        snapshotReason: String? = nil,
        persistDebounced: Bool = false,
        _ mutation: (inout SessionRecord) -> Void
    ) {
        guard let index = database.sessions.firstIndex(where: { $0.id == id }) else { return }
        if let snapshotReason {
            let current = database.sessions[index]
            database.sessions[index].versions.append(
                Self.snapshot(current, reason: snapshotReason)
            )
            if database.sessions[index].versions.count > 50 {
                database.sessions[index].versions.removeFirst(database.sessions[index].versions.count - 50)
            }
        }
        mutation(&database.sessions[index])
        Self.reconcileImageLinks(in: &database.sessions[index])
        // A role describes untouched model text, never authored thought/edit
        // text. A retained topic moved below a new root is unclassified rather
        // than silently promoted into an assertion. Do not erase its wording.
        for nodeIndex in database.sessions[index].nodes.indices {
            let node = database.sessions[index].nodes[nodeIndex]
            if node.isSecondaryEdit || node.kind == .thought || node.thoughtID != nil || node.importantMarkID != nil ||
                (node.semanticRole == .topic && (node.parentID != nil || node.relation != .root)) {
                database.sessions[index].nodes[nodeIndex].semanticRole = nil
            }
        }
        database.sessions[index].updatedAt = Date()
        if persistDebounced { persistSoon(delay: 0.7) } else { persistSoon() }
    }

    private func load() {
        let url = dataRoot.appendingPathComponent("database.json")
        do {
            let file = try ProtectedDatabaseFile(url: url)
            protectedFile = file
            let original = file.loadedData()
            guard let data = try file.recoverIfNeeded(isValid: {
                (try? JSONDecoder.configured.decode(AppDatabase.self, from: $0)) != nil
            }) else { return }
            if data != original { statusMessage = "记录已从最近有效备份恢复，损坏的原文件已另存保留。" }
            database = try JSONDecoder.configured.decode(AppDatabase.self, from: data)
            var migrated = false
            if database.settings == nil {
                database.settings = AppSettings()
                migrated = true
            }
            if database.schemaVersion < 2 {
                database.schemaVersion = 2
                migrated = true
            }
            if let path = database.settings?.whisperModelPath,
               path.hasSuffix("/small.pt"),
               ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0) < 50_000_000 {
                database.settings?.whisperModelPath = AppSettings().whisperModelPath
                migrated = true
            }
            let currentStructurePath = database.settings?.structureModelPath ?? ""
            let obsoleteStructureModels: Set<String> = [
                "DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf", "Qwen3-14B-Q4_K_M.gguf",
            ]
            let preferredStructurePath = AppSettings().structureModelPath
            if obsoleteStructureModels.contains(URL(fileURLWithPath: currentStructurePath).lastPathComponent),
               Self.isUsableGGUFModel(at: preferredStructurePath) {
                database.settings?.structureModelPath = preferredStructurePath
                migrated = true
            }
            for index in database.sessions.indices {
                let nodes = database.sessions[index].nodes
                if nodes.contains(where: { !$0.isDeleted && (abs($0.position.x) > 100_000 || abs($0.position.y) > 100_000) }) {
                    database.sessions[index].versions.append(Self.snapshot(database.sessions[index], reason: "修复异常拖动坐标前"))
                    let arranged = Self.layoutMindMap(nodes)
                    // Repair layout only, including when legacy relationships contain a cycle.
                    for nodeIndex in nodes.indices { database.sessions[index].nodes[nodeIndex].position = arranged[nodeIndex].position }
                    migrated = true
                    statusMessage = "检测到旧版拖动产生的异常位置，已恢复可见布局；原布局保存在版本中。"
                }
                if [.recording, .paused, .processing].contains(database.sessions[index].status) {
                    database.sessions[index].status = .failed
                    database.sessions[index].recoveryPending = true
                    migrated = true
                }
                if Self.ensureUserArtifacts(in: &database.sessions[index]) { migrated = true }
                let images = database.sessions[index].images
                Self.reconcileImageLinks(in: &database.sessions[index])
                if images != database.sessions[index].images { migrated = true }
            }
            if migrated { persistNow() }
        } catch {
            databaseReadFailed = true
            statusMessage = "本地数据库未能读取，原文件仍保留：\(error.localizedDescription)"
        }
    }

    private static func isUsableGGUFModel(at path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 1_000_000_000,
              let handle = FileHandle(forReadingAtPath: path)
        else { return false }
        defer { handle.closeFile() }
        return handle.readData(ofLength: 4) == Data("GGUF".utf8)
    }

    private func updateSettings(_ mutation: (inout AppSettings) -> Void) {
        var settings = database.settings ?? AppSettings()
        mutation(&settings)
        database.settings = settings
        persistSoon()
    }

    private func persistSoon(delay: TimeInterval = 0.15) {
        guard !inMemory else { return }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.persistNow() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    @discardableResult
    private func persistNow() -> Bool {
        if inMemory { return true }
        guard !databaseReadFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            let data = try JSONEncoder.configured.encode(database)
            guard let protectedFile else { throw ProtectedDatabaseFile.Failure.lockUnavailable }
            try protectedFile.save(data)
            return true
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func moveAudioToRecoverableTrash(for session: SessionRecord) -> [String]? {
        let fileManager = FileManager.default
        let sessionRoot = sessionDirectory(session.id).standardizedFileURL
        let trash = sessionRoot.appendingPathComponent("AudioTrash", isDirectory: true)
        do {
            try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
            var moved: [String] = []
            for rawPath in session.audioRelativePaths {
                let source = URL(fileURLWithPath: rawPath).standardizedFileURL
                guard isWithinSession(source, root: sessionRoot) else {
                    statusMessage = "拒绝移动不属于本会话目录的音频：\(source.lastPathComponent)"
                    return nil
                }
                let destination = trash.appendingPathComponent(source.lastPathComponent).standardizedFileURL
                if source == destination {
                    moved.append(destination.path)
                } else if fileManager.fileExists(atPath: source.path) {
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.moveItem(at: source, to: destination)
                    moved.append(destination.path)
                } else if fileManager.fileExists(atPath: destination.path) {
                    moved.append(destination.path)
                } else {
                    throw CocoaError(.fileNoSuchFile)
                }
            }
            return moved
        } catch {
            statusMessage = "音频未能进入 7 天可恢复区，因此不会继续永久清理：\(error.localizedDescription)"
            return nil
        }
    }

    private func permanentlyDeleteAudio(for session: SessionRecord) -> Bool {
        let fileManager = FileManager.default
        let sessionRoot = sessionDirectory(session.id).standardizedFileURL
        do {
            try IntegrityValidator.requireSafeAudioDeletion(from: session)
            for rawPath in session.audioRelativePaths {
                let file = URL(fileURLWithPath: rawPath).standardizedFileURL
                guard isWithinSession(file, root: sessionRoot) else {
                    statusMessage = "拒绝删除不属于本会话目录的音频：\(file.lastPathComponent)"
                    return false
                }
                if fileManager.fileExists(atPath: file.path) {
                    try fileManager.removeItem(at: file)
                }
            }
            return true
        } catch {
            statusMessage = "音频永久清理被阻止：\(error.localizedDescription)"
            return false
        }
    }

    private func isWithinSession(_ file: URL, root: URL) -> Bool {
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.path.hasPrefix(rootPrefix)
    }

    /// Timed marks survive the preview-to-final ASR ID change. Protect only a
    /// short time window, not five variable-length recognition segments.
    private static func resolveTimedMarks(in session: inout SessionRecord) {
        guard !session.transcript.isEmpty, var marks = session.importantMarks else { return }
        let previouslyProtected = Set(marks.flatMap(\.protectedSpanIDs))
        for index in marks.indices {
            guard let time = marks[index].anchorTime else { continue }
            let previousAnchor = session.transcript.first { $0.id == marks[index].anchorSpanID }
            // A composite has several independent source clocks. An unresolved
            // bookmark cannot guess its course from the nearest foreign quote.
            if session.isMergedRecord && previousAnchor == nil { continue }
            let eligible: [TranscriptSpan]
            if let previousAnchor, session.isMergedRecord || previousAnchor.origin != nil {
                eligible = session.transcript.filter {
                    $0.origin?.sessionID == previousAnchor.origin?.sessionID &&
                    ($0.origin?.authoredByUser == true) == (previousAnchor.origin?.authoredByUser == true)
                }
            } else { eligible = session.transcript }
            let nearby = eligible.min(by: {
                      let a = max($0.startTime - time, time - $0.endTime, 0)
                      let b = max($1.startTime - time, time - $1.endTime, 0)
                      return a < b
                  })
            let preservedAnchor = previousAnchor.flatMap { $0.startTime <= time + 12 && $0.endTime >= time - 12 ? $0 : nil }
            guard let anchor = preservedAnchor ?? nearby,
                  anchor.startTime <= time + 12, anchor.endTime >= time - 12 else { continue }
            marks[index].anchorSpanID = anchor.id
            marks[index].protectedSpanIDs = eligible.filter {
                $0.startTime <= time + 12 && $0.endTime >= time - 12
            }.map(\.id)
            for spanIndex in session.transcript.indices where marks[index].protectedSpanIDs.contains(session.transcript[spanIndex].id) {
                session.transcript[spanIndex].isImportant = true
            }
        }
        let stillProtected = Set(marks.flatMap(\.protectedSpanIDs))
        for index in session.transcript.indices where previouslyProtected.contains(session.transcript[index].id) && !stillProtected.contains(session.transcript[index].id) {
            session.transcript[index].isImportant = false
        }
        session.importantMarks = marks
    }

    /// Makes the user's own annotations first-class, visible records. Thoughts
    /// are copied verbatim into dedicated canvas nodes, and every important mark
    /// gets a dedicated evidence node even when the structure model omitted it.
    @discardableResult
    private static func ensureUserArtifacts(in session: inout SessionRecord, reattachOrphans: Bool = false) -> Bool {
        var changed = false
        let maxTranscriptEnd = session.transcript.map(\.endTime).max() ?? 0
        if maxTranscriptEnd > 0, let endedAt = session.endedAt {
            let recordingStart = endedAt.addingTimeInterval(-maxTranscriptEnd)
            for index in session.thoughts.indices where session.thoughts[index].anchorTime == nil {
                let elapsed = session.thoughts[index].createdAt.timeIntervalSince(recordingStart)
                session.thoughts[index].anchorTime = min(max(0, elapsed), maxTranscriptEnd)
                changed = true
            }
        }

        let spansByID = Dictionary(uniqueKeysWithValues: session.transcript.map { ($0.id, $0) })
        func nodeTime(_ node: KnowledgeNode) -> TimeInterval? {
            let times = node.sourceSpanIDs.compactMap { id -> TimeInterval? in
                guard let span = spansByID[id] else { return nil }
                return (span.startTime + span.endTime) / 2
            }
            guard !times.isEmpty else { return nil }
            return times.reduce(0, +) / Double(times.count)
        }
        func closestParent(to anchor: TimeInterval?, preferredID: UUID? = nil) -> KnowledgeNode? {
            let bases = session.nodes.filter {
                !$0.isDeleted && $0.thoughtID == nil && $0.importantMarkID == nil && !$0.sourceSpanIDs.isEmpty
            }
            if let preferredID, let preferred = bases.first(where: { $0.id == preferredID }) { return preferred }
            guard let anchor else { return bases.first(where: { $0.kind == .main }) ?? bases.first }
            // Prefer substantive branches over the central course overview.
            let branches = bases.filter { $0.parentID != nil }
            let coveredBranches = branches.filter { $0.coveredSourceSpanIDs?.isEmpty == false }
            let pool = !coveredBranches.isEmpty ? coveredBranches : (branches.isEmpty ? bases : branches)
            return pool.min {
                let left = ($0.coveredSourceSpanIDs ?? $0.sourceSpanIDs).compactMap { spansByID[$0] }.map { max($0.startTime - anchor, anchor - $0.endTime, 0) }.min() ?? abs((nodeTime($0) ?? anchor) - anchor)
                let right = ($1.coveredSourceSpanIDs ?? $1.sourceSpanIDs).compactMap { spansByID[$0] }.map { max($0.startTime - anchor, anchor - $0.endTime, 0) }.min() ?? abs((nodeTime($1) ?? anchor) - anchor)
                return left < right
            }
        }

        let baseMaxY = session.nodes
            .filter { !$0.isDeleted && $0.thoughtID == nil && $0.importantMarkID == nil }
            .map(\.position.y).max() ?? 190
        let importantLaneY = baseMaxY + 220
        let markRows = max(1, Int(ceil(Double((session.importantMarks ?? []).count) / 5.0)))
        let thoughtLaneY = importantLaneY + Double(markRows) * 190 + 30

        for (thoughtIndex, thought) in session.thoughts.enumerated() where !thought.isDeleted {
            let parent = closestParent(to: thought.anchorTime, preferredID: thought.attachedNodeID)
            if let existingIndex = session.nodes.firstIndex(where: {
                $0.thoughtID == thought.id ||
                    ($0.thoughtID == nil && $0.kind == .thought && $0.userEditedText == thought.text)
            }) {
                if session.nodes[existingIndex].thoughtID != thought.id {
                    session.nodes[existingIndex].thoughtID = thought.id
                    changed = true
                }
                if session.nodes[existingIndex].userEditedText != thought.text {
                    session.nodes[existingIndex].userEditedText = thought.text
                    changed = true
                }
                let oldParent = session.nodes[existingIndex].parentID
                let orphan = oldParent == nil || !session.nodes.contains { $0.id == oldParent && !$0.isDeleted }
                let validAttachedID = thought.attachedNodeID.flatMap { id in
                    session.nodes.contains { $0.id == id && !$0.isDeleted && $0.id != session.nodes[existingIndex].id } ? id : nil
                }
                let resolvedParent = reattachOrphans && orphan ? parent?.id : validAttachedID
                if let resolvedParent,
                   session.nodes[existingIndex].parentID != resolvedParent {
                    session.nodes[existingIndex].parentID = resolvedParent
                    session.nodes[existingIndex].relation = .userThought
                    changed = true
                }
            } else {
                session.nodes.append(
                    KnowledgeNode(
                        sourceSpanIDs: [],
                        kind: .thought,
                        parentID: parent?.id,
                        relation: .userThought,
                        position: CanvasPoint(
                            x: 250 + Double(thoughtIndex % 5) * 330,
                            y: thoughtLaneY + Double(thoughtIndex / 5) * 190
                        ),
                        userEditedText: thought.text,
                        isSecondaryEdit: thought.isSecondaryEdit,
                        manualRevisionAt: thought.createdAt,
                        thoughtID: thought.id
                    )
                )
                changed = true
            }
        }

        let validSpanIDs = Set(session.transcript.map(\.id))
        for (markIndex, mark) in (session.importantMarks ?? []).enumerated() {
            let protectedIDs = mark.protectedSpanIDs.filter { validSpanIDs.contains($0) }
            guard !protectedIDs.isEmpty else { continue }
            let anchorSpan = spansByID[mark.anchorSpanID] ?? protectedIDs.compactMap { spansByID[$0] }.first
            let anchorTime = anchorSpan.map { ($0.startTime + $0.endTime) / 2 }
            let parent = closestParent(to: anchorTime)
            if let existingIndex = session.nodes.firstIndex(where: { $0.importantMarkID == mark.id }) {
                let oldParent = session.nodes[existingIndex].parentID
                if reattachOrphans, let parent,
                   oldParent == nil || !session.nodes.contains(where: { $0.id == oldParent && !$0.isDeleted }) {
                    session.nodes[existingIndex].parentID = parent.id
                    session.nodes[existingIndex].relation = .supports
                    changed = true
                }
                if session.nodes[existingIndex].sourceSpanIDs != protectedIDs {
                    session.nodes[existingIndex].sourceSpanIDs = protectedIDs
                    changed = true
                }
            } else {
                session.nodes.append(
                    KnowledgeNode(
                        sourceSpanIDs: protectedIDs,
                        kind: .evidence,
                        parentID: parent?.id,
                        relation: .supports,
                        position: CanvasPoint(
                            x: 250 + Double(markIndex % 5) * 330,
                            y: importantLaneY + Double(markIndex / 5) * 190
                        ),
                        manualRevisionAt: mark.createdAt,
                        userLabel: "重点",
                        importantMarkID: mark.id
                    )
                )
                changed = true
            }
        }
        return changed
    }

    private static func parseSpeakerPrefix(_ line: String) -> (name: String, role: SpeakerRole, text: String) {
        let separators = ["：", ":"]
        for separator in separators {
            guard let range = line.range(of: separator) else { continue }
            let prefix = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let text = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !prefix.isEmpty, prefix.count <= 12, !text.isEmpty else { continue }
            let role: SpeakerRole
            if prefix.contains("主播") { role = .host }
            else if prefix.contains("嘉宾") { role = .guest }
            else if prefix.contains("连麦") { role = .caller }
            else if prefix == "我" || prefix.contains("用户") { role = .user }
            else { role = .unknown }
            return (prefix, role, text)
        }
        return ("主播", .host, line)
    }

    private static func literalSkeleton(from transcript: [TranscriptSpan]) -> [KnowledgeNode] {
        let source = transcript.filter { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var nodes: [KnowledgeNode] = []
        for (index, span) in source.enumerated() {
            let parentID = index == 0 ? nil : nodes[index - 1].id
            nodes.append(
                KnowledgeNode(
                    sourceSpanIDs: [span.id],
                    kind: .main,
                    parentID: parentID,
                    relation: index == 0 ? .root : .child,
                    confidence: nil,
                    position: layoutPoint(index: index, kind: .main)
                )
            )
        }
        return nodes
    }

    private static func layoutPoint(index: Int, kind: NodeKind) -> CanvasPoint {
        // Chronological reading grid. Node type is communicated by colour and
        // the relationship line, not by scattering each type into a separate
        // coordinate system that can overlap or jump off-canvas.
        CanvasPoint(
            x: 180 + Double(index % 5) * 340,
            y: 190 + Double(index / 5) * 220
        )
    }

    /// Classic left-to-right mind-map layout. Parents sit midway between their
    /// children; depth determines the column, so edges never form a long
    /// chronological chain or cross unrelated rows.
    private static func layoutMindMap(_ source: [KnowledgeNode]) -> [KnowledgeNode] {
        var nodes = source
        let activeIndices = nodes.indices.filter { !nodes[$0].isDeleted }
        let indexByID = Dictionary(uniqueKeysWithValues: activeIndices.map { (nodes[$0].id, $0) })
        let orderByID = Dictionary(uniqueKeysWithValues: activeIndices.enumerated().map {
            (nodes[$0.element].id, $0.offset)
        })
        var children: [UUID: [UUID]] = [:]
        for index in activeIndices {
            if let parentID = nodes[index].parentID, indexByID[parentID] != nil {
                children[parentID, default: []].append(nodes[index].id)
            }
        }
        for parentID in children.keys {
            children[parentID]?.sort { (orderByID[$0] ?? 0) < (orderByID[$1] ?? 0) }
        }
        var roots = activeIndices.filter {
            guard let parentID = nodes[$0].parentID else { return true }
            return indexByID[parentID] == nil
        }.map { nodes[$0].id }
        roots.sort { (orderByID[$0] ?? 0) < (orderByID[$1] ?? 0) }

        var nextLeafY = 150.0
        var visited: Set<UUID> = []
        @discardableResult
        func place(_ id: UUID, depth: Int) -> Double {
            guard let index = indexByID[id], visited.insert(id).inserted else {
                let y = nextLeafY
                nextLeafY += 190
                return y
            }
            let childIDs = (children[id] ?? []).filter { !visited.contains($0) }
            let y: Double
            if childIDs.isEmpty {
                y = nextLeafY
                nextLeafY += 190
            } else {
                let childYs = childIDs.map { place($0, depth: depth + 1) }
                y = (childYs.first! + childYs.last!) / 2
            }
            nodes[index].position = CanvasPoint(x: 190 + Double(depth) * 360, y: y)
            return y
        }
        for root in roots {
            _ = place(root, depth: 0)
            nextLeafY += 80
        }
        for index in activeIndices where !visited.contains(nodes[index].id) {
            nodes[index].parentID = nil
            nodes[index].relation = .root
            _ = place(nodes[index].id, depth: 0)
            nextLeafY += 80
        }
        return nodes
    }

    private static func descendantIDs(of nodeID: UUID, nodes: [KnowledgeNode]) -> Set<UUID> {
        var result = Set<UUID>()
        var frontier = [nodeID]
        while let current = frontier.popLast() {
            let children = nodes.filter { !$0.isDeleted && $0.parentID == current }.map(\.id)
            for child in children where result.insert(child).inserted {
                frontier.append(child)
            }
        }
        return result
    }

    private static func demoSession() -> SessionRecord {
        let host = Speaker(role: .host, displayName: "主播")
        let user = Speaker(role: .user, displayName: "我")
        let raw = [
            "不是重看一遍逐字稿，而是一眼扫完就能回顾整场内容的结构。",
            "看见主播在解决什么问题、如何做、依靠什么实现、得到什么结果。",
            "当用户对某个结论产生疑问时，可以从结构节点回到逐字稿证据。",
            "最终目的不是收藏信息，而是帮助用户复用方法、迁移理解并完成内化。",
        ]
        let spans = raw.enumerated().map { index, text in
            TranscriptSpan(
                sequence: index + 1,
                startTime: Double(index * 18),
                endTime: Double(index * 18 + 15),
                speakerID: host.id,
                originalText: text,
                isImportant: index == 2
            )
        }
        var session = SessionRecord(
            title: "演示｜产品需求原话",
            createdAt: Date().addingTimeInterval(-3600),
            endedAt: Date().addingTimeInterval(-900),
            sourceName: "本地演示数据",
            sourceKind: "演示",
            status: .ready,
            speakers: [host, user],
            transcript: spans,
            thoughts: [UserThought(text: "主画布要先让我看见全貌。", isSecondaryEdit: true)],
            transcriptComplete: true,
            structureSaved: true
        )
        session.nodes = literalSkeleton(from: spans)
        session.nodes[2].kind = .branch
        session.nodes[2].position = CanvasPoint(x: 750, y: 520)
        return session
    }
}

private extension JSONEncoder {
    static var configured: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var configured: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

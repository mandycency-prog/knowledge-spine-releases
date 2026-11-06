import Foundation

public enum MindMapExchangeError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): return message } }
}

/// Portable, audio-free exchange. These pure functions never write a database.
/// Callers append the complete returned array only after successful decoding.
public enum PortableMindMap {
    public static let fileExtension = "kspine"
    public static let formatIdentifier = "knowledge-spine-map"
    public static let currentVersion = 2
    public static let maximumBytes = 32 * 1024 * 1024
    private static let maximumEntities = 250_000

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var sessions: [PortableSession]
        var imageData: [String: Data]? = nil
    }

    /// Whitelist local data: no audio URLs, paths, settings, task state or logs.
    /// A path deliberately written in a user's text remains text, not a file link.
    private struct PortableSession: Codable {
        var id: UUID
        var title: String
        var createdAt: Date
        var endedAt: Date?
        var updatedAt: Date
        var sourceName: String
        var sourceKind: String
        var speakers: [Speaker]
        var transcript: [TranscriptSpan]
        var nodes: [KnowledgeNode]
        var thoughts: [UserThought]
        var versions: [PortableSnapshot]
        var candidateVersions: [PortableSnapshot]?
        var importantMarks: [ImportantMark]?
        var pendingImportantTimes: [TimeInterval]?
        var transcriptComplete: Bool
        var structureSaved: Bool
        var isMergedRecord: Bool
        var analysisWarnings: [String]?
        var images: [ImageAttachment]?
        var focusedStudyQuestion: String?
        var focusedStudyReports: [FocusedStudyReport]?

        init(_ record: SessionRecord) {
            id = record.id; title = record.title; createdAt = record.createdAt
            endedAt = record.endedAt; updatedAt = record.updatedAt
            sourceName = PortableMindMap.safeSourceName(record.sourceName)
            sourceKind = PortableMindMap.safeSourceName(record.sourceKind)
            speakers = record.speakers; transcript = record.transcript; nodes = record.nodes
            thoughts = record.thoughts; versions = record.versions.map(PortableSnapshot.init)
            candidateVersions = record.candidateVersions?.map(PortableSnapshot.init)
            importantMarks = record.importantMarks; pendingImportantTimes = record.pendingImportantTimes
            transcriptComplete = record.transcriptComplete; structureSaved = record.structureSaved
            isMergedRecord = record.isMergedRecord
            analysisWarnings = PortableMindMap.portableWarnings(record.analysisWarnings)
            images = record.images?.map(PortableMindMap.portableImage)
            focusedStudyQuestion = record.focusedStudyQuestion
            focusedStudyReports = record.focusedStudyReports
        }

        func record(imageData: [String: Data] = [:]) -> SessionRecord {
            var result = SessionRecord(id: id, title: title, createdAt: createdAt, endedAt: endedAt, updatedAt: updatedAt,
                          sourceName: sourceName, sourceKind: sourceKind, status: nodes.isEmpty ? .draft : .ready,
                          speakers: speakers, transcript: transcript, nodes: nodes, thoughts: thoughts,
                          versions: versions.map { $0.snapshot(imageData: imageData) }, audioRelativePaths: [], audioState: .none,
                          transcriptComplete: transcriptComplete, structureSaved: structureSaved, filesComplete: true,
                          isMergedRecord: isMergedRecord, candidateVersions: candidateVersions?.map { $0.snapshot(imageData: imageData) },
                          importantMarks: importantMarks, pendingImportantTimes: pendingImportantTimes,
                          recoveryPending: false, automaticRecoveryAttempts: 0)
            result.analysisWarnings = PortableMindMap.portableWarnings(analysisWarnings)
            result.images = images?.map { PortableMindMap.hydratedImage($0, data: imageData) }
            result.focusedStudyQuestion = focusedStudyQuestion
            result.focusedStudyReports = focusedStudyReports
            return result
        }
    }

    private struct PortableSnapshot: Codable {
        var id: UUID
        var createdAt: Date
        var reason: String
        var nodes: [KnowledgeNode]
        var thoughts: [UserThought]
        var transcript: [TranscriptSpan]?
        var speakers: [Speaker]?
        var importantMarks: [ImportantMark]?
        var pendingImportantTimes: [TimeInterval]?
        var transcriptComplete: Bool?
        var structureSaved: Bool?
        var analysisWarnings: [String]?
        var images: [ImageAttachment]?

        init(_ snapshot: StructureSnapshot) {
            id = snapshot.id; createdAt = snapshot.createdAt; reason = snapshot.reason
            nodes = snapshot.nodes; thoughts = snapshot.thoughts; transcript = snapshot.transcript
            speakers = snapshot.speakers; importantMarks = snapshot.importantMarks
            pendingImportantTimes = snapshot.pendingImportantTimes
            transcriptComplete = snapshot.transcriptComplete; structureSaved = snapshot.structureSaved
            analysisWarnings = PortableMindMap.portableWarnings(snapshot.analysisWarnings)
            images = snapshot.images?.map(PortableMindMap.portableImage)
        }

        func snapshot(imageData: [String: Data] = [:]) -> StructureSnapshot {
            StructureSnapshot(id: id, createdAt: createdAt, reason: reason, nodes: nodes, thoughts: thoughts,
                              transcript: transcript, speakers: speakers, importantMarks: importantMarks,
                              pendingImportantTimes: pendingImportantTimes, transcriptComplete: transcriptComplete,
                              structureSaved: structureSaved,
                              analysisWarnings: PortableMindMap.portableWarnings(analysisWarnings),
                              images: images?.map { PortableMindMap.hydratedImage($0, data: imageData) })
        }
    }

    public static func exportData(sessions: [SessionRecord]) throws -> Data {
        // Validate the originals before replacing local paths or deduplicating bytes.
        var imageData: [String: Data] = [:]
        for image in sessions.flatMap(allImages) {
            try ImageAttachmentValidation.validate(image, requireData: true)
            imageData[image.sha256.lowercased()] = image.portableData
        }
        let portable = sessions.map(PortableSession.init)
        try validate(portable.map { $0.record(imageData: imageData) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(format: formatIdentifier, version: currentVersion, sessions: portable,
                                              imageData: imageData.isEmpty ? nil : imageData))
        guard data.count <= maximumBytes else { throw failure("导图文件超过 32 MB，请分场导出") }
        return data
    }

    /// All IDs are fresh, including historical entities. Identity is stable
    /// across a session's versions, while unrelated sessions get separate maps.
    public static func importData(_ data: Data, existingSessions: [SessionRecord] = []) throws -> [SessionRecord] {
        try importBatch([data], existingSessions: existingSessions)
    }

    /// Decode the whole selection before mapping identities. Provenance between
    /// separately exported files must point to this batch's new source copy.
    /// Repeated original session IDs are ambiguous versions, never last-wins.
    public static func importBatch(_ payloads: [Data], existingSessions: [SessionRecord] = []) throws -> [SessionRecord] {
        guard !payloads.isEmpty, payloads.count <= 50 else { throw failure("一次请选择 1–50 个导图文件") }
        var totalBytes = 0
        for data in payloads {
            guard !data.isEmpty, data.count <= maximumBytes - totalBytes else {
                throw failure("导图文件为空或本次总大小超过 32 MB")
            }
            totalBytes += data.count
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var records: [SessionRecord] = []
        for data in payloads {
            let envelope: Envelope
            do { envelope = try decoder.decode(Envelope.self, from: data) }
            catch { throw failure("无法读取导图文件：格式损坏或字段不完整") }
            guard envelope.format == formatIdentifier, (1...currentVersion).contains(envelope.version) else {
                throw failure("不支持此导图文件格式或版本")
            }
            guard !envelope.sessions.isEmpty else { throw failure("导图文件没有记录") }
            let decoded = envelope.sessions.map { $0.record(imageData: envelope.imageData ?? [:]) }
            let imageKeys = Set(decoded.flatMap(allImages).map { $0.sha256.lowercased() })
            guard Set(envelope.imageData?.keys.map { $0 } ?? []).isSubset(of: imageKeys) else {
                throw failure("导图包含没有来源的图片数据")
            }
            records.append(contentsOf: decoded)
        }
        try validate(records)
        var reserved = Set<UUID>()
        for session in existingSessions + records { collectIDs(session).forEach { reserved.insert($0) } }
        var maps: [UUID: [UUID: UUID]] = [:]
        for session in records {
            var map: [UUID: UUID] = [:]
            for id in collectIDs(session) where map[id] == nil {
                var replacement = UUID()
                while reserved.contains(replacement) { replacement = UUID() }
                reserved.insert(replacement); map[id] = replacement
            }
            maps[session.id] = map
        }
        let imported = try records.map { try remap($0, maps: maps) }
        try validate(imported)
        return imported
    }

    private static func failure(_ message: String) -> MindMapExchangeError { .invalid(message) }
    private static func portableImage(_ image: ImageAttachment) -> ImageAttachment {
        var copy = image
        copy.relativePath = ImageAttachmentValidation.portablePath(id: image.id, mimeType: image.mimeType) ?? "invalid"
        copy.sha256 = image.sha256.lowercased()
        copy.portableData = nil
        // Runtime diagnostics may contain machine-local file names.
        copy.analysisError = portableWarnings(image.analysisError.map { [$0] })?.first
        return copy
    }
    private static func hydratedImage(_ image: ImageAttachment, data: [String: Data]) -> ImageAttachment {
        var copy = image
        copy.portableData = data[image.sha256.lowercased()] ?? image.portableData
        return copy
    }
    private static func safeSourceName(_ name: String) -> String {
        if name.hasPrefix("/") || name.hasPrefix("file://") { return URL(fileURLWithPath: name).lastPathComponent }
        return name
    }

    /// Warnings are content-completeness information, not disposable logs.
    /// A path can contain spaces, so never guess its end and leak the remainder.
    /// Preserve other clauses and the diagnostic prefix; redact the uncertain
    /// suffix explicitly. This is never applied to authored/transcribed text.
    private static func portableWarnings(_ warnings: [String]?) -> [String]? {
        warnings?.map { warning in
            warning.components(separatedBy: .newlines).map { line in
                line.components(separatedBy: "。").map { sentence in
                    sentence.components(separatedBy: "；").map { clause in
                        let patterns = ["file://", "~/", "~\\", "\\\\"]
                        var starts = patterns.compactMap { clause.range(of: $0)?.lowerBound }
                        // Keep ordinary ratios such as 3/4; all other slash
                        // forms are ambiguous in a machine-generated warning.
                        for index in clause.indices where clause[index] == "/" {
                            let left = index > clause.startIndex ? clause[clause.index(before: index)] : nil
                            let after = clause.index(after: index)
                            let right = after < clause.endIndex ? clause[after] : nil
                            if left?.isNumber != true || right?.isNumber != true { starts.append(index) }
                        }
                        if let range = clause.range(of: #"[A-Za-z]:\\"#, options: .regularExpression) { starts.append(range.lowerBound) }
                        guard let start = starts.min() else { return clause }
                        return String(clause[..<start]) + "[本机路径及相关细节已隐藏；原记录含处理说明，请回原记录查看]"
                    }.joined(separator: "；")
                }.joined(separator: "。")
            }.joined(separator: "\n")
        }
    }

    private static func validate(_ records: [SessionRecord]) throws {
        guard !records.isEmpty, records.count <= 50 else { throw failure("一次导入须包含 1–50 场记录") }
        try unique(records.map(\.id), "记录")
        var count = 0
        let allSessions = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let originTargets = allSessions.mapValues { session in Set(allNodes(session).map(\.id) + allSpans(session).map(\.id) + allImages(session).map(\.id)) }
        for session in records {
            guard !session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("记录标题为空") }
            try dates([session.createdAt, session.updatedAt] + [session.endedAt].compactMap { $0 })
            let snapshots = session.versions + (session.candidateVersions ?? [])
            guard snapshots.count <= 200 else { throw failure("单场版本过多，请分开备份") }
            try unique(snapshots.map(\.id), "版本")
            // Repetition across versions is normal, but one UUID must not name
            // two different entity types within the same session.
            var types: [UUID: String] = [:]
            func register(_ ids: [UUID], _ type: String) throws {
                count += ids.count
                guard count <= maximumEntities else { throw failure("导图内容过大") }
                for id in ids {
                    if let previous = types[id], previous != type { throw failure("同一 ID 被用于不同类型的内容") }
                    types[id] = type
                }
            }
            try register([session.id], "session")
            try register(snapshots.map(\.id), "snapshot")
            try register(allSpeakers(session).map(\.id), "speaker")
            try register(allSpans(session).map(\.id), "span")
            try register(allNodes(session).map(\.id), "node")
            let images = allImages(session)
            guard Set(images.map(\.id)).count <= ImageAttachmentValidation.maximumImagesPerSession else { throw failure("单场图片超过 50 张") }
            try register(images.map(\.id), "image")
            try register((session.focusedStudyReports ?? []).map(\.id), "focusedReport")
            try register((session.focusedStudyReports ?? []).flatMap { $0.sections.map(\.id) }, "focusedSection")
            try register((session.thoughts + snapshots.flatMap(\.thoughts)).map(\.id), "thought")
            try register(((session.importantMarks ?? []) + snapshots.flatMap { $0.importantMarks ?? [] }).map(\.id), "mark")
            try register(((session.importantMarks ?? []) + snapshots.flatMap { $0.importantMarks ?? [] }).map(\.anchorSpanID), "span")
            let historicalSpeakers = Set(allSpeakers(session).map(\.id))
            try validateScope(nodes: session.nodes, thoughts: session.thoughts, spans: session.transcript,
                              speakers: session.speakers, marks: session.importantMarks ?? [],
                              pending: session.pendingImportantTimes ?? [], historicalSpeakers: historicalSpeakers,
                              images: session.images ?? [])
            for snapshot in snapshots {
                try dates([snapshot.createdAt])
                try validateScope(nodes: snapshot.nodes, thoughts: snapshot.thoughts,
                                  spans: snapshot.transcript ?? session.transcript,
                                  speakers: snapshot.speakers ?? session.speakers,
                                  marks: snapshot.importantMarks ?? session.importantMarks ?? [],
                                  pending: snapshot.pendingImportantTimes ?? [], historicalSpeakers: historicalSpeakers,
                                  images: snapshot.images ?? session.images ?? [])
            }
            try unique((session.focusedStudyReports ?? []).map(\.id), "专题报告")
            let currentSpanIDs = Set(allSpans(session).map(\.id)), currentImageIDs = Set(allImages(session).map(\.id))
            for report in session.focusedStudyReports ?? [] {
                try dates([report.createdAt]); try unique(report.sections.map(\.id), "专题章节")
                for section in report.sections {
                    try unique(section.sourceSpanIDs, "专题原话来源"); try unique(section.sourceImageIDs ?? [], "专题图片来源")
                    guard Set(section.sourceSpanIDs).isSubset(of: currentSpanIDs),
                          Set(section.sourceImageIDs ?? []).isSubset(of: currentImageIDs) else { throw failure("专题引用的来源不存在") }
                }
            }
            // Internal origins must resolve. External provenance remains a
            // clearly external link, not a made-up new local UUID.
            for origin in allNodes(session).compactMap(\.origin) + allSpans(session).compactMap(\.origin) + allImages(session).compactMap(\.origin) {
                if let targets = originTargets[origin.sessionID], !targets.contains(origin.itemID) {
                    throw failure("包内出处指向不存在的原记录内容")
                }
                if let time = origin.startTime { try validTime(time) }
            }
        }
    }

    private static func validateScope(nodes: [KnowledgeNode], thoughts: [UserThought], spans: [TranscriptSpan],
                                      speakers: [Speaker], marks: [ImportantMark], pending: [TimeInterval],
                                      historicalSpeakers: Set<UUID>, images: [ImageAttachment]) throws {
        guard nodes.count <= 10_000, spans.count <= 100_000, thoughts.count <= 20_000, marks.count <= 20_000 else {
            throw failure("单个版本的内容过大")
        }
        try unique(nodes.map(\.id), "节点"); try unique(spans.map(\.id), "原话")
        try unique(speakers.map(\.id), "说话人"); try unique(thoughts.map(\.id), "思考")
        try unique(marks.map(\.id), "重点")
        try unique(images.map(\.id), "图片")
        guard Set(spans.map(\.sequence)).count == spans.count else { throw failure("原话顺序编号重复") }
        let nodeIDs = Set(nodes.map(\.id)), spanIDs = Set(spans.map(\.id))
        let imageIDs = Set(images.map(\.id))
        let speakerIDs = Set(speakers.map(\.id)), thoughtIDs = Set(thoughts.map(\.id)), markIDs = Set(marks.map(\.id))
        for span in spans { try validateSpan(span, speakers: speakerIDs) }
        for image in images {
            try ImageAttachmentValidation.validate(image, requireData: true)
            guard image.relativePath == ImageAttachmentValidation.portablePath(id: image.id, mimeType: image.mimeType) else {
                throw failure("导图图片路径不是受控相对路径")
            }
            if let id = image.anchorSpanID, !spanIDs.contains(id) { throw failure("图片关联的原话不存在") }
            if let id = image.attachedNodeID, !nodeIDs.contains(id) { throw failure("图片挂接的节点不存在") }
        }
        for thought in thoughts {
            try dates([thought.createdAt]); if let time = thought.anchorTime { try validTime(time) }
            if let id = thought.attachedNodeID, !nodeIDs.contains(id) { throw failure("思考挂接的节点不存在") }
        }
        for mark in marks {
            try dates([mark.createdAt]); if let time = mark.anchorTime { try validTime(time) }
            try unique(mark.protectedSpanIDs, "重点保护来源")
            guard Set(mark.protectedSpanIDs).isSubset(of: spanIDs) else { throw failure("重点引用的原话不存在") }
            // A capture-time mark can intentionally have only a timestamp.
            if !spanIDs.contains(mark.anchorSpanID) && !(mark.anchorTime != nil && mark.protectedSpanIDs.isEmpty) {
                throw failure("重点锚定的原话不存在")
            }
        }
        for time in pending { try validTime(time) }
        let parents = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.parentID) })
        var checkedParents = Set<UUID>()
        for node in nodes {
            guard node.position.x.isFinite, node.position.y.isFinite,
                  abs(node.position.x) <= 1_000_000, abs(node.position.y) <= 1_000_000 else { throw failure("节点坐标无效或过大") }
            if let confidence = node.confidence, !confidence.isFinite || !(0...1).contains(confidence) { throw failure("节点置信度无效") }
            try dates([node.manualRevisionAt, node.positionEditedAt].compactMap { $0 })
            try unique(node.sourceSpanIDs, "节点来源"); try unique(node.coveredSourceSpanIDs ?? [], "节点覆盖来源")
            try unique(node.sourceImageIDs ?? [], "节点图片来源")
            try unique(node.coveredSourceImageIDs ?? [], "节点覆盖图片来源")
            guard Set(node.sourceSpanIDs + (node.coveredSourceSpanIDs ?? [])).isSubset(of: spanIDs) else { throw failure("节点引用的原话不存在") }
            guard Set((node.sourceImageIDs ?? []) + (node.coveredSourceImageIDs ?? [])).isSubset(of: imageIDs) else { throw failure("节点引用的图片不存在") }
            if let id = node.parentID, !nodeIDs.contains(id) { throw failure("父节点不存在") }
            if let id = node.thoughtID, !thoughtIDs.contains(id) { throw failure("节点关联的思考不存在") }
            if let id = node.importantMarkID, !markIDs.contains(id) { throw failure("节点关联的重点不存在") }
            try IntegrityValidator.validateStoredNode(node, transcript: spans, images: images)
            let archived = node.archivedSourceSpans ?? []
            try unique(archived.map(\.id), "历史原话")
            for span in archived { try validateSpan(span, speakers: historicalSpeakers) }
            var seen = Set<UUID>(), cursor: UUID? = node.id
            while let id = cursor {
                if checkedParents.contains(id) { break }
                guard seen.insert(id).inserted else { throw failure("导图父子关系存在循环") }
                cursor = parents[id] ?? nil
            }
            checkedParents.formUnion(seen)
        }
    }

    private static func validateSpan(_ span: TranscriptSpan, speakers: Set<UUID>) throws {
        guard span.sequence >= 0, speakers.contains(span.speakerID) else { throw failure("原话顺序或说话人引用无效") }
        try validTime(span.startTime); try validTime(span.endTime)
        guard span.endTime >= span.startTime else { throw failure("原话结束时间早于开始时间") }
    }
    private static func validTime(_ time: Double) throws {
        guard time.isFinite, time >= 0, time <= 315_576_000 else { throw failure("时间位置无效") }
    }
    private static func dates(_ values: [Date]) throws {
        guard values.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { throw failure("日期无效") }
    }
    private static func unique(_ values: [UUID], _ label: String) throws {
        guard Set(values).count == values.count else { throw failure("\(label) ID 重复") }
    }
    private static func snapshots(_ session: SessionRecord) -> [StructureSnapshot] { session.versions + (session.candidateVersions ?? []) }
    private static func allNodes(_ session: SessionRecord) -> [KnowledgeNode] { session.nodes + snapshots(session).flatMap(\.nodes) }
    private static func allSpans(_ session: SessionRecord) -> [TranscriptSpan] {
        session.transcript + snapshots(session).flatMap { $0.transcript ?? [] } + allNodes(session).flatMap { $0.archivedSourceSpans ?? [] }
    }
    private static func allSpeakers(_ session: SessionRecord) -> [Speaker] { session.speakers + snapshots(session).flatMap { $0.speakers ?? [] } }
    private static func allImages(_ session: SessionRecord) -> [ImageAttachment] { (session.images ?? []) + snapshots(session).flatMap { $0.images ?? [] } }
    private static func collectIDs(_ session: SessionRecord) -> Set<UUID> {
        let versions = snapshots(session)
        let marks = (session.importantMarks ?? []) + versions.flatMap { $0.importantMarks ?? [] }
        var ids = Set([session.id] + versions.map(\.id) + allNodes(session).map(\.id) + allSpans(session).map(\.id)
                      + allSpeakers(session).map(\.id) + (session.thoughts + versions.flatMap(\.thoughts)).map(\.id)
                      + marks.map(\.id) + marks.map(\.anchorSpanID))
        let excerpts = allNodes(session).flatMap { ($0.coreOriginals ?? []) + ($0.conditionOriginals ?? []) }
        ids.formUnion(excerpts.flatMap { $0.parts.map(\.sourceID) })
        ids.formUnion(allImages(session).map(\.id))
        ids.formUnion((session.focusedStudyReports ?? []).map(\.id))
        ids.formUnion((session.focusedStudyReports ?? []).flatMap { $0.sections.map(\.id) })
        for origin in allNodes(session).compactMap(\.origin) + allSpans(session).compactMap(\.origin) + excerpts.compactMap(\.origin) + allImages(session).compactMap(\.origin) {
            ids.insert(origin.sessionID); ids.insert(origin.itemID)
        }
        return ids
    }

    private static func remap(_ original: SessionRecord, maps: [UUID: [UUID: UUID]]) throws -> SessionRecord {
        guard let map = maps[original.id] else { throw failure("记录映射缺失") }
        func id(_ old: UUID) throws -> UUID {
            guard let new = map[old] else { throw failure("内容引用映射缺失") }; return new
        }
        func origin(_ reference: SourceReference?) throws -> SourceReference? {
            guard var reference else { return nil }
            if let targetMap = maps[reference.sessionID] {
                guard let sessionID = targetMap[reference.sessionID], let itemID = targetMap[reference.itemID] else { throw failure("出处映射缺失") }
                reference.sessionID = sessionID; reference.itemID = itemID
            }
            return reference
        }
        func span(_ value: TranscriptSpan) throws -> TranscriptSpan {
            var value = value; value.id = try id(value.id); value.speakerID = try id(value.speakerID)
            value.origin = try origin(value.origin); return value
        }
        func speaker(_ value: Speaker) throws -> Speaker { var value = value; value.id = try id(value.id); return value }
        func thought(_ value: UserThought) throws -> UserThought {
            var value = value; value.id = try id(value.id); value.attachedNodeID = try value.attachedNodeID.map(id); return value
        }
        func mark(_ value: ImportantMark) throws -> ImportantMark {
            var value = value; value.id = try id(value.id); value.anchorSpanID = try id(value.anchorSpanID)
            value.protectedSpanIDs = try value.protectedSpanIDs.map(id); return value
        }
        func image(_ value: ImageAttachment) throws -> ImageAttachment {
            var value = value
            value.id = try id(value.id)
            value.anchorSpanID = try value.anchorSpanID.map(id)
            value.attachedNodeID = try value.attachedNodeID.map(id)
            value.origin = try origin(value.origin)
            guard let path = ImageAttachmentValidation.portablePath(id: value.id, mimeType: value.mimeType) else { throw failure("图片格式不支持") }
            value.relativePath = path
            return value
        }
        func node(_ value: KnowledgeNode) throws -> KnowledgeNode {
            var value = value; value.id = try id(value.id); value.parentID = try value.parentID.map(id)
            value.sourceSpanIDs = try value.sourceSpanIDs.map(id); value.coveredSourceSpanIDs = try value.coveredSourceSpanIDs?.map(id)
            value.sourceImageIDs = try value.sourceImageIDs?.map(id)
            value.coveredSourceImageIDs = try value.coveredSourceImageIDs?.map(id)
            value.thoughtID = try value.thoughtID.map(id); value.importantMarkID = try value.importantMarkID.map(id)
            value.archivedSourceSpans = try value.archivedSourceSpans?.map(span); value.origin = try origin(value.origin)
            func excerpt(_ value: OriginalExcerpt) throws -> OriginalExcerpt {
                var value = value
                value.parts = try value.parts.map { part in
                    var part = part; part.sourceID = try id(part.sourceID); return part
                }
                value.origin = try origin(value.origin)
                return value
            }
            value.coreOriginals = try value.coreOriginals?.map(excerpt)
            value.conditionOriginals = try value.conditionOriginals?.map(excerpt)
            value.annotationInputFingerprint = nil // A machine-local source-ID fingerprint is no longer valid.
            return value
        }
        func snapshot(_ value: StructureSnapshot) throws -> StructureSnapshot {
            var value = value; value.id = try id(value.id); value.nodes = try value.nodes.map(node)
            value.thoughts = try value.thoughts.map(thought); value.transcript = try value.transcript?.map(span)
            value.speakers = try value.speakers?.map(speaker); value.importantMarks = try value.importantMarks?.map(mark)
            value.images = try value.images?.map(image)
            return value
        }
        var value = original
        value.id = try id(value.id); value.speakers = try value.speakers.map(speaker); value.transcript = try value.transcript.map(span)
        value.nodes = try value.nodes.map(node); value.thoughts = try value.thoughts.map(thought)
        value.importantMarks = try value.importantMarks?.map(mark); value.versions = try value.versions.map(snapshot)
        value.candidateVersions = try value.candidateVersions?.map(snapshot)
        value.images = try value.images?.map(image)
        value.focusedStudyReports = try value.focusedStudyReports?.map { report in
            var report = report; report.id = try id(report.id)
            report.sections = try report.sections.map { section in
                var section = section; section.id = try id(section.id)
                section.sourceSpanIDs = try section.sourceSpanIDs.map(id)
                section.sourceImageIDs = try section.sourceImageIDs?.map(id)
                return section
            }
            return report
        }
        return value
    }

    /// Plain headings and indented Markdown lists become human-authored nodes.
    /// No audio/transcript is invented; paragraphs remain verbatim node text.
    public static func importMarkdown(_ text: String, title: String = "导入的导图",
                                      existingSessions: [SessionRecord] = []) throws -> SessionRecord {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 5 * 1024 * 1024 else { throw failure("Markdown 内容为空或超过 5 MB") }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard lines.count <= 50_000 else { throw failure("Markdown 行数过多") }
        let heading = try NSRegularExpression(pattern: "^(#{1,6})[ \\t]+(.+)$")
        let item = try NSRegularExpression(pattern: "^([ \\t]*)(?:[-+*]|[0-9]+[.)])[ \\t]+(.+)$")
        var nodes: [KnowledgeNode] = [], headings: [(Int, UUID)] = [], list: [(Int, UUID)] = []
        var last: Int?, fenced = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !fenced && trimmed.range(of: "^(?:#{1,6}|[-+*]+|[0-9]+[.)])$", options: .regularExpression) != nil { continue }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle() }
            let range = NSRange(line.startIndex..., in: line)
            let h = fenced ? nil : heading.firstMatch(in: line, range: range)
            let l = fenced ? nil : item.firstMatch(in: line, range: range)
            if let match = h ?? l {
                func group(_ index: Int) -> String { String(line[Range(match.range(at: index), in: line)!]) }
                let content = group(2)
                guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let parent: UUID?
                if h != nil {
                    let level = group(1).count
                    while let entry = headings.last, entry.0 >= level { headings.removeLast() }
                    parent = headings.last?.1; list.removeAll()
                } else {
                    let indent = group(1).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                    guard indent <= 128 else { throw failure("Markdown 缩进过深") }
                    while let entry = list.last, entry.0 >= indent { list.removeLast() }
                    parent = list.last?.1 ?? headings.last?.1
                }
                let node = KnowledgeNode(sourceSpanIDs: [], kind: parent == nil ? .main : .branch, parentID: parent,
                                         relation: parent == nil ? .root : .child,
                                         position: CanvasPoint(x: Double(headings.count + list.count) * 280, y: Double(nodes.count) * 64),
                                         userEditedText: content, isSecondaryEdit: true, manualRevisionAt: Date(), semanticRole: nil)
                nodes.append(node); last = nodes.count - 1
                if h != nil { headings.append((group(1).count, node.id)) }
                else { list.append((group(1).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }, node.id)) }
            } else if let index = last {
                nodes[index].userEditedText = (nodes[index].userEditedText ?? "") + "\n" + line
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                nodes.append(KnowledgeNode(sourceSpanIDs: [], kind: .main, relation: .root, position: CanvasPoint(x: 0, y: 0),
                                           userEditedText: line, isSecondaryEdit: true, manualRevisionAt: Date()))
                last = nodes.count - 1
            }
            guard nodes.count <= 10_000 else { throw failure("Markdown 节点超过 10000 个") }
        }
        guard !nodes.isEmpty else { throw failure("Markdown 没有可导入的文字") }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = SessionRecord(title: name.isEmpty ? "导入的导图" : title, sourceName: "Markdown 文件", sourceKind: "Markdown 导入（用户内容）",
                                    status: .ready, nodes: nodes, transcriptComplete: true, structureSaved: true)
        return try importData(exportData(sessions: [session]), existingSessions: existingSessions)[0]
    }
}

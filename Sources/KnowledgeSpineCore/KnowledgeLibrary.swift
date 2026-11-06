import Foundation

public struct SourceReference: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var sessionTitle: String
    public var itemID: UUID
    public var startTime: TimeInterval?
    /// True for a user's written words; never an audio quotation or AI claim.
    public var authoredByUser: Bool? = nil

    public init(sessionID: UUID, sessionTitle: String, itemID: UUID, startTime: TimeInterval? = nil, authoredByUser: Bool? = nil) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.itemID = itemID
        self.startTime = startTime
        self.authoredByUser = authoredByUser
    }
}

public struct KnowledgeCollection: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var sessionIDs: [UUID]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, sessionIDs: [UUID] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sessionIDs = sessionIDs
        self.createdAt = createdAt
    }
}

/// A composite is a new document, not a destructive union of the originals.
/// Each source gets its own ID map and a disjoint document timeline. Origin
/// references retain the real lesson time, while the new timeline prevents
/// two lessons both starting at 00:00 from being interleaved.
public enum KnowledgeRecordMerger {
    public static func combine(title: String, sources: [SessionRecord], selectedNodeIDs: Set<UUID>? = nil,
                               wholeSessionIDs: Set<UUID> = [], includeAuthoredSourceText: Bool = false) -> SessionRecord? {
        guard !sources.isEmpty else { return nil }
        var result = SessionRecord(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名综合记录" : title,
            sourceName: sources.map(\.title).joined(separator: "、"), sourceKind: "综合记录",
            status: .ready, transcriptComplete: true, structureSaved: true, isMergedRecord: true
        )
        var timeOffset = 0.0
        var layoutOffset = 150.0
        for original in sources {
            var source = original
            let whole = selectedNodeIDs == nil || wholeSessionIDs.contains(source.id)
            // Written additions are separate user sources even if this lesson
            // also has a transcript. Never overwrite the host's source words.
            if includeAuthoredSourceText {
                let writer = Speaker(role: .user)
                var nextSequence = (source.transcript.map(\.sequence).max() ?? 0) + 1
                var writtenTime = max(source.transcript.map(\.endTime).max() ?? 0,
                                      source.thoughts.compactMap(\.anchorTime).max() ?? 0,
                                      source.importantMarks?.compactMap(\.anchorTime).max() ?? 0,
                                      source.pendingImportantTimes?.max() ?? 0) + 25
                for index in source.nodes.indices where !source.nodes[index].isDeleted {
                    let node = source.nodes[index]
                    guard whole || selectedNodeIDs?.contains(node.id) == true else { continue }
                    let authoredTitle = (node.manualRevisionAt != nil || node.isSecondaryEdit || node.sourceSpanIDs.isEmpty) ? node.userLabel : nil
                    let parts = [authoredTitle, node.userEditedText].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    guard !parts.isEmpty else { continue }
                    let authoredText = parts.joined(separator: "\n")
                    // Re-integrating a topic must not duplicate its already
                    // referenced user source. Equal words from other authors
                    // or unrelated nodes are not a deduplication match.
                    if source.transcript.contains(where: {
                        node.sourceSpanIDs.contains($0.id) && $0.origin?.authoredByUser == true && $0.originalText == authoredText
                    }) { continue }
                    if !source.speakers.contains(where: { $0.id == writer.id }) { source.speakers.append(writer) }
                    var span = TranscriptSpan(sequence: nextSequence,
                        startTime: writtenTime, endTime: writtenTime + 1,
                        speakerID: writer.id, originalText: authoredText)
                    span.origin = SourceReference(sessionID: source.id, sessionTitle: source.title, itemID: node.id, authoredByUser: true)
                    source.transcript.append(span)
                    source.nodes[index].sourceSpanIDs.append(span.id)
                    nextSequence += 1
                    writtenTime += 1
                }
            }
            let active = source.nodes.filter { !$0.isDeleted }
            var included = Set(active.filter { whole || selectedNodeIDs!.contains($0.id) }.map(\.id))
            // Choosing a branch also carries the annotations attached to it.
            for node in active where node.thoughtID != nil || node.importantMarkID != nil {
                if let parent = node.parentID, included.contains(parent) { included.insert(node.id) }
            }
            var selected = active.filter { included.contains($0.id) }
            guard !selected.isEmpty || whole else { continue }
            let thoughtIDs = Set(selected.compactMap(\.thoughtID))
            let thoughts = source.thoughts.filter {
                !$0.isDeleted && (whole || thoughtIDs.contains($0.id) || $0.attachedNodeID.map(included.contains) == true)
            }
            let covered = Set(selected.flatMap { $0.sourceSpanIDs + ($0.coveredSourceSpanIDs ?? []) })
            let markIDs = Set(selected.compactMap(\.importantMarkID))
            let marks = (source.importantMarks ?? []).filter {
                whole || markIDs.contains($0.id) || !$0.protectedSpanIDs.allSatisfy { !covered.contains($0) }
            }
            let carriedThoughtIDs = Set(thoughts.map(\.id))
            let carriedMarkIDs = Set(marks.map(\.id))
            for node in active where node.thoughtID.map(carriedThoughtIDs.contains) == true || node.importantMarkID.map(carriedMarkIDs.contains) == true {
                included.insert(node.id)
            }
            selected = active.filter { included.contains($0.id) }
            var neededSpans = covered.union(marks.flatMap { $0.protectedSpanIDs + [$0.anchorSpanID] })
            let neededImages = Set(selected.flatMap { ($0.sourceImageIDs ?? []) + ($0.coveredSourceImageIDs ?? []) })
            let images = (source.images ?? []).filter {
                neededImages.contains($0.id) || ($0.deletedAt == nil && (whole || $0.attachedNodeID.map(included.contains) == true))
            }
            neededSpans.formUnion(images.compactMap(\.anchorSpanID))
            // Retain the actual nearby passage for a thought-only selection.
            for thought in thoughts {
                if let anchor = thought.anchorTime {
                    neededSpans.formUnion(source.transcript.filter { $0.endTime >= anchor - 15 && $0.startTime <= anchor + 15 }.map(\.id))
                }
            }
            let spans = source.transcript.filter { whole || neededSpans.contains($0.id) }
                .sorted { $0.sequence == $1.sequence ? $0.startTime < $1.startTime : $0.sequence < $1.sequence }
            var speakerMap: [UUID: UUID] = [:]
            for speaker in source.speakers {
                var copy = speaker
                copy.id = UUID()
                speakerMap[speaker.id] = copy.id
                result.speakers.append(copy)
            }
            for id in Set(spans.map(\.speakerID)) where speakerMap[id] == nil {
                let anonymous = Speaker(role: .unknown)
                speakerMap[id] = anonymous.id
                result.speakers.append(anonymous)
            }
            let spanMap = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, UUID()) })
            let nodeMap = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, UUID()) })
            let thoughtMap = Dictionary(uniqueKeysWithValues: thoughts.map { ($0.id, UUID()) })
            let markMap = Dictionary(uniqueKeysWithValues: marks.map { ($0.id, UUID()) })
            let imageMap = Dictionary(uniqueKeysWithValues: images.map { ($0.id, UUID()) })
            var previousSourceSequence: Int?
            for span in spans {
                var copy = span
                copy.id = spanMap[span.id]!
                copy.speakerID = speakerMap[span.speakerID]!
                // Selecting separated nodes must not turn non-adjacent source
                // passages into one quote. Preserve a gap, including on a
                // second integration of an already combined record.
                let contiguous = previousSourceSequence.map { $0 < Int.max && span.sequence == $0 + 1 } ?? true
                copy.sequence = (result.transcript.last?.sequence ?? 0) + (contiguous ? 1 : 2)
                previousSourceSequence = span.sequence
                copy.startTime += timeOffset
                copy.endTime += timeOffset
                copy.origin = span.origin ?? SourceReference(sessionID: source.id, sessionTitle: source.title, itemID: span.id, startTime: span.startTime)
                result.transcript.append(copy)
            }
            for thought in thoughts {
                var copy = thought
                copy.id = thoughtMap[thought.id]!
                copy.attachedNodeID = thought.attachedNodeID.flatMap { nodeMap[$0] }
                copy.anchorTime = thought.anchorTime.map { $0 + timeOffset }
                result.thoughts.append(copy)
            }
            for image in images {
                var copy = image
                copy.id = imageMap[image.id]!
                copy.anchorSpanID = image.anchorSpanID.flatMap { spanMap[$0] }
                copy.attachedNodeID = image.attachedNodeID.flatMap { nodeMap[$0] }
                copy.anchorTime = image.anchorTime.map { $0 + timeOffset }
                copy.origin = image.origin ?? SourceReference(sessionID: source.id, sessionTitle: source.title,
                    itemID: image.id, startTime: image.anchorTime)
                result.images = (result.images ?? []) + [copy]
            }
            for mark in marks {
                var copy = mark
                copy.id = markMap[mark.id]!
                // A bookmark can precede transcription. Preserve the intent
                // and time without inventing a corresponding quotation.
                copy.anchorSpanID = spanMap[mark.anchorSpanID] ?? UUID()
                copy.protectedSpanIDs = mark.protectedSpanIDs.compactMap { spanMap[$0] }
                copy.anchorTime = mark.anchorTime.map { $0 + timeOffset }
                result.importantMarks = (result.importantMarks ?? []) + [copy]
            }
            if whole {
                result.pendingImportantTimes = (result.pendingImportantTimes ?? []) + (source.pendingImportantTimes ?? []).map { $0 + timeOffset }
            }
            let minX = selected.map(\.position.x).min() ?? 0
            let minY = selected.map(\.position.y).min() ?? 0
            let copiedSequences = Dictionary(uniqueKeysWithValues: result.transcript.map { ($0.id, $0.sequence) })
            for node in selected {
                var copy = node
                copy.id = nodeMap[node.id]!
                copy.sourceSpanIDs = node.sourceSpanIDs.compactMap { spanMap[$0] }
                copy.sourceImageIDs = node.sourceImageIDs.map { $0.compactMap { imageMap[$0] } }
                copy.coveredSourceImageIDs = node.coveredSourceImageIDs.map { $0.compactMap { imageMap[$0] } }
                copy.coveredSourceSpanIDs = node.coveredSourceSpanIDs.map { $0.compactMap { spanMap[$0] } }
                copy.archivedSourceSpans = node.archivedSourceSpans?.map { archived in
                    var copy = archived
                    copy.id = spanMap[archived.id] ?? archived.id
                    if let mappedID = spanMap[archived.id], let sequence = copiedSequences[mappedID] { copy.sequence = sequence }
                    copy.speakerID = speakerMap[archived.speakerID] ?? archived.speakerID
                    copy.startTime += timeOffset
                    copy.endTime += timeOffset
                    copy.origin = archived.origin ?? source.transcript.first { $0.id == archived.id }?.origin ?? SourceReference(sessionID: source.id, sessionTitle: source.title,
                        itemID: archived.id, startTime: archived.startTime)
                    return copy
                }
                func remapExcerpt(_ excerpt: OriginalExcerpt) -> OriginalExcerpt {
                    var excerpt = excerpt
                    let originalID = excerpt.parts.first?.sourceID
                    excerpt.parts = excerpt.parts.map { part in
                        var part = part; part.sourceID = spanMap[part.sourceID] ?? part.sourceID; return part
                    }
                    if excerpt.origin == nil, let originalID {
                        let archived = node.archivedSourceSpans?.first { $0.id == originalID }
                        let current = source.transcript.first { $0.id == originalID }
                        let evidence = archived ?? current
                        excerpt.origin = archived?.origin ?? current?.origin ?? SourceReference(sessionID: source.id, sessionTitle: source.title,
                                                        itemID: originalID, startTime: evidence?.startTime)
                    }
                    return excerpt
                }
                copy.coreOriginals = node.coreOriginals?.map(remapExcerpt)
                copy.conditionOriginals = node.conditionOriginals?.map(remapExcerpt)
                copy.parentID = node.parentID.flatMap { nodeMap[$0] }
                copy.relation = copy.parentID == nil ? .root : node.relation
                copy.thoughtID = node.thoughtID.flatMap { thoughtMap[$0] }
                copy.importantMarkID = node.importantMarkID.flatMap { markMap[$0] }
                copy.origin = node.origin ?? SourceReference(sessionID: source.id, sessionTitle: source.title, itemID: node.id)
                copy.position = CanvasPoint(x: node.position.x - minX + 190, y: node.position.y - minY + layoutOffset)
                copy.positionIsAutomatic = false
                copy.annotationInputFingerprint = nil
                result.nodes.append(copy)
            }
            layoutOffset += (selected.map(\.position.y).max() ?? minY) - minY + 360
            timeOffset += max(source.transcript.map(\.endTime).max() ?? 0,
                              source.thoughts.compactMap(\.anchorTime).max() ?? 0,
                              source.importantMarks?.compactMap(\.anchorTime).max() ?? 0,
                              source.pendingImportantTimes?.max() ?? 0,
                              images.compactMap(\.anchorTime).max() ?? 0) + 25
        }
        return result.nodes.isEmpty && result.thoughts.isEmpty && result.transcript.isEmpty && (result.images ?? []).isEmpty ? nil : result
    }
}

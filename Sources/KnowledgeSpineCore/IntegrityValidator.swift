import Foundation

public enum IntegrityViolation: Error, Equatable, CustomStringConvertible {
    case emptySource(UUID)
    case unknownSource(UUID)
    case unknownImageSource(UUID)
    case unknownParent(UUID)
    case duplicateNode(UUID)
    case generatedSemanticText(UUID)
    case invalidSemanticRole(UUID)
    case unsafeAudioDeletion

    public var description: String {
        switch self {
        case .emptySource(let id): "节点 \(id) 没有来源片段"
        case .unknownSource(let id): "找不到来源片段 \(id)"
        case .unknownImageSource(let id): "找不到图片来源 \(id)"
        case .unknownParent(let id): "找不到父节点 \(id)"
        case .duplicateNode(let id): "节点 ID 重复 \(id)"
        case .generatedSemanticText(let id): "模型节点 \(id) 含有自由生成文字"
        case .invalidSemanticRole(let id): "主题节点 \(id) 必须是根节点，且不能带论断文字"
        case .unsafeAudioDeletion: "转写、结构或文件状态未完成，禁止删除音频"
        }
    }
}

public enum IntegrityValidator {
    public static func presentationNodes(_ source: [KnowledgeNode], transcript: [TranscriptSpan], images: [ImageAttachment] = [], overviewOnly: Bool = false) -> [KnowledgeNode] {
        let background = Set(transcript.filter { $0.isFilteredBackground }.map(\.id))
        let active = source.filter { !$0.isDeleted }
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        let kept = active.filter { node in
            let authored = node.kind == .thought || node.isSecondaryEdit || node.importantMarkID != nil || node.userLabel?.isEmpty == false
            if overviewOnly && node.kind == .evidence && !authored { return false }
            return authored || node.sourceImageIDs?.isEmpty == false || node.sourceSpanIDs.isEmpty || !node.sourceSpanIDs.allSatisfy { background.contains($0) }
        }
        let visibleIDs = Set(kept.map(\.id))
        return kept.map { original in
            var node = original
            var parent = node.parentID
            var visited: Set<UUID> = [node.id]
            while let id = parent, !visibleIDs.contains(id) {
                guard visited.insert(id).inserted else { parent = nil; break }
                parent = byID[id]?.parentID
            }
            node.parentID = parent
            if parent == nil { node.relation = .root }
            return node
        }
    }

    public static func visibleText(for node: KnowledgeNode, transcript: [TranscriptSpan], images: [ImageAttachment] = []) -> String {
        if node.isSecondaryEdit || node.kind == .thought {
            return node.userEditedText ?? ""
        }

        if let summary = node.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary.simplifiedChineseForDisplay
        }

        if let label = node.userLabel, !label.isEmpty { return label }

        let spansByID = Dictionary(uniqueKeysWithValues: transcript.map { ($0.id, $0) })
        let spoken = node.sourceSpanIDs.compactMap { spansByID[$0]?.simplifiedOriginalText }.joined(separator: "\n")
        if !spoken.isEmpty { return spoken }
        let imageIDs = Set(node.sourceImageIDs ?? [])
        return images.filter { imageIDs.contains($0.id) }.map { image in
            let extracted = image.analysis?.extractedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (extracted.isEmpty ? image.title : extracted).simplifiedChineseForDisplay
        }.joined(separator: "\n")
    }

    public static func originalSourceText(for node: KnowledgeNode, transcript: [TranscriptSpan]) -> String {
        let spansByID = Dictionary(uniqueKeysWithValues: transcript.map { ($0.id, $0) })
        return node.sourceSpanIDs.compactMap { spansByID[$0]?.originalText }.joined(separator: "\n")
    }

    public static func validate(
        candidates: [StructureCandidate],
        transcript: [TranscriptSpan],
        images: [ImageAttachment] = []
    ) throws {
        let spanIDs = Set(transcript.map(\.id))
        let imageIDs = Set(images.filter { $0.deletedAt == nil }.map(\.id))
        let candidateIDs = Set(candidates.map(\.nodeID))
        guard candidateIDs.count == candidates.count else {
            let grouped = Dictionary(grouping: candidates, by: \.nodeID)
            throw IntegrityViolation.duplicateNode(grouped.first(where: { $0.value.count > 1 })!.key)
        }

        for candidate in candidates {
            if candidate.sourceBoundStatus == "extracted" {
                guard let core = candidate.coreOriginals, !core.isEmpty,
                      candidate.summary == core.map(\.text).joined(separator: "\n\n") else {
                    throw IntegrityViolation.generatedSemanticText(candidate.nodeID)
                }
            }
            try validateExcerpts((candidate.coreOriginals ?? []) + (candidate.conditionOriginals ?? []),
                                 nodeID: candidate.nodeID, sourceSpanIDs: Set(candidate.sourceSpanIDs), transcript: transcript)
            try validateSemanticRole(candidate.semanticRole, nodeID: candidate.nodeID, parentID: candidate.parentID,
                                     relation: candidate.relation, argumentSummary: candidate.argumentSummary)
            guard !candidate.sourceSpanIDs.isEmpty || candidate.sourceImageIDs?.isEmpty == false else {
                throw IntegrityViolation.emptySource(candidate.nodeID)
            }
            if let missing = ((candidate.sourceImageIDs ?? []) + (candidate.coveredSourceImageIDs ?? [])).first(where: { !imageIDs.contains($0) }) {
                throw IntegrityViolation.unknownImageSource(missing)
            }
            if let missing = (candidate.sourceSpanIDs + (candidate.coveredSourceSpanIDs ?? [])).first(where: { !spanIDs.contains($0) }) {
                throw IntegrityViolation.unknownSource(missing)
            }
            if let parentID = candidate.parentID, !candidateIDs.contains(parentID) {
                throw IntegrityViolation.unknownParent(parentID)
            }
        }
    }

    public static func validateStoredNode(_ node: KnowledgeNode, transcript: [TranscriptSpan], images: [ImageAttachment] = []) throws {
        let imageIDs = Set(images.map(\.id))
        if let missing = ((node.sourceImageIDs ?? []) + (node.coveredSourceImageIDs ?? [])).first(where: { !imageIDs.contains($0) }) {
            throw IntegrityViolation.unknownImageSource(missing)
        }
        try validateSemanticRole(node.semanticRole, nodeID: node.id, parentID: node.parentID,
                                 relation: node.relation, argumentSummary: node.argumentSummary)
        let isVerbatimThought = node.kind == .thought && node.thoughtID != nil
        if !node.isSecondaryEdit, !isVerbatimThought, node.userEditedText?.isEmpty == false {
            throw IntegrityViolation.generatedSemanticText(node.id)
        }
        if node.sourceBoundStatus == "extracted", !node.isSecondaryEdit, !isVerbatimThought {
            guard let core = node.coreOriginals, !core.isEmpty,
                  node.aiSummary == core.map(\.text).joined(separator: "\n\n") else {
                throw IntegrityViolation.generatedSemanticText(node.id)
            }
        }
        // Archives are the actual words selected at that time, including an
        // earlier correction with the same ID. A partial archive overrides only
        // its own IDs; it must not hide other still-current excerpt sources.
        let archived = node.archivedSourceSpans ?? []
        let archivedIDs = Set(archived.map(\.id))
        try validateExcerpts((node.coreOriginals ?? []) + (node.conditionOriginals ?? []),
                             nodeID: node.id, sourceSpanIDs: Set(node.sourceSpanIDs).union(archivedIDs),
                             transcript: archived + transcript.filter { !archivedIDs.contains($0.id) })
        if !node.isSecondaryEdit && !isVerbatimThought {
            guard !node.sourceSpanIDs.isEmpty || node.sourceImageIDs?.isEmpty == false else { throw IntegrityViolation.emptySource(node.id) }
            let spanIDs = Set(transcript.map(\.id))
            if let missing = (node.sourceSpanIDs + (node.coveredSourceSpanIDs ?? [])).first(where: { !spanIDs.contains($0) }) {
                throw IntegrityViolation.unknownSource(missing)
            }
        }
    }

    /// Verify saved quotations, never a model's assertion that they are quotes.
    /// Offsets use Python-compatible Unicode scalars and must describe one
    /// continuous passage: selecting distant slices cannot erase a negation.
    public static func validateExcerpts(_ excerpts: [OriginalExcerpt], nodeID: UUID,
                                        sourceSpanIDs: Set<UUID>, transcript: [TranscriptSpan]) throws {
        guard !excerpts.isEmpty else { return }
        var sources: [UUID: TranscriptSpan] = [:]
        for span in transcript {
            guard sources.updateValue(span, forKey: span.id) == nil else {
                throw IntegrityViolation.generatedSemanticText(nodeID)
            }
        }
        for excerpt in excerpts {
            guard !excerpt.parts.isEmpty else { throw IntegrityViolation.emptySource(nodeID) }
            var rebuilt = ""
            var previous: (part: OriginalExcerptPart, span: TranscriptSpan, length: Int)?
            var first: TranscriptSpan?
            for part in excerpt.parts {
                guard sourceSpanIDs.contains(part.sourceID), let span = sources[part.sourceID] else {
                    throw IntegrityViolation.unknownSource(part.sourceID)
                }
                let corrected = span.correctedText
                let original = corrected?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? corrected! : span.originalText
                let scalars = Array(original.unicodeScalars)
                guard part.startOffset >= 0, part.endOffset > part.startOffset, part.endOffset <= scalars.count else {
                    throw IntegrityViolation.generatedSemanticText(nodeID)
                }
                if let previous {
                    let continuous: Bool
                    if previous.span.id == span.id {
                        continuous = previous.part.endOffset == part.startOffset
                    } else {
                        continuous = previous.part.endOffset == previous.length && part.startOffset == 0
                            && previous.span.sequence < Int.max && span.sequence == previous.span.sequence + 1
                            && previous.span.origin?.sessionID == span.origin?.sessionID
                            && previous.span.origin?.authoredByUser == span.origin?.authoredByUser
                            && previous.span.speakerID == span.speakerID
                    }
                    guard continuous else { throw IntegrityViolation.generatedSemanticText(nodeID) }
                }
                if first == nil { first = span }
                rebuilt += String(String.UnicodeScalarView(scalars[part.startOffset..<part.endOffset]))
                previous = (part, span, scalars.count)
            }
            guard rebuilt == excerpt.text else { throw IntegrityViolation.generatedSemanticText(nodeID) }
            guard excerpt.origin == first?.origin else { throw IntegrityViolation.generatedSemanticText(nodeID) }
            if let origin = excerpt.origin {
                guard
                      origin.startTime.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                    throw IntegrityViolation.generatedSemanticText(nodeID)
                }
            }
            if let time = excerpt.time {
                guard time.count == 2, time.allSatisfy({ $0.isFinite && $0 >= 0 }), time[1] >= time[0] else {
                    throw IntegrityViolation.generatedSemanticText(nodeID)
                }
            }
        }
    }

    private static func validateSemanticRole(_ role: NodeSemanticRole?, nodeID: UUID, parentID: UUID?, relation: RelationKind, argumentSummary: String?) throws {
        if role == .topic && (parentID != nil || relation != .root || argumentSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) {
            throw IntegrityViolation.invalidSemanticRole(nodeID)
        }
    }

    public static func canPermanentlyDeleteAudio(from session: SessionRecord) -> Bool {
        session.transcriptComplete && session.structureSaved && session.filesComplete
    }

    public static func requireSafeAudioDeletion(from session: SessionRecord) throws {
        guard canPermanentlyDeleteAudio(from: session) else {
            throw IntegrityViolation.unsafeAudioDeletion
        }
    }
}

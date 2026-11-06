import Foundation

public extension String {
    /// Presentation/export conversion only. Stored user and source data remain unchanged.
    var simplifiedChineseForDisplay: String {
        applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? self
    }
}

public enum SpeakerRole: String, Codable, CaseIterable, Sendable {
    case host = "主播"
    case guest = "嘉宾"
    case caller = "连麦者"
    case user = "我"
    case unknown = "说话人"
}

public enum NodeKind: String, Codable, CaseIterable, Sendable {
    case main = "主线"
    case branch = "支线"
    case evidence = "证据"
    case thought = "我的思考"
}

public enum RelationKind: String, Codable, CaseIterable, Sendable {
    case root
    case child
    case parallel
    case supports
    case userThought
}

public enum SessionStatus: String, Codable, Sendable {
    case draft = "准备中"
    case recording = "正在接收"
    case paused = "已暂停"
    case processing = "本地处理中"
    case ready = "结构已保存"
    case failed = "需要处理"
}

public enum AudioState: String, Codable, Sendable {
    case none
    case retained
    case recoverableTrash
    case permanentlyDeleted
}

public struct CanvasPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Speaker: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var role: SpeakerRole
    public var displayName: String

    public init(id: UUID = UUID(), role: SpeakerRole, displayName: String? = nil) {
        self.id = id
        self.role = role
        self.displayName = displayName ?? role.rawValue
    }
}

public struct TranscriptSpan: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sequence: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var speakerID: UUID
    public var originalText: String
    public var correctedText: String?
    /// Readable automatic punctuation, never a replacement for raw ASR words.
    public var punctuatedText: String? = nil
    /// An explicitly labelled reading aid; never raw recognition or excerpt evidence.
    public var proofreadText: String? = nil
    public var proofreadBasis: String? = nil
    public var proofreadUncertainties: [String]? = nil
    public var proofreadingVersion: String? = nil
    public var proofreadPunctuatedText: String? = nil
    public var isImportant: Bool
    /// True when local analysis identifies music, lyrics, or recognition
    /// hallucination. Raw recognition remains stored as evidence.
    public var isBackgroundAudio: Bool?
    /// A combined/imported manuscript keeps the original record and time.
    public var origin: SourceReference? = nil

    public init(
        id: UUID = UUID(),
        sequence: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerID: UUID,
        originalText: String,
        correctedText: String? = nil,
        isImportant: Bool = false,
        isBackgroundAudio: Bool? = nil,
        punctuatedText: String? = nil,
        proofreadText: String? = nil,
        proofreadBasis: String? = nil,
        proofreadUncertainties: [String]? = nil,
        proofreadingVersion: String? = nil,
        proofreadPunctuatedText: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.startTime = startTime
        self.endTime = endTime
        self.speakerID = speakerID
        self.originalText = originalText
        self.correctedText = correctedText
        self.punctuatedText = punctuatedText
        self.proofreadText = proofreadText
        self.proofreadBasis = proofreadBasis
        self.proofreadUncertainties = proofreadUncertainties
        self.proofreadingVersion = proofreadingVersion
        self.proofreadPunctuatedText = proofreadPunctuatedText
        self.isImportant = isImportant
        self.isBackgroundAudio = isBackgroundAudio
    }

    public var displayedText: String {
        TranscriptReadingFormatter.text(for: self)
    }

    /// A stale correction or AI rewrite of user-authored text must not be shown.
    public var validProofreadText: String? {
        guard origin?.authoredByUser != true, let proofreadBasis,
              proofreadBasis.utf8.elementsEqual(originalText.utf8),
              let text = proofreadText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// This layer may only place Chinese punctuation and whitespace.
    /// Decimal points, signs, words and all other source characters are bound.
    public var validProofreadPunctuatedText: String? {
        guard let basis = validProofreadText, let text = proofreadPunctuatedText,
              TranscriptReadingFormatter.isPunctuationOnlyRewrite(text, of: basis) else { return nil }
        return text
    }

    public var hasManualCorrection: Bool {
        correctedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public var hasAutomaticCorrection: Bool {
        guard !hasManualCorrection, let text = validProofreadText else { return false }
        return Self.simplified(validProofreadPunctuatedText ?? text) != Self.simplified(originalText)
    }

    public var validProofreadUncertainties: [String] {
        guard !hasManualCorrection, validProofreadText != nil else { return [] }
        return (proofreadUncertainties ?? []).compactMap {
            let text = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Self.simplified(text)
        }
    }

    public var simplifiedOriginalText: String { Self.simplified(readableOriginal) }

    var readableOriginal: String {
        // The current acoustic formatter only appends one punctuation mark.
        // Reject arbitrary persisted replacements, including modified digits.
        guard let punctuatedText, punctuatedText.hasPrefix(originalText),
              punctuatedText.count == originalText.count + 1,
              let last = punctuatedText.last, "。，！？；：,.!?;:".contains(last) else { return originalText }
        return punctuatedText
    }

    public var isFilteredBackground: Bool {
        isBackgroundAudio == true && !isImportant && correctedText == nil
    }

    private static func simplified(_ text: String) -> String {
        text.simplifiedChineseForDisplay
    }
}

/// Explicit model semantics, not a classification of the user's own wording.
/// Nil remains unclassified for legacy records and human-authored edits.
public enum NodeSemanticRole: String, Codable, Equatable, Sendable {
    case topic
    case assertion
}

public struct OriginalExcerptPart: Codable, Equatable, Sendable {
    public var sourceID: UUID
    public var startOffset: Int
    public var endOffset: Int

    public init(sourceID: UUID, startOffset: Int, endOffset: Int) {
        self.sourceID = sourceID; self.startOffset = startOffset; self.endOffset = endOffset
    }
}

public struct OriginalExcerpt: Codable, Equatable, Sendable {
    public var text: String
    public var parts: [OriginalExcerptPart]
    public var origin: SourceReference?
    public var time: [Double]?

    public init(text: String, parts: [OriginalExcerptPart], origin: SourceReference? = nil, time: [Double]? = nil) {
        self.text = text; self.parts = parts; self.origin = origin; self.time = time
    }
}

public struct KnowledgeNode: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sourceSpanIDs: [UUID]
    public var sourceImageIDs: [UUID]? = nil
    public var coveredSourceImageIDs: [UUID]? = nil
    public var kind: NodeKind
    public var parentID: UUID?
    public var relation: RelationKind
    public var confidence: Double?
    public var position: CanvasPoint
    public var isCollapsed: Bool
    public var userEditedText: String?
    public var isSecondaryEdit: Bool
    public var isDeleted: Bool
    /// Non-nil means a human has changed the model-proposed node. Re-analysis
    /// must preserve this node unless the user explicitly accepts replacement.
    public var manualRevisionAt: Date?
    public var positionEditedAt: Date? = nil
    /// Nil identifies legacy records whose manual edit may also be a drag.
    public var positionIsAutomatic: Bool? = nil
    public var userLabel: String?
    /// Links a visible canvas node back to the user's verbatim thought.
    /// Model-generated nodes never set this field.
    public var thoughtID: UUID?
    /// Links a dedicated visible evidence node to the user's important mark.
    public var importantMarkID: UUID?
    /// Local-model summary shown on the mind map. Every summary must retain
    /// sourceSpanIDs so the user can inspect the speaker's exact words.
    public var aiSummary: String?
    public var argumentSummary: String? = nil
    public var relationToPrevious: String? = nil
    public var annotationInputFingerprint: String? = nil
    public var coveredSourceSpanIDs: [UUID]? = nil
    /// Evidence captured when an authored node was edited against an older
    /// transcription. Current source IDs are timeline links, not replacements
    /// for these verbatim historical quotations.
    public var archivedSourceSpans: [TranscriptSpan]? = nil
    public var semanticRole: NodeSemanticRole? = nil
    public var origin: SourceReference? = nil
    /// Distinguishes model-selected verbatim points from rewritten summaries.
    public var sourceBoundStatus: String? = nil
    public var navigationLabel: String? = nil
    public var coreOriginals: [OriginalExcerpt]? = nil
    public var conditionOriginals: [OriginalExcerpt]? = nil

    public init(
        id: UUID = UUID(),
        sourceSpanIDs: [UUID],
        kind: NodeKind,
        parentID: UUID? = nil,
        relation: RelationKind,
        confidence: Double? = nil,
        position: CanvasPoint,
        isCollapsed: Bool = false,
        userEditedText: String? = nil,
        isSecondaryEdit: Bool = false,
        isDeleted: Bool = false,
        manualRevisionAt: Date? = nil,
        positionEditedAt: Date? = nil,
        positionIsAutomatic: Bool? = true,
        userLabel: String? = nil,
        thoughtID: UUID? = nil,
        importantMarkID: UUID? = nil,
        aiSummary: String? = nil,
        argumentSummary: String? = nil,
        relationToPrevious: String? = nil,
        coveredSourceSpanIDs: [UUID]? = nil,
        archivedSourceSpans: [TranscriptSpan]? = nil,
        semanticRole: NodeSemanticRole? = nil,
        sourceImageIDs: [UUID]? = nil,
        coveredSourceImageIDs: [UUID]? = nil
    ) {
        self.id = id
        self.sourceSpanIDs = sourceSpanIDs
        self.sourceImageIDs = sourceImageIDs
        self.coveredSourceImageIDs = coveredSourceImageIDs
        self.kind = kind
        self.parentID = parentID
        self.relation = relation
        self.confidence = confidence
        self.position = position
        self.isCollapsed = isCollapsed
        self.userEditedText = userEditedText
        self.isSecondaryEdit = isSecondaryEdit
        self.isDeleted = isDeleted
        self.manualRevisionAt = manualRevisionAt
        self.positionEditedAt = positionEditedAt
        self.positionIsAutomatic = positionIsAutomatic
        self.userLabel = userLabel
        self.thoughtID = thoughtID
        self.importantMarkID = importantMarkID
        self.aiSummary = aiSummary
        self.argumentSummary = argumentSummary
        self.relationToPrevious = relationToPrevious
        self.coveredSourceSpanIDs = coveredSourceSpanIDs
        self.archivedSourceSpans = archivedSourceSpans
        self.semanticRole = semanticRole
    }
}

extension KnowledgeNode {
    public func hasHistoricalEvidence(comparedTo transcript: [TranscriptSpan]) -> Bool {
        let current = Dictionary(uniqueKeysWithValues: transcript.map { ($0.id, $0) })
        return (archivedSourceSpans ?? []).contains { archived in
            guard let span = current[archived.id] else { return true }
            return archived.originalText != span.originalText || archived.correctedText != span.correctedText
        }
    }
}

public struct ImportantMark: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var anchorSpanID: UUID
    public var protectedSpanIDs: [UUID]
    public var anchorTime: TimeInterval? = nil

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        anchorSpanID: UUID,
        protectedSpanIDs: [UUID],
        anchorTime: TimeInterval? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.anchorSpanID = anchorSpanID
        self.protectedSpanIDs = protectedSpanIDs
        self.anchorTime = anchorTime
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var pythonPath: String
    public var whisperModelPath: String
    public var structureModelPath: String
    public var ffmpegPath: String
    public var analysisProvider: String? = nil
    public var apiConfiguration: APIConfiguration? = nil
    public var imageAPIConfiguration: APIConfiguration? = nil

    public init(
        pythonPath: String = PortableRuntime.defaults.pythonPath,
        whisperModelPath: String = PortableRuntime.defaults.whisperModelPath,
        structureModelPath: String = PortableRuntime.defaults.structureModelPath,
        ffmpegPath: String = PortableRuntime.defaults.ffmpegPath
    ) {
        self.pythonPath = pythonPath
        self.whisperModelPath = whisperModelPath
        self.structureModelPath = structureModelPath
        self.ffmpegPath = ffmpegPath
    }
}

public struct UserThought: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var text: String
    public var attachedNodeID: UUID?
    public var isSecondaryEdit: Bool
    public var isDeleted: Bool
    /// Elapsed seconds from the beginning of the recording. This lets the
    /// transcript show the thought at the exact point where it was written.
    public var anchorTime: TimeInterval?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String,
        attachedNodeID: UUID? = nil,
        isSecondaryEdit: Bool,
        isDeleted: Bool = false,
        anchorTime: TimeInterval? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.attachedNodeID = attachedNodeID
        self.isSecondaryEdit = isSecondaryEdit
        self.isDeleted = isDeleted
        self.anchorTime = anchorTime
    }
}

public struct StructureSnapshot: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var reason: String
    public var nodes: [KnowledgeNode]
    public var thoughts: [UserThought]
    /// Optional for compatibility with snapshots written before transcript
    /// versions became atomic with their corresponding map.
    public var transcript: [TranscriptSpan]? = nil
    public var speakers: [Speaker]? = nil
    public var importantMarks: [ImportantMark]? = nil
    public var pendingImportantTimes: [TimeInterval]? = nil
    public var transcriptComplete: Bool? = nil
    public var structureSaved: Bool? = nil
    public var analysisWarnings: [String]? = nil
    public var images: [ImageAttachment]? = nil

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        reason: String,
        nodes: [KnowledgeNode],
        thoughts: [UserThought],
        transcript: [TranscriptSpan]? = nil,
        speakers: [Speaker]? = nil,
        importantMarks: [ImportantMark]? = nil,
        pendingImportantTimes: [TimeInterval]? = nil,
        transcriptComplete: Bool? = nil,
        structureSaved: Bool? = nil,
        analysisWarnings: [String]? = nil,
        images: [ImageAttachment]? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.reason = reason
        self.nodes = nodes
        self.thoughts = thoughts
        self.transcript = transcript
        self.speakers = speakers
        self.importantMarks = importantMarks
        self.pendingImportantTimes = pendingImportantTimes
        self.transcriptComplete = transcriptComplete
        self.structureSaved = structureSaved
        self.analysisWarnings = analysisWarnings
        self.images = images
    }
}

public struct SessionRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var endedAt: Date?
    public var updatedAt: Date
    public var sourceName: String
    public var sourceKind: String
    public var status: SessionStatus
    public var speakers: [Speaker]
    public var transcript: [TranscriptSpan]
    public var nodes: [KnowledgeNode]
    public var thoughts: [UserThought]
    public var versions: [StructureSnapshot]
    public var audioRelativePaths: [String]
    public var audioState: AudioState
    public var transcriptComplete: Bool
    public var structureSaved: Bool
    public var filesComplete: Bool
    public var deletedAt: Date?
    public var isMergedRecord: Bool
    /// Kept optional so V1 databases written before this field remain readable.
    public var audioTrashedAt: Date?
    public var audioRestoredAt: Date?
    public var candidateVersions: [StructureSnapshot]?
    public var importantMarks: [ImportantMark]?
    public var pendingImportantTimes: [TimeInterval]?
    public var recoveryPending: Bool?
    public var automaticRecoveryAttempts: Int?
    public var analysisWarnings: [String]? = nil
    public var processingRunLabel: String? = nil
    public var processingRetranscribe: Bool? = nil
    /// The last failed attempt is durable; it must not be inferred from an empty map.
    public var lastProcessingError: String? = nil
    public var focusedStudyQuestion: String? = nil
    public var focusedStudyReports: [FocusedStudyReport]? = nil
    public var focusedStudyError: String? = nil
    public var images: [ImageAttachment]? = nil

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        endedAt: Date? = nil,
        updatedAt: Date = Date(),
        sourceName: String,
        sourceKind: String,
        status: SessionStatus = .draft,
        speakers: [Speaker] = [],
        transcript: [TranscriptSpan] = [],
        nodes: [KnowledgeNode] = [],
        thoughts: [UserThought] = [],
        versions: [StructureSnapshot] = [],
        audioRelativePaths: [String] = [],
        audioState: AudioState = .none,
        transcriptComplete: Bool = false,
        structureSaved: Bool = false,
        filesComplete: Bool = true,
        deletedAt: Date? = nil,
        isMergedRecord: Bool = false,
        audioTrashedAt: Date? = nil,
        audioRestoredAt: Date? = nil,
        candidateVersions: [StructureSnapshot]? = nil,
        importantMarks: [ImportantMark]? = nil,
        pendingImportantTimes: [TimeInterval]? = nil,
        recoveryPending: Bool? = nil,
        automaticRecoveryAttempts: Int? = nil,
        images: [ImageAttachment]? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.updatedAt = updatedAt
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.status = status
        self.speakers = speakers
        self.transcript = transcript
        self.nodes = nodes
        self.thoughts = thoughts
        self.versions = versions
        self.audioRelativePaths = audioRelativePaths
        self.audioState = audioState
        self.transcriptComplete = transcriptComplete
        self.structureSaved = structureSaved
        self.filesComplete = filesComplete
        self.deletedAt = deletedAt
        self.isMergedRecord = isMergedRecord
        self.audioTrashedAt = audioTrashedAt
        self.audioRestoredAt = audioRestoredAt
        self.candidateVersions = candidateVersions
        self.importantMarks = importantMarks
        self.pendingImportantTimes = pendingImportantTimes
        self.recoveryPending = recoveryPending
        self.automaticRecoveryAttempts = automaticRecoveryAttempts
        self.images = images
    }
}

public struct AppDatabase: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sessions: [SessionRecord]
    /// Optional for backwards-compatible decoding of existing local data.
    public var settings: AppSettings?
    /// Collections reference records; removing a collection never deletes them.
    public var collections: [KnowledgeCollection]? = nil

    public init(schemaVersion: Int = 2, sessions: [SessionRecord] = [], settings: AppSettings? = AppSettings()) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
        self.settings = settings
    }
}

public struct StructureCandidate: Codable, Equatable, Sendable {
    public var nodeID: UUID
    public var sourceSpanIDs: [UUID]
    public var sourceImageIDs: [UUID]? = nil
    public var coveredSourceImageIDs: [UUID]? = nil
    public var kind: NodeKind
    public var parentID: UUID?
    public var relation: RelationKind
    public var confidence: Double
    public var summary: String?
    public var argumentSummary: String? = nil
    public var relationToPrevious: String? = nil
    public var coveredSourceSpanIDs: [UUID]? = nil
    public var semanticRole: NodeSemanticRole? = nil
    /// Program-owned navigation title, not a model factual assertion.
    public var navigationRoot: Bool? = nil
    public var sourceBoundStatus: String? = nil
    public var navigationLabel: String? = nil
    public var coreOriginals: [OriginalExcerpt]? = nil
    public var conditionOriginals: [OriginalExcerpt]? = nil

    public init(
        nodeID: UUID = UUID(),
        sourceSpanIDs: [UUID],
        kind: NodeKind,
        parentID: UUID? = nil,
        relation: RelationKind,
        confidence: Double,
        summary: String? = nil,
        argumentSummary: String? = nil,
        relationToPrevious: String? = nil,
        coveredSourceSpanIDs: [UUID]? = nil,
        semanticRole: NodeSemanticRole? = nil,
        sourceImageIDs: [UUID]? = nil,
        coveredSourceImageIDs: [UUID]? = nil
    ) {
        self.nodeID = nodeID
        self.sourceSpanIDs = sourceSpanIDs
        self.sourceImageIDs = sourceImageIDs
        self.coveredSourceImageIDs = coveredSourceImageIDs
        self.kind = kind
        self.parentID = parentID
        self.relation = relation
        self.confidence = confidence
        self.summary = summary
        self.argumentSummary = argumentSummary
        self.relationToPrevious = relationToPrevious
        self.coveredSourceSpanIDs = coveredSourceSpanIDs
        self.semanticRole = semanticRole
    }
}

import Foundation

public struct FocusedStudySection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var heading: String
    public var explanation: String
    public var sourceSpanIDs: [UUID]
    public var sourceImageIDs: [UUID]? = nil
    public init(id: UUID = UUID(), heading: String, explanation: String, sourceSpanIDs: [UUID], sourceImageIDs: [UUID]? = nil) {
        self.id = id; self.heading = heading; self.explanation = explanation; self.sourceSpanIDs = sourceSpanIDs
        self.sourceImageIDs = sourceImageIDs
    }
}

public struct FocusedStudyReport: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var question: String
    public var createdAt: Date
    public var sections: [FocusedStudySection]
    public var gaps: [String]
    public init(id: UUID = UUID(), question: String, createdAt: Date = Date(), sections: [FocusedStudySection], gaps: [String] = []) {
        self.id = id; self.question = question; self.createdAt = createdAt; self.sections = sections; self.gaps = gaps
    }
}

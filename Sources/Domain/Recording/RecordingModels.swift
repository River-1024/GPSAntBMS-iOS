import Foundation

enum RecordingSegmentKind: String, Codable, Equatable {
    case normal
    case locked
}

struct RecordingSegment: Codable, Equatable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let sequence: Int
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: TimeInterval
    let byteCount: Int64
    let fileName: String
    var kind: RecordingSegmentKind
    var interruptionReason: String?

    init(id: UUID = UUID(),
         sessionID: UUID,
         sequence: Int,
         startedAt: Date,
         endedAt: Date,
         durationSeconds: TimeInterval,
         byteCount: Int64,
         fileName: String,
         kind: RecordingSegmentKind = .normal,
         interruptionReason: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = max(0, durationSeconds)
        self.byteCount = max(0, byteCount)
        self.fileName = fileName
        self.kind = kind
        self.interruptionReason = interruptionReason
    }
}

struct RecordingManifest: Codable, Equatable {
    var segments: [RecordingSegment]

    static let empty = RecordingManifest(segments: [])
}

enum RecordingCapacityLimit: Int, Codable, CaseIterable, Hashable {
    case fiveGB = 5
    case tenGB = 10
    case twentyGB = 20

    static let defaultValue: RecordingCapacityLimit = .tenGB

    var byteCount: Int64 { Int64(rawValue) * 1_000_000_000 }

    var displayText: String { "\(rawValue) GB" }
}

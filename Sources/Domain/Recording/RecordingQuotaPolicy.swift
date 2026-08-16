import Foundation

struct RecordingQuotaDecision: Equatable {
    let segmentIDsToDelete: [UUID]
    let canAllocate: Bool
    let lockedBytes: Int64
}

enum RecordingQuotaPolicy {
    static func decision(segments: [RecordingSegment],
                         capacityBytes: Int64,
                         requiredBytes: Int64,
                         protectedSegmentIDs: Set<UUID> = []) -> RecordingQuotaDecision {
        let capacity = max(0, capacityBytes)
        let required = max(0, requiredBytes)
        let lockedBytes = segments
            .filter { $0.kind == .locked }
            .reduce(Int64(0)) { $0 + $1.byteCount }
        var usedBytes = segments.reduce(Int64(0)) { $0 + $1.byteCount }
        var deletions: [UUID] = []

        let normalOldestFirst = segments
            .filter { $0.kind == .normal && !protectedSegmentIDs.contains($0.id) }
            .sorted {
                if $0.startedAt == $1.startedAt { return $0.sequence < $1.sequence }
                return $0.startedAt < $1.startedAt
            }

        for segment in normalOldestFirst where usedBytes + required > capacity {
            deletions.append(segment.id)
            usedBytes -= segment.byteCount
        }

        return RecordingQuotaDecision(
            segmentIDsToDelete: deletions,
            canAllocate: usedBytes + required <= capacity,
            lockedBytes: lockedBytes
        )
    }
}

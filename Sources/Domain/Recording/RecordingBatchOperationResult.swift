import Foundation

struct RecordingBatchDeleteResult: Equatable {
    let deletedIDs: Set<UUID>
    let protectedIDs: Set<UUID>
    let failedIDs: Set<UUID>

    var deletedCount: Int { deletedIDs.count }
    var protectedCount: Int { protectedIDs.count }
    var failedCount: Int { failedIDs.count }
    var madeProgress: Bool { !deletedIDs.isEmpty }
}

struct RecordingBatchMutationResult: Equatable {
    let changedIDs: Set<UUID>
    let unchangedIDs: Set<UUID>
    let failedIDs: Set<UUID>

    var changedCount: Int { changedIDs.count }
}

struct RecordingSelectionState: Equatable {
    private(set) var selectedIDs: Set<UUID> = []

    mutating func select(_ id: UUID) {
        selectedIDs.insert(id)
    }

    mutating func toggle(_ id: UUID) {
        if !selectedIDs.remove(id).isEmpty { return }
        selectedIDs.insert(id)
    }

    mutating func selectAll(_ segments: [RecordingSegment]) {
        selectedIDs = Set(segments.map(\.id))
    }

    mutating func clear() {
        selectedIDs.removeAll()
    }

    mutating func prune(availableSegments: [RecordingSegment]) {
        selectedIDs.formIntersection(Set(availableSegments.map(\.id)))
    }
}

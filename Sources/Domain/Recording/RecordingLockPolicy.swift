import Foundation

struct RecordingLockPolicy: Equatable {
    private(set) var lockedSequences: Set<Int> = []
    private(set) var pendingNextSequences: Set<Int> = []

    mutating func requestLock(currentSequence: Int, previousSequence: Int?) {
        if let previousSequence { lockedSequences.insert(previousSequence) }
        lockedSequences.insert(currentSequence)
        pendingNextSequences.insert(currentSequence + 1)
    }

    mutating func segmentCompleted(sequence: Int) -> Bool {
        guard pendingNextSequences.remove(sequence) != nil else {
            return lockedSequences.contains(sequence)
        }
        lockedSequences.insert(sequence)
        return true
    }

    func shouldLock(sequence: Int) -> Bool {
        lockedSequences.contains(sequence) || pendingNextSequences.contains(sequence)
    }

    mutating func discardPending(sequence: Int) {
        pendingNextSequences.remove(sequence)
    }
}

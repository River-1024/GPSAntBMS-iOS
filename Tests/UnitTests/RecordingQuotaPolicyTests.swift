import XCTest
@testable import GPSAntBMS

final class RecordingQuotaPolicyTests: XCTestCase {
    private func segment(sequence: Int, bytes: Int64, kind: RecordingSegmentKind = .normal) -> RecordingSegment {
        let date = Date(timeIntervalSinceReferenceDate: TimeInterval(sequence))
        return RecordingSegment(sessionID: UUID(), sequence: sequence, startedAt: date,
                                endedAt: date.addingTimeInterval(1), durationSeconds: 1,
                                byteCount: bytes, fileName: "\(sequence).mov", kind: kind)
    }

    func testDeletesOldestNormalSegmentsUntilAllocationFits() {
        let segments = [segment(sequence: 1, bytes: 40), segment(sequence: 2, bytes: 40), segment(sequence: 3, bytes: 20)]
        let decision = RecordingQuotaPolicy.decision(segments: segments, capacityBytes: 100, requiredBytes: 50)
        XCTAssertEqual(decision.segmentIDsToDelete, [segments[0].id, segments[1].id])
        XCTAssertTrue(decision.canAllocate)
    }

    func testNeverDeletesLockedSegments() {
        let locked = segment(sequence: 1, bytes: 90, kind: .locked)
        let decision = RecordingQuotaPolicy.decision(segments: [locked], capacityBytes: 100, requiredBytes: 20)
        XCTAssertEqual(decision.segmentIDsToDelete, [])
        XCTAssertFalse(decision.canAllocate)
        XCTAssertEqual(decision.lockedBytes, 90)
    }

    func testDoesNotDeleteTemporarilyProtectedPreviousSegment() {
        let previous = segment(sequence: 1, bytes: 60)
        let older = segment(sequence: 0, bytes: 40)
        let decision = RecordingQuotaPolicy.decision(
            segments: [older, previous], capacityBytes: 100, requiredBytes: 30,
            protectedSegmentIDs: [previous.id])
        XCTAssertEqual(decision.segmentIDsToDelete, [older.id])
        XCTAssertTrue(decision.canAllocate)
    }
}

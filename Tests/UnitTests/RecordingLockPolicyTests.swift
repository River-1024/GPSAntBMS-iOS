import XCTest
@testable import GPSAntBMS

final class RecordingLockPolicyTests: XCTestCase {
    func testFirstSegmentLocksCurrentAndNext() {
        var policy = RecordingLockPolicy()
        policy.requestLock(currentSequence: 0, previousSequence: nil)
        XCTAssertTrue(policy.shouldLock(sequence: 0))
        XCTAssertTrue(policy.shouldLock(sequence: 1))
        XCTAssertFalse(policy.shouldLock(sequence: -1))
    }

    func testRepeatedRequestsAreIdempotentAndExtendWindow() {
        var policy = RecordingLockPolicy()
        policy.requestLock(currentSequence: 1, previousSequence: 0)
        policy.requestLock(currentSequence: 2, previousSequence: 1)
        XCTAssertTrue(policy.shouldLock(sequence: 0))
        XCTAssertTrue(policy.shouldLock(sequence: 1))
        XCTAssertTrue(policy.shouldLock(sequence: 2))
        XCTAssertTrue(policy.shouldLock(sequence: 3))
        XCTAssertTrue(policy.segmentCompleted(sequence: 3))
    }
}

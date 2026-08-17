import XCTest
@testable import GPSAntBMS

final class RecordingSelectionStateTests: XCTestCase {
    func testSelectToggleAllAndPrune() {
        let first = segment(sequence: 0)
        let second = segment(sequence: 1)
        let third = segment(sequence: 2)
        var selection = RecordingSelectionState()

        selection.select(first.id)
        selection.toggle(second.id)
        selection.toggle(first.id)
        XCTAssertEqual(selection.selectedIDs, [second.id])

        selection.selectAll([first, second, third])
        XCTAssertEqual(selection.selectedIDs, [first.id, second.id, third.id])

        selection.prune(availableSegments: [first, third])
        XCTAssertEqual(selection.selectedIDs, [first.id, third.id])
    }

    func testClearRemovesAllSelectedIDs() {
        let segment = segment(sequence: 0)
        var selection = RecordingSelectionState()
        selection.select(segment.id)
        selection.clear()

        XCTAssertTrue(selection.selectedIDs.isEmpty)
    }

    private func segment(sequence: Int) -> RecordingSegment {
        let date = Date(timeIntervalSinceReferenceDate: TimeInterval(sequence))
        return RecordingSegment(sessionID: UUID(), sequence: sequence, startedAt: date,
                                endedAt: date, durationSeconds: 0, byteCount: 0,
                                fileName: "\(sequence).mov")
    }
}

import AVFoundation
import XCTest
@testable import GPSAntBMS

private final class MockDashcamCapture: DashcamCaptureBackend {
    let captureSession = AVCaptureSession()
    var eventHandler: ((DashcamCaptureEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var stopSessionCount = 0

    func prepare(completion: @escaping (Result<Void, RecordingFailure>) -> Void) {
        completion(.success(()))
    }

    func startRecording(sessionID: UUID, firstSequence: Int,
                        temporaryURL: @escaping (Int) -> URL) {
        startCount += 1
    }

    func stopRecording(reason: String?) { stopCount += 1 }
    func stopSession() { stopSessionCount += 1 }
    func shutdown() { stopCount += 1 }
}

private struct AllowedDashcamPermissions: DashcamPermissionProviding {
    func requestCapturePermissions(completion: @escaping (Result<Void, RecordingFailure>) -> Void) {
        completion(.success(()))
    }
    func requestPhotoAddPermission(completion: @escaping (Bool) -> Void) { completion(true) }
}

@MainActor
final class DashcamRecordingControllerTests: XCTestCase {
    private var directory: URL!
    private var capture: MockDashcamCapture!
    private var controller: DashcamRecordingController!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashcamControllerTests-\(UUID().uuidString)", isDirectory: true)
        capture = MockDashcamCapture()
        controller = DashcamRecordingController(
            capture: capture,
            permissions: AllowedDashcamPermissions(),
            store: RecordingStore(directoryURL: directory),
            capacityBytes: { 1_000_000_000 })
    }

    override func tearDownWithError() throws {
        controller = nil
        capture = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitForState(
        _ expected: DashcamRecordingState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if controller.state == expected { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待录像状态超时：\(expected)，当前状态：\(controller.state)", file: file, line: line)
    }

    func testStartPublishesRecordingOnlyAfterBackendConfirmation() async {
        controller.openCalibration()
        await waitForState(.preview)

        controller.confirmStart()
        XCTAssertEqual(controller.state, .starting)
        XCTAssertEqual(capture.startCount, 1)

        capture.eventHandler?(.recordingStarted(Date(timeIntervalSinceReferenceDate: 10), sequence: 0))
        await waitForState(.recording(startedAt: Date(timeIntervalSinceReferenceDate: 10)))
        XCTAssertTrue(controller.isRecording)
    }

    func testStopWaitsForBackendStoppedEvent() async {
        controller.openCalibration()
        await waitForState(.preview)
        controller.confirmStart()
        let startedAt = Date()
        capture.eventHandler?(.recordingStarted(startedAt, sequence: 0))
        await waitForState(.recording(startedAt: startedAt))

        controller.stop()
        XCTAssertEqual(controller.state, .finalizing)
        XCTAssertEqual(capture.stopCount, 1)

        capture.eventHandler?(.stopped)
        await waitForState(.idle)
    }

    func testBackgroundDoesNotResumeAfterManualStop() async {
        controller.openCalibration()
        await waitForState(.preview)
        controller.confirmStart()
        let startedAt = Date()
        capture.eventHandler?(.recordingStarted(startedAt, sequence: 0))
        await waitForState(.recording(startedAt: startedAt))
        controller.stop()
        capture.eventHandler?(.stopped)
        await waitForState(.idle)

        controller.applicationDidBecomeActive()
        XCTAssertEqual(capture.startCount, 1)
    }

    func testBackgroundMarksInterruptedAndResumesNewCapture() async {
        controller.openCalibration()
        await waitForState(.preview)
        controller.confirmStart()
        let startedAt = Date()
        capture.eventHandler?(.recordingStarted(startedAt, sequence: 0))
        await waitForState(.recording(startedAt: startedAt))

        controller.applicationWillResignActive()
        guard case .interrupted = controller.state else {
            return XCTFail("退后台必须显示中断状态")
        }

        controller.applicationDidBecomeActive()
        await waitForState(.starting)
        XCTAssertEqual(capture.startCount, 2)
    }

    func testWriterFailureNeverLeavesRecordingStateVisible() async {
        controller.openCalibration()
        await waitForState(.preview)
        controller.confirmStart()
        let startedAt = Date()
        capture.eventHandler?(.recordingStarted(startedAt, sequence: 0))
        await waitForState(.recording(startedAt: startedAt))

        capture.eventHandler?(.failed(.writerFailed("test")))
        await waitForState(.failed(.writerFailed("test")))

        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(controller.state, .failed(.writerFailed("test")))
        XCTAssertEqual(capture.stopCount, 1)
    }
}

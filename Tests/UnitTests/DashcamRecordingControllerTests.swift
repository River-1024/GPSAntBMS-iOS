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

private final class MockRecordingExportService: RecordingExporting {
    private(set) var exportedURLs: [URL] = []

    func exportVideos(at urls: [URL], completion: @escaping (RecordingExportResult) -> Void) {
        exportedURLs = urls
        completion(RecordingExportResult(exportedCount: urls.count,
                                         unreadableCount: 0,
                                         failedCount: 0))
    }
}

private enum ManifestWriteTestError: Error {
    case failed
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

    func testLockedSegmentCannotBeDeleted() throws {
        let locked = try seedSegment(sequence: 0, kind: .locked)

        let result = controller.deleteSegment(locked)

        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(result.protectedIDs, [locked.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.fileURL(for: locked).path))
        XCTAssertEqual(controller.segments.map(\.id), [locked.id])
    }

    func testBatchDeleteRemovesOnlyNormalSegments() throws {
        let normal = try seedSegment(sequence: 0)
        let locked = try seedSegment(sequence: 1, kind: .locked)

        let result = controller.deleteSegments(ids: [normal.id, locked.id])

        XCTAssertEqual(result.deletedIDs, [normal.id])
        XCTAssertEqual(result.protectedIDs, [locked.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.fileURL(for: normal).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.fileURL(for: locked).path))
        XCTAssertEqual(controller.segments.map(\.id), [locked.id])
    }

    func testDeleteFailureLeavesSegmentVisibleAndReportedAsFailed() throws {
        let normal = try seedSegment(sequence: 0)
        try FileManager.default.removeItem(at: controller.fileURL(for: normal))

        let result = controller.deleteSegment(normal)

        XCTAssertEqual(result.failedIDs, [normal.id])
        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(controller.segments.map(\.id), [normal.id])
    }

    func testManifestSaveFailureDoesNotReportDeletedSuccess() throws {
        let normal = try seedSegment(sequence: 0)
        let store = RecordingStore(directoryURL: directory)
        controller = DashcamRecordingController(
            capture: capture,
            permissions: AllowedDashcamPermissions(),
            store: store,
            manifestWriter: { _ in throw ManifestWriteTestError.failed },
            capacityBytes: { 1_000_000_000 })

        let result = controller.deleteSegment(normal)

        XCTAssertEqual(result.deletedCount, 0)
        XCTAssertEqual(result.failedIDs, [normal.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.fileURL(for: normal).path))
        XCTAssertEqual(controller.segments.map(\.id), [normal.id])
        XCTAssertEqual(store.load().manifest.segments.map(\.id), [normal.id])
        XCTAssertEqual(controller.alertText, "录像清单保存失败，删除操作已撤销")
    }

    func testLaunchRestoresStagedDeletionWhenManifestStillContainsSegment() throws {
        let normal = try seedSegment(sequence: 0)
        let store = RecordingStore(directoryURL: directory)
        let stagedURL = try store.stageDeletion(normal)

        controller = DashcamRecordingController(
            capture: capture,
            permissions: AllowedDashcamPermissions(),
            store: store,
            capacityBytes: { 1_000_000_000 })

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.fileURL(for: normal).path))
        XCTAssertEqual(controller.segments.map(\.id), [normal.id])
    }

    func testLaunchFinalizesStagedDeletionWhenManifestNoLongerContainsSegment() throws {
        let normal = try seedSegment(sequence: 0)
        let store = RecordingStore(directoryURL: directory)
        let stagedURL = try store.stageDeletion(normal)
        try store.save(.empty)

        controller = DashcamRecordingController(
            capture: capture,
            permissions: AllowedDashcamPermissions(),
            store: store,
            capacityBytes: { 1_000_000_000 })

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.fileURL(for: normal).path))
        XCTAssertTrue(controller.segments.isEmpty)
    }

    func testManualLockAndUnlockPersistToManifest() throws {
        let normal = try seedSegment(sequence: 0)

        XCTAssertEqual(controller.lockSegments(ids: [normal.id]).changedIDs, [normal.id])
        XCTAssertEqual(controller.segments.first?.kind, .locked)

        XCTAssertEqual(controller.unlockSegments(ids: [normal.id]).changedIDs, [normal.id])
        XCTAssertEqual(controller.segments.first?.kind, .normal)
        XCTAssertEqual(RecordingStore(directoryURL: directory).load().manifest.segments.first?.kind, .normal)
    }

    func testLockStateRollsBackWhenManifestSaveFails() throws {
        let normal = try seedSegment(sequence: 0)
        let store = RecordingStore(directoryURL: directory)
        controller = DashcamRecordingController(
            capture: capture,
            permissions: AllowedDashcamPermissions(),
            store: store,
            manifestWriter: { _ in throw ManifestWriteTestError.failed },
            capacityBytes: { 1_000_000_000 })

        let result = controller.lockSegments(ids: [normal.id])

        XCTAssertEqual(result.changedCount, 0)
        XCTAssertEqual(result.failedIDs, [normal.id])
        XCTAssertEqual(controller.segments.first?.kind, .normal)
        XCTAssertEqual(store.load().manifest.segments.first?.kind, .normal)
    }

    func testBatchPhotoExportKeepsSourceFiles() async throws {
        let normal = try seedSegment(sequence: 0)
        let locked = try seedSegment(sequence: 1, kind: .locked)
        let exportService = MockRecordingExportService()
        controller = DashcamRecordingController(
            capture: capture,
            permissions: AllowedDashcamPermissions(),
            store: RecordingStore(directoryURL: directory),
            exportService: exportService,
            capacityBytes: { 1_000_000_000 })

        controller.exportToPhotos([normal, locked])
        for _ in 0..<100 where exportService.exportedURLs.count != 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(exportService.exportedURLs.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.fileURL(for: normal).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.fileURL(for: locked).path))
    }

    @discardableResult
    private func seedSegment(
        sequence: Int,
        kind: RecordingSegmentKind = .normal
    ) throws -> RecordingSegment {
        let startedAt = Date(timeIntervalSinceReferenceDate: TimeInterval(sequence))
        let segment = RecordingSegment(
            sessionID: UUID(),
            sequence: sequence,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(10),
            durationSeconds: 10,
            byteCount: 3,
            fileName: "seed-\(sequence).mov",
            kind: kind
        )
        let store = RecordingStore(directoryURL: directory)
        let url = store.finalURL(fileName: segment.fileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: url)
        var manifest = store.load().manifest
        manifest.segments.append(segment)
        try store.save(manifest)
        controller = DashcamRecordingController(
            capture: capture,
            permissions: AllowedDashcamPermissions(),
            store: store,
            capacityBytes: { 1_000_000_000 })
        return segment
    }
}

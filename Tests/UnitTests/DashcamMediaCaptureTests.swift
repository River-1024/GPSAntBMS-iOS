import AVFoundation
import UIKit
import XCTest
@testable import GPSAntBMS

private final class MockApplicationAudioSession: ApplicationAudioSessionConfiguring {
    private(set) var activeValues: [Bool] = []
    private(set) var category: AVAudioSession.Category?
    private(set) var mode: AVAudioSession.Mode?
    private(set) var options: AVAudioSession.CategoryOptions = []

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        self.category = category
        self.mode = mode
        self.options = options
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        activeValues.append(active)
    }
}

final class DashcamMediaCaptureTests: XCTestCase {
    func testAudioSessionPolicyMixesWithExistingPlayback() {
        XCTAssertEqual(DashcamAudioSessionPolicy.category, .playAndRecord)
        XCTAssertEqual(DashcamAudioSessionPolicy.mode, .videoRecording)
        XCTAssertTrue(DashcamAudioSessionPolicy.options.contains(.mixWithOthers))
        XCTAssertFalse(DashcamAudioSessionPolicy.options.contains(.duckOthers))
    }

    func testLegacyCaptureSessionUsesApplicationManagedAudioSession() {
        let session = AVCaptureSession()

        DashcamCaptureAudioSessionPolicy.configure(session, strategy: .applicationManaged)

        XCTAssertTrue(session.usesApplicationAudioSession)
        XCTAssertFalse(session.automaticallyConfiguresApplicationAudioSession)
    }

    func testModernCaptureSessionAllowsMixingWithOtherAudio() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("需要 iOS 18 或更高版本") }
        let session = AVCaptureSession()

        DashcamCaptureAudioSessionPolicy.configure(session, strategy: .automaticMixing)

        XCTAssertTrue(session.usesApplicationAudioSession)
        XCTAssertTrue(session.automaticallyConfiguresApplicationAudioSession)
        XCTAssertTrue(session.configuresApplicationAudioSessionToMixWithOthers)
    }

    func testCaptureAudioStrategySupportsLegacyAndModernSystems() {
        XCTAssertEqual(
            DashcamCaptureAudioSessionPolicy.strategy(supportsAutomaticMixing: false),
            .applicationManaged)
        XCTAssertEqual(
            DashcamCaptureAudioSessionPolicy.strategy(supportsAutomaticMixing: true),
            .automaticMixing)
    }

    func testLateDashcamDeactivationDoesNotStopBackgroundKeepAliveAudio() throws {
        let session = MockApplicationAudioSession()
        let coordinator = ApplicationAudioSessionCoordinator(audioSession: session)

        try coordinator.activateDashcam()
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertEqual(session.mode, .videoRecording)
        XCTAssertTrue(session.options.contains(.mixWithOthers))
        XCTAssertFalse(session.options.contains(.duckOthers))

        try coordinator.activateBackgroundKeepAlive()
        coordinator.deactivateDashcam()

        XCTAssertEqual(session.activeValues, [true, true])

        coordinator.deactivateBackgroundKeepAlive()
        XCTAssertEqual(session.activeValues, [true, true, false])
    }

    func testLateBackgroundDeactivationDoesNotStopDashcamAudio() throws {
        let session = MockApplicationAudioSession()
        let coordinator = ApplicationAudioSessionCoordinator(audioSession: session)

        try coordinator.activateBackgroundKeepAlive()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .default)
        XCTAssertTrue(session.options.contains(.mixWithOthers))

        try coordinator.activateDashcam()
        coordinator.deactivateBackgroundKeepAlive()

        XCTAssertEqual(session.activeValues, [true, true])

        coordinator.deactivateDashcam()
        XCTAssertEqual(session.activeValues, [true, true, false])
    }

    func testPreviewModeRejectsSamplesUntilRecordingIsRequested() {
        XCTAssertFalse(DashcamCaptureMode.preview.acceptsSamples)
        XCTAssertTrue(DashcamCaptureMode.recording.acceptsSamples)
        XCTAssertFalse(DashcamCaptureMode.stopping.acceptsSamples)
    }

    func testInterfaceOrientationMapsToCaptureOrientation() {
        XCTAssertEqual(
            DashcamVideoOrientation(interfaceOrientation: .portrait).captureOrientation,
            .portrait)
        XCTAssertEqual(
            DashcamVideoOrientation(interfaceOrientation: .landscapeLeft).captureOrientation,
            .landscapeLeft)
        XCTAssertEqual(
            DashcamVideoOrientation(interfaceOrientation: .landscapeRight).captureOrientation,
            .landscapeRight)
    }

    func testWriterTransformMatchesPortraitAndLandscapePlayback() {
        assertTransform(
            DashcamVideoOrientation.portrait.writerTransform,
            equals: CGAffineTransform(rotationAngle: .pi / 2))
        assertTransform(
            DashcamVideoOrientation.portraitUpsideDown.writerTransform,
            equals: CGAffineTransform(rotationAngle: -.pi / 2))
        assertTransform(
            DashcamVideoOrientation.landscapeLeft.writerTransform,
            equals: CGAffineTransform(rotationAngle: .pi))
        assertTransform(DashcamVideoOrientation.landscapeRight.writerTransform, equals: .identity)
    }

    private func assertTransform(
        _ actual: CGAffineTransform,
        equals expected: CGAffineTransform,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.a, expected.a, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.b, expected.b, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.c, expected.c, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.d, expected.d, accuracy: 0.0001, file: file, line: line)
    }
}

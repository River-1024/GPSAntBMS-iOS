import AVFoundation
import UIKit
import XCTest
@testable import GPSAntBMS

final class DashcamMediaCaptureTests: XCTestCase {
    func testAudioSessionPolicyMixesWithExistingPlayback() {
        XCTAssertEqual(DashcamAudioSessionPolicy.category, .playAndRecord)
        XCTAssertEqual(DashcamAudioSessionPolicy.mode, .videoRecording)
        XCTAssertTrue(DashcamAudioSessionPolicy.options.contains(.mixWithOthers))
        XCTAssertFalse(DashcamAudioSessionPolicy.options.contains(.duckOthers))
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

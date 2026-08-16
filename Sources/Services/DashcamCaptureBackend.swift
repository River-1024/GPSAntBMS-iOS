import AVFoundation
import Foundation

struct DashcamCompletedSegment {
    let sessionID: UUID
    let sequence: Int
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: TimeInterval
    let temporaryURL: URL
}

enum DashcamCaptureEvent {
    case recordingStarted(Date, sequence: Int)
    case segmentCompleted(DashcamCompletedSegment)
    case stopped
    case interrupted(String)
    case interruptionEnded
    case failed(RecordingFailure)
}

protocol DashcamCaptureBackend: AnyObject {
    var captureSession: AVCaptureSession { get }
    var eventHandler: ((DashcamCaptureEvent) -> Void)? { get set }
    func prepare(completion: @escaping (Result<Void, RecordingFailure>) -> Void)
    func startRecording(sessionID: UUID, firstSequence: Int,
                        temporaryURL: @escaping (Int) -> URL)
    func stopRecording(reason: String?)
    func stopSession()
    func shutdown()
}

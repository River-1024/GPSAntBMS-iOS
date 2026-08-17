import AVFoundation
import Foundation
import UIKit

enum DashcamCaptureMode: Equatable {
    case preview
    case recording
    case stopping

    var acceptsSamples: Bool { self == .recording }
}

enum DashcamAudioSessionPolicy {
    static let category: AVAudioSession.Category = .playAndRecord
    static let mode: AVAudioSession.Mode = .videoRecording
    static let options: AVAudioSession.CategoryOptions = [.mixWithOthers]
}

enum DashcamVideoOrientation: Equatable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    init(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: self = .portrait
        }
    }

    static func currentInterfaceOrientation() -> DashcamVideoOrientation {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .map(\.interfaceOrientation)
            .first { $0 != .unknown } ?? .portrait
        return DashcamVideoOrientation(interfaceOrientation: orientation)
    }

    var captureOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        }
    }

    var writerTransform: CGAffineTransform {
        switch self {
        case .portrait: return CGAffineTransform(rotationAngle: .pi / 2)
        case .portraitUpsideDown: return CGAffineTransform(rotationAngle: -.pi / 2)
        case .landscapeLeft: return CGAffineTransform(rotationAngle: .pi)
        case .landscapeRight: return .identity
        }
    }
}

final class DashcamMediaCapture: NSObject, DashcamCaptureBackend {
    let captureSession = AVCaptureSession()
    var eventHandler: ((DashcamCaptureEvent) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.zjsf.gpsantbms.dashcam.session")
    private let writerQueue = DispatchQueue(label: "com.zjsf.gpsantbms.dashcam.writer")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var writerStartPTS: CMTime?
    private var currentStartedAt: Date?
    private var currentSessionID: UUID?
    private var currentSequence = 0
    private var temporaryURLProvider: ((Int) -> URL)?
    private var captureMode: DashcamCaptureMode = .preview
    private var hasConfirmedAudioForSession = false
    private var audioConfirmationWorkItem: DispatchWorkItem?
    private var requestedOrientation: DashcamVideoOrientation = .portrait
    private var activeWriterOrientation: DashcamVideoOrientation?
    private var configured = false
    private let segmentDuration = CMTime(seconds: 180, preferredTimescale: 600)
    private var observers: [NSObjectProtocol] = []
    private let audioSessionCoordinator: ApplicationAudioSessionCoordinating

    init(audioSessionCoordinator: ApplicationAudioSessionCoordinating = ApplicationAudioSessionCoordinator()) {
        self.audioSessionCoordinator = audioSessionCoordinator
        super.init()
        audioSessionCoordinator.configureCaptureSession(captureSession)
        videoOutput.setSampleBufferDelegate(self, queue: writerQueue)
        audioOutput.setSampleBufferDelegate(self, queue: writerQueue)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        registerNotifications()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    func prepare(completion: @escaping (Result<Void, RecordingFailure>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.configured {
                do {
                    try self.audioSessionCoordinator.activateDashcam()
                } catch {
                    DispatchQueue.main.async { completion(.failure(.microphoneUnavailable)) }
                    return
                }
                if !self.captureSession.isRunning { self.captureSession.startRunning() }
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            do {
                try self.configureSession()
                self.captureSession.startRunning()
                self.configured = true
                DispatchQueue.main.async { completion(.success(())) }
            } catch let failure as RecordingFailure {
                DispatchQueue.main.async { completion(.failure(failure)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(.cameraUnavailable)) }
            }
        }
    }

    func startRecording(sessionID: UUID, firstSequence: Int,
                        temporaryURL: @escaping (Int) -> URL) {
        let orientation = DashcamVideoOrientation.currentInterfaceOrientation()
        writerQueue.async { [weak self] in
            guard let self, self.writer == nil else { return }
            self.currentSessionID = sessionID
            self.currentSequence = firstSequence
            self.temporaryURLProvider = temporaryURL
            self.requestedOrientation = orientation
            self.captureMode = .recording
            self.hasConfirmedAudioForSession = false
        }
    }

    func stopRecording(reason: String?) {
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.captureMode = .stopping
            self.finishCurrentSegment(reason: reason, startNext: false)
        }
    }

    func shutdown() {
        stopRecording(reason: "应用进入后台")
        stopSession()
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning { self.captureSession.stopRunning() }
            self.audioSessionCoordinator.deactivateDashcam()
        }
    }

    private func configureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .hd1920x1080

        try audioSessionCoordinator.activateDashcam()

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw RecordingFailure.cameraUnavailable }
        try configureFormat(camera)
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(cameraInput) else { throw RecordingFailure.unsupportedFormat }
        captureSession.addInput(cameraInput)

        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw RecordingFailure.microphoneUnavailable
        }
        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
        guard captureSession.canAddInput(microphoneInput) else { throw RecordingFailure.microphoneUnavailable }
        captureSession.addInput(microphoneInput)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        guard captureSession.canAddOutput(videoOutput), captureSession.canAddOutput(audioOutput) else {
            throw RecordingFailure.unsupportedFormat
        }
        captureSession.addOutput(videoOutput)
        captureSession.addOutput(audioOutput)
        if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
    }

    private func configureFormat(_ device: AVCaptureDevice) throws {
        guard let selectedFormat = device.formats.first(where: { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == 1920 && dimensions.height == 1080
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }) else { throw RecordingFailure.unsupportedFormat }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = selectedFormat
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
    }

    private func append(_ sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) {
        guard captureMode.acceptsSamples else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil {
            guard mediaType == .video else { return }
            do { try beginWriter(at: pts) }
            catch { failWriter(error) ; return }
        }
        guard let start = writerStartPTS else { return }
        if mediaType == .video, CMTimeSubtract(pts, start) >= segmentDuration {
            finishCurrentSegment(reason: nil, startNext: true)
            do { try beginWriter(at: pts) }
            catch { failWriter(error); return }
        }
        let input = mediaType == .video ? videoInput : audioInput
        guard let input, input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer) {
            failWriter(writer?.error)
        } else if mediaType == .audio, !hasConfirmedAudioForSession {
            hasConfirmedAudioForSession = true
            audioConfirmationWorkItem?.cancel()
            let sequence = currentSequence
            DispatchQueue.main.async { [weak self] in
                self?.eventHandler?(.recordingStarted(Date(), sequence: sequence))
            }
        }
    }

    private func beginWriter(at pts: CMTime) throws {
        guard let temporaryURLProvider else { throw RecordingFailure.storageUnavailable }
        let url = temporaryURLProvider(currentSequence)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ]
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        videoInput.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true
        videoInput.transform = requestedOrientation.writerTransform
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw RecordingFailure.unsupportedFormat }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { throw writer.error ?? RecordingFailure.storageUnavailable }
        writer.startSession(atSourceTime: pts)
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        writerStartPTS = pts
        currentStartedAt = Date()
        activeWriterOrientation = requestedOrientation
        if !hasConfirmedAudioForSession {
            audioConfirmationWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak writer] in
                guard let self, let writer, self.writer === writer,
                      !self.hasConfirmedAudioForSession else { return }
                self.failWriter(RecordingFailure.microphoneUnavailable)
            }
            audioConfirmationWorkItem = workItem
            writerQueue.asyncAfter(deadline: .now() + 3, execute: workItem)
        }
    }

    private func finishCurrentSegment(reason: String?, startNext: Bool) {
        guard let writer, let sessionID = currentSessionID,
              let startedAt = currentStartedAt else {
            clearWriter()
            DispatchQueue.main.async { [weak self] in
                if let reason {
                    self?.eventHandler?(.interrupted(reason))
                } else {
                    self?.eventHandler?(.stopped)
                }
            }
            return
        }
        let url = writer.outputURL
        let sequence = currentSequence
        let duration = max(0, Date().timeIntervalSince(startedAt))
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        clearWriter()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            if writer.status == .completed {
                let completed = DashcamCompletedSegment(sessionID: sessionID, sequence: sequence,
                    startedAt: startedAt, endedAt: Date(), durationSeconds: duration, temporaryURL: url)
                DispatchQueue.main.async {
                    self.eventHandler?(.segmentCompleted(completed))
                    if !startNext && reason == nil { self.eventHandler?(.stopped) }
                }
            } else {
                self.writerQueue.async {
                    self.failWriter(writer.error)
                }
            }
        }
        if startNext { currentSequence += 1 }
        if let reason {
            DispatchQueue.main.async { [weak self] in self?.eventHandler?(.interrupted(reason)) }
        }
    }

    private func clearWriter() {
        writer = nil
        videoInput = nil
        audioInput = nil
        writerStartPTS = nil
        currentStartedAt = nil
        activeWriterOrientation = nil
    }

    private func failWriter(_ error: Error?) {
        captureMode = .stopping
        audioConfirmationWorkItem?.cancel()
        writer?.cancelWriting()
        clearWriter()
        let failure = (error as? RecordingFailure)
            ?? .writerFailed(error?.localizedDescription ?? "未知写入错误")
        DispatchQueue.main.async { [weak self] in self?.eventHandler?(.failed(failure)) }
    }

    private func registerNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: captureSession, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)
                .flatMap { AVCaptureSession.InterruptionReason(rawValue: $0.intValue) }
            self?.stopRecording(reason: reason == .videoDeviceNotAvailableInBackground ? "应用进入后台" : "摄像头被系统占用")
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: captureSession, queue: .main) { [weak self] _ in
            self?.eventHandler?(.interruptionEnded)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: captureSession, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.eventHandler?(.failed(.writerFailed(error?.localizedDescription ?? "摄像头运行错误")))
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType.uintValue) else { return }
            switch type {
            case .began:
                self?.stopRecording(reason: "音频被电话或系统功能占用")
            case .ended:
                self?.eventHandler?(.interruptionEnded)
            @unknown default:
                break
            }
        })
        observers.append(center.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            let orientation = DashcamVideoOrientation.currentInterfaceOrientation()
            self?.writerQueue.async { self?.handleOrientationChange(orientation) }
        })
    }

    private func handleOrientationChange(_ orientation: DashcamVideoOrientation) {
        guard orientation != requestedOrientation else { return }
        requestedOrientation = orientation
        guard captureMode.acceptsSamples, writer != nil,
              activeWriterOrientation != orientation else { return }
        finishCurrentSegment(reason: nil, startNext: true)
    }
}

extension DashcamMediaCapture: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        append(sampleBuffer, mediaType: output === videoOutput ? .video : .audio)
    }
}

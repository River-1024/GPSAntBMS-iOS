import AVFoundation
import Foundation

enum DashcamCaptureAudioSessionStrategy: Equatable {
    case automaticMixing
    case applicationManaged
}

enum DashcamCaptureAudioSessionPolicy {
    static func strategy(supportsAutomaticMixing: Bool) -> DashcamCaptureAudioSessionStrategy {
        supportsAutomaticMixing ? .automaticMixing : .applicationManaged
    }

    static func configure(_ captureSession: AVCaptureSession) {
        let selectedStrategy: DashcamCaptureAudioSessionStrategy
        if #available(iOS 18.0, *) {
            selectedStrategy = strategy(supportsAutomaticMixing: true)
        } else {
            selectedStrategy = strategy(supportsAutomaticMixing: false)
        }
        configure(captureSession, strategy: selectedStrategy)
    }

    static func configure(
        _ captureSession: AVCaptureSession,
        strategy: DashcamCaptureAudioSessionStrategy
    ) {
        captureSession.usesApplicationAudioSession = true
        switch strategy {
        case .automaticMixing:
            captureSession.automaticallyConfiguresApplicationAudioSession = true
            if #available(iOS 18.0, *) {
                captureSession.configuresApplicationAudioSessionToMixWithOthers = true
            }
        case .applicationManaged:
            captureSession.automaticallyConfiguresApplicationAudioSession = false
        }
    }
}

protocol ApplicationAudioSessionCoordinating: AnyObject {
    func configureCaptureSession(_ captureSession: AVCaptureSession)
    func activateDashcam() throws
    func deactivateDashcam()
    func activateBackgroundKeepAlive() throws
    func deactivateBackgroundKeepAlive()
}

protocol ApplicationAudioSessionConfiguring: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: ApplicationAudioSessionConfiguring {}

final class ApplicationAudioSessionCoordinator: ApplicationAudioSessionCoordinating {
    private enum Owner: Equatable {
        case dashcam
        case backgroundKeepAlive
    }

    private let audioSession: ApplicationAudioSessionConfiguring
    private let lock = NSLock()
    private var owner: Owner?

    init(audioSession: ApplicationAudioSessionConfiguring = AVAudioSession.sharedInstance()) {
        self.audioSession = audioSession
    }

    func configureCaptureSession(_ captureSession: AVCaptureSession) {
        DashcamCaptureAudioSessionPolicy.configure(captureSession)
    }

    func activateDashcam() throws {
        try activate(
            owner: .dashcam,
            category: DashcamAudioSessionPolicy.category,
            mode: DashcamAudioSessionPolicy.mode,
            options: DashcamAudioSessionPolicy.options)
    }

    func deactivateDashcam() {
        deactivate(owner: .dashcam)
    }

    func activateBackgroundKeepAlive() throws {
        try activate(
            owner: .backgroundKeepAlive,
            category: .playback,
            mode: .default,
            options: [.mixWithOthers])
    }

    func deactivateBackgroundKeepAlive() {
        deactivate(owner: .backgroundKeepAlive)
    }

    private func activate(
        owner newOwner: Owner,
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try audioSession.setCategory(
                category,
                mode: mode,
                options: options)
            try audioSession.setActive(true, options: [])
            owner = newOwner
        } catch {
            owner = nil
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    private func deactivate(owner expectedOwner: Owner) {
        lock.lock()
        defer { lock.unlock() }
        guard owner == expectedOwner else { return }
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        owner = nil
    }
}

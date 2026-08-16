import AVFoundation
import Foundation

/// 个人设备的后台行程保活音频源：播放零样本缓冲区，不抢占外部音乐。
///
/// 仅在用户显式开启后台行程且正在记录时由 App 生命周期启动；它不承担播放功能，
/// 也不会在前台或停止行程后继续运行。
final class BackgroundKeepAliveService {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isConfigured = false
    private var isRunning = false
    private var wantsToRun = false

    func start() {
        wantsToRun = true
        guard !isRunning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.startWhenCaptureSessionHasReleasedAudio()
        }
    }

    func stop() {
        wantsToRun = false
        guard isRunning || engine.isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startWhenCaptureSessionHasReleasedAudio() {
        guard wantsToRun, !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            configureEngineIfNeeded()
            try engine.start()
            player.play()
            isRunning = true
        } catch {
            stop()
        }
    }

    private func configureEngineIfNeeded() {
        guard !isConfigured else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = buffer.frameCapacity
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        isConfigured = true
    }
}

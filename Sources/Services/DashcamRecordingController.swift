import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class DashcamRecordingController: ObservableObject {
    @Published private(set) var state: DashcamRecordingState = .idle
    @Published private(set) var segments: [RecordingSegment] = []
    @Published private(set) var sessionDurationSeconds: TimeInterval = 0
    @Published private(set) var alertText: String?
    @Published var isPreviewPresented = false

    var captureSession: AVCaptureSession { capture.captureSession }
    var isRecording: Bool { state.isRecording }
    var shouldOfferSettings: Bool {
        guard case .failed(let failure) = state else { return false }
        return failure == .cameraPermissionDenied
            || failure == .microphonePermissionDenied
            || failure == .photoPermissionDenied
    }

    private let capture: DashcamCaptureBackend
    private let permissions: DashcamPermissionProviding
    private let store: RecordingStore
    private let exportService: RecordingExportService
    private let capacityBytes: () -> Int64
    private let log: ((SoftwareLogLevel, String) -> Void)?
    private var manifest: RecordingManifest
    private var lockPolicy = RecordingLockPolicy()
    private var sessionID: UUID?
    private var currentSequence = -1
    private var recordingStartedAt: Date?
    private var wantsRecording = false
    private var applicationIsActive = true
    private var timer: AnyCancellable?
    private var thermalObserver: NSObjectProtocol?

    init(capture: DashcamCaptureBackend = DashcamMediaCapture(),
         permissions: DashcamPermissionProviding = SystemDashcamPermissionProvider(),
         store: RecordingStore = RecordingStore(),
         exportService: RecordingExportService = RecordingExportService(),
         capacityBytes: @escaping () -> Int64 = { RecordingCapacityLimit.defaultValue.byteCount },
         log: ((SoftwareLogLevel, String) -> Void)? = nil) {
        self.capture = capture
        self.permissions = permissions
        self.store = store
        self.exportService = exportService
        self.capacityBytes = capacityBytes
        self.log = log
        let result = store.load()
        let recovered = (try? store.reconcile(result.manifest)) ?? result.manifest
        manifest = recovered
        segments = recovered.segments.sorted { $0.startedAt > $1.startedAt }
        capture.eventHandler = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        if result.failedToDecode {
            alertText = "录像清单已从本地文件恢复"
            try? store.save(recovered)
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleThermalState() } }
    }

    deinit {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    func openCalibration() {
        guard !isRecording else { isPreviewPresented = true; return }
        state = .authorizing
        permissions.requestCapturePermissions { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let failure): self.fail(failure)
                case .success:
                    self.capture.prepare { prepareResult in
                        Task { @MainActor in
                            switch prepareResult {
                            case .success:
                                self.state = .preview
                                self.isPreviewPresented = true
                            case .failure(let failure): self.fail(failure)
                            }
                        }
                    }
                }
            }
        }
    }

    func confirmStart() {
        guard case .preview = state else { return }
        guard ProcessInfo.processInfo.thermalState != .critical else { fail(.thermalCritical); return }
        let estimatedSegmentBytes: Int64 = 190_000_000
        guard reclaimSpace(requiredBytes: estimatedSegmentBytes) else { return }
        let id = UUID()
        sessionID = id
        lockPolicy = RecordingLockPolicy()
        currentSequence = -1
        wantsRecording = true
        state = .starting
        isPreviewPresented = false
        UIApplication.shared.isIdleTimerDisabled = true
        capture.startRecording(sessionID: id, firstSequence: nextSequence) { [store] sequence in
            store.temporaryURL(sessionID: id, sequence: sequence)
        }
    }

    func stop() {
        wantsRecording = false
        guard isRecording || state == .starting || isInterrupted else { return }
        state = .finalizing
        capture.stopRecording(reason: nil)
    }

    func cancelCalibration() {
        guard !isRecording else { isPreviewPresented = false; return }
        isPreviewPresented = false
        state = .idle
        capture.stopSession()
    }

    func lockEvidence() {
        guard isRecording else { return }
        let current = max(0, currentSequence)
        lockPolicy.requestLock(currentSequence: current,
                               previousSequence: current > 0 ? current - 1 : nil)
        applyLocksToCompletedSegments()
        persistManifest()
    }

    func deleteSegment(_ segment: RecordingSegment) {
        do {
            try store.delete(segment)
            manifest.segments.removeAll { $0.id == segment.id }
            persistManifest()
        } catch {
            alertText = "录像删除失败"
        }
    }

    func fileURL(for segment: RecordingSegment) -> URL {
        store.finalURL(fileName: segment.fileName)
    }

    func exportToPhotos(_ segment: RecordingSegment) {
        permissions.requestPhotoAddPermission { [weak self] allowed in
            guard let self else { return }
            guard allowed else { self.alertText = RecordingFailure.photoPermissionDenied.displayText; return }
            self.exportService.exportVideo(at: self.fileURL(for: segment)) { result in
                switch result {
                case .success: self.alertText = "录像已导出到系统照片"
                case .failure: self.alertText = "录像导出失败"
                }
            }
        }
    }

    func clearAlert() { alertText = nil }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func enforceCapacityLimit() {
        _ = reclaimSpace(requiredBytes: 0)
    }

    func applicationDidBecomeActive() {
        applicationIsActive = true
        guard wantsRecording, case .interrupted = state else { return }
        capture.prepare { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    guard let sessionID = self.sessionID else { return }
                    self.state = .starting
                    let resumeSequence = max(self.nextSequence, self.currentSequence + 1)
                    self.capture.startRecording(sessionID: sessionID, firstSequence: resumeSequence) { [store = self.store] sequence in
                        store.temporaryURL(sessionID: sessionID, sequence: sequence)
                    }
                case .failure(let failure): self.fail(failure)
                }
            }
        }
    }

    func applicationWillResignActive() {
        applicationIsActive = false
        guard wantsRecording else { return }
        state = .interrupted(reason: "应用已离开前台")
        capture.shutdown()
        stopTimer()
    }

    private var nextSequence: Int {
        guard let sessionID else { return 0 }
        return (manifest.segments.filter { $0.sessionID == sessionID }.map(\.sequence).max() ?? -1) + 1
    }

    private var isInterrupted: Bool {
        if case .interrupted = state { return true }
        return false
    }

    private func handle(_ event: DashcamCaptureEvent) {
        switch event {
        case .recordingStarted(let date, let sequence):
            if recordingStartedAt == nil { recordingStartedAt = date }
            currentSequence = sequence
            state = .recording(startedAt: recordingStartedAt ?? date)
            startTimer()
            log?(.info, "录像开始")
        case .segmentCompleted(let completed):
            commit(completed)
        case .stopped:
            if case .finalizing = state { finishSession() }
        case .interrupted(let reason):
            state = .interrupted(reason: reason)
            stopTimer()
            log?(.warning, "录像中断：\(reason)")
        case .interruptionEnded:
            if applicationIsActive { applicationDidBecomeActive() }
        case .failed(let failure):
            fail(failure)
        }
    }

    private func commit(_ completed: DashcamCompletedSegment) {
        let fileName = "\(completed.sessionID.uuidString)-\(completed.sequence)-\(Int(completed.startedAt.timeIntervalSince1970)).mov"
        do {
            let finalURL = try store.commitTemporaryFile(at: completed.temporaryURL, fileName: fileName)
            let locked = lockPolicy.segmentCompleted(sequence: completed.sequence)
            let segment = RecordingSegment(sessionID: completed.sessionID, sequence: completed.sequence,
                startedAt: completed.startedAt, endedAt: completed.endedAt,
                durationSeconds: completed.durationSeconds, byteCount: try store.byteCount(for: finalURL),
                fileName: fileName, kind: locked ? .locked : .normal)
            manifest.segments.append(segment)
            guard persistManifest() else {
                fail(.storageUnavailable)
                return
            }
            _ = reclaimSpace(requiredBytes: 0)
        } catch {
            fail(.writerFailed(error.localizedDescription))
        }
    }

    private func reclaimSpace(requiredBytes: Int64) -> Bool {
        let protectedIDs: Set<UUID>
        if wantsRecording, let sessionID,
           let latest = manifest.segments
            .filter({ $0.sessionID == sessionID })
            .max(by: { $0.sequence < $1.sequence }) {
            protectedIDs = [latest.id]
        } else {
            protectedIDs = []
        }
        let decision = RecordingQuotaPolicy.decision(
            segments: manifest.segments, capacityBytes: capacityBytes(),
            requiredBytes: requiredBytes, protectedSegmentIDs: protectedIDs)
        if let available = store.availableCapacityForRecording(), available < requiredBytes {
            fail(.storageUnavailable)
            return false
        }
        for id in decision.segmentIDsToDelete {
            guard let segment = manifest.segments.first(where: { $0.id == id }) else { continue }
            do {
                try store.delete(segment)
                manifest.segments.removeAll { $0.id == id }
                guard persistManifest() else {
                    if wantsRecording { fail(.storageUnavailable) }
                    return false
                }
            } catch {
                if wantsRecording { fail(.storageUnavailable) }
                else { alertText = "旧录像删除失败" }
                return false
            }
        }
        guard decision.canAllocate else {
            fail(decision.lockedBytes >= capacityBytes() ? .lockedContentFillsCapacity : .storageUnavailable)
            return false
        }
        return true
    }

    private func applyLocksToCompletedSegments() {
        for index in manifest.segments.indices
        where manifest.segments[index].sessionID == sessionID
            && lockPolicy.shouldLock(sequence: manifest.segments[index].sequence) {
            manifest.segments[index].kind = .locked
        }
    }

    @discardableResult
    private func persistManifest() -> Bool {
        do {
            try store.save(manifest)
            segments = manifest.segments.sorted { $0.startedAt > $1.startedAt }
            return true
        } catch {
            alertText = "录像清单保存失败"
            return false
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, let start = self.recordingStartedAt else { return }
            self.sessionDurationSeconds = Date().timeIntervalSince(start)
        }
    }

    private func stopTimer() { timer?.cancel(); timer = nil }

    private func finishSession() {
        stopTimer()
        capture.stopSession()
        state = .idle
        recordingStartedAt = nil
        sessionID = nil
        currentSequence = -1
        UIApplication.shared.isIdleTimerDisabled = false
        log?(.info, "录像停止")
    }

    private func fail(_ failure: RecordingFailure) {
        let shouldStopCapture = isRecording || state == .starting || isInterrupted || state == .finalizing
        wantsRecording = false
        stopTimer()
        state = .failed(failure)
        alertText = failure.displayText
        UIApplication.shared.isIdleTimerDisabled = false
        if shouldStopCapture { capture.stopRecording(reason: nil) }
        capture.stopSession()
        log?(.error, failure.displayText)
    }

    private func handleThermalState() {
        if ProcessInfo.processInfo.thermalState == .critical {
            fail(.thermalCritical)
        } else if ProcessInfo.processInfo.thermalState == .serious {
            alertText = "设备温度较高，请注意散热"
        }
    }
}

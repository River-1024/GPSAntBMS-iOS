import AVFoundation
import Foundation
import Photos

protocol DashcamPermissionProviding {
    func requestCapturePermissions(completion: @escaping (Result<Void, RecordingFailure>) -> Void)
    func requestPhotoAddPermission(completion: @escaping (Bool) -> Void)
}

struct SystemDashcamPermissionProvider: DashcamPermissionProviding {
    func requestCapturePermissions(completion: @escaping (Result<Void, RecordingFailure>) -> Void) {
        request(.video, denied: .cameraPermissionDenied) { videoResult in
            switch videoResult {
            case .failure: completion(videoResult)
            case .success:
                self.request(.audio, denied: .microphonePermissionDenied, completion: completion)
            }
        }
    }

    func requestPhotoAddPermission(completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async { completion(status == .authorized || status == .limited) }
        }
    }

    private func request(_ mediaType: AVMediaType, denied: RecordingFailure,
                         completion: @escaping (Result<Void, RecordingFailure>) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: completion(.success(()))
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                DispatchQueue.main.async { completion(granted ? .success(()) : .failure(denied)) }
            }
        default: completion(.failure(denied))
        }
    }
}

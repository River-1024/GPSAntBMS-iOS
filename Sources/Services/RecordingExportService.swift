import Foundation
import Photos

final class RecordingExportService {
    func exportVideo(at url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(error ?? RecordingFailure.photoPermissionDenied))
                }
            }
        }
    }
}

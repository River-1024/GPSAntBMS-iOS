import Foundation
import Photos

struct RecordingExportResult: Equatable {
    let exportedCount: Int
    let unreadableCount: Int
    let failedCount: Int

    var completedCount: Int { exportedCount + failedCount }
}

protocol RecordingExporting: AnyObject {
    func exportVideos(at urls: [URL], completion: @escaping (RecordingExportResult) -> Void)
}

final class RecordingExportService: RecordingExporting {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func exportVideo(at url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        exportVideos(at: [url]) { result in
            if result.exportedCount == 1 {
                completion(.success(()))
            } else {
                completion(.failure(RecordingFailure.photoPermissionDenied))
            }
        }
    }

    func exportVideos(at urls: [URL], completion: @escaping (RecordingExportResult) -> Void) {
        let readableURLs = urls.filter { fileManager.isReadableFile(atPath: $0.path) }
        let unreadableCount = urls.count - readableURLs.count
        guard !readableURLs.isEmpty else {
            DispatchQueue.main.async {
                completion(RecordingExportResult(exportedCount: 0,
                                                 unreadableCount: unreadableCount,
                                                 failedCount: 0))
            }
            return
        }
        var acceptedRequestCount = 0
        PHPhotoLibrary.shared().performChanges {
            for url in readableURLs {
                if PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) != nil {
                    acceptedRequestCount += 1
                }
            }
        } completionHandler: { success, _ in
            DispatchQueue.main.async {
                completion(RecordingExportResult(
                    exportedCount: success ? acceptedRequestCount : 0,
                    unreadableCount: unreadableCount,
                    failedCount: success ? readableURLs.count - acceptedRequestCount : readableURLs.count
                ))
            }
        }
    }
}

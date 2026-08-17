import Foundation

final class RecordingStore {
    struct LoadResult: Equatable {
        let manifest: RecordingManifest
        let failedToDecode: Bool
    }

    enum StoreError: Error {
        case applicationSupportUnavailable
        case segmentMissing
    }

    private let fileManager: FileManager
    let directoryURL: URL
    let segmentsDirectoryURL: URL
    let inProgressDirectoryURL: URL
    private let manifestURL: URL

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let base = directoryURL ?? support.appendingPathComponent("GPSAntBMS/Recordings", isDirectory: true)
        self.directoryURL = base
        self.segmentsDirectoryURL = base.appendingPathComponent("Segments", isDirectory: true)
        self.inProgressDirectoryURL = base.appendingPathComponent("InProgress", isDirectory: true)
        self.manifestURL = base.appendingPathComponent("recording-manifest.json")
    }

    func load() -> LoadResult {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return LoadResult(manifest: .empty, failedToDecode: false)
        }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(RecordingManifest.self, from: data)
        else {
            return LoadResult(manifest: .empty, failedToDecode: true)
        }
        return LoadResult(manifest: manifest, failedToDecode: false)
    }

    func save(_ manifest: RecordingManifest) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    func reconcile(_ manifest: RecordingManifest) throws -> RecordingManifest {
        try ensureDirectories()
        let existingSegments = manifest.segments.filter {
            fileManager.fileExists(atPath: finalURL(fileName: $0.fileName).path)
        }
        let knownFiles = Set(existingSegments.map(\.fileName))
        let recovered = try fileManager.contentsOfDirectory(
            at: segmentsDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])
            .filter { $0.pathExtension.lowercased() == "mov" && !knownFiles.contains($0.lastPathComponent) }
            .compactMap { url -> RecordingSegment? in
                let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
                guard parts.count >= 7,
                      let sessionID = UUID(uuidString: parts.prefix(5).joined(separator: "-")),
                      let sequence = Int(parts[5]),
                      let timestamp = TimeInterval(parts[6]) else { return nil }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                let start = Date(timeIntervalSince1970: timestamp)
                return RecordingSegment(
                    sessionID: sessionID, sequence: sequence, startedAt: start,
                    endedAt: values?.creationDate ?? start, durationSeconds: 0,
                    byteCount: Int64(values?.fileSize ?? 0), fileName: url.lastPathComponent,
                    kind: .normal)
            }
        return RecordingManifest(segments: existingSegments + recovered)
    }

    func finalURL(fileName: String) -> URL {
        segmentsDirectoryURL.appendingPathComponent(fileName)
    }

    func temporaryURL(sessionID: UUID, sequence: Int) -> URL {
        inProgressDirectoryURL
            .appendingPathComponent("\(sessionID.uuidString)-\(sequence).recording")
    }

    func commitTemporaryFile(at temporaryURL: URL, fileName: String) throws -> URL {
        try ensureDirectories()
        guard fileManager.fileExists(atPath: temporaryURL.path) else { throw StoreError.segmentMissing }
        let destination = finalURL(fileName: fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    func delete(_ segment: RecordingSegment) throws {
        let url = finalURL(fileName: segment.fileName)
        guard fileManager.fileExists(atPath: url.path) else { throw StoreError.segmentMissing }
        try fileManager.removeItem(at: url)
    }

    func stageDeletion(_ segment: RecordingSegment) throws -> URL {
        try ensureDirectories()
        let source = finalURL(fileName: segment.fileName)
        guard fileManager.fileExists(atPath: source.path) else { throw StoreError.segmentMissing }
        let staged = stagedDeletionURL(for: segment)
        if fileManager.fileExists(atPath: staged.path) {
            try fileManager.removeItem(at: staged)
        }
        try fileManager.moveItem(at: source, to: staged)
        return staged
    }

    func finalizeDeletion(at stagedURL: URL) throws {
        guard fileManager.fileExists(atPath: stagedURL.path) else { return }
        try fileManager.removeItem(at: stagedURL)
    }

    func restoreDeletion(at stagedURL: URL, segment: RecordingSegment) throws {
        try ensureDirectories()
        guard fileManager.fileExists(atPath: stagedURL.path) else { throw StoreError.segmentMissing }
        let destination = finalURL(fileName: segment.fileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: stagedURL, to: destination)
    }

    func recoverStagedDeletions(manifest: RecordingManifest) throws {
        try ensureDirectories()
        for segment in manifest.segments {
            let stagedURL = stagedDeletionURL(for: segment)
            if fileManager.fileExists(atPath: stagedURL.path) {
                try restoreDeletion(at: stagedURL, segment: segment)
            }
        }

        for stagedURL in try fileManager.contentsOfDirectory(
            at: inProgressDirectoryURL,
            includingPropertiesForKeys: nil
        ) where stagedURL.lastPathComponent.hasPrefix("deleting-") {
            try finalizeDeletion(at: stagedURL)
        }
    }

    func removeStaleTemporaryFiles() throws {
        try ensureDirectories()
        for url in try fileManager.contentsOfDirectory(at: inProgressDirectoryURL,
                                                       includingPropertiesForKeys: nil) {
            try fileManager.removeItem(at: url)
        }
    }

    func byteCount(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    func availableCapacityForRecording() -> Int64? {
        try? ensureDirectories()
        let values = try? directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: segmentsDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: inProgressDirectoryURL, withIntermediateDirectories: true)
    }

    private func stagedDeletionURL(for segment: RecordingSegment) -> URL {
        inProgressDirectoryURL
            .appendingPathComponent("deleting-\(segment.id.uuidString)-\(segment.fileName)")
    }
}

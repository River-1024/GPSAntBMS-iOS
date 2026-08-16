import Foundation

final class SoftwareLogStore {
    enum LoadFailure: Error, Equatable {
        case unreadable
        case decodingFailed
    }

    struct LoadResult: Equatable {
        let entries: [SoftwareLogEntry]
        let failure: LoadFailure?

        static let empty = LoadResult(entries: [], failure: nil)
    }

    static let defaultMaximumEntries = 400

    private let fileURL: URL
    private let maximumEntries: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        directoryURL: URL,
        fileName: String = "softwareLogs.json",
        maximumEntries: Int = SoftwareLogStore.defaultMaximumEntries
    ) {
        fileURL = directoryURL.appendingPathComponent(fileName)
        self.maximumEntries = max(1, maximumEntries)
    }

    convenience init?(
        fileName: String = "softwareLogs.json",
        maximumEntries: Int = SoftwareLogStore.defaultMaximumEntries
    ) {
        guard let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else { return nil }
        self.init(directoryURL: directory, fileName: fileName, maximumEntries: maximumEntries)
    }

    func bounded(_ entries: [SoftwareLogEntry]) -> [SoftwareLogEntry] {
        Array(entries.suffix(maximumEntries))
    }

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let data = try Data(contentsOf: fileURL)
            do {
                return LoadResult(entries: bounded(try decoder.decode([SoftwareLogEntry].self, from: data)),
                                  failure: nil)
            } catch {
                return LoadResult(entries: [], failure: .decodingFailed)
            }
        } catch {
            return LoadResult(entries: [], failure: .unreadable)
        }
    }

    func save(_ entries: [SoftwareLogEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try encoder.encode(bounded(entries)).write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

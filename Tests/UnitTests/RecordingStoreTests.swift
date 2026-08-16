import XCTest
@testable import GPSAntBMS

final class RecordingStoreTests: XCTestCase {
    private var directory: URL!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = RecordingStore(directoryURL: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testManifestRoundTrip() throws {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let segment = RecordingSegment(sessionID: UUID(), sequence: 0, startedAt: now,
                                       endedAt: now.addingTimeInterval(3), durationSeconds: 3,
                                       byteCount: 42, fileName: "segment.mov")
        let manifest = RecordingManifest(segments: [segment])
        try store.save(manifest)
        XCTAssertEqual(store.load(), .init(manifest: manifest, failedToDecode: false))
    }

    func testCorruptManifestReturnsTypedFailure() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("bad json".utf8).write(to: directory.appendingPathComponent("recording-manifest.json"))
        XCTAssertEqual(store.load(), .init(manifest: .empty, failedToDecode: true))
    }

    func testCommitMovesTemporaryFileToSegmentsDirectory() throws {
        let temporary = store.temporaryURL(sessionID: UUID(), sequence: 0)
        try FileManager.default.createDirectory(at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: temporary)
        let final = try store.commitTemporaryFile(at: temporary, fileName: "final.mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        XCTAssertEqual(try store.byteCount(for: final), 3)
    }
}

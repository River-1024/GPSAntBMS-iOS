import Foundation
import XCTest
@testable import GPSAntBMS

final class SoftwareLogStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoftwareLogStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveLoadKeepsOnlyNewestEntries() throws {
        let store = SoftwareLogStore(directoryURL: directory, maximumEntries: 2)
        let entries = (0..<3).map {
            SoftwareLogEntry(timestamp: Date(timeIntervalSince1970: TimeInterval($0)),
                             level: .info, source: "测试", message: "日志 \($0)")
        }

        try store.save(entries)
        let result = store.load()

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.entries.map(\.message), ["日志 1", "日志 2"])
    }

    func testClearRemovesPersistedEntries() throws {
        let store = SoftwareLogStore(directoryURL: directory)
        try store.save([SoftwareLogEntry(level: .warning, source: "测试", message: "内容")])

        try store.clear()

        XCTAssertEqual(store.load(), .empty)
    }

    func testCorruptedFileReturnsTypedFailure() throws {
        let fileURL = directory.appendingPathComponent("softwareLogs.json")
        try Data("not-json".utf8).write(to: fileURL)

        let result = SoftwareLogStore(directoryURL: directory).load()

        XCTAssertEqual(result.entries, [])
        XCTAssertEqual(result.failure, .decodingFailed)
    }
}

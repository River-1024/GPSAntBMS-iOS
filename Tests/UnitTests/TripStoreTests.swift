import Foundation
import XCTest
@testable import GPSAntBMS

/// `TripStore` 行程历史持久化单元测试。
/// 注入临时目录，不触碰真实 Application Support。
final class TripStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: TripStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TripStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = TripStore(directoryURL: tempDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        store = nil
    }

    private func storeFileURL() -> URL {
        tempDirectory.appendingPathComponent("tripHistory.json")
    }

    private func makeRecord(id: UUID = UUID(), sampleCount: Int = 0) -> TripRecord {
        let t = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let samples = (0..<sampleCount).map { index in
            TripLocationSample(
                timestamp: t.addingTimeInterval(TimeInterval(index)),
                latitude: 0.001 * Double(index),
                longitude: 0,
                speedKmh: 20,
                horizontalAccuracyMeters: 5
            )
        }
        return TripRecord(
            id: id,
            startedAt: t,
            endedAt: t.addingTimeInterval(100),
            durationSeconds: 100,
            distanceKm: 0.5,
            averageSpeedKmh: 18,
            samples: samples
        )
    }

    // MARK: - 加载

    func testMissingFileLoadsEmptyWithoutFailure() {
        // Given 空临时目录
        // When 加载不存在的历史文件
        let result = store.load()

        // Then 空历史且无失败
        XCTAssertEqual(result, .empty)
        XCTAssertTrue(result.history.isEmpty)
        XCTAssertNil(result.failure)
    }

    func testCorruptFileLoadsEmptyWithDecodingFailure() throws {
        // Given 历史文件中写入损坏内容
        try Data("这不是合法 JSON {{{".utf8).write(to: storeFileURL())

        // When 加载
        let result = store.load()

        // Then 空历史 + 类型化失败（非崩溃、非 fatal）
        XCTAssertTrue(result.history.isEmpty)
        XCTAssertEqual(result.failure, .decodingFailed)
    }

    // MARK: - 保存

    func testSaveThenLoadRoundTrips() throws {
        // Given 两条行程记录（一条含采样，一条为空行程）
        let first = makeRecord(sampleCount: 2)
        let second = makeRecord(id: UUID())
        let history = [first, second]

        // When 保存后重新加载
        try store.save(history)
        let result = store.load()

        // Then 历史完整一致
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.history, history)
        XCTAssertEqual(result.history[0].samples.count, 2)
    }

    func testSaveWritesJSONFile() throws {
        // Given 一条行程记录
        let history = [makeRecord()]

        // When 保存（实现使用 Data.write(options: .atomic)）
        try store.save(history)

        // Then 文件存在且内容为可解码的 JSON 数组
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeFileURL().path))
        let data = try Data(contentsOf: storeFileURL())
        let decoded = try JSONDecoder().decode([TripRecord].self, from: data)
        XCTAssertEqual(decoded, history)
    }

    func testSaveOverwritesCorruptFile() throws {
        // Given 损坏文件
        try Data("garbage".utf8).write(to: storeFileURL())

        // When 保存新历史后加载
        let history = [makeRecord()]
        try store.save(history)
        let result = store.load()

        // Then 恢复为完整历史
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.history, history)
    }

    // MARK: - Codable 往返

    func testCodableRoundTripPreservesBMSFieldsAndDates() throws {
        // Given 含可选 BMS 字段与可选字段缺失的采样
        let timestamp = Date(timeIntervalSinceReferenceDate: 1_000_000.5)
        let withBms = TripLocationSample(
            timestamp: timestamp,
            latitude: 1.5,
            longitude: 2.5,
            speedKmh: 33.3,
            horizontalAccuracyMeters: 7.5,
            remainingAh: 152.25,
            powerW: -450
        )
        let withoutBms = TripLocationSample(
            timestamp: timestamp.addingTimeInterval(1),
            latitude: 0,
            longitude: 0,
            speedKmh: 0,
            horizontalAccuracyMeters: 100
        )
        let record = TripRecord(
            id: UUID(),
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(60),
            durationSeconds: 60,
            distanceKm: 1.25,
            averageSpeedKmh: 75,
            samples: [withBms, withoutBms]
        )

        // When JSONEncoder → JSONDecoder 往返
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode([record])
        let decoded = try decoder.decode([TripRecord].self, from: data)

        // Then 完全一致（含 Date 精度与可选字段）
        XCTAssertEqual(decoded, [record])
        XCTAssertEqual(decoded[0].samples[0].remainingAh, 152.25)
        XCTAssertEqual(decoded[0].samples[0].powerW, -450)
        XCTAssertNil(decoded[0].samples[1].remainingAh)
    }

    func testLegacyRecordWithoutNewFieldsDecodesWithDefaults() throws {
        let record = makeRecord()
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        ["name", "startRemainingAh", "endRemainingAh", "consumedAh", "energyAhPer100Km"]
            .forEach { object.removeValue(forKey: $0) }
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TripRecord.self, from: legacyData)

        XCTAssertEqual(decoded.name, "")
        XCTAssertNil(decoded.startRemainingAh)
        XCTAssertNil(decoded.endRemainingAh)
        XCTAssertEqual(decoded.consumedAh, 0)
        XCTAssertEqual(decoded.energyAhPer100Km, 0)
    }
}

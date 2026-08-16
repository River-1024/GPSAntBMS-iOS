import XCTest
@testable import GPSAntBMS

/// `RangePoolStore` 持久化单元测试：round-trip、损坏回退、聚合校验与原子性。
final class RangePoolStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RangePoolStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    private func makeStore() -> RangePoolStore {
        RangePoolStore(directoryURL: tempDirectory)
    }

    private func poolFileURL() -> URL {
        tempDirectory.appendingPathComponent("range-computation-pool.json")
    }

    private func makeSegment(
        startedAt: Date,
        duration: TimeInterval = 60,
        distanceKm: Double = 1.0,
        netConsumedAh: Double = 0.5
    ) -> RangeSegment {
        RangeSegment(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            duration: duration,
            distanceKm: distanceKm,
            netConsumedAh: netConsumedAh,
            averageSpeedKmh: 60,
            admissionThresholdKmh: 30)
    }

    private func makeState() -> RangePoolState {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var state = RangePoolState.empty()
        state.segments = [
            makeSegment(startedAt: base, duration: 120, distanceKm: 2.0, netConsumedAh: 1.0),
            makeSegment(startedAt: base.addingTimeInterval(120), duration: 60,
                        distanceKm: 1.0, netConsumedAh: -0.5)
        ]
        state.mileageFactorKmPerAh = 2.0
        state.averageEffectiveSpeedKmh = 45.0
        state.mileageFactorUpdatedAt = base.addingTimeInterval(120)
        state.averageSpeedUpdatedAt = base.addingTimeInterval(120)
        state.settingsRevision = 3
        state.oldWeightPercent = 70
        state.newWeightPercent = 30
        return state.withAggregates()
    }

    // MARK: - Round-trip

    /// 完整状态（含负净消耗段、两个更新时间、revision、权重）round-trip 不丢字段。
    func testFullStateRoundTrip() throws {
        let store = makeStore()
        let original = makeState()

        try store.save(original)

        let loaded = makeStore().load()
        XCTAssertNil(loaded.failure)
        XCTAssertEqual(loaded.state, original)
    }

    // MARK: - 缺失 / 损坏回退

    /// 缺失文件返回空池无失败。
    func testMissingFileReturnsEmptyState() {
        let result = makeStore().load()
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.state, .empty())
    }

    /// 空文件返回空池 + emptyFile 告警。
    func testEmptyFileReturnsEmptyWithWarning() throws {
        try Data().write(to: poolFileURL())
        let result = makeStore().load()
        XCTAssertEqual(result.failure, .emptyFile)
        XCTAssertEqual(result.state, .empty())
    }

    /// 损坏 JSON 返回空池 + decodingFailed 告警，不崩溃。
    func testCorruptJSONReturnsEmptyWithWarning() throws {
        try Data("not valid json {{{".utf8).write(to: poolFileURL())
        let result = makeStore().load()
        XCTAssertEqual(result.failure, .decodingFailed)
        XCTAssertEqual(result.state, .empty())
    }

    /// 不支持的 schema 版本返回空池 + unsupportedSchema 告警。
    func testUnsupportedSchemaReturnsEmptyWithWarning() throws {
        let data = try JSONEncoder().encode(RangePoolFileV1(schemaVersion: 99, state: makeState()))
        try data.write(to: poolFileURL())
        let result = makeStore().load()
        XCTAssertEqual(result.failure, .unsupportedSchema)
        XCTAssertEqual(result.state, .empty())
    }

    /// 不可读文件（路径是目录）返回 unreadable 告警。
    func testUnreadableReturnsEmptyWithWarning() throws {
        try FileManager.default.createDirectory(at: poolFileURL(), withIntermediateDirectories: false)
        let result = makeStore().load()
        XCTAssertEqual(result.failure, .unreadable)
        XCTAssertEqual(result.state, .empty())
    }

    // MARK: - 聚合校验 / 净化

    /// decode 后聚合字段与 segments 不一致时，sanitized 重算并归一（不崩溃）。
    func testAggregatesRecomputedAfterDecode() throws {
        let store = makeStore()
        var original = makeState()
        // 人为破坏聚合字段（与 segments 不一致）
        original.sourceDistanceKm = 999
        original.sourceNetConsumedAh = 999
        original.validDurationSeconds = 999

        try store.save(original)
        let loaded = makeStore().load()
        XCTAssertNil(loaded.failure)
        // 聚合被重新计算，恢复与 segments 一致
        XCTAssertEqual(loaded.state.sourceDistanceKm, 3.0, accuracy: 1e-9)
        XCTAssertEqual(loaded.state.sourceNetConsumedAh, 0.5, accuracy: 1e-9)
        XCTAssertEqual(loaded.state.validDurationSeconds, 180, accuracy: 1e-9)
    }

    /// decode 后无效分段（时间不一致）被剔除。
    func testInvalidSegmentsDroppedAfterDecode() throws {
        let store = makeStore()
        var original = makeState()
        // 时间不一致的无效分段：duration 与 started/ended 不符
        original.segments.append(RangeSegment(
            startedAt: original.segments[0].startedAt,
            endedAt: original.segments[0].startedAt.addingTimeInterval(60),
            duration: 30, distanceKm: 1.0, netConsumedAh: 0.5,
            averageSpeedKmh: 60, admissionThresholdKmh: 30))

        try store.save(original)
        let loaded = makeStore().load()
        XCTAssertNil(loaded.failure)
        XCTAssertEqual(loaded.state.segments.count, 2, "无效分段被剔除")
    }

    // MARK: - 原子保存失败不破坏旧文件

    /// 保存失败（父目录只读，原子写入无法建临时文件）返回错误且旧文件仍可读。
    func testFailedSaveKeepsOldFileReadable() throws {
        let store = makeStore()
        try store.save(makeState())
        let before = try Data(contentsOf: poolFileURL())

        // 父目录设为只读：`.atomic` 写入需在父目录创建临时文件，必然失败；
        // 已存在的旧文件仍可读，且内容保持不变。
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDirectory.path)
        }
        XCTAssertThrowsError(try store.save(makeState()))

        let after = try Data(contentsOf: poolFileURL())
        XCTAssertEqual(after, before)
    }

    // MARK: - 恢复后首快照不跨段

    /// 保存 → 重新加载（模拟重启）→ 引擎恢复；首条快照只建立基线，不跨重启造段。
    func testRecoveredEngineFirstSnapshotDoesNotCrossRestart() throws {
        let store = makeStore()
        let saved = makeState()
        try store.save(saved)

        let loaded = makeStore().load()
        XCTAssertNil(loaded.failure)
        var engine = RangeComputationEngine(initialState: loaded.state)
        XCTAssertEqual(engine.state.segments.count, 2)

        // 重启后首条快照：只建立基线
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = RangeTelemetrySnapshot(
            timestamp: base.addingTimeInterval(300),
            speedKmh: 40, latitude: 0, longitude: 0,
            remainingAh: 10, remainingAhUpdatedAt: base.addingTimeInterval(300),
            settingsRevision: 3)
        engine.addSnapshot(snapshot, effectiveSpeedKmh: 30, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 2, "重启后首快照不得与持久化段跨造新段")
    }
}

/// 测试用同构文件包装（用于构造不支持的 schema 版本）。
private struct RangePoolFileV1: Codable {
    let schemaVersion: Int
    let state: RangePoolState
}

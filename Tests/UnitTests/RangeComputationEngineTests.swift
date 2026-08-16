import XCTest
@testable import GPSAntBMS

/// `RangeComputationEngine` 纯逻辑单元测试（与 Android `RangeModels.kt` 口径对齐：
/// 快照准入、累计有效窗口、比例裁剪、净消耗门槛、刷新节流、新旧权重混合、
/// 平均有效速度与因子保留）。
final class RangeComputationEngineTests: XCTestCase {

    /// 固定基准时间，保证测试确定性。
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// 0.001° 纬度对应的 haversine 距离（km，R = 6371.0088）
    private let stepKm = 0.001 * 6371.0088 * .pi / 180

    /// 构造一条默认合格的快照（30 km/h 阈值下速度 40 达标，Ah 新鲜）。
    private func snapshot(
        timestamp: Date? = nil,
        speedKmh: Double = 40.0,
        latitude: Double = 0.0,
        longitude: Double = 0.0,
        remainingAh: Double = 10.0,
        remainingAhUpdatedAt: Date? = nil,
        settingsRevision: Int64 = 0
    ) -> RangeTelemetrySnapshot {
        let time = timestamp ?? base
        return RangeTelemetrySnapshot(
            timestamp: time,
            speedKmh: speedKmh,
            latitude: latitude,
            longitude: longitude,
            remainingAh: remainingAh,
            remainingAhUpdatedAt: remainingAhUpdatedAt ?? time,
            settingsRevision: settingsRevision)
    }

    /// 连续发送两条合格快照（间隔 10 s、0.001° 步进、消耗由 ah1/ah2 决定）。
    private func sendPair(
        engine: inout RangeComputationEngine,
        t1: Date,
        t2: Date,
        lat1: Double = 0.0,
        lat2: Double = 0.001,
        ah1: Double = 10.0,
        ah2: Double = 9.9,
        speed: Double = 40.0,
        threshold: Double = 30.0,
        refresh: Int = 60,
        revision: Int64 = 0
    ) {
        engine.addSnapshot(snapshot(timestamp: t1, speedKmh: speed, latitude: lat1, remainingAh: ah1,
                                    settingsRevision: revision),
                           effectiveSpeedKmh: threshold, refreshSeconds: refresh)
        engine.addSnapshot(snapshot(timestamp: t2, speedKmh: speed, latitude: lat2, remainingAh: ah2,
                                    settingsRevision: revision),
                           effectiveSpeedKmh: threshold, refreshSeconds: refresh)
    }

    /// 直接构造一条合法分段（供窗口/裁剪测试绕过 10 s 准入构造长段）。
    private func segment(
        startedAt: Date,
        duration: TimeInterval,
        distanceKm: Double = 1.0,
        netConsumedAh: Double = 0.5,
        speedKmh: Double = 60.0,
        thresholdKmh: Double = 30.0
    ) -> RangeSegment {
        RangeSegment(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            duration: duration,
            distanceKm: distanceKm,
            netConsumedAh: netConsumedAh,
            averageSpeedKmh: speedKmh,
            admissionThresholdKmh: thresholdKmh)
    }

    // MARK: - 空状态

    func testEmptyStateIsUnavailable() {
        var engine = RangeComputationEngine()
        let estimate = engine.estimate(remainingAh: 10.0)

        XCTAssertEqual(estimate.source, .unavailable)
        XCTAssertNil(estimate.factorKmPerAh)
        XCTAssertNil(estimate.estimatedRangeKm)
        XCTAssertEqual(estimate.segmentCount, 0)
        XCTAssertEqual(estimate.windowDistanceKm, 0.0)
        XCTAssertEqual(estimate.windowConsumedAh, 0.0)
        XCTAssertNil(estimate.averageEffectiveSpeedKmh)
        XCTAssertEqual(estimate.poolValidDurationSeconds, 0)
    }

    // MARK: - 独立收集：单快照只建立基线

    /// 第一条快照只建立 transient baseline，不产生分段（AE1 的前提）。
    func testSingleSnapshotOnlyEstablishesBaseline() {
        var engine = RangeComputationEngine()
        let after = engine.addSnapshot(snapshot(), effectiveSpeedKmh: 30.0, refreshSeconds: 60)

        XCTAssertEqual(after.segments.count, 0)
        XCTAssertNil(after.mileageFactorKmPerAh)
        XCTAssertNil(engine.estimate(remainingAh: 10).computedFactorKmPerAh)
    }

    /// 未调用 startTrip：连续两条合格快照即产生 1 段与综合因子（AE1）。
    func testTwoQualifiedSnapshotsProduceSegmentAndFactor() {
        var engine = RangeComputationEngine()
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10))

        let state = engine.state
        XCTAssertEqual(state.segments.count, 1)
        XCTAssertNotNil(state.mileageFactorKmPerAh)
        let estimate = engine.estimate(remainingAh: 9.9)
        XCTAssertEqual(estimate.source, .computed)
        XCTAssertNotNil(estimate.estimatedRangeKm)
    }

    // MARK: - 准入

    /// 两端瞬时速度任一端等于阈值即拒绝（R4：严格大于）。
    func testSpeedEqualToThresholdRejects() {
        var engine = RangeComputationEngine()
        engine.addSnapshot(snapshot(timestamp: base, speedKmh: 30.0),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(10), speedKmh: 30.0),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 0)
    }

    /// 任一端低于阈值即拒绝。
    func testSpeedBelowThresholdRejects() {
        var engine = RangeComputationEngine()
        engine.addSnapshot(snapshot(timestamp: base, speedKmh: 29.9),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(10), speedKmh: 40.0),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 0)
    }

    /// 非有限速度拒绝。
    func testNonFiniteSpeedRejects() {
        var engine = RangeComputationEngine()
        engine.addSnapshot(snapshot(timestamp: base, speedKmh: .nan),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(10), speedKmh: 40.0),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 0)
    }

    /// 间隔超过 10 秒拒绝（AE4）。
    func testGapOverTenSecondsRejects() {
        var engine = RangeComputationEngine()
        engine.addSnapshot(snapshot(timestamp: base), effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(10.001)),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 0)
    }

    /// 间隔恰为 10 秒接受。
    func testGapExactlyTenSecondsAccepts() {
        var engine = RangeComputationEngine()
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10))
        XCTAssertEqual(engine.state.segments.count, 1)
    }

    /// Ah 新鲜度超过 10 秒拒绝（AE4）。
    func testStaleAhRejects() {
        var engine = RangeComputationEngine()
        let stale = base.addingTimeInterval(-11)
        engine.addSnapshot(snapshot(timestamp: base, remainingAhUpdatedAt: stale),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(10), remainingAhUpdatedAt: stale),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 0)
    }

    /// Ah 更新时间晚于 GPS 时间（gap < 0）拒绝。
    func testAhUpdatedAfterGpsTimeRejects() {
        var engine = RangeComputationEngine()
        engine.addSnapshot(snapshot(timestamp: base, remainingAhUpdatedAt: base.addingTimeInterval(1)),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(10)),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 0)
    }

    /// 距离超过 2 km 拒绝（AE4）。
    func testDistanceOverTwoKilometersRejects() {
        var engine = RangeComputationEngine()
        // 0.02° ≈ 2.22 km > 2 km
        engine.addSnapshot(snapshot(timestamp: base), effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(10), latitude: 0.02),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 0)
    }

    /// 零距离（同点）拒绝。
    func testZeroDistanceRejects() {
        var engine = RangeComputationEngine()
        engine.addSnapshot(snapshot(timestamp: base), effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(10), latitude: 0.0),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 0)
    }

    /// 非法坐标拒绝。
    func testInvalidCoordinatesReject() {
        var engine = RangeComputationEngine()
        engine.addSnapshot(snapshot(timestamp: base, latitude: 91.0),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(10), latitude: 0.001),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 0)
    }

    /// 负剩余 Ah 拒绝。
    func testNegativeRemainingAhRejects() {
        var engine = RangeComputationEngine()
        engine.addSnapshot(snapshot(timestamp: base, remainingAh: -1),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(10), remainingAh: 9.9),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 0)
    }

    // MARK: - 净消耗与充电段

    /// 负 netConsumedAh（充电段）允许进入池并参与聚合，不丢弃（R5 / AE5）。
    func testChargingSegmentIsRetainedWithNegativeNetConsumedAh() {
        var engine = RangeComputationEngine()
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10),
                 ah1: 10.0, ah2: 10.5)

        let state = engine.state
        XCTAssertEqual(state.segments.count, 1)
        XCTAssertEqual(state.segments[0].netConsumedAh, -0.5, accuracy: 1e-9)
        XCTAssertEqual(state.sourceNetConsumedAh, -0.5, accuracy: 1e-9)
    }

    // MARK: - 0.01 Ah 门槛与因子保留

    /// 窗口净消耗低于 0.01 Ah 不产生新因子；旧因子保留（AE5）。
    func testSubThresholdConsumptionKeepsOldFactor() {
        var engine = RangeComputationEngine()
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 9.9)
        let firstFactor = engine.state.mileageFactorKmPerAh
        XCTAssertNotNil(firstFactor)

        // 刷新到期（+70 s）后的充电段把窗口净消耗拉低：仍保留旧因子
        sendPair(engine: &engine, t1: base.addingTimeInterval(70), t2: base.addingTimeInterval(80),
                 lat1: 0.001, lat2: 0.002, ah1: 9.9, ah2: 10.392)

        let state = engine.state
        XCTAssertEqual(state.segments.count, 2)
        XCTAssertEqual(state.mileageFactorKmPerAh ?? 0, firstFactor ?? -1, accuracy: 1e-9)
    }

    /// 窗口净消耗达到 0.01 Ah 产生新因子。
    func testThresholdConsumptionProducesFactor() {
        var engine = RangeComputationEngine()
        // 0.01° 距离（≈1.11 km）、消耗 0.01 Ah
        engine.addSnapshot(snapshot(timestamp: base), effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(10), latitude: 0.01,
                                    remainingAh: 9.99),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertNotNil(engine.state.mileageFactorKmPerAh)
    }

    // MARK: - 累计有效窗口与比例裁剪

    /// 15 分钟累计窗口加入 20 分钟有效段：只保留最后 15 分钟，distance/netConsumedAh
    /// 按 15/20 缩放（AE3）。
    func testWindowTrimsToAccumulatedDurationWithProportionalScale() {
        let raw = RangePoolState.empty(targetWindowMinutes: 15)
        let longSegment = segment(startedAt: base, duration: 20 * 60,
                                  distanceKm: 1.0, netConsumedAh: 1.0)
        var pool = raw
        pool.segments = [longSegment]

        let trimmed = pool.trimmedToWindow()
        XCTAssertEqual(trimmed.segments.count, 1)
        XCTAssertEqual(trimmed.segments[0].duration, 15 * 60, accuracy: 1e-6)
        XCTAssertEqual(trimmed.segments[0].distanceKm, 0.75, accuracy: 1e-6)
        XCTAssertEqual(trimmed.segments[0].netConsumedAh, 0.75, accuracy: 1e-6)
        XCTAssertEqual(trimmed.validDurationSeconds, 15 * 60, accuracy: 1e-6)
        XCTAssertEqual(trimmed.sourceDistanceKm, 0.75, accuracy: 1e-6)
        XCTAssertEqual(trimmed.sourceNetConsumedAh, 0.75, accuracy: 1e-6)
    }

    /// 超窗时删除最老完整分段，保留新段（窗口 10 分钟，两段累计 20 分钟，
    /// 溢出恰好等于最老段时长 → 整体删除而非部分缩放）。
    func testWindowDropsOldestCompleteSegment() {
        let raw = RangePoolState.empty(targetWindowMinutes: 10)
        let first = segment(startedAt: base, duration: 10 * 60, distanceKm: 1.0, netConsumedAh: 0.5)
        let second = segment(startedAt: base.addingTimeInterval(10 * 60), duration: 10 * 60,
                             distanceKm: 1.0, netConsumedAh: 0.5)
        var pool = raw
        pool.segments = [first, second]

        let trimmed = pool.trimmedToWindow()
        XCTAssertEqual(trimmed.segments.count, 1)
        XCTAssertEqual(trimmed.segments[0].startedAt, base.addingTimeInterval(10 * 60))
        XCTAssertEqual(trimmed.sourceNetConsumedAh, 0.5, accuracy: 1e-9)
        XCTAssertEqual(trimmed.validDurationSeconds, 10 * 60, accuracy: 1e-6)
    }

    /// 边界分段部分裁剪：15 分钟窗口内 10 分钟 + 10 分钟两段 → 最老段保留 5 分钟并缩放。
    func testWindowPartiallyScalesBoundarySegment() {
        let raw = RangePoolState.empty(targetWindowMinutes: 15)
        let first = segment(startedAt: base, duration: 10 * 60, distanceKm: 1.0, netConsumedAh: 0.5)
        let second = segment(startedAt: base.addingTimeInterval(10 * 60), duration: 10 * 60,
                             distanceKm: 2.0, netConsumedAh: 1.0)
        var pool = raw
        pool.segments = [first, second]

        let trimmed = pool.trimmedToWindow()
        XCTAssertEqual(trimmed.segments.count, 2)
        // 溢出 5 分钟 → 最老段保留 5/10
        XCTAssertEqual(trimmed.segments[0].duration, 5 * 60, accuracy: 1e-6)
        XCTAssertEqual(trimmed.segments[0].distanceKm, 0.5, accuracy: 1e-6)
        XCTAssertEqual(trimmed.segments[0].netConsumedAh, 0.25, accuracy: 1e-6)
        XCTAssertEqual(trimmed.segments[1].duration, 10 * 60, accuracy: 1e-6)
        XCTAssertEqual(trimmed.sourceDistanceKm, 2.5, accuracy: 1e-6)
        XCTAssertEqual(trimmed.sourceNetConsumedAh, 1.25, accuracy: 1e-6)
    }

    /// 停车/低速等待不会自动驱逐旧段（累计有效时长窗口，不按墙钟过期）。
    func testWindowDoesNotExpireByWallClock() {
        var engine = RangeComputationEngine(initialState: .empty(targetWindowMinutes: 15))
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 9.9)
        XCTAssertEqual(engine.state.segments.count, 1)

        // 20 分钟后（墙钟）低速快照（< 阈值）：不产生新段也不清空旧池
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(20 * 60), speedKmh: 5.0,
                                    latitude: 0.01, remainingAh: 9.8),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 1)
        XCTAssertEqual(engine.state.sourceDistanceKm, stepKm, accuracy: 1e-6)
    }

    // MARK: - 因子保留（不回退手动）

    /// 20 分钟无新有效段后旧因子仍可估算，不回退手动（R8）。
    func testStalePoolStillUsesComputedFactor() {
        var engine = RangeComputationEngine()
        engine.manualFactorKmPerAh = 8.0
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 9.9)

        let now = base.addingTimeInterval(20 * 60)
        let estimate = engine.estimate(remainingAh: 5.0)
        XCTAssertEqual(estimate.source, .computed)
        XCTAssertEqual(estimate.segmentCount, 1)
        XCTAssertNotNil(estimate.estimatedRangeKm)
    }

    /// 从未产生综合因子时才使用手动因子兜底。
    func testManualFallbackOnlyWhenNeverComputed() {
        var engine = RangeComputationEngine()
        engine.manualFactorKmPerAh = 8.0
        let fallback = engine.estimate(remainingAh: 20.0)
        XCTAssertEqual(fallback.source, .manual)
        XCTAssertEqual(fallback.factorKmPerAh ?? 0, 8.0, accuracy: 1e-9)

        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 9.9)
        let computed = engine.estimate(remainingAh: 20.0)
        XCTAssertEqual(computed.source, .computed)
        XCTAssertNotNil(computed.computedFactorKmPerAh)
    }

    // MARK: - 刷新节流

    /// 刷新间隔内新分段更新池聚合，但不更新因子/平均速度（AE6）。
    /// 对 2 首快照（t=20，lat 0.001）与对 1 末快照（t=10，lat 0.001）同坐标，
    /// 零距离被拒并重建基线；t=30 快照与其间隔 10 s 造段（累计 2 段）。
    func testRefreshIntervalSuppressesFactorAndAverageUpdate() {
        var engine = RangeComputationEngine()
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 9.9)
        let firstFactor = engine.state.mileageFactorKmPerAh ?? 0
        let firstAverage = engine.state.averageEffectiveSpeedKmh ?? 0

        // 刷新内（t=20/30，消耗 0.2）：新段只更新聚合
        sendPair(engine: &engine, t1: base.addingTimeInterval(20), t2: base.addingTimeInterval(30),
                 lat1: 0.001, lat2: 0.002, ah1: 9.9, ah2: 9.7)

        XCTAssertEqual(engine.state.segments.count, 2)
        XCTAssertEqual(engine.state.mileageFactorKmPerAh ?? 0, firstFactor, accuracy: 1e-9)
        XCTAssertEqual(engine.state.averageEffectiveSpeedKmh ?? 0, firstAverage, accuracy: 1e-9)
    }

    /// 到达刷新边界（>= 60 s）后更新因子与平均速度。
    func testRefreshBoundaryUpdatesFactorAndAverage() {
        var engine = RangeComputationEngine()
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 9.9)
        let firstFactor = engine.state.mileageFactorKmPerAh ?? 0

        // 刷新内（t=20/30）：不更新
        sendPair(engine: &engine, t1: base.addingTimeInterval(20), t2: base.addingTimeInterval(30),
                 lat1: 0.001, lat2: 0.002, ah1: 9.9, ah2: 9.7)
        XCTAssertEqual(engine.state.mileageFactorKmPerAh ?? 0, firstFactor, accuracy: 1e-9)

        // t=80 快照与上一快照（t=30）间隔 50 s > 10 s：拒绝但重建基线；
        // t=90 快照与其间隔 10 s：造段；距首次刷新（t=10）80 s >= 60 → 更新。
        sendPair(engine: &engine, t1: base.addingTimeInterval(80), t2: base.addingTimeInterval(90),
                 lat1: 0.002, lat2: 0.003, ah1: 9.7, ah2: 9.6)
        XCTAssertNotEqual(engine.state.mileageFactorKmPerAh ?? 0, firstFactor, accuracy: 1e-9)
        XCTAssertNotNil(engine.state.averageEffectiveSpeedKmh)
    }

    /// 权重混合：首段直接采用；后续按 old/new 权重混合。
    func testWeightedBlendUsesOldNewWeights() {
        var engine = RangeComputationEngine(initialState: .empty(
            oldWeightPercent: 70, newWeightPercent: 30))
        // 首段：raw1 = stepKm / 0.1
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 9.9)
        let firstFactor = stepKm / 0.1
        XCTAssertEqual(engine.state.mileageFactorKmPerAh ?? 0, firstFactor, accuracy: 1e-6)

        // t=80 重建基线（间隔 70 s 拒绝），t=90 造段并刷新（80 s >= 60）：
        // raw2 = 窗口聚合 = 2*stepKm / 0.3
        sendPair(engine: &engine, t1: base.addingTimeInterval(80), t2: base.addingTimeInterval(90),
                 lat1: 0.001, lat2: 0.002, ah1: 9.9, ah2: 9.7)
        let state = engine.state
        let raw2 = 2 * stepKm / 0.3
        let expected = 0.7 * firstFactor + 0.3 * raw2
        XCTAssertEqual(state.mileageFactorKmPerAh ?? 0, expected, accuracy: 1e-6)
    }

    /// 修改权重后下一次到期混合使用新权重（不再固定 70/30）。
    func testConfigurationChangeAppliesNewWeights() {
        var engine = RangeComputationEngine()
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 9.9)
        let firstFactor = stepKm / 0.1

        // 更新配置：权重 50/50，窗口不变，revision 不变
        engine.updateConfiguration(
            targetWindowMinutes: 15, settingsRevision: 0,
            oldWeightPercent: 50, newWeightPercent: 50,
            now: base.addingTimeInterval(70))

        // t=80 重建基线（间隔 50 s 拒绝，revision 相同故不额外清基线），
        // t=90 造段并刷新（距首次 80 s >= 60）：按 50/50 混合
        sendPair(engine: &engine, t1: base.addingTimeInterval(80), t2: base.addingTimeInterval(90),
                 lat1: 0.001, lat2: 0.002, ah1: 9.9, ah2: 9.7)
        let state = engine.state
        let raw2 = 2 * stepKm / 0.3
        let expected = 0.5 * firstFactor + 0.5 * raw2
        XCTAssertEqual(state.mileageFactorKmPerAh ?? 0, expected, accuracy: 1e-6)
    }

    // MARK: - 设置 revision

    /// 阈值变更（revision +1）：清 transient baseline，不整体丢池；新 revision 内
    /// 的相邻快照正常造段，但与旧 revision 快照不跨段（AE7）。
    func testRevisionChangeRebuildsBaseline() {
        var engine = RangeComputationEngine()
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 9.9)
        XCTAssertEqual(engine.state.segments.count, 1)

        // 阈值变更 → revision 1（引擎只清 transient baseline，不清池）
        engine.updateConfiguration(
            targetWindowMinutes: 15, settingsRevision: 1,
            oldWeightPercent: 70, newWeightPercent: 30,
            now: base.addingTimeInterval(11))
        XCTAssertEqual(engine.state.segments.count, 1, "阈值变更不得清空已持久化池")

        // 新 revision 下的第一条快照：只建立基线，不与其前（旧 revision）快照造段
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(12), speedKmh: 60.0,
                                    settingsRevision: 1),
                           effectiveSpeedKmh: 50.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 1, "跨 revision 不造段")

        // 新 revision 内第二条快照：正常造段
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(22), speedKmh: 60.0,
                                    latitude: 0.001, settingsRevision: 1),
                           effectiveSpeedKmh: 50.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 2)
    }

    /// 跨 revision 的相邻快照被拒绝（即使时间/速度合格）。
    func testCrossRevisionSnapshotsRejected() {
        var engine = RangeComputationEngine()
        engine.addSnapshot(snapshot(timestamp: base, settingsRevision: 0),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        engine.addSnapshot(snapshot(timestamp: base.addingTimeInterval(10), latitude: 0.001,
                                    settingsRevision: 1),
                           effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(engine.state.segments.count, 0)
    }

    // MARK: - 配置变更

    /// 窗口缩短：立即裁剪并强制重算（KTD3）。
    func testWindowShrinkTrimsImmediately() {
        var pool = RangePoolState.empty(targetWindowMinutes: 15)
        pool.segments = [segment(startedAt: base, duration: 10 * 60, distanceKm: 1.0, netConsumedAh: 0.5)]
        var engine = RangeComputationEngine(initialState: pool)
        XCTAssertEqual(engine.state.validDurationSeconds, 10 * 60, accuracy: 1e-6)

        engine.updateConfiguration(
            targetWindowMinutes: 5, settingsRevision: 0,
            oldWeightPercent: 70, newWeightPercent: 30,
            now: base.addingTimeInterval(10 * 60))
        XCTAssertEqual(engine.state.validDurationSeconds, 5 * 60, accuracy: 1e-6)
        XCTAssertEqual(engine.state.segments[0].distanceKm, 0.5, accuracy: 1e-6)
    }

    /// 窗口变长：保留已有池。
    func testWindowGrowKeepsExistingPool() {
        var pool = RangePoolState.empty(targetWindowMinutes: 15)
        pool.segments = [segment(startedAt: base, duration: 10 * 60, distanceKm: 1.0, netConsumedAh: 0.5)]
        var engine = RangeComputationEngine(initialState: pool)

        engine.updateConfiguration(
            targetWindowMinutes: 30, settingsRevision: 0,
            oldWeightPercent: 70, newWeightPercent: 30,
            now: base.addingTimeInterval(10 * 60))
        XCTAssertEqual(engine.state.validDurationSeconds, 10 * 60, accuracy: 1e-6)
        XCTAssertEqual(engine.state.segments.count, 1)
    }

    // MARK: - 平均有效速度

    /// 平均有效速度与因子独立推进：即使净消耗不足 0.01，平均速度仍可产生。
    func testAverageEffectiveSpeedUpdatesIndependently() {
        var engine = RangeComputationEngine()
        // 充电段：净消耗为负（< 0.01），但距离/时长有效
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 10.5)

        let state = engine.state
        XCTAssertNil(state.mileageFactorKmPerAh, "净消耗不足门槛不产生因子")
        XCTAssertNotNil(state.averageEffectiveSpeedKmh, "平均有效速度独立产生")
        // stepKm / (10/3600) ≈ 40.0 km/h
        XCTAssertEqual(state.averageEffectiveSpeedKmh ?? 0, stepKm * 360, accuracy: 0.5)
    }

    // MARK: - Codable / sanitized

    /// 状态完整 Codable 往返不丢字段（含负 netConsumedAh）。
    func testStateCodableRoundTripPreservesAllFields() throws {
        var engine = RangeComputationEngine()
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 9.9)
        let state = engine.state

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RangePoolState.self, from: data)

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.segments, state.segments)
    }

    /// 负 netConsumedAh 可编码、可恢复。
    func testNegativeNetConsumedAhRoundTrips() throws {
        var engine = RangeComputationEngine()
        sendPair(engine: &engine, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 10.5)

        let data = try JSONEncoder().encode(engine.state)
        let decoded = try JSONDecoder().decode(RangePoolState.self, from: data)
        XCTAssertEqual(decoded.segments[0].netConsumedAh, -0.5, accuracy: 1e-9)
    }

    /// sanitized：无效分段（时间不一致、超距、非法速度）被剔除并重新聚合。
    func testSanitizedDropsInvalidSegments() {
        let valid = segment(startedAt: base, duration: 60, distanceKm: 1.0, netConsumedAh: 0.5)
        // 时间不一致：duration（30 s）与 endedAt - startedAt（60 s）不符
        let invalidTime = RangeSegment(
            startedAt: base,
            endedAt: base.addingTimeInterval(60),
            duration: 30,
            distanceKm: 1.0,
            netConsumedAh: 0.5,
            averageSpeedKmh: 60,
            admissionThresholdKmh: 30)
        let invalidDistance = segment(startedAt: base, duration: 60, distanceKm: 3.0, netConsumedAh: 0.5)
        let invalidSpeed = segment(startedAt: base, duration: 60, distanceKm: 1.0,
                                   netConsumedAh: 0.5, speedKmh: -1)

        var raw = RangePoolState.empty()
        raw.segments = [valid, invalidTime, invalidDistance, invalidSpeed]
        raw.sourceDistanceKm = 99
        raw.sourceNetConsumedAh = 99
        raw.validDurationSeconds = 99
        raw.settingsRevision = -5

        let cleaned = raw.sanitized()
        XCTAssertEqual(cleaned.segments, [valid])
        XCTAssertEqual(cleaned.sourceDistanceKm, 1.0, accuracy: 1e-9)
        XCTAssertEqual(cleaned.sourceNetConsumedAh, 0.5, accuracy: 1e-9)
        XCTAssertEqual(cleaned.validDurationSeconds, 60, accuracy: 1e-9)
        XCTAssertEqual(cleaned.settingsRevision, 0)
    }

    /// transient previous snapshot 不属于持久化状态（引擎状态不含快照字段）。
    func testTransientBaselineNotPartOfPersistedState() throws {
        var engine = RangeComputationEngine()
        // 只发一条快照：仅建立 transient baseline
        engine.addSnapshot(snapshot(timestamp: base), effectiveSpeedKmh: 30.0, refreshSeconds: 60)

        let data = try JSONEncoder().encode(engine.state)
        let decoded = try JSONDecoder().decode(RangePoolState.self, from: data)
        // 状态中无任何快照相关字段：解码后空池
        XCTAssertEqual(decoded, RangePoolState.empty())
    }

    /// 恢复后的第一条快照不会与"重启前"跨段：新引擎从持久化池开始，首快照只建基线。
    func testRecoveredEngineFirstSnapshotOnlyBaseline() {
        var first = RangeComputationEngine()
        sendPair(engine: &first, t1: base, t2: base.addingTimeInterval(10), ah1: 10.0, ah2: 9.9)
        let persisted = first.state

        var recovered = RangeComputationEngine(initialState: persisted)
        XCTAssertEqual(recovered.state.segments.count, 1)

        // 重启后的首条快照：只建立基线（transient 未恢复）
        recovered.addSnapshot(snapshot(timestamp: base.addingTimeInterval(20)),
                              effectiveSpeedKmh: 30.0, refreshSeconds: 60)
        XCTAssertEqual(recovered.state.segments.count, 1, "重启后首快照不得造段")
    }
}

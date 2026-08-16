import Combine
import Foundation
import XCTest
@testable import GPSAntBMS

/// 可注入的位置采样提供者 Mock（不依赖真实 GPS）。
private final class MockLocationProvider: LocationSampleProviding {
    private let subject = PassthroughSubject<TripLocationSample, Never>()

    var samplePublisher: AnyPublisher<TripLocationSample, Never> {
        subject.eraseToAnyPublisher()
    }

    func send(_ sample: TripLocationSample) {
        subject.send(sample)
    }
}

/// 可注入的快照提供者 Mock（不依赖真实 BLE）。
private final class MockBmsProvider: BmsSnapshotProviding {
    private let subject = PassthroughSubject<BmsSnapshot, Never>()
    private(set) var snapshot = BmsSnapshot()

    var snapshotPublisher: AnyPublisher<BmsSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    func send(_ snapshot: BmsSnapshot) {
        self.snapshot = snapshot
        subject.send(snapshot)
    }
}

/// 记录委托调用的轮询间隔 Mock。
private final class MockPollingIntervalTarget: PollingIntervalSettable {
    private(set) var appliedIntervals: [Int] = []

    func setPollingInterval(_ milliseconds: Int) {
        appliedIntervals.append(milliseconds)
    }
}

/// `TripSessionController` 前台行程会话控制器单元测试。
/// 全部注入 Mock 数据源、临时目录与可控时钟，完全确定性；无真实 BLE/GPS。
final class TripSessionControllerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    /// 0.001° 纬度对应的 haversine 距离（km，R = 6371.0088，与引擎一致）
    private let stepKm = 0.001 * 6371.0088 * .pi / 180

    private var tempDirectory: URL!
    private var settingsSuite: UserDefaults!
    private var settingsSuiteName: String!
    private var nowValue: Date!
    private var locationProvider: MockLocationProvider!
    private var bmsProvider: MockBmsProvider!
    private var pollingTarget: MockPollingIntervalTarget!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TripSessionControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let suiteName = "TripSessionControllerTests-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("无法创建 UserDefaults suite")
            return
        }
        settingsSuiteName = suiteName
        settingsSuite = suite
        nowValue = t0
        locationProvider = MockLocationProvider()
        bmsProvider = MockBmsProvider()
        pollingTarget = MockPollingIntervalTarget()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        settingsSuite.removePersistentDomain(forName: settingsSuiteName)
        settingsSuite = nil
        settingsSuiteName = nil
        nowValue = nil
        locationProvider = nil
        bmsProvider = nil
        pollingTarget = nil
    }

    private func makeController() -> TripSessionController {
        TripSessionController(
            locationProvider: locationProvider,
            bmsProvider: bmsProvider,
            pollingIntervalTarget: pollingTarget,
            rangePoolStore: RangePoolStore(directoryURL: tempDirectory),
            tripStore: TripStore(directoryURL: tempDirectory),
            settingsStore: AppSettingsStore(userDefaults: settingsSuite),
            now: { self.nowValue })
    }

    /// 等待主队列完成 `.receive(on: DispatchQueue.main)` 的异步投递。
    /// 排空两次：第一次执行发送时已排队的 sink（池状态更新 → @Published 触发
    /// 镜像 sink 二次排队），第二次执行镜像链路，保证 `tripSession.rangeEstimate`
    /// 反映池的最新状态。
    private func drainMainQueue() {
        for _ in 0..<2 {
            let drained = expectation(description: "drain main queue")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 1)
        }
    }

    private func sample(at date: Date, latitude: Double = 0,
                        speedKmh: Double = 40, accuracy: Double = 5) -> TripLocationSample {
        TripLocationSample(
            timestamp: date, latitude: latitude, longitude: 0,
            speedKmh: speedKmh, horizontalAccuracyMeters: accuracy)
    }

    private func snapshot(remainingAh: Double, powerW: Double = 0, connected: Bool = true) -> BmsSnapshot {
        var snapshot = BmsSnapshot()
        snapshot.isConnected = connected
        snapshot.remainingChargeAh = remainingAh
        snapshot.power = powerW
        return snapshot
    }

    private func historyFileURL() -> URL {
        tempDirectory.appendingPathComponent("tripHistory.json")
    }

    // MARK: - 开始 / 行程控制

    func testStartTripIsIdempotent() {
        let controller = makeController()

        controller.startTrip()
        controller.startTrip()

        XCTAssertTrue(controller.isRecording)
        XCTAssertTrue(controller.history.isEmpty)
    }

    func testStopTripWithoutStartIsNoOp() {
        let controller = makeController()

        controller.stopTrip()

        XCTAssertFalse(controller.isRecording)
        XCTAssertTrue(controller.history.isEmpty)
    }

    // MARK: - 生命周期：暂停不结束 + 持久化

    func testLifecycleStopPausesRecorderAndPersistsWithoutEndingTrip() {
        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(2)
        locationProvider.send(sample(at: t0.addingTimeInterval(2), latitude: 0.001))
        drainMainQueue()
        XCTAssertEqual(controller.currentDistanceKm, stepKm, accuracy: 0.0001)
        XCTAssertEqual(controller.currentDurationSeconds, 2, accuracy: 0.0001)
        XCTAssertTrue(controller.isRecording)

        // 退后台：暂停 + 持久化，行程不结束
        controller.stopForegroundSession()
        XCTAssertTrue(controller.isRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyFileURL().path))

        // 后台采样被拒绝，距离与时长冻结
        nowValue = t0.addingTimeInterval(60)
        locationProvider.send(sample(at: t0.addingTimeInterval(60), latitude: 0.01))
        drainMainQueue()
        XCTAssertEqual(controller.currentDistanceKm, stepKm, accuracy: 0.0001)
        XCTAssertEqual(controller.currentDurationSeconds, 2, accuracy: 0.0001)

        // 回前台：记录时钟恢复
        nowValue = t0.addingTimeInterval(62)
        controller.startForegroundSession()
        XCTAssertEqual(controller.currentDurationSeconds, 2, accuracy: 0.0001)
        nowValue = t0.addingTimeInterval(65)
        controller.stopTrip()
        XCTAssertEqual(controller.history[0].durationSeconds, 5)
    }

    // MARK: - 开始/停止与持久化

    func testStopTripArchivesAndPersistsHistory() {
        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()
        bmsProvider.send(snapshot(remainingAh: 150))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(2)
        locationProvider.send(sample(at: t0.addingTimeInterval(2), latitude: 0.001))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(10)
        controller.stopTrip()

        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(controller.currentDistanceKm, 0)
        XCTAssertEqual(controller.history.count, 1)
        XCTAssertEqual(controller.history[0].durationSeconds, 10)
        XCTAssertEqual(controller.history[0].distanceKm, stepKm, accuracy: 0.0001)
        XCTAssertEqual(controller.history[0].samples.count, 2)
        XCTAssertEqual(controller.history[0].samples[1].remainingAh, 150)

        // 已持久化：新 store 实例重新加载一致
        let reloaded = TripStore(directoryURL: tempDirectory).load()
        XCTAssertNil(reloaded.failure)
        XCTAssertEqual(reloaded.history, controller.history)

        // stop 幂等
        controller.stopTrip()
        XCTAssertEqual(controller.history.count, 1)
    }

    func testDeleteTripAndClearTripsPersistImmediately() {
        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(2)
        locationProvider.send(sample(at: t0.addingTimeInterval(2), latitude: 0.001))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(3)
        controller.stopTrip()
        controller.startTrip()
        nowValue = t0.addingTimeInterval(4)
        locationProvider.send(sample(at: t0.addingTimeInterval(4)))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(5)
        locationProvider.send(sample(at: t0.addingTimeInterval(5), latitude: 0.001))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(6)
        controller.stopTrip()
        XCTAssertEqual(controller.history.count, 2)

        let removedID = controller.history[0].id
        controller.deleteTrip(id: removedID)
        XCTAssertEqual(controller.history.count, 1)
        XCTAssertEqual(TripStore(directoryURL: tempDirectory).load().history, controller.history)

        controller.clearTrips()
        XCTAssertTrue(controller.history.isEmpty)
        let afterClear = TripStore(directoryURL: tempDirectory).load()
        XCTAssertTrue(afterClear.history.isEmpty)
        XCTAssertNil(afterClear.failure)
    }

    // MARK: - 富化与续航估算

    func testAcceptedSamplesEnrichedWithLatestSnapshot() {
        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()
        bmsProvider.send(snapshot(remainingAh: 150, powerW: -450))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(2)
        locationProvider.send(sample(at: t0.addingTimeInterval(2), latitude: 0.001))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(3)
        controller.stopTrip()

        let record = controller.history[0]
        XCTAssertEqual(record.samples.count, 2)
        XCTAssertEqual(record.samples[0].remainingAh, 150)
        XCTAssertEqual(record.samples[0].powerW, -450)
        XCTAssertEqual(record.samples[1].remainingAh, 150)
        XCTAssertEqual(record.samples[1].powerW, -450)
    }

    func testComputedRangeFromAcceptedSegments() {
        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()
        // 分段：10 s、0.005°（≈5 × stepKm）、消耗 0.1 Ah → 平均速度 > 30 阈值
        bmsProvider.send(snapshot(remainingAh: 10))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        bmsProvider.send(snapshot(remainingAh: 9.9))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(11)
        locationProvider.send(sample(at: t0.addingTimeInterval(11), latitude: 0.005))
        drainMainQueue()

        let expectedFactor = stepKm * 5 / 0.1
        XCTAssertEqual(controller.rangeEstimate.source, .computed)
        XCTAssertEqual(controller.rangeEstimate.factorKmPerAh ?? 0, expectedFactor, accuracy: 1e-6)
        XCTAssertEqual(controller.rangeEstimate.estimatedRangeKm ?? 0, expectedFactor * 9.9, accuracy: 1e-6)

        // 快照更新后估算随最新剩余容量刷新
        bmsProvider.send(snapshot(remainingAh: 5))
        drainMainQueue()
        XCTAssertEqual(controller.rangeEstimate.estimatedRangeKm ?? 0, expectedFactor * 5, accuracy: 1e-6)
    }

    /// 充电段（剩余容量上升）产生负净消耗分段并进入池（R5：负值允许入池，
    /// 不丢弃）；窗口净消耗为负低于 0.01 Ah 门槛时不产生综合因子，回退手动。
    func testChargingSnapshotsFeedSegmentsWithNegativeNetConsumption() {
        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()
        bmsProvider.send(snapshot(remainingAh: 10))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        // 剩余容量上升（充电）：净消耗为负，仍入池
        bmsProvider.send(snapshot(remainingAh: 10.5))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(11)
        locationProvider.send(sample(at: t0.addingTimeInterval(11), latitude: 0.005))
        drainMainQueue()

        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1)
        XCTAssertEqual(controller.rangeEstimate.windowConsumedAh, -0.5, accuracy: 1e-6)
        XCTAssertEqual(controller.rangeEstimate.source, .manual) // 净消耗不足门槛，回退手动
        // 平均有效速度独立产生（不因因子缺失而缺失）
        XCTAssertNotNil(controller.rangeEstimate.averageEffectiveSpeedKmh)
    }

    func testNoRangeSegmentAcrossInactiveInterval() {
        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()
        // 分段 1：10 s、0.005°（≈5 × stepKm）、消耗 0.1 Ah → 平均速度 > 30 阈值
        bmsProvider.send(snapshot(remainingAh: 10))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        bmsProvider.send(snapshot(remainingAh: 9.9))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(11)
        locationProvider.send(sample(at: t0.addingTimeInterval(11), latitude: 0.005))
        drainMainQueue()
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1)

        // 退后台（短于 30 s 阈值）；后台期间保留最后遥测（9.8 Ah）
        nowValue = t0.addingTimeInterval(12)
        controller.stopForegroundSession()
        bmsProvider.send(snapshot(remainingAh: 9.8))
        drainMainQueue()
        // 回前台：首个采样必须作为新分段起点，不得跨非活跃间隔生成续航分段
        nowValue = t0.addingTimeInterval(20)
        controller.startForegroundSession()
        nowValue = t0.addingTimeInterval(21)
        locationProvider.send(sample(at: t0.addingTimeInterval(21), latitude: 0.006))
        drainMainQueue()
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1)
        XCTAssertEqual(controller.rangeEstimate.windowDistanceKm, stepKm * 5, accuracy: 1e-6)

        // 分段 2：10 s、stepKm、消耗 0.1 Ah → 平均速度 > 30 阈值，入窗
        bmsProvider.send(snapshot(remainingAh: 9.7))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(31)
        locationProvider.send(sample(at: t0.addingTimeInterval(31), latitude: 0.007))
        drainMainQueue()
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 2)
        XCTAssertEqual(controller.rangeEstimate.windowDistanceKm, stepKm * 6, accuracy: 1e-6)
    }

    func testDisconnectedSnapshotInvalidatesRangeAndStopsEnrichingSamples() {
        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()
        // 连接中：快照用于富化采样与投影续航
        bmsProvider.send(snapshot(remainingAh: 150, powerW: -450))
        drainMainQueue()
        controller.updateManualRangeFactor(8)
        drainMainQueue()
        XCTAssertEqual(controller.rangeEstimate.estimatedRangeKm ?? 0, 1200, accuracy: 1e-9)
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        // 断开：快照保留非零遥测但连接标记为断开 → 估算立即失效
        bmsProvider.send(snapshot(remainingAh: 150, powerW: -450, connected: false))
        drainMainQueue()
        XCTAssertNil(controller.rangeEstimate.estimatedRangeKm)
        // 断开后的采样不再被富化；此前采样保留原值
        nowValue = t0.addingTimeInterval(2)
        locationProvider.send(sample(at: t0.addingTimeInterval(2), latitude: 0.001))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(3)
        controller.stopTrip()
        let record = controller.history[0]
        XCTAssertEqual(record.samples.count, 2)
        XCTAssertEqual(record.samples[0].remainingAh, 150)
        XCTAssertEqual(record.samples[0].powerW, -450)
        XCTAssertNil(record.samples[1].remainingAh)
        XCTAssertNil(record.samples[1].powerW)
    }

    // MARK: - 设置

    func testPollingIntervalUpdatePersistsAndDelegates() {
        let controller = makeController()

        // 初始化时应用持久化（此处为默认 1000 ms）轮询间隔一次
        XCTAssertEqual(pollingTarget.appliedIntervals, [1000])

        controller.updatePollingInterval(3000)

        XCTAssertEqual(controller.settings.pollingIntervalMilliseconds, 3000)
        XCTAssertEqual(pollingTarget.appliedIntervals, [1000, 3000])
        // 越界钳制后委托钳制值
        controller.updatePollingInterval(50)
        XCTAssertEqual(controller.settings.pollingIntervalMilliseconds, 200)
        XCTAssertEqual(pollingTarget.appliedIntervals, [1000, 3000, 200])
        // 持久化
        let reloaded = AppSettingsStore(userDefaults: settingsSuite).load()
        XCTAssertEqual(reloaded.pollingIntervalMilliseconds, 200)
    }

    func testManualRangeFactorUpdatePersistsAndFallsBack() {
        let controller = makeController()
        bmsProvider.send(snapshot(remainingAh: 20))
        drainMainQueue()

        controller.updateManualRangeFactor(8)
        drainMainQueue()

        XCTAssertEqual(controller.settings.manualRangeKmPerAh, 8)
        XCTAssertEqual(controller.rangeEstimate.source, .manual)
        XCTAssertEqual(controller.rangeEstimate.estimatedRangeKm ?? 0, 160, accuracy: 1e-9)
        // 钳制
        controller.updateManualRangeFactor(0.01)
        XCTAssertEqual(controller.settings.manualRangeKmPerAh, 0.1)
        XCTAssertEqual(AppSettingsStore(userDefaults: settingsSuite).load().manualRangeKmPerAh, 0.1)
    }

    func testRangeDisplayAndBackgroundTrackingUpdatesPersist() {
        let controller = makeController()

        controller.updateRangeDisplayMode(.both)
        controller.updateBackgroundTrackingEnabled(true)

        XCTAssertEqual(controller.settings.rangeDisplayMode, .both)
        XCTAssertTrue(controller.settings.backgroundTrackingEnabled)
        let persisted = AppSettingsStore(userDefaults: settingsSuite).load()
        XCTAssertEqual(persisted.rangeDisplayMode, .both)
        XCTAssertTrue(persisted.backgroundTrackingEnabled)
    }

    func testEffectiveSpeedUpdatePersists() {
        let controller = makeController()

        controller.updateEffectiveSpeed(55)

        XCTAssertEqual(controller.settings.effectiveSpeedKmh, 55)
        XCTAssertEqual(AppSettingsStore(userDefaults: settingsSuite).load().effectiveSpeedKmh, 55)
        // 钳制（Android 对齐：有效速度上限 120 km/h）
        controller.updateEffectiveSpeed(999)
        XCTAssertEqual(controller.settings.effectiveSpeedKmh, 120)
    }

    func testAppearanceUpdatePersists() {
        let controller = makeController()

        controller.updateAppearance(.light)

        XCTAssertEqual(controller.settings.appearance, .light)
        XCTAssertEqual(AppSettingsStore(userDefaults: settingsSuite).load().appearance, .light)
    }

    func testThresholdUpdatesPreserveYellowRedOrdering() {
        let controller = makeController()

        controller.updateThresholds(powerYellow: 3_000)
        XCTAssertEqual(controller.settings.powerRedThresholdWatts, 3_000)

        controller.updateThresholds(socYellow: 10)
        XCTAssertEqual(controller.settings.socRedThreshold, 10)

        controller.updateThresholds(voltageYellow: 120)
        XCTAssertEqual(controller.settings.voltageDiffRedMillivolts, 120)

        controller.updateThresholds(temperatureYellow: 80)
        XCTAssertEqual(controller.settings.temperatureRedCelsius, 80)

        controller.updateThresholds(powerRed: 500)
        XCTAssertEqual(controller.settings.powerRedThresholdWatts, 3_000)

        controller.updateThresholds(socRed: 90)
        XCTAssertEqual(controller.settings.socRedThreshold, 10)
    }

    // MARK: - 启动时持久化设置的应用

    func testPersistedPollingIntervalAppliedExactlyOnceAtStartup() {
        let stored = AppSettings(
            pollingIntervalMilliseconds: 5000,
            manualRangeKmPerAh: 1.0,
            effectiveSpeedKmh: 30)
        AppSettingsStore(userDefaults: settingsSuite).save(stored)

        let controller = makeController()

        // 初始化恰好应用一次持久化轮询间隔
        XCTAssertEqual(pollingTarget.appliedIntervals, [5000])
        // 运行时更新仅追加，不重复应用启动值
        controller.updatePollingInterval(7000)
        XCTAssertEqual(pollingTarget.appliedIntervals, [5000, 7000])
    }

    func testPersistedEffectiveSpeedBecomesSpeedThresholdAtStartup() {
        let stored = AppSettings(
            pollingIntervalMilliseconds: 2000,
            manualRangeKmPerAh: 1.0,
            effectiveSpeedKmh: 50)
        AppSettingsStore(userDefaults: settingsSuite).save(stored)

        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()

        // 平均速度 ~40 km/h 的分段（默认阈值 30 会接受）：持久化阈值 50 应拒绝
        bmsProvider.send(snapshot(remainingAh: 10))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        bmsProvider.send(snapshot(remainingAh: 9.9))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(11)
        locationProvider.send(sample(at: t0.addingTimeInterval(11), latitude: 0.001))
        drainMainQueue()

        XCTAssertEqual(controller.rangeEstimate.segmentCount, 0)
        XCTAssertEqual(controller.rangeEstimate.source, .manual)
        // 轮询间隔同样来自持久化设置
        XCTAssertEqual(pollingTarget.appliedIntervals, [2000])
    }

    // MARK: - 有效速度阈值行为

    func testDefaultSpeedThresholdAcceptsModerateSpeedSegment() {
        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()

        // 平均速度 ~40 km/h（10 s、0.001° ≈ stepKm）> 默认阈值 30：入窗
        bmsProvider.send(snapshot(remainingAh: 10))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        bmsProvider.send(snapshot(remainingAh: 9.9))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(11)
        locationProvider.send(sample(at: t0.addingTimeInterval(11), latitude: 0.001))
        drainMainQueue()

        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1)
        XCTAssertEqual(controller.rangeEstimate.source, .computed)
    }

    /// 阈值变更：保留已持久化池与综合因子，但清 transient baseline（KTD3/R9）。
    /// 新阈值下首个快照只建立基线，不跨 revision 造段；低于新阈值的速度被拒绝。
    func testEffectiveSpeedUpdatePreservesPoolAndRebuildsBaseline() {
        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()

        // 默认阈值 30：40 km/h 分段入窗
        bmsProvider.send(snapshot(remainingAh: 10))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        bmsProvider.send(snapshot(remainingAh: 9.9))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(11)
        locationProvider.send(sample(at: t0.addingTimeInterval(11), latitude: 0.001))
        drainMainQueue()
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1)
        let factorBefore = controller.rangeEstimate.factorKmPerAh

        // 阈值提升到 50：池保留，revision 递增
        controller.updateEffectiveSpeed(50)
        drainMainQueue()
        XCTAssertEqual(controller.settings.effectiveSpeedKmh, 50)
        XCTAssertEqual(AppSettingsStore(userDefaults: settingsSuite).load().effectiveSpeedKmh, 50)
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1, "阈值变更不得清空已持久化池")
        XCTAssertEqual(controller.rangeEstimate.source, .computed)
        XCTAssertEqual(controller.rangeEstimate.factorKmPerAh, factorBefore, "综合因子保留")

        // 新 revision 下首个快照只建立基线：40 km/h（< 新阈值 50）被拒绝，
        // 且不与旧 baseline 跨 revision 造段
        bmsProvider.send(snapshot(remainingAh: 9.8))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(21)
        locationProvider.send(sample(at: t0.addingTimeInterval(21), latitude: 0.002, speedKmh: 40))
        drainMainQueue()
        bmsProvider.send(snapshot(remainingAh: 9.7))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(31)
        locationProvider.send(sample(at: t0.addingTimeInterval(31), latitude: 0.003, speedKmh: 40))
        drainMainQueue()
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1, "低于新阈值且跨 revision 不造段")

        // 60 km/h 分段在新阈值下入窗：t=31（40 km/h < 50）被拒后成为基线，
        // t=41 与 t=31 因 t=31 端速度不合格仍被拒（准入要求两端严格大于阈值），
        // t=51 与 t=41（两端 60 > 50）才造段 → 共 2 段
        bmsProvider.send(snapshot(remainingAh: 9.6))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(41)
        locationProvider.send(sample(at: t0.addingTimeInterval(41), latitude: 0.0045, speedKmh: 60))
        drainMainQueue()
        bmsProvider.send(snapshot(remainingAh: 9.5))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(51)
        locationProvider.send(sample(at: t0.addingTimeInterval(51), latitude: 0.006, speedKmh: 60))
        drainMainQueue()
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 2)
        XCTAssertEqual(controller.rangeEstimate.source, .computed)
    }

    func testEffectiveSpeedUpdatePreservesManualFallback() {
        let controller = makeController()
        controller.updateManualRangeFactor(8)
        drainMainQueue()

        controller.updateEffectiveSpeed(50)
        drainMainQueue()

        XCTAssertEqual(controller.settings.effectiveSpeedKmh, 50)
        XCTAssertEqual(controller.rangeEstimate.source, .manual)
        XCTAssertEqual(controller.rangeEstimate.factorKmPerAh ?? 0, 8, accuracy: 1e-9)
        // 钳制后的阈值同样生效且手动兜底保留
        controller.updateEffectiveSpeed(999)
        drainMainQueue()
        XCTAssertEqual(controller.settings.effectiveSpeedKmh, 120)
        XCTAssertEqual(controller.rangeEstimate.source, .manual)
        XCTAssertEqual(controller.rangeEstimate.factorKmPerAh ?? 0, 8, accuracy: 1e-9)
    }

    // MARK: - 续航设置 ↔ 引擎运行值集成（U4：设置值 == 引擎运行值 == 下一次结果）

    /// 窗口设置：保存后立即裁剪引擎窗口；后续结果受新窗口影响。
    func testRangeWindowUpdateTakesEffectImmediately() {
        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()

        // 产生一段 10 s 有效段
        bmsProvider.send(snapshot(remainingAh: 10))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        bmsProvider.send(snapshot(remainingAh: 9.9))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(11)
        locationProvider.send(sample(at: t0.addingTimeInterval(11), latitude: 0.001))
        drainMainQueue()
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1)

        // 窗口缩短到 1 分钟（60 s）不影响单段；持久化与引擎一致
        controller.updateRangeWindowSeconds(60)
        drainMainQueue()
        XCTAssertEqual(controller.settings.rangeWindowSeconds, 60)
        XCTAssertEqual(AppSettingsStore(userDefaults: settingsSuite).load().rangeWindowSeconds, 60)
        // 引擎运行值：仍保留段（10 s < 60 s 窗口）
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1)
    }

    /// 刷新设置：保存后持久化，引擎后续节流使用新刷新间隔。
    func testRangeRefreshUpdatePersistsAndAffectsEngine() {
        let controller = makeController()
        controller.updateRangeRefreshSeconds(300)
        XCTAssertEqual(controller.settings.rangeRefreshSeconds, 300)
        XCTAssertEqual(AppSettingsStore(userDefaults: settingsSuite).load().rangeRefreshSeconds, 300)
        // 越界钳制
        controller.updateRangeRefreshSeconds(1)
        XCTAssertEqual(controller.settings.rangeRefreshSeconds, 30)
    }

    /// 权重设置：保存后立即转发引擎；下一次到期混合使用新权重。
    func testRangeWeightsUpdatePersistsAndAppliesToEngine() {
        let controller = makeController()
        controller.startForegroundSession()
        controller.startTrip()

        // 首段：factor1 = distance / 0.1
        bmsProvider.send(snapshot(remainingAh: 10))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(1)
        locationProvider.send(sample(at: t0.addingTimeInterval(1)))
        drainMainQueue()
        bmsProvider.send(snapshot(remainingAh: 9.9))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(11)
        locationProvider.send(sample(at: t0.addingTimeInterval(11), latitude: 0.001))
        drainMainQueue()
        let firstFactor = controller.rangeEstimate.factorKmPerAh ?? 0
        XCTAssertEqual(controller.rangeEstimate.source, .computed)

        // 权重 50/50
        controller.updateRangeWeights(old: 0.5, new: 0.5)
        drainMainQueue()
        XCTAssertEqual(controller.settings.oldRangeWeight, 0.5, accuracy: 1e-9)
        XCTAssertEqual(controller.settings.newRangeWeight, 0.5, accuracy: 1e-9)
        let persisted = AppSettingsStore(userDefaults: settingsSuite).load()
        XCTAssertEqual(persisted.oldRangeWeight, 0.5, accuracy: 1e-9)
        XCTAssertEqual(persisted.newRangeWeight, 0.5, accuracy: 1e-9)

        // 刷新到期（距首次 70 s >= 60 s）：第二段（消耗 0.2 Ah）按 50/50 混合
        bmsProvider.send(snapshot(remainingAh: 9.8))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(81)
        locationProvider.send(sample(at: t0.addingTimeInterval(81), latitude: 0.002))
        drainMainQueue()
        bmsProvider.send(snapshot(remainingAh: 9.6))
        drainMainQueue()
        nowValue = t0.addingTimeInterval(91)
        locationProvider.send(sample(at: t0.addingTimeInterval(91), latitude: 0.003))
        drainMainQueue()

        let stateDistance = controller.rangeEstimate.windowDistanceKm
        let raw2 = stateDistance / 0.3
        let expected = 0.5 * firstFactor + 0.5 * raw2
        XCTAssertEqual(controller.rangeEstimate.factorKmPerAh ?? 0, expected, accuracy: 1e-6)
    }

    // MARK: - 存储警告

    func testCorruptHistoryFileShowsStorageWarningWithoutCrashing() throws {
        try Data("not valid json {{{".utf8).write(to: historyFileURL())

        let controller = makeController()

        XCTAssertNotNil(controller.storageWarning)
        XCTAssertTrue(controller.history.isEmpty)
        // 保存新历史后警告清除
        controller.startForegroundSession()
        controller.startTrip()
        nowValue = t0.addingTimeInterval(1)
        controller.stopTrip()
        XCTAssertNil(controller.storageWarning)
    }
}

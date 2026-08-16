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

/// `RangePoolController` 单元测试：独立收集、生命周期、去抖保存、断连与恢复。
/// 全部注入 Mock 数据源、临时目录与可控时钟；保存调度器改为立即执行。
final class RangePoolControllerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// 0.001° 纬度对应的 haversine 距离（km，R = 6371.0088）
    private let stepKm = 0.001 * 6371.0088 * .pi / 180

    private var tempDirectory: URL!
    private var settingsSuite: UserDefaults!
    private var settingsSuiteName: String!
    private var nowValue: Date!
    private var locationProvider: MockLocationProvider!
    private var bmsProvider: MockBmsProvider!
    private var scheduledSaves: [() -> Void] = []

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RangePoolControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let suiteName = "RangePoolControllerTests-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("无法创建 UserDefaults suite")
            return
        }
        settingsSuiteName = suiteName
        settingsSuite = suite
        nowValue = t0
        locationProvider = MockLocationProvider()
        bmsProvider = MockBmsProvider()
        scheduledSaves = []
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
        scheduledSaves = []
    }

    private func makeController() -> RangePoolController {
        RangePoolController(
            locationProvider: locationProvider,
            bmsProvider: bmsProvider,
            poolStore: RangePoolStore(directoryURL: tempDirectory),
            settingsStore: AppSettingsStore(userDefaults: settingsSuite),
            saveScheduler: { [weak self] work in
                self?.scheduledSaves.append(work)
            },
            now: { self.nowValue })
    }

    /// 等待主队列完成 `.receive(on: DispatchQueue.main)` 的异步投递。
    private func drainMainQueue() {
        let drained = expectation(description: "drain main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    private func sample(at date: Date, latitude: Double = 0,
                        speedKmh: Double = 40, accuracy: Double = 5) -> TripLocationSample {
        TripLocationSample(
            timestamp: date, latitude: latitude, longitude: 0,
            speedKmh: speedKmh, horizontalAccuracyMeters: accuracy)
    }

    private func snapshot(remainingAh: Double, connected: Bool = true, updatedAt: Date? = nil) -> BmsSnapshot {
        var snapshot = BmsSnapshot()
        snapshot.isConnected = connected
        snapshot.remainingChargeAh = remainingAh
        snapshot.lastUpdatedAt = updatedAt
        return snapshot
    }

    private func sendQualifiedPair() {
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
    }

    // MARK: - 独立收集

    /// 不调用 startTrip：前台两段合格快照即产生综合因子（AE1）。
    func testProducesFactorWithoutStartingTrip() {
        let controller = makeController()
        controller.startForegroundSession()
        sendQualifiedPair()

        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1)
        XCTAssertEqual(controller.rangeEstimate.source, .computed)
        XCTAssertNotNil(controller.rangeEstimate.factorKmPerAh)
    }

    /// 未激活前台时不收集遥测：无综合分段（segmentCount 0），
    /// 但 BMS 有效容量仍使手动因子可投影（手动兜底不受前台门控）。
    func testNoCollectionWhenNotForeground() {
        let controller = makeController()
        // 不调用 startForegroundSession
        sendQualifiedPair()
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 0)
        XCTAssertEqual(controller.rangeEstimate.source, .manual)
        XCTAssertEqual(controller.rangeEstimate.estimatedRangeKm ?? 0, 9.9, accuracy: 1e-6,
                       "默认手动因子 1.0 × 最新有效容量 9.9")
    }

    // MARK: - 生命周期

    /// 退后台 flush 未落盘状态并清基线；恢复后首样本不造段（R2/AE8）。
    func testStopForegroundFlushesAndClearsBaseline() {
        let controller = makeController()
        controller.startForegroundSession()
        sendQualifiedPair()
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1)

        // 退后台：flush 立即落盘
        controller.stopForegroundSession()
        let fileURL = tempDirectory.appendingPathComponent("range-computation-pool.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // 恢复前台：首样本只建立基线
        controller.startForegroundSession()
        nowValue = t0.addingTimeInterval(21)
        locationProvider.send(sample(at: t0.addingTimeInterval(21), latitude: 0.002))
        drainMainQueue()
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1, "恢复后首样本不得造段")

        // 第二样本（与首样本间隔 10 s）：造段
        nowValue = t0.addingTimeInterval(31)
        locationProvider.send(sample(at: t0.addingTimeInterval(31), latitude: 0.003))
        drainMainQueue()
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 2)
    }

    /// 去抖保存只调度一次：连续状态变化合并为一次 flush。
    func testDebouncedSaveSchedulesOnce() {
        let controller = makeController()
        controller.startForegroundSession()
        sendQualifiedPair()
        // 两次状态变化只追加一次去抖调度
        XCTAssertEqual(scheduledSaves.count, 1)

        // 执行调度：落盘
        let pending = scheduledSaves
        scheduledSaves.removeAll()
        pending.forEach { $0() }
        let fileURL = tempDirectory.appendingPathComponent("range-computation-pool.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - 断连

    /// BMS 断连：停止为新快照提供有效容量、清基线，但保留已产生因子（R3/AE9）。
    func testDisconnectStopsNewSnapshotsButKeepsFactor() {
        let controller = makeController()
        controller.startForegroundSession()
        sendQualifiedPair()
        XCTAssertEqual(controller.rangeEstimate.source, .computed)

        bmsProvider.send(snapshot(remainingAh: 9.8, connected: false))
        drainMainQueue()
        // 估算仍可投影（因子保留），只是不再有新鲜 Ah 时新快照被拒绝
        XCTAssertEqual(controller.rangeEstimate.source, .computed)

        // 断连后的样本：没有有效剩余容量 → 不造段
        nowValue = t0.addingTimeInterval(41)
        locationProvider.send(sample(at: t0.addingTimeInterval(41), latitude: 0.004))
        drainMainQueue()
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 1)
    }

    // MARK: - 恢复

    /// 新控制器（模拟重启）恢复因子、平均速度、分段与设置 revision（AE8）。
    func testNewControllerRecoversPoolState() {
        let first = makeController()
        first.startForegroundSession()
        sendQualifiedPair()
        first.flushPendingSave()
        let factor = first.rangeEstimate.factorKmPerAh
        let average = first.rangeEstimate.averageEffectiveSpeedKmh
        XCTAssertNotNil(factor)

        // 新控制器从同一目录加载
        let second = makeController()
        XCTAssertEqual(second.rangeEstimate.segmentCount, 1)
        XCTAssertEqual(second.rangeEstimate.factorKmPerAh, factor)
        XCTAssertEqual(second.rangeEstimate.averageEffectiveSpeedKmh, average)

        // 重启后首条快照不跨重启造段
        second.startForegroundSession()
        nowValue = t0.addingTimeInterval(51)
        locationProvider.send(sample(at: t0.addingTimeInterval(51), latitude: 0.005))
        drainMainQueue()
        XCTAssertEqual(second.rangeEstimate.segmentCount, 1)
    }

    // MARK: - 告警

    /// 池文件损坏：显示 range warning，池为空，不崩溃；BLE/行程不受影响。
    func testCorruptPoolFileShowsWarningWithoutCrashing() throws {
        try Data("corrupt {{{".utf8)
            .write(to: tempDirectory.appendingPathComponent("range-computation-pool.json"))

        let controller = makeController()
        XCTAssertNotNil(controller.rangeStorageWarning)
        XCTAssertEqual(controller.rangeEstimate.segmentCount, 0)
        // 保存新状态后警告清除（flush 成功）
        controller.startForegroundSession()
        sendQualifiedPair()
        controller.flushPendingSave()
        XCTAssertNil(controller.rangeStorageWarning)
    }
}

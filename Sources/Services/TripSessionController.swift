import Combine
import Foundation

/// 轮询间隔设置委托：行程会话控制器将设置变更转发给真实蓝牙服务；
/// 测试注入 Mock，避免创建真实 CoreBluetooth 栈。
protocol PollingIntervalSettable: AnyObject {
    func setPollingInterval(_ milliseconds: Int)
}

/// `BmsBluetoothService` 已实现 `setPollingInterval(_:)`，此处仅声明协议一致性。
extension BmsBluetoothService: PollingIntervalSettable {}

/// 前台行程会话控制器：行程记录 / 历史持久化 / 续航估算镜像 / 设置的 facade。
///
/// 职责（对齐 `docs/MIGRATION_PLAN.md`「行程只在活跃场景下记录」与
/// 独立续航池设计）：
/// - 订阅 `LocationSampleProviding` 位置采样流与 `BmsSnapshotProviding` 快照流，
///   将接受的采样以最新剩余容量/实时功率富化后交给 `TripRecorder`；
/// - **续航估算不再由本类计算**：注入单一 `RangePoolController`，镜像其
///   `rangeEstimate` / `rangeStorageWarning` 为既有公开属性，保持 Dashboard、
///   Trips、BMS Detail 与 Settings 的调用面稳定；行程 start/stop/delete/clear
///   不影响续航池（R1/R14）；
/// - 续航设置（手动因子/窗口/刷新/权重/有效速度阈值）继续持久化 `AppSettings`，
///   保存后立即转发给 `RangePoolController` 生效（R9）；
/// - 设置变更立即持久化，轮询间隔转发到 `PollingIntervalSettable`
///   （初始化时加载的持久化值也会应用一次）；
/// - 生命周期：前台恢复记录时钟，退后台暂停并保存历史，**不**自动结束进行中
///   的行程；续航池生命周期由同一 `ForegroundSessionService` 驱动（幂等）。
final class TripSessionController: ObservableObject, ForegroundSessionService {
    // MARK: - 对外状态（@Published，UI 订阅）

    /// 是否正在记录行程。
    @Published private(set) var isRecording = false
    /// 已归档行程历史（新 → 旧）。
    @Published private(set) var history: [TripRecord] = []
    /// 当前行程累计距离（km）。
    @Published private(set) var currentDistanceKm: Double = 0
    /// 当前行程前台激活累计时长（s，实时增量）。
    @Published private(set) var currentDurationSeconds: TimeInterval = 0
    /// 当前行程平均速度（km/h）= 距离 / 前台时长。
    @Published private(set) var currentAverageSpeedKmh: Double = 0
    /// 最近一次续航估算（镜像 `RangePoolController`；无数据时 `.unavailable`）。
    @Published private(set) var rangeEstimate = RangeEstimate(
        factorKmPerAh: nil, source: .unavailable, estimatedRangeKm: nil,
        segmentCount: 0, windowDistanceKm: 0, windowConsumedAh: 0)
    /// 当前设置（变更即持久化）。
    @Published private(set) var settings: AppSettings
    /// 行程历史存储警告（加载/保存失败时非 nil，供 UI 提示；非致命）。
    @Published private(set) var storageWarning: String?
    /// 续航池存储警告（镜像 `RangePoolController`；与行程历史警告独立）。
    @Published private(set) var rangeStorageWarning: String?

    // MARK: - 依赖

    private let recorder: TripRecorder
    private let tripStore: TripStore
    /// 独立续航池控制器（注入单一实例；nil 时内部创建用于预览/测试）。
    private let rangePool: RangePoolController
    private let settingsStore: AppSettingsStore
    private let locationProvider: LocationSampleProviding?
    private let bmsProvider: BmsSnapshotProviding?
    private let pollingIntervalTarget: PollingIntervalSettable?
    private let now: () -> Date
    private var cancellables: Set<AnyCancellable> = []
    /// 最新 BMS 剩余容量（Ah；断开/无效时为 nil，断开快照立即失效）。
    private var latestRemainingAh: Double?
    /// 最新 BMS 实时功率（W；未连接时为 nil）。
    private var latestPowerW: Double?

    /// - Parameters:
    ///   - locationProvider: 位置采样流（生产：`LocationService`；nil 用于预览）。
    ///   - bmsProvider: 快照流（生产：`BmsBluetoothService`；nil 用于预览）。
    ///   - pollingIntervalTarget: 轮询间隔委托（生产：`BmsBluetoothService`）。
    ///   - rangePool: 独立续航池控制器（生产：组合根注入单一实例；nil 时内部
    ///     创建共享相同 provider 的实例，便于测试/预览）。
    ///   - rangePoolStore: 内部创建续航池时使用的存储（测试注入临时目录；
    ///     仅当 `rangePool == nil` 时生效）。
    ///   - tripStore: 历史持久化（默认 Application Support，不可用时临时目录兜底）。
    ///   - settingsStore: 设置持久化（默认 UserDefaults.standard）。
    ///   - now: 时钟注入（测试确定性；默认 `Date.init`）。
    init(
        locationProvider: LocationSampleProviding? = nil,
        bmsProvider: BmsSnapshotProviding? = nil,
        pollingIntervalTarget: PollingIntervalSettable? = nil,
        rangePool: RangePoolController? = nil,
        rangePoolStore: RangePoolStore? = nil,
        tripStore: TripStore = TripStore()
            ?? TripStore(directoryURL: FileManager.default.temporaryDirectory),
        settingsStore: AppSettingsStore = AppSettingsStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.locationProvider = locationProvider
        self.bmsProvider = bmsProvider
        self.pollingIntervalTarget = pollingIntervalTarget
        self.tripStore = tripStore
        self.settingsStore = settingsStore
        self.now = now
        self.recorder = TripRecorder(now: now)
        let loaded = settingsStore.load()
        self.settings = loaded
        // 注入或内部创建独立续航池（共享同一 Location/BMS 实例，不新建数据源）。
        let pool: RangePoolController
        if let rangePool {
            pool = rangePool
        } else {
            pool = RangePoolController(
                locationProvider: locationProvider,
                bmsProvider: bmsProvider,
                poolStore: rangePoolStore ?? RangePoolStore()
                    ?? RangePoolStore(directoryURL: FileManager.default.temporaryDirectory),
                settingsStore: settingsStore,
                now: now)
        }
        self.rangePool = pool
        // 将持久化续航设置同步到池服务（幂等；阈值 revision 由池内部初始化，
        // 此处不递增，避免恢复时误判为阈值变更）。
        pool.updateRangeConfiguration(
            windowSeconds: loaded.rangeWindowSeconds,
            oldWeight: loaded.oldRangeWeight,
            newWeight: loaded.newRangeWeight)
        pool.updateRangeRefreshSeconds(loaded.rangeRefreshSeconds)
        pool.updateManualRangeFactor(loaded.manualRangeKmPerAh)
        let loadResult = tripStore.load()
        self.history = loadResult.history
        self.storageWarning = loadResult.failure.map(Self.warningText(for:))
        // 所有存储设置加载完成后，将持久化轮询间隔应用到真实蓝牙服务（恰好一次；
        // 此后仅通过 `updatePollingInterval` 转发变更），再开始订阅/UI 交互。
        pollingIntervalTarget?.setPollingInterval(loaded.pollingIntervalMilliseconds)
        bindPublishers()
    }

    // MARK: - 行程控制（不影响续航池）

    /// 显式开始一段行程（幂等；未在前台时时钟不启动）。
    func startTrip() {
        recorder.start()
        refreshDerived()
    }

    /// 显式结束当前行程：归档到历史并持久化（幂等；未开始时为空操作）。
    func stopTrip(name: String = "") {
        guard let record = recorder.stop(name: name) else { return }
        history.insert(record, at: 0)
        persistHistory()
        refreshDerived()
    }

    /// 删除单条历史（立即持久化）。
    func deleteTrip(id: UUID) {
        history.removeAll { $0.id == id }
        persistHistory()
    }

    /// 批量删除历史（立即持久化）。
    func deleteTrips(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        history.removeAll { ids.contains($0.id) }
        persistHistory()
    }

    /// 清空全部历史（立即持久化；已为空时无副作用）。
    func clearTrips() {
        guard !history.isEmpty else { return }
        history.removeAll()
        persistHistory()
    }

    // MARK: - 设置（变更即持久化；经 AppSettings 构造钳制；续航设置转发池服务）

    /// 更新轮询间隔：钳制 → 持久化 → 委托真实蓝牙服务。
    func updatePollingInterval(_ milliseconds: Int) {
        var updated = settings
        updated.pollingIntervalMilliseconds = PollInterval.clamped(milliseconds)
        settings = updated
        settingsStore.save(updated)
        pollingIntervalTarget?.setPollingInterval(updated.pollingIntervalMilliseconds)
    }

    /// 更新手动续航系数（km/Ah）：持久化并转发池服务作为兜底因子。
    func updateManualRangeFactor(_ factorKmPerAh: Double) {
        var updated = settings
        updated.manualRangeKmPerAh = min(max(factorKmPerAh, AppSettings.minimumManualRangeKmPerAh),
                                         AppSettings.maximumManualRangeKmPerAh)
        settings = updated
        settingsStore.save(updated)
        rangePool.updateManualRangeFactor(updated.manualRangeKmPerAh)
    }

    func updateRangeDisplayMode(_ mode: RangeDisplayMode) {
        var updated = settings
        updated.rangeDisplayMode = mode
        commitSettings(updated)
    }

    func updateBackgroundTrackingEnabled(_ enabled: Bool) {
        var updated = settings
        updated.backgroundTrackingEnabled = enabled
        commitSettings(updated)
    }

    /// 更新有效速度阈值（km/h）：钳制持久化，转发池服务（阈值变更递增
    /// revision、清 transient baseline，不清已持久化池）。
    func updateEffectiveSpeed(_ speedKmh: Double) {
        var updated = settings
        updated.effectiveSpeedKmh = min(max(speedKmh, AppSettings.minimumEffectiveSpeedKmh),
                                        AppSettings.maximumEffectiveSpeedKmh)
        settings = updated
        settingsStore.save(updated)
        rangePool.updateEffectiveSpeed(updated.effectiveSpeedKmh)
    }

    func updateRangeWindowSeconds(_ seconds: Int) {
        var updated = settings
        updated.rangeWindowSeconds = min(max(seconds, AppSettings.minimumRangeWindowSeconds),
                                         AppSettings.maximumRangeWindowSeconds)
        commitSettings(updated)
        rangePool.updateRangeConfiguration(
            windowSeconds: updated.rangeWindowSeconds,
            oldWeight: updated.oldRangeWeight,
            newWeight: updated.newRangeWeight)
    }

    func updateRangeRefreshSeconds(_ seconds: Int) {
        var updated = settings
        updated.rangeRefreshSeconds = min(max(seconds, AppSettings.minimumRangeRefreshSeconds),
                                          AppSettings.maximumRangeRefreshSeconds)
        commitSettings(updated)
        rangePool.updateRangeRefreshSeconds(updated.rangeRefreshSeconds)
    }

    func updateRangeWeights(old: Double, new: Double) {
        var updated = settings
        let clampedOld = min(max(old, 0), 1)
        let clampedNew = min(max(new, 0), 1)
        let total = clampedOld + clampedNew
        updated.oldRangeWeight = total > 0 ? clampedOld / total : 0.7
        updated.newRangeWeight = total > 0 ? clampedNew / total : 0.3
        commitSettings(updated)
        rangePool.updateRangeConfiguration(
            windowSeconds: updated.rangeWindowSeconds,
            oldWeight: updated.oldRangeWeight,
            newWeight: updated.newRangeWeight)
    }

    func updateHomeAuxiliaryTextEnabled(_ enabled: Bool) {
        var updated = settings
        updated.homeAuxiliaryTextEnabled = enabled
        commitSettings(updated)
    }

    func updateDashboardDensity(_ density: DashboardDensity) {
        var updated = settings
        updated.dashboardDensity = density
        commitSettings(updated)
    }

    func updateTemperatureSource(_ source: TemperatureSource) {
        var updated = settings
        updated.temperatureSource = source
        commitSettings(updated)
    }

    func updateScreenOrientation(_ orientation: ScreenOrientationPreference) {
        var updated = settings
        updated.screenOrientation = orientation
        commitSettings(updated)
    }

    func updateAppearance(_ appearance: AppearancePreference) {
        var updated = settings
        updated.appearance = appearance
        commitSettings(updated)
    }

    func updateRecordingCapacityLimit(_ limit: RecordingCapacityLimit) {
        var updated = settings
        updated.recordingCapacityLimit = limit
        commitSettings(updated)
    }

    func updateThresholds(
        powerYellow: Double? = nil,
        powerRed: Double? = nil,
        socYellow: Double? = nil,
        socRed: Double? = nil,
        voltageYellow: Double? = nil,
        voltageRed: Double? = nil,
        temperatureYellow: Double? = nil,
        temperatureRed: Double? = nil
    ) {
        var updated = settings
        if let powerYellow {
            updated.powerYellowThresholdWatts = min(max(powerYellow, 0), 100_000)
            updated.powerRedThresholdWatts = max(updated.powerRedThresholdWatts, updated.powerYellowThresholdWatts)
        }
        if let powerRed {
            updated.powerRedThresholdWatts = min(max(powerRed, updated.powerYellowThresholdWatts), 100_000)
        }
        if let socYellow {
            updated.socYellowThreshold = min(max(socYellow, 0), 100)
            updated.socRedThreshold = min(updated.socRedThreshold, updated.socYellowThreshold)
        }
        if let socRed { updated.socRedThreshold = min(max(socRed, 0), updated.socYellowThreshold) }
        if let voltageYellow {
            updated.voltageDiffYellowMillivolts = min(max(voltageYellow, 0), 1_000)
            updated.voltageDiffRedMillivolts = max(updated.voltageDiffRedMillivolts, updated.voltageDiffYellowMillivolts)
        }
        if let voltageRed {
            updated.voltageDiffRedMillivolts = min(max(voltageRed, updated.voltageDiffYellowMillivolts), 1_000)
        }
        if let temperatureYellow {
            updated.temperatureYellowCelsius = min(max(temperatureYellow, -40), 150)
            updated.temperatureRedCelsius = max(updated.temperatureRedCelsius, updated.temperatureYellowCelsius)
        }
        if let temperatureRed {
            updated.temperatureRedCelsius = min(max(temperatureRed, updated.temperatureYellowCelsius), 150)
        }
        commitSettings(updated)
    }

    // MARK: - 前台生命周期（ForegroundSessionService，幂等）

    /// 前台激活：恢复记录时钟（进行中的行程仅暂停，不结束）；续航池重建基线。
    func startForegroundSession() {
        recorder.setForegroundActive(true)
        rangePool.startForegroundSession()
        refreshDerived()
    }

    /// 退前台/后台：暂停记录时钟并立即保存历史；续航池 flush 并清基线；
    /// **不**自动结束进行中的行程。
    func stopForegroundSession() {
        recorder.setForegroundActive(false)
        rangePool.stopForegroundSession()
        persistHistory()
        refreshDerived()
    }

    // MARK: - 订阅（统一在主队列交付）

    private func bindPublishers() {
        locationProvider?.samplePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in self?.handleLocationSample(sample) }
            .store(in: &cancellables)
        bmsProvider?.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in self?.handleSnapshot(snapshot) }
            .store(in: &cancellables)
        // 镜像独立续航池估算与告警（UI 调用面保持 `tripSession.rangeEstimate`）。
        rangePool.$rangeEstimate
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] estimate in self?.rangeEstimate = estimate }
            .store(in: &cancellables)
        rangePool.$rangeStorageWarning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] warning in self?.rangeStorageWarning = warning }
            .store(in: &cancellables)
    }

    private func handleLocationSample(_ sample: TripLocationSample) {
        // 行程记录只由 TripRecorder 自校验；续航入池由 RangePoolController
        // 独立订阅同一采样流处理，此处不重复构造分段。
        recorder.record(enrichedSample(from: sample))
        refreshDerived()
    }

    private func handleSnapshot(_ snapshot: BmsSnapshot) {
        // 断开快照即使保留非零遥测也视为无有效数据：剩余容量立即失效，
        // 不再富化后续采样（功率同样门控连接状态）；续航池由 RangePoolController
        // 独立处理断连语义。0 Ah（耗尽）是有效容量（Android 准入一致）。
        latestRemainingAh = snapshot.isConnected
            && snapshot.remainingChargeAh.isFinite
            && snapshot.remainingChargeAh >= 0
            ? snapshot.remainingChargeAh : nil
        latestPowerW = snapshot.isConnected ? snapshot.displayPower() : nil
    }

    // MARK: - 富化

    /// 用最新 BMS 值富化纯位置采样（BMS 可选字段由控制器统一填充）。
    private func enrichedSample(from sample: TripLocationSample) -> TripLocationSample {
        TripLocationSample(
            timestamp: sample.timestamp,
            latitude: sample.latitude,
            longitude: sample.longitude,
            speedKmh: sample.speedKmh,
            horizontalAccuracyMeters: sample.horizontalAccuracyMeters,
            remainingAh: latestRemainingAh,
            powerW: latestPowerW)
    }

    // MARK: - 派生刷新 / 持久化

    private func refreshDerived() {
        isRecording = recorder.isRecording
        currentDistanceKm = recorder.distanceKm
        currentDurationSeconds = recorder.currentDurationSeconds(at: now())
        let durationHours = currentDurationSeconds / 3600
        currentAverageSpeedKmh = durationHours > 0 ? currentDistanceKm / durationHours : 0
    }

    private func persistHistory() {
        do {
            try tripStore.save(history)
            storageWarning = nil
        } catch {
            storageWarning = "行程历史保存失败"
        }
    }

    private func commitSettings(_ updated: AppSettings) {
        settings = updated
        settingsStore.save(updated)
    }

    private static func warningText(for failure: TripStore.LoadFailure) -> String {
        switch failure {
        case .unreadable: return "行程历史无法读取，本次会话从空历史开始"
        case .decodingFailed: return "行程历史文件损坏，已从空历史开始"
        }
    }
}

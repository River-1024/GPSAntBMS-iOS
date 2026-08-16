import Combine
import Foundation

/// 独立综合续航计算池控制器（与 Android `MainActivity` 的 RangePool 接入对齐）。
///
/// 职责：
/// - **独立收集**：直接订阅既有 `LocationSampleProviding` 与 `BmsSnapshotProviding`
///   publisher，构造 `RangeTelemetrySnapshot` 喂给引擎；不调用也不依赖
///   `TripRecorder.record()` / `startTrip()` / `stopTrip()`，行程生命周期不清池；
/// - **恢复**：初始化时加载 `AppSettings` → 加载 `RangePoolStore` → 构造引擎并
///   恢复 `RangePoolState`；transient previous snapshot 不持久化，重启后首个
///   快照只建立基线；
/// - **生命周期**：实现 `ForegroundSessionService`；退前台停止接收并 flush 池，
///   清 transient baseline（不清 pool/factor）；回前台重新建立基线；
/// - **持久化**：状态变化后 5 秒去抖保存（调度器可注入）；前台停止、显式 flush
///   立即落盘；保存/加载失败只更新独立的 range storage warning，不阻断 BMS/行程；
/// - **断连**：BMS 断开时立即停止为新快照提供有效容量并清基线，已产生因子保留。
final class RangePoolController: ObservableObject, ForegroundSessionService {
    // MARK: - 对外状态

    /// 最近一次续航估算（镜像引擎只读投影）。
    @Published private(set) var rangeEstimate = RangeEstimate(
        factorKmPerAh: nil, source: .unavailable, estimatedRangeKm: nil,
        segmentCount: 0, windowDistanceKm: 0, windowConsumedAh: 0)
    /// 续航池存储警告（加载/保存失败时非 nil；与行程历史警告独立）。
    @Published private(set) var rangeStorageWarning: String?

    // MARK: - 依赖

    private var rangeEngine: RangeComputationEngine
    private let poolStore: RangePoolStore
    private let locationProvider: LocationSampleProviding?
    private let bmsProvider: BmsSnapshotProviding?
    private let now: () -> Date
    private var cancellables: Set<AnyCancellable> = []
    /// 最新 BMS 剩余容量（Ah；断开/无效时为 nil）。
    private var latestRemainingAh: Double?
    /// 最新 BMS 剩余容量更新时间（Ah 新鲜度基准）。
    private var latestRemainingAhUpdatedAt: Date?
    /// 当前有效速度阈值（km/h），来自设置。
    private var effectiveSpeedKmh: Double
    /// 当前刷新间隔（秒）。
    private var refreshSeconds: Int
    /// 设置 revision（阈值变更递增）。
    private var settingsRevision: Int64
    /// 前台会话是否激活。
    private var isForegroundActive = false
    /// 最近一次保存是否失败（用于成功后清除告警，避免依赖展示文案）。
    private var saveFailed = false
    /// 加载是否失败（成功保存新状态后可清除，表示已用当前 schema 覆盖损坏文件）。
    private var loadFailed = false
    /// 去抖保存调度器（测试注入记录调用；默认 5 秒主队列延迟）。
    private let saveScheduler: (@escaping () -> Void) -> Void
    private var saveWorkItem: DispatchWorkItem?

    /// - Parameters:
    ///   - locationProvider: 位置采样流（与 TripSessionController 共享同一实例）。
    ///   - bmsProvider: 快照流（与 TripSessionController 共享同一实例）。
    ///   - poolStore: 续航池持久化（默认 Application Support）。
    ///   - settingsStore: 设置存储（初始化读取续航配置）。
    ///   - saveScheduler: 去抖保存调度器；默认 5 秒后主队列执行。
    ///   - now: 时钟注入（测试确定性）。
    init(
        locationProvider: LocationSampleProviding? = nil,
        bmsProvider: BmsSnapshotProviding? = nil,
        poolStore: RangePoolStore = RangePoolStore()
            ?? RangePoolStore(directoryURL: FileManager.default.temporaryDirectory),
        settingsStore: AppSettingsStore = AppSettingsStore(),
        saveScheduler: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.locationProvider = locationProvider
        self.bmsProvider = bmsProvider
        self.poolStore = poolStore
        self.saveScheduler = saveScheduler
        self.now = now

        let settings = settingsStore.load()
        self.effectiveSpeedKmh = settings.effectiveSpeedKmh
        self.refreshSeconds = settings.rangeRefreshSeconds

        // 加载持久化池（缺失→空池；损坏→空池 + 告警，不崩溃）
        let loadResult = poolStore.load()
        let initialState = loadResult.state
        // 以恢复状态的 settingsRevision 为权威（单一来源）：恢复后任何配置变更
        // 都基于该值递增，避免 controller 本地 0 与持久化值不一致导致误清基线。
        self.settingsRevision = initialState.settingsRevision
        self.rangeEngine = RangeComputationEngine(initialState: initialState)
        self.rangeEngine.manualFactorKmPerAh = settings.manualRangeKmPerAh
        if let failure = loadResult.failure {
            self.loadFailed = true
            self.rangeStorageWarning = Self.warningText(for: failure)
        }
        // 恢复后以当前设置为准同步配置（窗口/权重来自设置；revision 保持 0，
        // 避免恢复时误判为阈值变更）
        self.rangeEngine.updateConfiguration(
            targetWindowMinutes: max(settings.rangeWindowSeconds / 60, 1),
            settingsRevision: self.settingsRevision,
            oldWeightPercent: settings.oldRangeWeight * 100,
            newWeightPercent: settings.newRangeWeight * 100,
            now: now())
        refreshEstimate()
        bindPublishers()
    }

    // MARK: - 配置更新（由 TripSessionController 设置变更转发）

    /// 更新窗口/权重（持久化由设置层负责）；窗口缩短立即裁剪并强制重算。
    func updateRangeConfiguration(windowSeconds: Int, oldWeight: Double, newWeight: Double) {
        applyConfiguration(
            targetWindowMinutes: max(windowSeconds / 60, 1),
            settingsRevision: settingsRevision,
            oldWeightPercent: oldWeight * 100,
            newWeightPercent: newWeight * 100)
    }

    /// 有效速度阈值变更：revision +1，清 transient baseline，保留池。
    func updateEffectiveSpeed(_ speedKmh: Double) {
        effectiveSpeedKmh = speedKmh
        settingsRevision += 1
        applyConfiguration(
            targetWindowMinutes: rangeEngine.state.targetWindowMinutes,
            settingsRevision: settingsRevision,
            oldWeightPercent: rangeEngine.state.oldWeightPercent,
            newWeightPercent: rangeEngine.state.newWeightPercent)
    }

    /// 刷新间隔更新：只影响后续节流判断。
    func updateRangeRefreshSeconds(_ seconds: Int) {
        refreshSeconds = seconds
    }

    /// 手动兜底因子更新（由设置层持久化后转发）。
    func updateManualRangeFactor(_ factorKmPerAh: Double) {
        rangeEngine.manualFactorKmPerAh = factorKmPerAh
        refreshEstimate()
    }

    // MARK: - 前台生命周期（ForegroundSessionService，幂等）

    func startForegroundSession() {
        guard !isForegroundActive else { return }
        isForegroundActive = true
        // 回前台：清 transient baseline，首个样本只建立新基线
        rangeEngine.clearBaseline()
    }

    func stopForegroundSession() {
        guard isForegroundActive else { return }
        isForegroundActive = false
        // 停止接收新快照：清基线并 flush 未落盘状态
        rangeEngine.clearBaseline()
        flushPendingSave()
    }

    /// 立即持久化当前池状态（生命周期停止/销毁时调用；失败只更新告警）。
    func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        do {
            try poolStore.save(rangeEngine.state)
            // 成功保存：清除保存失败告警；若此前加载失败（损坏/旧 schema），
            // 本次成功保存已用当前 schema 覆盖文件，一并清除加载告警。
            if saveFailed {
                saveFailed = false
                rangeStorageWarning = nil
            }
            if loadFailed {
                loadFailed = false
                rangeStorageWarning = nil
            }
        } catch {
            saveFailed = true
            rangeStorageWarning = "续航计算池保存失败"
        }
    }

    // MARK: - 订阅

    private func bindPublishers() {
        locationProvider?.samplePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in self?.handleLocationSample(sample) }
            .store(in: &cancellables)
        bmsProvider?.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in self?.handleSnapshot(snapshot) }
            .store(in: &cancellables)
    }

    private func handleLocationSample(_ sample: TripLocationSample) {
        guard isForegroundActive else { return }
        guard let remainingAh = latestRemainingAh else { return }
        let ahUpdatedAt = latestRemainingAhUpdatedAt ?? sample.timestamp
        let snapshot = RangeTelemetrySnapshot(
            timestamp: sample.timestamp,
            speedKmh: sample.speedKmh,
            latitude: sample.latitude,
            longitude: sample.longitude,
            remainingAh: remainingAh,
            remainingAhUpdatedAt: ahUpdatedAt,
            settingsRevision: settingsRevision)
        let before = rangeEngine.state
        rangeEngine.addSnapshot(
            snapshot,
            effectiveSpeedKmh: effectiveSpeedKmh,
            refreshSeconds: refreshSeconds)
        // 仅当池状态实际推进（准入通过）时刷新估算并安排保存；
        // 首样本基线/准入拒绝不产生 Combine 通知与去抖调度 churn。
        if rangeEngine.state != before {
            refreshEstimate()
            scheduleSave()
        }
    }

    private func handleSnapshot(_ snapshot: BmsSnapshot) {
        // 有效容量：已连接、有限且 >= 0（0 Ah = 电量耗尽，仍是有效遥测；
        // 与 Android 准入一致只拒绝负值/非有限值）。断连时清容量与基线。
        let hasValidCapacity = snapshot.isConnected
            && snapshot.remainingChargeAh.isFinite
            && snapshot.remainingChargeAh >= 0
        if hasValidCapacity {
            latestRemainingAh = snapshot.remainingChargeAh
            latestRemainingAhUpdatedAt = snapshot.lastUpdatedAt
        } else {
            // 断开/无效：停止为新快照提供有效容量并清基线（因子与池保留）
            latestRemainingAh = nil
            latestRemainingAhUpdatedAt = nil
            rangeEngine.clearBaseline()
        }
        refreshEstimate()
    }

    // MARK: - 内部

    private func refreshEstimate() {
        let estimate = rangeEngine.estimate(remainingAh: latestRemainingAh)
        if estimate != rangeEstimate {
            rangeEstimate = estimate
        }
    }

    /// 应用引擎配置变更：统一执行更新、估算刷新与去抖保存。
    private func applyConfiguration(
        targetWindowMinutes: Int,
        settingsRevision: Int64,
        oldWeightPercent: Double,
        newWeightPercent: Double
    ) {
        rangeEngine.updateConfiguration(
            targetWindowMinutes: targetWindowMinutes,
            settingsRevision: settingsRevision,
            oldWeightPercent: oldWeightPercent,
            newWeightPercent: newWeightPercent,
            now: now())
        refreshEstimate()
        scheduleSave()
    }

    /// 状态变化后安排 5 秒去抖保存（再次变化会重置计时）。
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingSave()
        }
        saveWorkItem = work
        saveScheduler {
            work.perform()
        }
    }

    private static func warningText(for failure: RangePoolStore.LoadFailure) -> String {
        switch failure {
        case .unreadable: return "续航计算池无法读取，本次会话从空池开始"
        case .emptyFile: return "续航计算池文件为空，已从空池开始"
        case .unsupportedSchema: return "续航计算池版本不支持，已从空池开始"
        case .decodingFailed: return "续航计算池损坏，已从空池开始"
        }
    }
}

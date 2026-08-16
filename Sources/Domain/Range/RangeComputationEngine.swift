import Foundation

/// 剩余续航计算引擎（纯 Swift，仅依赖 Foundation）。
///
/// 与 Android `RangeModels.kt` 的 `RangeComputationEngine` 逐语义对齐：
/// - 输入为 `RangeTelemetrySnapshot` 快照流；`addSnapshot` 只在该快照与上一
///   快照满足全部准入条件时生成分段（不依赖任何手动行程状态）；
/// - 窗口按**累计有效驾驶时长**裁剪（`trimmedToWindow`），边界分段按比例缩放；
/// - 综合因子与平均有效速度按同一旧/新权重与刷新节流规则独立更新
///   （`recalculate`），净消耗不足 0.01 Ah 时保留已有因子；
/// - `estimate` 是只读投影：综合因子一旦产生，不因墙钟时间过去或暂时无新
///   分段而回退为手动值；只有从未产生综合因子时才使用手动因子兜底。
///
/// 引擎不读写文件、不依赖 UIKit/SwiftUI/CoreBluetooth/Combine；持久化由
/// `RangePoolStore` 负责，引擎只持有并转换 `RangePoolState`。
struct RangeComputationEngine {
    // MARK: - Android 对齐常量

    /// 相邻快照最大时间间隔（秒）：超过则拒绝分段
    static let maxTelemetryGapSeconds: TimeInterval = 10
    /// 单段最大距离（km）
    static let maxSegmentDistanceKm = 2.0
    /// 产生新综合因子所需的最低窗口净消耗（Ah）
    static let minTrustedConsumptionAh = 0.01
    /// 浮点比较容差（与 Android `FLOATING_POINT_EPSILON` 一致）
    static let floatingPointEpsilon = 1e-9
    /// 默认窗口（分钟）
    static let defaultWindowMinutes = 15
    /// 默认旧/新权重（百分制）
    static let defaultOldWeightPercent = 70.0
    static let defaultNewWeightPercent = 30.0

    // MARK: - 状态

    /// 当前计算池状态（唯一状态来源；引擎负责状态转换）
    private(set) var state: RangePoolState

    /// transient 上一快照：仅用于相邻快照造段，**永不持久化**。
    /// 设置 revision 变化或 `clearBaseline()` 时清空。
    private var previousSnapshot: RangeTelemetrySnapshot?

    /// 手动兜底因子（km/Ah）；仅在计算因子不可用时使用，且不会污染历史因子
    var manualFactorKmPerAh: Double?

    // MARK: - 初始化

    /// - Parameter initialState: 持久化恢复或空池；内部先 `sanitized()`。
    init(initialState: RangePoolState = .empty()) {
        self.state = initialState.sanitized()
    }

    // MARK: - 快照入池

    /// 接收一条遥测快照；与上一快照满足全部准入条件时生成分段并入池，
    /// 返回更新后的状态。任何拒绝都不改变已有因子与分段。
    ///
    /// 准入（与 Android `toSegment` 对齐）：
    /// - 两端 settings revision 相同；
    /// - 两端瞬时速度有限且**严格大于** `effectiveSpeedKmh`；
    /// - 时间间隔在 (0, 10] 秒；
    /// - 两端剩余 Ah 相对各自 GPS 时间的新鲜度均不超过 10 秒；
    /// - 两端坐标有效、Ah 有限非负；
    /// - haversine 距离有限、> 0 且 ≤ 2 km。
    ///
    /// 净消耗 = 前快照 Ah − 后快照 Ah，允许负值（充电段）参与聚合。
    @discardableResult
    mutating func addSnapshot(
        _ snapshot: RangeTelemetrySnapshot,
        effectiveSpeedKmh: Double,
        refreshSeconds: Int
    ) -> RangePoolState {
        let previous = previousSnapshot
        previousSnapshot = snapshot
        guard let previous else { return state }
        guard let segment = segment(from: previous, to: snapshot, thresholdKmh: effectiveSpeedKmh) else {
            return state
        }
        var updated = state
        updated.segments.append(segment)
        updated = updated.trimmedToWindow()
        state = recalculated(
            from: updated,
            now: snapshot.timestamp,
            refreshInterval: TimeInterval(max(refreshSeconds, 0)),
            force: false)
        return state
    }

    /// 运行时配置更新（窗口/权重/阈值 revision）。与 Android `updateConfiguration` 对齐：
    /// - revision 变化：清空 transient previous snapshot（不整体丢池）；
    /// - 窗口缩短：立即裁剪并强制重算；窗口变长或不变：仅裁剪；
    /// - 权重/刷新设置只影响后续计算。
    @discardableResult
    mutating func updateConfiguration(
        targetWindowMinutes: Int,
        settingsRevision: Int64,
        oldWeightPercent: Double,
        newWeightPercent: Double,
        now: Date
    ) -> RangePoolState {
        if settingsRevision != state.settingsRevision {
            previousSnapshot = nil
        }
        let previousWindowMinutes = state.targetWindowMinutes
        var configured = state
        configured.targetWindowMinutes = max(targetWindowMinutes, 1)
        configured.settingsRevision = max(settingsRevision, 0)
        configured.oldWeightPercent = oldWeightPercent
        configured.newWeightPercent = newWeightPercent
        configured = configured.trimmedToWindow()
        state = if configured.targetWindowMinutes < previousWindowMinutes {
            recalculated(from: configured, now: now, refreshInterval: 0, force: true)
        } else {
            configured
        }
        return state
    }

    /// 清空 transient previous baseline（前后台切换、BMS 断连后调用）。
    mutating func clearBaseline() {
        previousSnapshot = nil
    }

    // MARK: - 估算投影

    /// 只读投影估算剩余续航，不修改任何状态。
    ///
    /// - 综合因子取自池状态（`mileageFactorKmPerAh`），不因墙钟过期而清除；
    /// - 仅当综合因子从未产生时才回退手动因子（`source == .manual`）；
    /// - `remainingAh` 为有限非负数时估算值 = 因子 × remainingAh，否则为 nil。
    func estimate(remainingAh: Double?) -> RangeEstimate {
        let pool = state
        let computedFactor = pool.mileageFactorKmPerAh.flatMap { value in
            value.isFinite && value > 0.0 ? value : nil
        }
        let manualFactor = manualFactorKmPerAh.flatMap { value in
            value.isFinite && value > 0.0 ? value : nil
        }
        let computedRangeKm = computedFactor.flatMap { estimatedRange(factor: $0, remainingAh: remainingAh) }
        let manualRangeKm = manualFactor.flatMap { estimatedRange(factor: $0, remainingAh: remainingAh) }

        var factor: Double?
        var source: RangeFactorSource = .unavailable
        if let computedFactor {
            factor = computedFactor
            source = .computed
        } else if let manual = manualFactor {
            factor = manual
            source = .manual
        }

        // 选中因子的投影直接复用已计算分支（computed 优先，与 source 选择一致）
        let rangeKm = computedFactor != nil ? computedRangeKm : manualRangeKm
        return RangeEstimate(
            factorKmPerAh: factor,
            source: source,
            estimatedRangeKm: rangeKm,
            segmentCount: pool.segments.count,
            windowDistanceKm: pool.sourceDistanceKm,
            windowConsumedAh: pool.sourceNetConsumedAh,
            computedFactorKmPerAh: computedFactor,
            computedEstimatedRangeKm: computedRangeKm,
            manualFactorKmPerAh: manualFactor,
            manualEstimatedRangeKm: manualRangeKm,
            averageEffectiveSpeedKmh: pool.averageEffectiveSpeedKmh,
            poolValidDurationSeconds: pool.validDurationSeconds,
            mileageFactorUpdatedAt: pool.mileageFactorUpdatedAt
        )
    }

    // MARK: - 私有：准入 / 聚合 / 重算

    /// 相邻快照 → 分段；任一准入条件不满足返回 nil（不改变状态）。
    private func segment(
        from previous: RangeTelemetrySnapshot,
        to current: RangeTelemetrySnapshot,
        thresholdKmh: Double
    ) -> RangeSegment? {
        if previous.settingsRevision != current.settingsRevision { return nil }
        if !previous.speedKmh.isFinite || !current.speedKmh.isFinite { return nil }
        if previous.speedKmh <= thresholdKmh || current.speedKmh <= thresholdKmh { return nil }

        let duration = current.timestamp.timeIntervalSince(previous.timestamp)
        guard duration > 0, duration <= Self.maxTelemetryGapSeconds else { return nil }

        if !previous.hasFreshAhAtGpsTime() || !current.hasFreshAhAtGpsTime() { return nil }
        if !previous.hasValidCoordinates() || !current.hasValidCoordinates() { return nil }
        if !previous.remainingAh.isFinite || !current.remainingAh.isFinite { return nil }
        if previous.remainingAh < 0 || current.remainingAh < 0 { return nil }

        let distance = Self.haversineKm(
            lat1: previous.latitude, lon1: previous.longitude,
            lat2: current.latitude, lon2: current.longitude)
        guard distance.isFinite, distance > 0, distance <= Self.maxSegmentDistanceKm else { return nil }

        let hours = duration / 3600
        return RangeSegment(
            startedAt: previous.timestamp,
            endedAt: current.timestamp,
            duration: duration,
            distanceKm: distance,
            netConsumedAh: previous.remainingAh - current.remainingAh,
            averageSpeedKmh: distance / hours,
            admissionThresholdKmh: thresholdKmh)
    }

    private func estimatedRange(factor: Double, remainingAh: Double?) -> Double? {
        guard let remainingAh, remainingAh.isFinite, remainingAh >= 0.0 else { return nil }
        return factor * remainingAh
    }

    /// 与 Android `recalculate` 对齐：分别对综合因子与平均有效速度做刷新
    /// 到期判断；净消耗不足 `minTrustedConsumptionAh` 时保留旧因子。
    private func recalculated(
        from pool: RangePoolState,
        now: Date,
        refreshInterval: TimeInterval,
        force: Bool
    ) -> RangePoolState {
        let aggregate = pool.withAggregates()
        let weights = aggregate.normalizedWeights()

        // 平均有效速度：raw = 距离 / 有效时长折算小时
        let averageDue = force || isRefreshDue(lastUpdatedAt: aggregate.averageSpeedUpdatedAt, now: now, refreshInterval: refreshInterval)
        let rawAverage: Double? = {
            guard aggregate.validDurationSeconds > 0, aggregate.sourceDistanceKm > 0 else { return nil }
            return aggregate.sourceDistanceKm / (aggregate.validDurationSeconds / 3600)
        }()
        let nextAverage: Double? = {
            if averageDue, let rawAverage {
                if let prior = aggregate.averageEffectiveSpeedKmh {
                    return prior * weights.old + rawAverage * weights.new
                }
                return rawAverage
            }
            return aggregate.averageEffectiveSpeedKmh
        }()

        // 综合因子：raw = 距离 / 净消耗；净消耗低于门槛不产生新因子
        let factorDue = force || isRefreshDue(lastUpdatedAt: aggregate.mileageFactorUpdatedAt, now: now, refreshInterval: refreshInterval)
        let rawFactor: Double? = {
            guard aggregate.sourceDistanceKm > 0 else { return nil }
            guard aggregate.sourceNetConsumedAh + Self.floatingPointEpsilon >= Self.minTrustedConsumptionAh else {
                return nil
            }
            return aggregate.sourceDistanceKm / aggregate.sourceNetConsumedAh
        }()
        let nextFactor: Double? = {
            if factorDue, let rawFactor {
                if let prior = aggregate.mileageFactorKmPerAh {
                    return prior * weights.old + rawFactor * weights.new
                }
                return rawFactor
            }
            return aggregate.mileageFactorKmPerAh
        }()

        var updated = aggregate
        updated.mileageFactorKmPerAh = nextFactor
        updated.averageEffectiveSpeedKmh = nextAverage
        if factorDue, rawFactor != nil {
            updated.mileageFactorUpdatedAt = now
        }
        if averageDue, rawAverage != nil {
            updated.averageSpeedUpdatedAt = now
        }
        return updated
    }

    /// 刷新到期判断：从未更新（nil）或距上次更新已达刷新间隔即视为到期。
    private func isRefreshDue(lastUpdatedAt: Date?, now: Date, refreshInterval: TimeInterval) -> Bool {
        guard let lastUpdatedAt else { return true }
        return now.timeIntervalSince(lastUpdatedAt) >= refreshInterval
    }
}

// MARK: - 快照校验扩展

private extension RangeTelemetrySnapshot {
    /// Ah 新鲜度：GPS 时间与 Ah 更新时间间隔在 [0, 10] 秒内（Android `hasFreshAhAtGpsTime`）。
    func hasFreshAhAtGpsTime() -> Bool {
        let gap = timestamp.timeIntervalSince(remainingAhUpdatedAt)
        return gap >= 0 && gap <= RangeComputationEngine.maxTelemetryGapSeconds
    }

    /// 坐标有效性：有限且在合法范围（Android `hasValidCoordinates`）。
    func hasValidCoordinates() -> Bool {
        latitude.isFinite && longitude.isFinite
            && latitude >= -90 && latitude <= 90
            && longitude >= -180 && longitude <= 180
    }
}

// MARK: - Haversine

extension RangeComputationEngine {
    /// haversine 距离（km）；与 Android `RangeModels.kt` 一致（R = 6371.0088）。
    static func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadiusKm = 6371.0088
        let lat1Rad = lat1 * .pi / 180
        let lat2Rad = lat2 * .pi / 180
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1Rad) * cos(lat2Rad) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * asin(sqrt(min(max(a, 0), 1)))
        return earthRadiusKm * c
    }
}

import Foundation

// MARK: - 遥测快照

/// 一条续航遥测快照（与 Android `RangeTelemetrySnapshot` 逐字段对齐）。
///
/// 由控制器从前台 Location/BMS 流构造；准入校验（两端瞬时速度、时间间隔、
/// Ah 新鲜度、坐标/距离合法性）由引擎在 `addSnapshot` 中完成，本层不关心
/// 来源细节与持久化。
struct RangeTelemetrySnapshot: Equatable {
    /// GPS 时间
    let timestamp: Date

    /// 瞬时速度（km/h）
    let speedKmh: Double

    /// 纬度（度）
    let latitude: Double

    /// 经度（度）
    let longitude: Double

    /// BMS 剩余容量（Ah）
    let remainingAh: Double

    /// 剩余 Ah 的更新时间（新鲜度校验基准，须不早于 GPS 时间）
    let remainingAhUpdatedAt: Date

    /// 设置 revision（阈值变更后 +1；跨 revision 不造段）
    let settingsRevision: Int64
}

// MARK: - 分段

/// 一段已通过准入校验的续航分段（引擎状态的一部分，可持久化）。
///
/// 与 Android `RangeSegment` 对齐：`netConsumedAh` 允许负值（充电段），
/// `duration` 必须等于 `endedAt - startedAt`，`admissionThresholdKmh` 记录
/// 该分段准入时使用的有效速度阈值。
struct RangeSegment: Codable, Equatable {
    /// 分段开始时间
    let startedAt: Date

    /// 分段结束时间（窗口裁剪的基准）
    let endedAt: Date

    /// 分段时长（秒），必须为有限正数且等于 `endedAt - startedAt`
    let duration: TimeInterval

    /// 分段里程（km），必须为有限正数且不超过 2 km
    let distanceKm: Double

    /// 分段净消耗（Ah）= 前快照 Ah − 后快照 Ah；充电段为负值，允许入池
    let netConsumedAh: Double

    /// 分段平均速度（km/h），必须为有限值且严格大于准入阈值
    let averageSpeedKmh: Double

    /// 该分段准入时使用的有效速度阈值（km/h）
    let admissionThresholdKmh: Double
}

extension RangeSegment {
    /// 持久化/恢复校验：时间一致性、距离/速度/阈值/消耗有限合法。
    /// 与 Android `RangeSegment.isValid()` 对齐；负 `netConsumedAh` 合法。
    var isValid: Bool {
        guard startedAt.timeIntervalSince1970 >= 0 else { return false }
        guard endedAt > startedAt else { return false }
        let actualDuration = endedAt.timeIntervalSince(startedAt)
        guard duration.isFinite, abs(duration - actualDuration) < 1e-6 else { return false }
        guard distanceKm.isFinite, distanceKm > 0,
              distanceKm <= RangeComputationEngine.maxSegmentDistanceKm else { return false }
        guard netConsumedAh.isFinite else { return false }
        guard averageSpeedKmh.isFinite, averageSpeedKmh > 0 else { return false }
        guard admissionThresholdKmh.isFinite else { return false }
        return true
    }
}

// MARK: - 计算池状态

/// 综合续航计算池的完整持久化状态（与 Android `RangePoolState` 对齐）。
///
/// - `sourceDistanceKm` / `sourceNetConsumedAh` / `validDurationSeconds` 为
///   从 `segments` 重新计算的聚合值；decode/恢复后必须经 `sanitized()` 校验。
/// - 两个更新时间分别对应综合因子与平均有效速度的刷新节流，独立推进。
/// - transient previous snapshot 不属于本状态，永不持久化。
struct RangePoolState: Codable, Equatable {
    /// 已接受的有效分段（按时间排序）
    var segments: [RangeSegment]

    /// 累计有效窗口时长（分钟），钳制最小为 1
    var targetWindowMinutes: Int

    /// 综合里程因子（km/Ah）；尚无可信观测时为 nil
    var mileageFactorKmPerAh: Double?

    /// 综合平均有效速度（km/h）；尚无可信观测时为 nil
    var averageEffectiveSpeedKmh: Double?

    /// 窗口内总里程（km）
    var sourceDistanceKm: Double

    /// 窗口内净消耗（Ah，允许为负：充电段参与聚合）
    var sourceNetConsumedAh: Double

    /// 窗口内累计有效驾驶时长（秒）
    var validDurationSeconds: TimeInterval

    /// 综合因子最近刷新时间（nil = 尚未产生）
    var mileageFactorUpdatedAt: Date?

    /// 平均有效速度最近刷新时间（nil = 尚未产生）
    var averageSpeedUpdatedAt: Date?

    /// 设置 revision（阈值变更递增；解码校验非负）
    var settingsRevision: Int64

    /// 旧因子权重（百分制，Android 对齐：70）
    var oldWeightPercent: Double

    /// 新观测权重（百分制，Android 对齐：30）
    var newWeightPercent: Double

    /// 空池：窗口/权重使用 Android 对齐默认值。
    static func empty(
        targetWindowMinutes: Int = RangeComputationEngine.defaultWindowMinutes,
        settingsRevision: Int64 = 0,
        oldWeightPercent: Double = RangeComputationEngine.defaultOldWeightPercent,
        newWeightPercent: Double = RangeComputationEngine.defaultNewWeightPercent
    ) -> RangePoolState {
        RangePoolState(
            segments: [],
            targetWindowMinutes: max(targetWindowMinutes, 1),
            mileageFactorKmPerAh: nil,
            averageEffectiveSpeedKmh: nil,
            sourceDistanceKm: 0,
            sourceNetConsumedAh: 0,
            validDurationSeconds: 0,
            mileageFactorUpdatedAt: nil,
            averageSpeedUpdatedAt: nil,
            settingsRevision: max(settingsRevision, 0),
            oldWeightPercent: oldWeightPercent,
            newWeightPercent: newWeightPercent)
    }
}

extension RangePoolState {
    /// 窗口分钟合法范围（Android 对齐：1...120 分钟）。
    static let minimumWindowMinutes = 1
    static let maximumWindowMinutes = 120

    /// 解码/恢复后的净化入口：过滤无效分段、钳制配置、按窗口裁剪并重新聚合。
    /// 与 Android `sanitized()` 对齐；无效分段不能进入运行状态。
    /// `targetWindowMinutes` 钳制到 1...120（损坏/越界持久化值不会触发整数溢出）。
    func sanitized() -> RangePoolState {
        var cleaned = self
        cleaned.segments = segments.filter(\.isValid)
        cleaned.targetWindowMinutes = min(max(targetWindowMinutes, Self.minimumWindowMinutes),
                                          Self.maximumWindowMinutes)
        cleaned.settingsRevision = max(settingsRevision, 0)
        cleaned = cleaned.trimmedToWindow()
        return cleaned.withAggregates()
    }

    /// 按累计有效驾驶时长裁剪窗口（不按墙钟时间自动过期）。
    ///
    /// 超窗时删除最老完整分段；边界分段按保留时长同比例缩放
    /// `duration`/`distanceKm`/`netConsumedAh`（`averageSpeedKmh` 与
    /// `admissionThresholdKmh` 保持原值），随后重新聚合。
    func trimmedToWindow() -> RangePoolState {
        let clampedWindow = min(max(targetWindowMinutes, Self.minimumWindowMinutes), Self.maximumWindowMinutes)
        let targetDuration = TimeInterval(clampedWindow) * 60
        let epsilon = RangeComputationEngine.floatingPointEpsilon
        var overflow = segments.reduce(0.0) { $0 + $1.duration } - targetDuration
        if overflow <= 0 { return withAggregates() }

        var retained = segments
        var dropCount = 0
        while overflow > 0, dropCount < retained.count {
            let oldest = retained[dropCount]
            if overflow >= oldest.duration - epsilon {
                overflow -= oldest.duration
                dropCount += 1
            } else {
                let keptDuration = oldest.duration - overflow
                let keptRatio = keptDuration / oldest.duration
                retained[dropCount] = RangeSegment(
                    startedAt: oldest.endedAt.addingTimeInterval(-keptDuration),
                    endedAt: oldest.endedAt,
                    duration: keptDuration,
                    distanceKm: oldest.distanceKm * keptRatio,
                    netConsumedAh: oldest.netConsumedAh * keptRatio,
                    averageSpeedKmh: oldest.averageSpeedKmh,
                    admissionThresholdKmh: oldest.admissionThresholdKmh)
                overflow = 0
            }
        }
        if dropCount > 0 {
            retained.removeFirst(dropCount)
        }
        var copy = self
        copy.segments = retained
        return copy.withAggregates()
    }

    /// 从 `segments` 重新计算聚合字段（单次遍历同时累计三项）。
    func withAggregates() -> RangePoolState {
        var copy = self
        var distance = 0.0
        var consumed = 0.0
        var duration = 0.0
        for segment in segments {
            distance += segment.distanceKm
            consumed += segment.netConsumedAh
            duration += segment.duration
        }
        copy.sourceDistanceKm = distance
        copy.sourceNetConsumedAh = consumed
        copy.validDurationSeconds = duration
        return copy
    }

    /// 权重归一化：非有限/负值回退 Android 默认（70/30），总和归一化。
    func normalizedWeights() -> (old: Double, new: Double) {
        let safeOld = oldWeightPercent.isFinite && oldWeightPercent >= 0
            ? oldWeightPercent : RangeComputationEngine.defaultOldWeightPercent
        let safeNew = newWeightPercent.isFinite && newWeightPercent >= 0
            ? newWeightPercent : RangeComputationEngine.defaultNewWeightPercent
        let total = safeOld + safeNew
        return total > 0
            ? (safeOld / total, safeNew / total)
            : (0.7, 0.3)
    }
}

// MARK: - 里程因子来源

/// 里程因子（km/Ah）的来源。
enum RangeFactorSource: Equatable, Hashable {
    /// 由窗口内分段聚合计算得出（含与历史因子的新旧权重混合）
    case computed
    /// 计算因子不可用时使用的用户手动值
    case manual
    /// 既无计算因子也无手动因子，无法估算
    case unavailable
}

/// 仪表盘显示哪一种续航估算。综合续航与手动续航始终独立计算，显示模式仅影响 UI。
enum RangeDisplayMode: String, Codable, CaseIterable, Hashable {
    case computed
    case manual
    case both

    var displayText: String {
        switch self {
        case .computed: return "综合续航"
        case .manual: return "手动续航"
        case .both: return "同时显示"
        }
    }
}

/// 可独立展示的一种续航估算；当当前连接没有有效剩余容量或综合分段不足时，数值为 nil。
struct RangeDisplayValue: Equatable {
    let source: RangeFactorSource
    let factorKmPerAh: Double?
    let estimatedRangeKm: Double?
}

// MARK: - 续航估算结果

/// 一次续航估算的结果（纯值类型，只读投影）。
struct RangeEstimate: Equatable {
    /// 生效的里程因子（km/Ah）；`source == .unavailable` 时为 nil
    let factorKmPerAh: Double?

    /// 因子来源
    let source: RangeFactorSource

    /// 估算剩余续航（km）；剩余容量无效时为 nil
    let estimatedRangeKm: Double?

    /// 窗口内参与计算的分段数
    let segmentCount: Int

    /// 窗口内总里程（km）
    let windowDistanceKm: Double

    /// 窗口内总消耗（Ah）
    let windowConsumedAh: Double

    /// 当前有效窗口得到的综合因子与续航，不因手动值存在而被覆盖。
    let computedFactorKmPerAh: Double?
    let computedEstimatedRangeKm: Double?
    /// 用户输入的手动因子与续航，不因综合数据存在而被隐藏。
    let manualFactorKmPerAh: Double?
    let manualEstimatedRangeKm: Double?

    /// 综合平均有效速度（km/h；无可信观测时为 nil，不伪造 0）。
    let averageEffectiveSpeedKmh: Double?

    /// 池内累计有效驾驶时长（s）。
    let poolValidDurationSeconds: TimeInterval

    /// 综合因子最近更新时间（nil = 尚未产生）。
    let mileageFactorUpdatedAt: Date?

    init(
        factorKmPerAh: Double?,
        source: RangeFactorSource,
        estimatedRangeKm: Double?,
        segmentCount: Int,
        windowDistanceKm: Double,
        windowConsumedAh: Double,
        computedFactorKmPerAh: Double? = nil,
        computedEstimatedRangeKm: Double? = nil,
        manualFactorKmPerAh: Double? = nil,
        manualEstimatedRangeKm: Double? = nil,
        averageEffectiveSpeedKmh: Double? = nil,
        poolValidDurationSeconds: TimeInterval = 0,
        mileageFactorUpdatedAt: Date? = nil
    ) {
        self.factorKmPerAh = factorKmPerAh
        self.source = source
        self.estimatedRangeKm = estimatedRangeKm
        self.segmentCount = segmentCount
        self.windowDistanceKm = windowDistanceKm
        self.windowConsumedAh = windowConsumedAh
        self.computedFactorKmPerAh = computedFactorKmPerAh
        self.computedEstimatedRangeKm = computedEstimatedRangeKm
        self.manualFactorKmPerAh = manualFactorKmPerAh
        self.manualEstimatedRangeKm = manualEstimatedRangeKm
        self.averageEffectiveSpeedKmh = averageEffectiveSpeedKmh
        self.poolValidDurationSeconds = poolValidDurationSeconds
        self.mileageFactorUpdatedAt = mileageFactorUpdatedAt
    }

    func displayValues(for mode: RangeDisplayMode) -> [RangeDisplayValue] {
        let computed = RangeDisplayValue(
            source: .computed,
            factorKmPerAh: computedFactorKmPerAh,
            estimatedRangeKm: computedEstimatedRangeKm)
        let manual = RangeDisplayValue(
            source: .manual,
            factorKmPerAh: manualFactorKmPerAh,
            estimatedRangeKm: manualEstimatedRangeKm)
        switch mode {
        case .computed: return [computed]
        case .manual: return [manual]
        case .both: return [computed, manual]
        }
    }
}

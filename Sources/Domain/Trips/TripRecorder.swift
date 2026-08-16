import Foundation

/// 前台行程记录器：只接受「显式开始 + 前台激活」期间的采样。
///
/// 语义（对齐 `docs/MIGRATION_PLAN.md`「行程只在活跃场景下记录」）：
/// - 未 `start()` 前调用 `record(_:)` 一律拒绝；
/// - 前台非激活（`.inactive`/`.background`）期间采样一律拒绝，且该时段时长不计入；
/// - 相邻采样校验：非有限值、负速度、水平精度越界、时间回退/重复、
///   间隔 > 30 s、分段跳跃 > 1 km；
/// - 间隔超限的采样被拒绝后断开分段（下一次接受作为新分段起点）；
/// - 任何前台非激活时段（即使短于 30 s）同样断开分段：回前台首个采样
///   作为新分段起点，距离/续航基线不跨非活跃间隔；
/// - `stop()` 一次性产出不可变 `TripRecord`，无暂停/恢复复杂状态机。
final class TripRecorder {
    /// 采样拒绝原因（类型化，供调用方/UI 提示）。
    enum RejectionReason: Equatable {
        case notStarted
        case notForegroundActive
        case nonFiniteValue
        case negativeSpeed
        case invalidHorizontalAccuracy
        case timestampRegressionOrDuplicate
        case gapTooLarge
        case jumpTooLarge
    }

    /// 记录尝试结果。
    enum RecordResult: Equatable {
        case accepted
        case rejected(RejectionReason)
    }

    /// 相邻采样最大间隔（s）
    static let maxGapSeconds: TimeInterval = 30
    /// 相邻采样分段距离上限（km）
    static let maxSegmentDistanceKm: Double = 1
    /// 水平精度有效上限（m）
    static let maxHorizontalAccuracyMeters: Double = 100

    /// 行程开始时间；nil 表示未开始/已结束
    private(set) var startedAt: Date?
    /// 当前前台激活状态（由外部生命周期驱动）
    private(set) var isForegroundActive = false
    /// 已接受的采样（只追加）
    private(set) var samples: [TripLocationSample] = []
    /// 已累计分段距离（km）
    private(set) var distanceKm: Double = 0
    /// 已累计前台激活时长（s）
    private(set) var accumulatedDurationSeconds: TimeInterval = 0

    /// 当前前台活跃时段的起点；nil 表示当前不在前台活跃时段
    private var segmentStart: Date?
    /// 上一个被接受的采样（间隔/跳跃校验基准）
    private var previousSample: TripLocationSample?
    private let now: () -> Date

    /// - Parameter now: 时钟注入（测试确定性；默认 `Date.init`）。
    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// 当前是否处于一段已开始、尚未结束的行程。
    var isRecording: Bool { startedAt != nil }

    /// 当前累计前台时长（s，含进行中前台时段的实时增量）。用于实时显示；
    /// `date` 可显式注入（测试确定性），默认使用注入时钟。
    func currentDurationSeconds(at date: Date? = nil) -> TimeInterval {
        let t = date ?? now()
        return accumulatedDurationSeconds + (segmentStart.map { t.timeIntervalSince($0) } ?? 0)
    }

    /// 显式开始一段行程（幂等：重复调用忽略）。
    /// 若当前不在前台，时钟不启动，待 `setForegroundActive(true)` 后开始累计。
    func start() {
        guard !isRecording else { return }
        let t = now()
        startedAt = t
        if isForegroundActive { segmentStart = t }
    }

    /// 前台激活状态变化（幂等，由 App 生命周期驱动）。
    /// 前台 → 非前台：冻结当前时段计时，并清除相邻采样基线
    /// （下一次接受作为新分段起点，距离/续航基线不跨非活跃间隔）；
    /// 非前台 → 前台：重新开始计时。
    func setForegroundActive(_ isActive: Bool) {
        guard isForegroundActive != isActive else { return }
        isForegroundActive = isActive
        let t = now()
        if isActive {
            if isRecording { segmentStart = t }
        } else {
            if let segment = segmentStart {
                accumulatedDurationSeconds += t.timeIntervalSince(segment)
            }
            segmentStart = nil
            // 非活跃间隔断开分段：即使短于 maxGapSeconds，回前台首个采样
            // 也作为新分段起点，避免后台位移/漂移计入跨边界距离。
            previousSample = nil
        }
    }

    /// 尝试记录一个采样；未开始/非前台/校验失败时拒绝并给出原因。
    @discardableResult
    func record(_ sample: TripLocationSample) -> RecordResult {
        guard let started = startedAt else { return .rejected(.notStarted) }
        guard isForegroundActive else { return .rejected(.notForegroundActive) }
        guard sample.latitude.isFinite, sample.longitude.isFinite, sample.speedKmh.isFinite else {
            return .rejected(.nonFiniteValue)
        }
        guard sample.speedKmh >= 0 else { return .rejected(.negativeSpeed) }
        guard sample.horizontalAccuracyMeters > 0,
              sample.horizontalAccuracyMeters <= Self.maxHorizontalAccuracyMeters else {
            return .rejected(.invalidHorizontalAccuracy)
        }
        if let previous = previousSample {
            guard sample.timestamp > previous.timestamp else {
                return .rejected(.timestampRegressionOrDuplicate)
            }
            guard sample.timestamp.timeIntervalSince(previous.timestamp) <= Self.maxGapSeconds else {
                // 间隔超限：拒绝并断开分段，下一次接受作为新分段起点
                previousSample = nil
                return .rejected(.gapTooLarge)
            }
            let segmentKm = previous.distanceKm(to: sample)
            guard segmentKm <= Self.maxSegmentDistanceKm else {
                return .rejected(.jumpTooLarge)
            }
            distanceKm += segmentKm
        } else {
            guard sample.timestamp >= started else {
                return .rejected(.timestampRegressionOrDuplicate)
            }
        }
        samples.append(sample)
        previousSample = sample
        return .accepted
    }

    /// 结束行程：返回不可变 `TripRecord` 并复位到空闲状态。
    /// 未开始/已结束时返回 nil（幂等）。
    func stop(name: String = "") -> TripRecord? {
        guard let started = startedAt else { return nil }
        let t = now()
        if let segment = segmentStart {
            accumulatedDurationSeconds += t.timeIntervalSince(segment)
            segmentStart = nil
        }
        let duration = accumulatedDurationSeconds
        let averageSpeed = duration > 0 && distanceKm > 0 ? distanceKm * 3600 / duration : 0
        let startRemainingAh = samples.compactMap(\.remainingAh).first
        let endRemainingAh = samples.compactMap(\.remainingAh).last
        let consumedAh = max(0, (startRemainingAh ?? 0) - (endRemainingAh ?? 0))
        let energyAhPer100Km = distanceKm > 0 ? consumedAh / distanceKm * 100 : 0
        let record = TripRecord(
            id: UUID(),
            name: name,
            startedAt: started,
            endedAt: t,
            durationSeconds: duration,
            distanceKm: distanceKm,
            averageSpeedKmh: averageSpeed,
            startRemainingAh: startRemainingAh,
            endRemainingAh: endRemainingAh,
            consumedAh: consumedAh,
            energyAhPer100Km: energyAhPer100Km,
            samples: samples
        )
        reset()
        return record
    }

    private func reset() {
        startedAt = nil
        samples = []
        distanceKm = 0
        accumulatedDurationSeconds = 0
        segmentStart = nil
        previousSample = nil
    }
}

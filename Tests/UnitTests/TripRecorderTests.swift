import Foundation
import XCTest
@testable import GPSAntBMS

/// `TripRecorder` 前台行程记录器单元测试。
/// 全部使用注入时钟与显式时间戳，完全确定性；Given/When/Then 结构。
final class TripRecorderTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    /// 0.001° 纬度对应的 haversine 距离（km，R = 6371）
    private let stepKm = 0.001 * 6371 * .pi / 180

    /// 便捷构造：可控时钟；默认已前台激活。
    private func makeRecorder(_ now: @escaping () -> Date) -> TripRecorder {
        let recorder = TripRecorder(now: now)
        recorder.setForegroundActive(true)
        return recorder
    }

    private func makeSample(_ timestamp: Date, latitude: Double = 0,
                            speedKmh: Double = 10, accuracy: Double = 5) -> TripLocationSample {
        TripLocationSample(timestamp: timestamp, latitude: latitude, longitude: 0,
                           speedKmh: speedKmh, horizontalAccuracyMeters: accuracy)
    }

    // MARK: - 开始 / 忽略 / 前台门控
    func testStartBeginsRecordingAndIsIdempotent() {
        // Given 可控时钟
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        // When 开始行程并再次调用 start()
        recorder.start()
        recorder.start()
        // Then 仅第一次生效，startedAt 与时钟一致
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(recorder.startedAt, t0)
    }
    func testRecordingBeforeStartIsIgnored() {
        // Given 未开始行程的记录器（前台激活）
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        // When 直接记录有效采样
        let result = recorder.record(makeSample(t0))
        // Then 拒绝且不产生任何采样；stop 返回 nil
        XCTAssertEqual(result, .rejected(.notStarted))
        XCTAssertTrue(recorder.samples.isEmpty)
        XCTAssertEqual(recorder.distanceKm, 0)
        XCTAssertNil(recorder.stop())
    }
    func testRecordingRequiresForegroundActive() {
        // Given 已开始行程但前台非激活（默认状态）
        var currentTime = t0
        let recorder = TripRecorder(now: { currentTime })
        recorder.start()
        // When 非前台时记录采样
        let rejected = recorder.record(makeSample(t0))
        // Then 拒绝；前台激活后同一采样被接受
        XCTAssertEqual(rejected, .rejected(.notForegroundActive))
        currentTime = t0.addingTimeInterval(1)
        recorder.setForegroundActive(true)
        XCTAssertEqual(recorder.record(makeSample(t0.addingTimeInterval(1))), .accepted)
        // And 再次退出前台后拒绝
        currentTime = t0.addingTimeInterval(2)
        recorder.setForegroundActive(false)
        XCTAssertEqual(recorder.record(makeSample(t0.addingTimeInterval(2))), .rejected(.notForegroundActive))
    }

    // MARK: - 接受与距离
    func testAcceptsValidSamplesAndAccumulatesHaversineDistance() {
        // Given 前台激活、已开始行程
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        recorder.start()
        // When 沿纬度方向以 0.001° 步进记录 4 个有效采样（间隔 1 s，含 BMS 可选字段）
        let results = (0..<4).map { index in
            recorder.record(TripLocationSample(
                timestamp: t0.addingTimeInterval(TimeInterval(index + 1)),
                latitude: 0.001 * Double(index), longitude: 0,
                speedKmh: 15, horizontalAccuracyMeters: 5,
                remainingAh: 150, powerW: 200))
        }
        // Then 全部接受，距离累计 3 个步进，BMS 字段保留
        XCTAssertEqual(results, [.accepted, .accepted, .accepted, .accepted])
        XCTAssertEqual(recorder.samples.count, 4)
        XCTAssertEqual(recorder.distanceKm, stepKm * 3, accuracy: 0.0001)
        XCTAssertEqual(recorder.samples[3].remainingAh, 150)
        XCTAssertEqual(recorder.samples[3].powerW, 200)
    }
    func testStopDerivesDurationAndAverageSpeed() {
        // Given 前台激活、已开始行程，采样跨度 30 s
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        recorder.start()
        (0..<4).forEach { index in
            recorder.record(makeSample(t0.addingTimeInterval(TimeInterval(index * 10 + 1)),
                                       latitude: 0.001 * Double(index)))
        }
        // When 在 t0 + 120 s 结束行程
        currentTime = t0.addingTimeInterval(120)
        let record = recorder.stop()
        // Then 时长 120 s，平均速度 = 距离 × 3600 / 120
        let expectedDistance = stepKm * 3
        XCTAssertEqual(record?.startedAt, t0)
        XCTAssertEqual(record?.endedAt, t0.addingTimeInterval(120))
        XCTAssertEqual(record?.durationSeconds, 120)
        XCTAssertEqual(record?.distanceKm ?? 0, expectedDistance, accuracy: 0.0001)
        XCTAssertEqual(record?.averageSpeedKmh ?? 0, expectedDistance * 3600 / 120, accuracy: 0.01)
        XCTAssertEqual(record?.samples.count, 4)
    }

    func testStopDerivesNameAndEnergyFields() {
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        recorder.start()
        recorder.record(TripLocationSample(timestamp: t0.addingTimeInterval(1), latitude: 0,
                                            longitude: 0, speedKmh: 10,
                                            horizontalAccuracyMeters: 5,
                                            remainingAh: 10, powerW: 100))
        recorder.record(TripLocationSample(timestamp: t0.addingTimeInterval(2), latitude: 0.001,
                                            longitude: 0, speedKmh: 10,
                                            horizontalAccuracyMeters: 5,
                                            remainingAh: 9.5, powerW: 200))
        currentTime = t0.addingTimeInterval(10)

        let record = recorder.stop(name: "测试行程")

        XCTAssertEqual(record?.name, "测试行程")
        XCTAssertEqual(record?.startRemainingAh, 10)
        XCTAssertEqual(record?.endRemainingAh, 9.5)
        XCTAssertEqual(record?.consumedAh, 0.5)
        XCTAssertGreaterThan(record?.energyAhPer100Km ?? 0, 0)
        XCTAssertGreaterThan(record?.kmPerAh ?? 0, 0)
    }

    // MARK: - 校验拒绝
    func testRejectsNonFiniteCoordinatesAndSpeed() {
        // Given 前台激活、已开始行程
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        recorder.start()
        // When 分别记录 NaN 纬度、无穷经度、无穷速度、负速度
        let nanLat = recorder.record(makeSample(t0.addingTimeInterval(1), latitude: .nan))
        let infLon = recorder.record(TripLocationSample(
            timestamp: t0.addingTimeInterval(2), latitude: 0, longitude: .infinity,
            speedKmh: 10, horizontalAccuracyMeters: 5))
        let infSpeed = recorder.record(makeSample(t0.addingTimeInterval(3), speedKmh: .infinity))
        let negativeSpeed = recorder.record(makeSample(t0.addingTimeInterval(4), speedKmh: -3))
        // Then 非有限值按非有限值拒绝，负速度按负速度拒绝，均不产生采样
        XCTAssertEqual(nanLat, .rejected(.nonFiniteValue))
        XCTAssertEqual(infLon, .rejected(.nonFiniteValue))
        XCTAssertEqual(infSpeed, .rejected(.nonFiniteValue))
        XCTAssertEqual(negativeSpeed, .rejected(.negativeSpeed))
        XCTAssertTrue(recorder.samples.isEmpty)
    }
    func testRejectsOutOfRangeHorizontalAccuracy() {
        // Given 前台激活、已开始行程
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        recorder.start()
        // When 依次记录精度 0、-1、101（越界）与 1、100（边界）
        let zero = recorder.record(makeSample(t0.addingTimeInterval(1), accuracy: 0))
        let negative = recorder.record(makeSample(t0.addingTimeInterval(2), accuracy: -1))
        let tooHigh = recorder.record(makeSample(t0.addingTimeInterval(3), accuracy: 101))
        let boundaryLow = recorder.record(makeSample(t0.addingTimeInterval(4), accuracy: 1))
        let boundaryHigh = recorder.record(makeSample(t0.addingTimeInterval(5), accuracy: 100))
        // Then 越界值拒绝，边界值 (0, 100] 接受
        XCTAssertEqual(zero, .rejected(.invalidHorizontalAccuracy))
        XCTAssertEqual(negative, .rejected(.invalidHorizontalAccuracy))
        XCTAssertEqual(tooHigh, .rejected(.invalidHorizontalAccuracy))
        XCTAssertEqual(boundaryLow, .accepted)
        XCTAssertEqual(boundaryHigh, .accepted)
    }
    func testRejectsTimestampRegressionAndDuplication() {
        // Given 前台激活、已开始行程
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        recorder.start()
        // When 先接受一个采样，再记录重复与回退时间戳
        XCTAssertEqual(recorder.record(makeSample(t0.addingTimeInterval(10))), .accepted)
        let duplicated = recorder.record(makeSample(t0.addingTimeInterval(10)))
        let regressed = recorder.record(makeSample(t0.addingTimeInterval(9)))
        // Then 重复与回退均拒绝
        XCTAssertEqual(duplicated, .rejected(.timestampRegressionOrDuplicate))
        XCTAssertEqual(regressed, .rejected(.timestampRegressionOrDuplicate))
        XCTAssertEqual(recorder.samples.count, 1)
    }
    func testRejectsGapOver30SecondsAndStartsNewSegment() {
        // Given 前台激活、已开始行程
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        recorder.start()
        XCTAssertEqual(recorder.record(makeSample(t0.addingTimeInterval(1))), .accepted)
        // When 31 s 后到达采样（超限），随后连续两个有效采样
        let gapped = recorder.record(makeSample(t0.addingTimeInterval(32)))
        let newLegStart = recorder.record(makeSample(t0.addingTimeInterval(33), latitude: 0.001))
        let newLegSecond = recorder.record(makeSample(t0.addingTimeInterval(34), latitude: 0.002))
        // Then 超限采样拒绝并断开分段；新分段从 33 s 起重新累计
        XCTAssertEqual(gapped, .rejected(.gapTooLarge))
        XCTAssertEqual(newLegStart, .accepted)
        XCTAssertEqual(newLegSecond, .accepted)
        XCTAssertEqual(recorder.samples.count, 3)
        XCTAssertEqual(recorder.distanceKm, stepKm, accuracy: 0.0001)
    }
    func testRejectsJumpOverOneKilometer() {
        // Given 前台激活、已开始行程
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        recorder.start()
        XCTAssertEqual(recorder.record(makeSample(t0.addingTimeInterval(1))), .accepted)
        // When 0.02° 纬度跳跃（约 2.2 km），随后回到邻近位置
        let jumped = recorder.record(makeSample(t0.addingTimeInterval(2), latitude: 0.02))
        let returned = recorder.record(makeSample(t0.addingTimeInterval(3), latitude: 0.001))
        // Then 跳跃拒绝（分段链保持），回到邻近位置后继续累计
        XCTAssertEqual(jumped, .rejected(.jumpTooLarge))
        XCTAssertEqual(returned, .accepted)
        XCTAssertEqual(recorder.distanceKm, stepKm, accuracy: 0.0001)
    }

    // MARK: - 实时前台时长

    func testCurrentDurationSecondsTracksLiveForegroundTime() {
        // Given 前台激活、已开始行程（t0 起）
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        recorder.start()
        // When 前台推进 5 s
        currentTime = t0.addingTimeInterval(5)
        // Then 实时增量计入
        XCTAssertEqual(recorder.currentDurationSeconds(), 5)
        // And 显式时间注入（测试确定性）：at: 参数优先于时钟
        XCTAssertEqual(recorder.currentDurationSeconds(at: t0.addingTimeInterval(7)), 7)
        // When 在 t0 + 10 s 退出前台，后台 40 s
        currentTime = t0.addingTimeInterval(10)
        recorder.setForegroundActive(false)
        currentTime = t0.addingTimeInterval(50)
        // Then 时长冻结在退出前台时刻（10 s），后台时间不计入
        XCTAssertEqual(recorder.currentDurationSeconds(), 10)
        // When 在 t0 + 50 s 回前台，前台推进 3 s
        recorder.setForegroundActive(true)
        currentTime = t0.addingTimeInterval(53)
        // Then 时长 = 10 + 3 = 13 s
        XCTAssertEqual(recorder.currentDurationSeconds(), 13)
        // When 结束行程
        currentTime = t0.addingTimeInterval(53)
        recorder.stop()
        // Then 复位为 0
        XCTAssertEqual(recorder.currentDurationSeconds(), 0)
    }

    // MARK: - 生命周期暂停语义
    func testDurationCountsOnlyForegroundActiveTime() {
        // Given 前台激活、已开始行程，t0+2 s 接受首个采样
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        recorder.start()
        XCTAssertEqual(recorder.record(makeSample(t0.addingTimeInterval(2))), .accepted)
        // When 前台 t0~t0+10 后进入非前台 40 s，回前台后继续采样
        currentTime = t0.addingTimeInterval(10)
        recorder.setForegroundActive(false)
        currentTime = t0.addingTimeInterval(50)
        recorder.setForegroundActive(true)
        currentTime = t0.addingTimeInterval(52)
        let firstAfterResume = recorder.record(makeSample(t0.addingTimeInterval(52), latitude: 0.001))
        currentTime = t0.addingTimeInterval(54)
        let newLegStart = recorder.record(makeSample(t0.addingTimeInterval(54), latitude: 0.001))
        currentTime = t0.addingTimeInterval(55)
        let newLegSecond = recorder.record(makeSample(t0.addingTimeInterval(55), latitude: 0.002))
        // When 在 t0 + 60 s 结束行程
        currentTime = t0.addingTimeInterval(60)
        let record = recorder.stop()
        // Then 时长只含前台 (10-0) + (60-50) = 20 s，后台 40 s 不计入；
        //     非活跃间隔断开分段：回前台首个采样即新分段起点（被接受，
        //     无跨边界距离），距离仅来自新分段内部
        XCTAssertEqual(firstAfterResume, .accepted)
        XCTAssertEqual(newLegStart, .accepted)
        XCTAssertEqual(newLegSecond, .accepted)
        XCTAssertEqual(record?.durationSeconds, 20)
        XCTAssertEqual(record?.distanceKm ?? 0, stepKm, accuracy: 0.0001)
        XCTAssertEqual(record?.averageSpeedKmh ?? 0, stepKm * 3600 / 20, accuracy: 0.01)
    }
    func testResumeUnder30SecondsStartsNewLegWithoutCrossBoundaryDistance() {
        // Given 前台激活、已开始行程，t0+1 s 接受首个采样（基线 0 距离）
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        recorder.start()
        XCTAssertEqual(recorder.record(makeSample(t0.addingTimeInterval(1))), .accepted)
        // When 短于 30 s 阈值退出前台，回前台后首个采样已远离（0.005° ≈ 5 × stepKm）
        currentTime = t0.addingTimeInterval(2)
        recorder.setForegroundActive(false)
        currentTime = t0.addingTimeInterval(20)
        recorder.setForegroundActive(true)
        let resumed = recorder.record(makeSample(t0.addingTimeInterval(20), latitude: 0.005))
        let legSecond = recorder.record(makeSample(t0.addingTimeInterval(21), latitude: 0.006))
        // Then 首个恢复采样被接受为新分段起点（非活跃间隔断开基线，
        //     不因间隔未超 30 s 而累计跨边界距离）；距离仅来自新分段内部
        XCTAssertEqual(resumed, .accepted)
        XCTAssertEqual(legSecond, .accepted)
        XCTAssertEqual(recorder.samples.count, 3)
        XCTAssertEqual(recorder.distanceKm, stepKm, accuracy: 0.0001)
    }
    func testStopWhileBackgroundedFreezesDurationAndAllowsRestart() {
        // Given 前台激活、已开始行程，采样后退出前台
        var currentTime = t0
        let recorder = makeRecorder { currentTime }
        recorder.start()
        currentTime = t0.addingTimeInterval(2)
        recorder.record(makeSample(t0.addingTimeInterval(2)))
        currentTime = t0.addingTimeInterval(10)
        recorder.setForegroundActive(false)
        // When 在非前台状态下结束行程
        currentTime = t0.addingTimeInterval(60)
        let record = recorder.stop()
        // Then 时长冻结在退出前台时刻（10 s），后台 50 s 不计入
        XCTAssertEqual(record?.durationSeconds, 10)
        XCTAssertEqual(record?.endedAt, t0.addingTimeInterval(60))
        XCTAssertFalse(recorder.isRecording)
        // And 可再次开始新行程
        currentTime = t0.addingTimeInterval(100)
        recorder.setForegroundActive(true)
        recorder.start()
        XCTAssertEqual(recorder.startedAt, t0.addingTimeInterval(100))
        XCTAssertEqual(recorder.record(makeSample(t0.addingTimeInterval(101))), .accepted)
        XCTAssertEqual(recorder.distanceKm, 0)
    }
}

import XCTest
@testable import GPSAntBMS

/// 查询命令串行化调度器：单在途 + 单合并挂起；以及轮询间隔钳制规则。
final class BleQuerySchedulerTests: XCTestCase {
    // MARK: - 串行化调度

    /// 空闲节拍：立即发送（标记在途）。
    func testFirstTickSendsImmediately() {
        var scheduler = BleQueryScheduler()

        XCTAssertTrue(scheduler.pollTick())
        XCTAssertTrue(scheduler.isInFlight)
        XCTAssertFalse(scheduler.hasPending)
    }

    /// 在途期间多个节拍只合并一个挂起查询。
    func testTickWhileInFlightCoalescesToSinglePending() {
        var scheduler = BleQueryScheduler()
        _ = scheduler.pollTick()

        XCTAssertFalse(scheduler.pollTick())
        XCTAssertFalse(scheduler.pollTick())
        XCTAssertTrue(scheduler.hasPending)
        XCTAssertTrue(scheduler.isInFlight)
    }

    /// 写入完成且无挂起查询时不补发。
    func testWriteCompletedWithoutPendingDoesNotResend() {
        var scheduler = BleQueryScheduler()
        _ = scheduler.pollTick()

        XCTAssertFalse(scheduler.writeCompleted())
        XCTAssertFalse(scheduler.isInFlight)
        XCTAssertFalse(scheduler.hasPending)
    }

    /// 写入完成且有挂起查询时立即补发并重新标记在途。
    func testWriteCompletedWithPendingResendsImmediately() {
        var scheduler = BleQueryScheduler()
        _ = scheduler.pollTick()
        _ = scheduler.pollTick() // 合并挂起

        XCTAssertTrue(scheduler.writeCompleted())
        XCTAssertTrue(scheduler.isInFlight)
        XCTAssertFalse(scheduler.hasPending)
    }

    /// 一次完成只补发一个查询（合并语义：N 个节拍 → 1 个挂起 → 1 次补发）。
    func testMultipleTicksProduceAtMostOneResend() {
        var scheduler = BleQueryScheduler()
        _ = scheduler.pollTick()
        _ = scheduler.pollTick()
        _ = scheduler.pollTick()
        _ = scheduler.pollTick()

        XCTAssertTrue(scheduler.writeCompleted()) // 补发第 1 个
        XCTAssertFalse(scheduler.writeCompleted()) // 第 2 个完成时无挂起
    }

    /// reset 清空在途与挂起，之后可立即发送新查询。
    func testResetAllowsImmediateSend() {
        var scheduler = BleQueryScheduler()
        _ = scheduler.pollTick()
        _ = scheduler.pollTick()
        scheduler.reset()

        XCTAssertFalse(scheduler.isInFlight)
        XCTAssertFalse(scheduler.hasPending)
        XCTAssertTrue(scheduler.pollTick())
    }

    // MARK: - 轮询间隔钳制

    /// 默认间隔 1000 ms；范围 200 ms 至 60000 ms（与 Android `coerceIn` 一致）。
    func testPollIntervalClamping() {
        XCTAssertEqual(PollInterval.defaultMilliseconds, 1_000)
        XCTAssertEqual(PollInterval.minimumMilliseconds, 200)
        XCTAssertEqual(PollInterval.maximumMilliseconds, 60_000)

        XCTAssertEqual(PollInterval.clamped(1_000), 1_000)
        XCTAssertEqual(PollInterval.clamped(50), 200)       // 低于下限 → 200
        XCTAssertEqual(PollInterval.clamped(90_000), 60_000) // 高于上限 → 60000
        XCTAssertEqual(PollInterval.clamped(200), 200)
        XCTAssertEqual(PollInterval.clamped(60_000), 60_000)
        XCTAssertEqual(PollInterval.clamped(500), 500)
    }
}

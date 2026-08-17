import SwiftUI
import XCTest
@testable import GPSAntBMS

/// 记录调用顺序的调用日志（启停顺序断言用）。
private final class CallLog {
    private(set) var calls: [String] = []

    func record(_ call: String) {
        calls.append(call)
    }
}

/// 记录调用次数与顺序的前台会话 Mock。
private final class MockForegroundService: ForegroundSessionService {
    private let label: String
    private let log: CallLog
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(label: String, log: CallLog) {
        self.label = label
        self.log = log
    }

    func startForegroundSession() {
        startCount += 1
        log.record("start:\(label)")
    }

    func stopForegroundSession() {
        stopCount += 1
        log.record("stop:\(label)")
    }
}

/// App 根生命周期协调器：scenePhase 到前台会话开关的唯一映射，启停均幂等。
/// 覆盖定位、蓝牙、行程会话与独立续航池四个前台服务，启停顺序固定
/// （启动：定位→蓝牙→行程→续航池；停止：行程→续航池→蓝牙→定位）。
final class AppLifecycleControllerTests: XCTestCase {
    private func makeController(backgroundSessionEnabled: @escaping () -> Bool = { false })
        -> (AppLifecycleController, MockForegroundService, MockForegroundService,
            MockForegroundService, MockForegroundService) {
        let log = CallLog()
        let location = MockForegroundService(label: "location", log: log)
        let bluetooth = MockForegroundService(label: "bluetooth", log: log)
        let trip = MockForegroundService(label: "trip", log: log)
        let rangePool = MockForegroundService(label: "rangePool", log: log)
        let controller = AppLifecycleController(
            locationService: location,
            bluetoothService: bluetooth,
            tripSession: trip,
            rangePool: rangePool,
            backgroundSessionEnabled: backgroundSessionEnabled)
        return (controller, location, bluetooth, trip, rangePool)
    }

    /// `.active` 启动定位、BLE、行程会话与续航池四个前台服务。
    func testActiveStartsAllForegroundServices() {
        let (controller, location, bluetooth, trip, rangePool) = makeController()

        controller.scenePhaseDidChange(.active)

        XCTAssertEqual(location.startCount, 1)
        XCTAssertEqual(bluetooth.startCount, 1)
        XCTAssertEqual(trip.startCount, 1)
        XCTAssertEqual(rangePool.startCount, 1)
        XCTAssertTrue(controller.isForegroundActive)
    }

    /// 重复 `.active` 不会重复启动服务（幂等）。
    func testRepeatedActiveDoesNotRestartServices() {
        let (controller, location, bluetooth, trip, rangePool) = makeController()

        controller.scenePhaseDidChange(.active)
        controller.scenePhaseDidChange(.active)

        XCTAssertEqual(location.startCount, 1)
        XCTAssertEqual(bluetooth.startCount, 1)
        XCTAssertEqual(trip.startCount, 1)
        XCTAssertEqual(rangePool.startCount, 1)
        XCTAssertTrue(controller.isForegroundActive)
    }

    /// iOS 16 启动序列：根内容 `onAppear` 补发的初始 `.active`，与随后
    /// `onChange` 上报的场景 `.active` 重复交付时，服务只启动一次（幂等）。
    func testInitialAppearActiveThenScenePhaseActiveStartsOnlyOnce() {
        let (controller, location, bluetooth, trip, rangePool) = makeController()

        // 根内容出现：补发当前 phase（iOS 16 `onChange` 不保证初始回调）。
        controller.scenePhaseDidChange(.active)
        // 随后场景迁移为 `.active` 时 `onChange` 再次上报。
        controller.scenePhaseDidChange(.active)

        XCTAssertEqual(location.startCount, 1)
        XCTAssertEqual(bluetooth.startCount, 1)
        XCTAssertEqual(trip.startCount, 1)
        XCTAssertEqual(rangePool.startCount, 1)
        XCTAssertTrue(controller.isForegroundActive)
    }

    /// `.inactive` 是临时转换，不能在尚未真正进入后台前主动断开 BLE/GPS。
    func testInactiveKeepsServicesRunning() {
        let (controller, location, bluetooth, trip, rangePool) = makeController()

        controller.scenePhaseDidChange(.active)
        controller.scenePhaseDidChange(.inactive)

        XCTAssertEqual(location.stopCount, 0)
        XCTAssertEqual(bluetooth.stopCount, 0)
        XCTAssertEqual(trip.stopCount, 0)
        XCTAssertEqual(rangePool.stopCount, 0)
        XCTAssertFalse(controller.isForegroundActive)
    }

    func testInactiveKeepsDashcamRecording() {
        let log = CallLog()
        let controller = AppLifecycleController(
            locationService: MockForegroundService(label: "location", log: log),
            bluetoothService: MockForegroundService(label: "bluetooth", log: log),
            tripSession: MockForegroundService(label: "trip", log: log),
            rangePool: MockForegroundService(label: "rangePool", log: log),
            dashcamDidBecomeActive: { log.record("dashcam:active") },
            dashcamWillResignActive: { log.record("dashcam:inactive") })

        controller.scenePhaseDidChange(.active)
        controller.scenePhaseDidChange(.inactive)

        XCTAssertEqual(log.calls.filter { $0.hasPrefix("dashcam:") }, ["dashcam:active"])
    }

    func testInactiveThenBackgroundStopsDashcamExactlyOnce() {
        let log = CallLog()
        let controller = AppLifecycleController(
            locationService: MockForegroundService(label: "location", log: log),
            bluetoothService: MockForegroundService(label: "bluetooth", log: log),
            tripSession: MockForegroundService(label: "trip", log: log),
            rangePool: MockForegroundService(label: "rangePool", log: log),
            dashcamDidBecomeActive: { log.record("dashcam:active") },
            dashcamWillResignActive: { log.record("dashcam:inactive") })

        controller.scenePhaseDidChange(.active)
        controller.scenePhaseDidChange(.inactive)
        controller.scenePhaseDidChange(.background)

        XCTAssertEqual(
            log.calls.filter { $0.hasPrefix("dashcam:") },
            ["dashcam:active", "dashcam:inactive"])
    }

    /// `.background` 停止四个前台服务。
    func testBackgroundStopsAllForegroundServices() {
        let (controller, location, bluetooth, trip, rangePool) = makeController()

        controller.scenePhaseDidChange(.active)
        controller.scenePhaseDidChange(.background)

        XCTAssertEqual(location.stopCount, 1)
        XCTAssertEqual(bluetooth.stopCount, 1)
        XCTAssertEqual(trip.stopCount, 1)
        XCTAssertEqual(rangePool.stopCount, 1)
        XCTAssertFalse(controller.isForegroundActive)
    }

    func testBackgroundKeepsServicesRunningWhenBackgroundSessionIsEnabled() {
        let (controller, location, bluetooth, trip, rangePool) = makeController(backgroundSessionEnabled: { true })

        controller.scenePhaseDidChange(.active)
        controller.scenePhaseDidChange(.background)

        XCTAssertEqual(location.startCount, 1)
        XCTAssertEqual(bluetooth.startCount, 1)
        XCTAssertEqual(trip.startCount, 1)
        XCTAssertEqual(rangePool.startCount, 1)
        XCTAssertEqual(location.stopCount, 0)
        XCTAssertEqual(bluetooth.stopCount, 0)
        XCTAssertEqual(trip.stopCount, 0)
        XCTAssertEqual(rangePool.stopCount, 0)
        XCTAssertFalse(controller.isForegroundActive)
    }

    /// `.inactive` 后紧跟 `.background` 仅在真正进入后台时停止一次。
    func testInactiveThenBackgroundStopsOnlyOnce() {
        let (controller, location, bluetooth, trip, rangePool) = makeController()

        controller.scenePhaseDidChange(.active)
        controller.scenePhaseDidChange(.inactive)
        controller.scenePhaseDidChange(.background)

        XCTAssertEqual(location.stopCount, 1)
        XCTAssertEqual(bluetooth.stopCount, 1)
        XCTAssertEqual(trip.stopCount, 1)
        XCTAssertEqual(rangePool.stopCount, 1)
    }

    /// 启动前收到非激活事件不产生停止副作用。
    func testNonActivePhaseBeforeFirstActiveIsIgnored() {
        let (controller, location, bluetooth, trip, rangePool) = makeController()

        controller.scenePhaseDidChange(.inactive)

        XCTAssertEqual(location.stopCount, 0)
        XCTAssertEqual(bluetooth.stopCount, 0)
        XCTAssertEqual(trip.stopCount, 0)
        XCTAssertEqual(rangePool.stopCount, 0)
        XCTAssertFalse(controller.isForegroundActive)
    }

    /// 停止后台会话后回到前台会重新启动服务。
    func testReturningToForegroundAfterBackgroundRestartsServices() {
        let (controller, location, bluetooth, trip, rangePool) = makeController()

        controller.scenePhaseDidChange(.active)
        controller.scenePhaseDidChange(.background)
        controller.scenePhaseDidChange(.active)

        XCTAssertEqual(location.startCount, 2)
        XCTAssertEqual(bluetooth.startCount, 2)
        XCTAssertEqual(trip.startCount, 2)
        XCTAssertEqual(rangePool.startCount, 2)
        XCTAssertEqual(location.stopCount, 1)
        XCTAssertEqual(bluetooth.stopCount, 1)
        XCTAssertEqual(trip.stopCount, 1)
        XCTAssertEqual(rangePool.stopCount, 1)
        XCTAssertTrue(controller.isForegroundActive)
    }

    // MARK: - 启停顺序

    /// 启动顺序：location → bluetooth → trip session → range pool。
    func testStartOrderingIsLocationThenBluetoothThenTripSessionThenRangePool() {
        let log = CallLog()
        let controller = AppLifecycleController(
            locationService: MockForegroundService(label: "location", log: log),
            bluetoothService: MockForegroundService(label: "bluetooth", log: log),
            tripSession: MockForegroundService(label: "trip", log: log),
            rangePool: MockForegroundService(label: "rangePool", log: log))

        controller.scenePhaseDidChange(.active)

        XCTAssertEqual(log.calls, ["start:location", "start:bluetooth", "start:trip", "start:rangePool"])
    }

    /// 停止顺序：trip session → range pool → bluetooth → location。
    func testStopOrderingIsTripSessionThenRangePoolThenBluetoothThenLocation() {
        let log = CallLog()
        let controller = AppLifecycleController(
            locationService: MockForegroundService(label: "location", log: log),
            bluetoothService: MockForegroundService(label: "bluetooth", log: log),
            tripSession: MockForegroundService(label: "trip", log: log),
            rangePool: MockForegroundService(label: "rangePool", log: log))

        controller.scenePhaseDidChange(.active)
        controller.scenePhaseDidChange(.background)

        XCTAssertEqual(log.calls, [
            "start:location", "start:bluetooth", "start:trip", "start:rangePool",
            "stop:trip", "stop:rangePool", "stop:bluetooth", "stop:location"
        ])
    }

    func testDashcamReceivesForegroundNotificationsWithoutJoiningServiceLifecycle() {
        let log = CallLog()
        let controller = AppLifecycleController(
            locationService: MockForegroundService(label: "location", log: log),
            bluetoothService: MockForegroundService(label: "bluetooth", log: log),
            tripSession: MockForegroundService(label: "trip", log: log),
            rangePool: MockForegroundService(label: "rangePool", log: log),
            dashcamDidBecomeActive: { log.record("dashcam:active") },
            dashcamWillResignActive: { log.record("dashcam:inactive") })

        controller.scenePhaseDidChange(.active)
        controller.scenePhaseDidChange(.background)

        XCTAssertEqual(log.calls, [
            "start:location", "start:bluetooth", "start:trip", "start:rangePool", "dashcam:active",
            "dashcam:inactive", "stop:trip", "stop:rangePool", "stop:bluetooth", "stop:location"
        ])
    }
}

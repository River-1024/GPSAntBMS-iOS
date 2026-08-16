import Combine
import CoreLocation
import XCTest
@testable import GPSAntBMS

/// 记录调用的 `CLLocationManager` 替身（不触发真实定位）。
private final class RecordingCLLocationManager: CLLocationManager {
    private(set) var startUpdateCount = 0
    private(set) var stopUpdateCount = 0
    private(set) var authorizationRequestCount = 0
    private(set) var alwaysAuthorizationRequestCount = 0

    var simulatedAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    override var authorizationStatus: CLAuthorizationStatus { simulatedAuthorizationStatus }

    // 系统属性回放：`pausesLocationUpdatesAutomatically` / `allowsBackgroundLocationUpdates`
    // 由系统（locationd）管理，真机与模拟器上写入后的读回值不受代码控制
    // （模拟器在授权/后台模式下会钳制读回值），故用存储属性记录写入值，
    // 让断言只验证业务代码写入的期望值，与系统行为解耦。
    private var recordedPausesLocationUpdatesAutomatically = true
    override var pausesLocationUpdatesAutomatically: Bool {
        get { recordedPausesLocationUpdatesAutomatically }
        set { recordedPausesLocationUpdatesAutomatically = newValue }
    }

    private var recordedAllowsBackgroundLocationUpdates = false
    override var allowsBackgroundLocationUpdates: Bool {
        get { recordedAllowsBackgroundLocationUpdates }
        set { recordedAllowsBackgroundLocationUpdates = newValue }
    }

    override func startUpdatingLocation() {
        startUpdateCount += 1
    }

    override func stopUpdatingLocation() {
        stopUpdateCount += 1
    }

    override func requestWhenInUseAuthorization() {
        authorizationRequestCount += 1
    }

    override func requestAlwaysAuthorization() {
        alwaysAuthorizationRequestCount += 1
    }
}

/// 前台定位服务：权限行为（仅 notDetermined 弹窗、仅授权启动）与会话启停（停止归零速度）。
final class LocationServiceTests: XCTestCase {
    private func makeService(_ manager: RecordingCLLocationManager = RecordingCLLocationManager())
        -> (LocationService, RecordingCLLocationManager) {
        (LocationService(manager: manager), manager)
    }

    /// 模拟系统授权回调（真实路径：delegate → `handleAuthorizationChange` → 发布状态）。
    private func deliverAuthorization(_ status: CLAuthorizationStatus,
                                      to service: LocationService,
                                      via manager: RecordingCLLocationManager) {
        manager.simulatedAuthorizationStatus = status
        service.locationManagerDidChangeAuthorization(manager)
    }

    private func location(speed: CLLocationSpeed) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 31.0, longitude: 121.0),
                   altitude: 0,
                   horizontalAccuracy: 5,
                   verticalAccuracy: 5,
                   course: 0,
                   speed: speed,
                   timestamp: Date())
    }

    /// 未决定授权：启动会话只弹权限框，不开始更新。
    func testNotDeterminedSessionRequestsAuthorizationWithoutStarting() {
        let (service, manager) = makeService()
        // 初始授权状态即 notDetermined（无任何回调）。

        service.startForegroundSession()

        XCTAssertEqual(manager.authorizationRequestCount, 1)
        XCTAssertEqual(manager.startUpdateCount, 0)
        XCTAssertEqual(service.authorizationStatus, .notDetermined)
    }

    /// 已授权：启动会话直接开始更新，且不再请求权限。
    func testAuthorizedSessionStartsUpdatesWithoutRequesting() {
        let (service, manager) = makeService()
        deliverAuthorization(.authorizedWhenInUse, to: service, via: manager)

        service.startForegroundSession()

        XCTAssertEqual(manager.startUpdateCount, 1)
        XCTAssertEqual(manager.authorizationRequestCount, 0)
        XCTAssertEqual(service.authorizationStatus, .authorizedWhenInUse)
    }

    func testBackgroundTrackingRequestsAlwaysAuthorizationAndEnablesUpdatesOnlyInBackgroundSession() {
        let (service, manager) = makeService()
        deliverAuthorization(.authorizedWhenInUse, to: service, via: manager)
        service.startForegroundSession()

        service.setBackgroundTrackingEnabled(true)
        XCTAssertEqual(manager.alwaysAuthorizationRequestCount, 1)
        XCTAssertFalse(manager.pausesLocationUpdatesAutomatically)
        XCTAssertFalse(manager.allowsBackgroundLocationUpdates)

        deliverAuthorization(.authorizedAlways, to: service, via: manager)
        service.setBackgroundSessionActive(true)
        XCTAssertTrue(manager.allowsBackgroundLocationUpdates)

        service.setBackgroundSessionActive(false)
        XCTAssertFalse(manager.allowsBackgroundLocationUpdates)

        service.setBackgroundTrackingEnabled(false)
        XCTAssertTrue(manager.pausesLocationUpdatesAutomatically)
    }

    /// 已拒绝/受限：启动会话不请求、不更新。
    func testDeniedSessionStartsNothing() {
        let (service, manager) = makeService()
        deliverAuthorization(.denied, to: service, via: manager)

        service.startForegroundSession()

        XCTAssertEqual(manager.authorizationRequestCount, 0)
        XCTAssertEqual(manager.startUpdateCount, 0)
    }

    // MARK: - 启动即同步管理器授权状态（无任何回调）

    /// 已授权（构造前注入模拟状态）：服务初始即上报已授权，启动会话直接开始更新且不请求权限。
    func testAuthorizedStartupSeedsStatusAndStartsWithoutRequesting() {
        let manager = RecordingCLLocationManager()
        manager.simulatedAuthorizationStatus = .authorizedWhenInUse
        let service = LocationService(manager: manager)

        XCTAssertEqual(service.authorizationStatus, .authorizedWhenInUse)

        service.startForegroundSession()

        XCTAssertEqual(manager.startUpdateCount, 1)
        XCTAssertEqual(manager.authorizationRequestCount, 0)
    }

    /// 已拒绝（构造前注入模拟状态）：服务初始即上报已拒绝，启动会话不请求、不更新。
    func testDeniedStartupSeedsStatusAndStartsNothing() {
        let manager = RecordingCLLocationManager()
        manager.simulatedAuthorizationStatus = .denied
        let service = LocationService(manager: manager)

        XCTAssertEqual(service.authorizationStatus, .denied)

        service.startForegroundSession()

        XCTAssertEqual(manager.authorizationRequestCount, 0)
        XCTAssertEqual(manager.startUpdateCount, 0)
    }

    /// 弹窗授权完成（会话仍激活）：经授权变化缝自动开始更新。
    func testAuthorizationGrantedMidSessionStartsUpdates() {
        let (service, manager) = makeService()
        service.startForegroundSession() // notDetermined：只弹窗
        XCTAssertEqual(manager.startUpdateCount, 0)

        deliverAuthorization(.authorizedWhenInUse, to: service, via: manager)

        XCTAssertEqual(manager.startUpdateCount, 1)
        XCTAssertEqual(service.authorizationStatus, .authorizedWhenInUse)
    }

    /// 会话中授权被拒绝：停止更新并归零速度。
    func testAuthorizationRevokedMidSessionStopsAndResetsSpeed() {
        let (service, manager) = makeService()
        deliverAuthorization(.authorizedWhenInUse, to: service, via: manager)
        service.startForegroundSession()
        service.locationManager(manager, didUpdateLocations: [location(speed: 10)])
        XCTAssertEqual(service.speedKmh, 36, accuracy: 0.001)

        deliverAuthorization(.denied, to: service, via: manager)

        XCTAssertEqual(manager.stopUpdateCount, 1)
        XCTAssertEqual(service.speedKmh, 0)
    }

    /// 停止前台会话：停止更新、速度归零，且幂等（重复停止不重复调用管理器）。
    func testStopForegroundSessionStopsAndResetsSpeedIdempotently() {
        let (service, manager) = makeService()
        deliverAuthorization(.authorizedWhenInUse, to: service, via: manager)
        service.startForegroundSession()
        service.locationManager(manager, didUpdateLocations: [location(speed: 10)])
        XCTAssertEqual(service.speedKmh, 36, accuracy: 0.001)

        service.stopForegroundSession()
        service.stopForegroundSession()

        XCTAssertEqual(manager.stopUpdateCount, 1)
        XCTAssertEqual(service.speedKmh, 0)
    }

    /// 非活跃期间到达的定位回调被丢弃（停止后不重新写入速度）。
    func testLateLocationUpdateAfterStopIsIgnored() {
        let (service, manager) = makeService()
        deliverAuthorization(.authorizedWhenInUse, to: service, via: manager)
        service.startForegroundSession()

        service.stopForegroundSession()
        service.locationManager(manager, didUpdateLocations: [location(speed: 10)])

        XCTAssertEqual(service.speedKmh, 0)
    }

    /// 速度换算：CLLocation.speed（m/s）× 3.6 = km/h；负速度忽略。
    func testSpeedUpdateConvertsMetersPerSecondToKmh() {
        let (service, manager) = makeService()
        deliverAuthorization(.authorizedWhenInUse, to: service, via: manager)
        service.startForegroundSession()

        service.locationManager(manager, didUpdateLocations: [location(speed: 10)])
        XCTAssertEqual(service.speedKmh, 36, accuracy: 0.001)

        service.locationManager(manager, didUpdateLocations: [location(speed: -1)])
        XCTAssertEqual(service.speedKmh, 36, accuracy: 0.001) // 负速度不覆盖
    }

    /// `requestWhenInUseAuthorization()` 仅在 notDetermined 时生效（已决定后为空操作）。
    func testRequestAuthorizationIsNoOpWhenAlreadyDecided() {
        let (service, manager) = makeService()
        deliverAuthorization(.authorizedWhenInUse, to: service, via: manager)

        service.requestWhenInUseAuthorization()

        XCTAssertEqual(manager.authorizationRequestCount, 0)
    }

    // MARK: - 行程采样发布

    /// 定位更新发布映射后的纯 TripLocationSample（时间/坐标/速度/精度；无 BMS 字段）。
    func testSamplePublisherEmitsMappedPureSample() {
        let (service, manager) = makeService()
        deliverAuthorization(.authorizedWhenInUse, to: service, via: manager)
        service.startForegroundSession()
        var received: [TripLocationSample] = []
        let cancellable = service.samplePublisher.sink { received.append($0) }
        defer { cancellable.cancel() }

        let timestamp = Date(timeIntervalSinceReferenceDate: 123_456)
        service.locationManager(manager, didUpdateLocations: [CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.0, longitude: 121.5),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 0, speed: 10, timestamp: timestamp)])

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].timestamp, timestamp)
        XCTAssertEqual(received[0].latitude, 31.0)
        XCTAssertEqual(received[0].longitude, 121.5)
        XCTAssertEqual(received[0].speedKmh, 36, accuracy: 0.001)
        XCTAssertEqual(received[0].horizontalAccuracyMeters, 5)
        XCTAssertNil(received[0].remainingAh)
        XCTAssertNil(received[0].powerW)
    }

    /// 负速度定位：速度显示不覆盖，但采样速度钳制为 0（行程视为静止）。
    func testSamplePublisherClampsNegativeSpeedToZero() {
        let (service, manager) = makeService()
        deliverAuthorization(.authorizedWhenInUse, to: service, via: manager)
        service.startForegroundSession()
        service.locationManager(manager, didUpdateLocations: [location(speed: 10)])
        XCTAssertEqual(service.speedKmh, 36, accuracy: 0.001)
        var received: [TripLocationSample] = []
        let cancellable = service.samplePublisher.sink { received.append($0) }
        defer { cancellable.cancel() }

        service.locationManager(manager, didUpdateLocations: [location(speed: -1)])

        XCTAssertEqual(service.speedKmh, 36, accuracy: 0.001) // 负速度不覆盖显示
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].speedKmh, 0)
    }

    /// 停止更新后到达的定位回调不发布采样（仅前台激活且正在更新时发布）。
    func testSamplePublisherIsSilentAfterStop() {
        let (service, manager) = makeService()
        deliverAuthorization(.authorizedWhenInUse, to: service, via: manager)
        service.startForegroundSession()
        service.stopForegroundSession()
        var received: [TripLocationSample] = []
        let cancellable = service.samplePublisher.sink { received.append($0) }
        defer { cancellable.cancel() }

        service.locationManager(manager, didUpdateLocations: [location(speed: 10)])

        XCTAssertTrue(received.isEmpty)
    }

    /// `start()` 需要前台会话激活 + 已授权（无会话直接调用不启动）。
    func testStartRequiresActiveSessionAndAuthorization() {
        let (service, manager) = makeService()
        deliverAuthorization(.authorizedWhenInUse, to: service, via: manager)

        service.start() // 未激活会话

        XCTAssertEqual(manager.startUpdateCount, 0)

        service.startForegroundSession()
        service.start() // 已激活 + 已授权

        XCTAssertEqual(manager.startUpdateCount, 1)
    }
}

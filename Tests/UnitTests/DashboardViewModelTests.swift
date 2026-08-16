import Combine
import CoreLocation
import XCTest
@testable import GPSAntBMS

/// 定位提供者 Mock：可编程发布速度与授权状态（验证视图模型的 GPS 订阅路径）。
private final class MockSpeedProvider: SpeedProviding {
    private let speedSubject = PassthroughSubject<Double, Never>()
    private let authorizationSubject = PassthroughSubject<CLAuthorizationStatus, Never>()

    var speedKmh: Double = 0
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    var speedPublisher: AnyPublisher<Double, Never> {
        speedSubject.eraseToAnyPublisher()
    }

    var authorizationPublisher: AnyPublisher<CLAuthorizationStatus, Never> {
        authorizationSubject.eraseToAnyPublisher()
    }

    func emit(speed: Double) {
        speedSubject.send(speed)
    }

    func emit(authorization: CLAuthorizationStatus) {
        authorizationSubject.send(authorization)
    }
}

/// 仪表盘视图模型：生命周期职责上移到 App 根协调器后的纯状态镜像 + 控制委托缝。
final class DashboardViewModelTests: XCTestCase {
    private func makeService() -> BmsBluetoothService {
        // 注入 MockCentralManager：模拟器上真实 CBCentralManager 的 daemon 系统状态
        // 回调会覆盖测试注入的蓝牙状态（无蓝牙硬件时回调 `.unsupported/.poweredOff`），
        // 使 5 秒等待类断言产生竞态；替身固定 `.poweredOn` 并空操作，见
        // TestSupport/MockCentralManager.swift。
        BmsBluetoothService(centralManager: MockCentralManager(state: .poweredOn),
                            peripheralUUIDStore: InMemoryPeripheralUUIDStore())
    }

    /// 初始状态全部为零值（未注入数据源）。
    func testInitialStateIsZeroed() {
        let viewModel = DashboardViewModel()

        XCTAssertEqual(viewModel.snapshot, BmsSnapshot())
        XCTAssertEqual(viewModel.bluetoothState, .unknown)
        XCTAssertFalse(viewModel.isScanning)
        XCTAssertEqual(viewModel.connectionState, .idle)
        XCTAssertTrue(viewModel.discoveredDevices.isEmpty)
        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(viewModel.speedKmh, 0)
        XCTAssertEqual(viewModel.authorizationStatus, .notDetermined)
    }

    /// `update(snapshot:)` 完整替换快照（预览/测试注入入口）。
    func testUpdateReplacesSnapshot() {
        let viewModel = DashboardViewModel()
        var snapshot = BmsSnapshot()
        snapshot.totalVoltage = 81.6
        snapshot.current = 12.5
        snapshot.soc = 93

        viewModel.update(snapshot: snapshot)

        XCTAssertEqual(viewModel.snapshot, snapshot)
        XCTAssertEqual(viewModel.snapshot.displayPower(), 81.6 * 12.5, accuracy: 0.001)
    }

    /// 注入共享蓝牙服务后，快照流自动驱动视图模型（App 组合根的共享服务路径）。
    func testSubscriptionDeliversSnapshotsFromSharedService() {
        let service = makeService()
        let viewModel = DashboardViewModel(bluetoothService: service)
        service.startForegroundSession()

        for segment in TestFixtures.messageTxtSegments {
            service.handleIncomingChunk(segment)
        }

        // 快照流经 `receive(on: DispatchQueue.main)` 异步投递：推进主队列等待到达
        // （模拟器 XCTest 的 `wait(for:)` 不驱动主队列，见 TestSupport/AsyncWait.swift）。
        waitUntil(viewModel.snapshot.totalVoltage == 81.602)

        XCTAssertEqual(viewModel.snapshot.soc, 93, accuracy: 0.001)
        XCTAssertEqual(viewModel.snapshot.bmsStatusText, "待机")
        XCTAssertFalse(viewModel.snapshot.isConnected)
    }

    /// 未注入提供者时，视图模型保持零值快照与状态且不订阅任何外部流。
    func testInitialStateWhenNoServicesIsZeroed() {
        let viewModel = DashboardViewModel(bluetoothService: nil, locationService: nil)

        XCTAssertEqual(viewModel.snapshot, BmsSnapshot())
        XCTAssertFalse(viewModel.snapshot.isConnected)
        XCTAssertEqual(viewModel.speedKmh, 0)
        XCTAssertEqual(viewModel.authorizationStatus, .notDetermined)
    }

    /// GPS：速度与授权状态经 `SpeedProviding` 流镜像到视图模型（含初始化初值读取）。
    func testSpeedAndAuthorizationMirrorFromLocationProvider() {
        let provider = MockSpeedProvider()
        provider.speedKmh = 12.3
        provider.authorizationStatus = .authorizedWhenInUse
        let viewModel = DashboardViewModel(locationService: provider)

        // 初始化即读取提供者当前值。
        XCTAssertEqual(viewModel.speedKmh, 12.3)
        XCTAssertEqual(viewModel.authorizationStatus, .authorizedWhenInUse)

        provider.emit(speed: 45.2)
        provider.emit(authorization: .denied)

        waitUntil(viewModel.speedKmh == 45.2 && viewModel.authorizationStatus == .denied)
    }

    /// 蓝牙状态镜像：服务侧状态变化经订阅驱动视图模型。
    func testBluetoothStateMirrorsFromSharedService() {
        let service = makeService()
        let viewModel = DashboardViewModel(bluetoothService: service)
        service.startForegroundSession()

        service.handleBluetoothStateChange(to: .poweredOn)

        waitUntil(viewModel.bluetoothState == .poweredOn && viewModel.isScanning)

        service.handleBluetoothStateChange(to: .poweredOff)

        waitUntil(viewModel.bluetoothState == .poweredOff && !viewModel.isScanning)
    }

    /// 控制委托：扫描/断开/轮询间隔方法转发到实际共享服务。
    func testControlMethodsDelegateToSharedService() {
        let service = makeService()
        let viewModel = DashboardViewModel(bluetoothService: service)
        service.startForegroundSession()
        service.handleBluetoothStateChange(to: .poweredOn)
        service.stopScan() // 复位：让 `startScan` 委托可被观察

        viewModel.startScan()
        XCTAssertTrue(service.isScanning)

        viewModel.stopScan()
        XCTAssertFalse(service.isScanning)

        viewModel.setPollingInterval(50)
        XCTAssertEqual(service.pollingIntervalMilliseconds, 200) // 钳制下限

        viewModel.disconnect()
        XCTAssertEqual(service.connectionState, .idle)
        XCTAssertFalse(service.isConnected)
    }

    /// 控制委托：连接未发现设备时，错误经服务回传并镜像到视图模型。
    func testConnectDelegatesAndMirrorsError() {
        let service = makeService()
        let viewModel = DashboardViewModel(bluetoothService: service)
        service.startForegroundSession()
        service.handleBluetoothStateChange(to: .poweredOn)
        service.stopScan()

        let device = BleDevice(id: UUID(), name: "ANT@TEST", rssi: -60)
        viewModel.connect(to: device)

        waitUntil(viewModel.lastError == .peripheralNotAvailable)

        XCTAssertEqual(service.lastError, .peripheralNotAvailable)
    }
}

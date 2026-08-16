import Combine
import CoreLocation
import Foundation

/// 仪表盘视图模型。
///
/// 数据源：由 App 组合根注入共享 `BmsBluetoothService` 与 `LocationService`，
/// 分别经 `BmsSnapshotProviding` 契约订阅 BMS 快照流、经 `SpeedProviding` 订阅
/// GPS 速度/授权流；未注入时保持零值（预览/单元测试场景）。
///
/// 状态镜像：蓝牙状态（`bluetoothState`/`isScanning`/`connectionState`/
/// `discoveredDevices`/`lastError`）与 GPS 状态均只镜像服务侧的单一事实来源，
/// 视图模型不持有、不写入任何原始数据（GPS 速度不写入 BLE 快照）。
///
/// 生命周期与控制：服务启停由 App 根 `AppLifecycleController`（scenePhase）统一驱动，
/// 视图模型不拥有生命周期；扫描/连接/断开/轮询方法仅转发到实际服务。
final class DashboardViewModel: ObservableObject {
    struct TelemetryPoint: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let soc: Double
        let powerW: Double
        let voltageV: Double
    }
    // MARK: - BMS 快照与蓝牙状态（镜像共享服务）

    @Published private(set) var snapshot: BmsSnapshot
    @Published private(set) var bluetoothState: BluetoothState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var connectionState: BleConnectionState = .idle
    @Published private(set) var discoveredDevices: [BleDevice] = []
    @Published private(set) var currentDevice: BleDevice?
    @Published private(set) var lastError: BleTransportError?
    @Published private(set) var telemetryHistory: [TelemetryPoint] = []

    // MARK: - GPS 状态（镜像共享定位服务）

    @Published private(set) var speedKmh: Double = 0
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let bluetoothService: BmsBluetoothService?
    private let locationService: SpeedProviding?
    private var cancellables: Set<AnyCancellable> = []

    /// - Parameters:
    ///   - bluetoothService: 共享蓝牙服务（生产路径必传；nil 用于预览/纯测试）。
    ///   - locationService: 共享定位提供者（生产路径必传；nil 用于预览/纯测试）。
    init(bluetoothService: BmsBluetoothService? = nil,
         locationService: SpeedProviding? = nil) {
        self.bluetoothService = bluetoothService
        self.locationService = locationService
        self.snapshot = bluetoothService?.snapshot ?? BmsSnapshot()
        self.bluetoothState = bluetoothService?.bluetoothState ?? .unknown
        self.isScanning = bluetoothService?.isScanning ?? false
        self.connectionState = bluetoothService?.connectionState ?? .idle
        self.discoveredDevices = bluetoothService?.discoveredDevices ?? []
        self.currentDevice = bluetoothService?.currentDevice
        self.lastError = bluetoothService?.lastError
        self.speedKmh = locationService?.speedKmh ?? 0
        self.authorizationStatus = locationService?.authorizationStatus ?? .notDetermined
        bindBluetoothService()
        bindLocationService()
    }

    // MARK: - 控制委托（转发到实际服务，不拥有生命周期）

    func startScan() { bluetoothService?.startScan() }
    func stopScan() { bluetoothService?.stopScan() }
    func connect(to device: BleDevice) { bluetoothService?.connect(to: device) }
    func disconnect() { bluetoothService?.disconnect() }
    func reconnect() {
        guard let device = currentDevice else { return }
        bluetoothService?.connect(to: device)
    }
    func setPollingInterval(_ milliseconds: Int) {
        bluetoothService?.setPollingInterval(milliseconds)
    }

    /// 快照手动注入入口（预览数据与单元测试缝；订阅驱动时无需调用）。
    func update(snapshot: BmsSnapshot) {
        self.snapshot = snapshot
        appendTelemetry(snapshot)
    }

    // MARK: - 服务绑定（仅镜像，服务是唯一事实来源）

    private func bindBluetoothService() {
        guard let service = bluetoothService else { return }
        // 经 BmsSnapshotProviding 契约订阅快照流。
        service.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.snapshot = snapshot
                self?.appendTelemetry(snapshot)
            }
            .store(in: &cancellables)
        service.$bluetoothState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.bluetoothState = $0 }
            .store(in: &cancellables)
        service.$isScanning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isScanning = $0 }
            .store(in: &cancellables)
        service.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.connectionState = $0 }
            .store(in: &cancellables)
        service.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.discoveredDevices = $0 }
            .store(in: &cancellables)
        service.$currentDevice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.currentDevice = $0 }
            .store(in: &cancellables)
        service.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastError = $0 }
            .store(in: &cancellables)
    }

    private func bindLocationService() {
        guard let locationService else { return }
        locationService.speedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.speedKmh = $0 }
            .store(in: &cancellables)
        locationService.authorizationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.authorizationStatus = $0 }
            .store(in: &cancellables)
    }

    private func appendTelemetry(_ snapshot: BmsSnapshot) {
        guard snapshot.isConnected else { return }
        telemetryHistory = Array((telemetryHistory + [TelemetryPoint(
            timestamp: snapshot.lastUpdatedAt ?? Date(),
            soc: snapshot.soc,
            powerW: snapshot.displayPower(),
            voltageV: snapshot.totalVoltage)]).suffix(120))
    }
}

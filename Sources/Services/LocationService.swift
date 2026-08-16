import Combine
import CoreLocation
import Foundation

/// 仪表盘 GPS 速度/授权状态提供者契约。
///
/// `DashboardViewModel` 只依赖该协议（而非具体 `LocationService`），
/// 便于单元测试注入 Mock；`LocationService` 是生产实现。
/// 速度与授权状态唯一来源在服务内部（`@Published`），视图模型仅镜像。
protocol SpeedProviding: AnyObject {
    /// 当前 GPS 速度（km/h；未授权/未更新时为 0）。
    var speedKmh: Double { get }

    /// 速度更新流。
    var speedPublisher: AnyPublisher<Double, Never> { get }

    /// 当前定位授权状态。
    var authorizationStatus: CLAuthorizationStatus { get }

    /// 授权状态变化流。
    var authorizationPublisher: AnyPublisher<CLAuthorizationStatus, Never> { get }
}

/// 位置采样提供者契约：纯 `TripLocationSample` 流（不含 BMS 字段）。
///
/// `TripSessionController` 依赖该协议（而非具体 `LocationService`），
/// 便于单元测试注入 Mock；`LocationService` 是生产实现。
protocol LocationSampleProviding: AnyObject {
    /// 位置采样流（活动会话或已开启后台行程且正在更新时发布）。
    var samplePublisher: AnyPublisher<TripLocationSample, Never> { get }
}

/// 定位服务：默认仅前台运行；用户显式启用后台行程后，可在正在记录的后台会话中继续定位。
///
/// 设计约束（与 Android 端对齐但收窄）：
/// - 无 HTTP/WebSocket 上报，数据仅在本机 UI 展示。
/// - 生命周期由 App 根 `AppLifecycleController` 统一驱动（`ForegroundSessionService`）。
/// - 权限行为：仅在 `notDetermined` 时弹权限框；仅授权后启动更新；
///   授权变化（拒绝/受限）立即停止并归零速度。
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var speedKmh: Double = 0
    /// 当前授权状态；初始值在 `init` 中同步自注入的 `CLLocationManager`，
    /// 此后由 `handleAuthorizationChange`（delegate 回调）驱动。
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// 行程位置采样发布通道（活动会话或已开启的后台行程中发送）。
    private let sampleSubject = PassthroughSubject<TripLocationSample, Never>()

    private let manager: CLLocationManager
    private var isUpdating = false
    /// 数据会话是否激活；后台行程开启时在 `.background` 中保持为 true。
    private var isSessionActive = false
    private var backgroundTrackingEnabled = false
    private var isBackgroundSessionActive = false

    /// - Parameter manager: 注入用（测试记录调用）；默认新建真实管理器。
    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        // 启动即同步管理器当前授权状态：已授权/已拒绝无需等待系统回调即可正确决策
        // （iOS 14+ 首次 `locationManagerDidChangeAuthorization` 在设置 delegate 后异步到达）。
        // 直接赋值 @Published 后备存储（而非 wrapped setter）：wrapped setter 会触发
        // `objectWillChange.send()`，访问 ObservableObject 存储，在 super.init 之前不安全。
        _authorizationStatus = Published(initialValue: manager.authorizationStatus)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
    }

    /// 请求前台定位权限。仅在未决定时请求（已决定后不再弹窗）。
    func requestWhenInUseAuthorization() {
        guard authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// 用户主动开启后台行程时升级为始终定位授权；关闭时立即撤销后台定位标记。
    func setBackgroundTrackingEnabled(_ enabled: Bool) {
        backgroundTrackingEnabled = enabled
        manager.pausesLocationUpdatesAutomatically = !enabled
        if enabled, authorizationStatus != .authorizedAlways {
            manager.requestAlwaysAuthorization()
        }
        updateBackgroundLocationAllowance()
    }

    /// 仅由根生命周期在真正进入/离开后台时调用。
    func setBackgroundSessionActive(_ active: Bool) {
        isBackgroundSessionActive = active
        updateBackgroundLocationAllowance()
    }

    /// 开始前台定位更新（幂等：重复调用不会重复启动；仅授权 + 前台会话激活时生效）。
    func start() {
        guard isSessionActive, authorizationStatus.isAuthorized, !isUpdating else { return }
        updateBackgroundLocationAllowance()
        isUpdating = true
        manager.startUpdatingLocation()
    }

    /// 停止定位更新（幂等：重复调用不会重复停止；停止时速度归零）。
    func stop() {
        guard isUpdating else { return }
        isUpdating = false
        manager.allowsBackgroundLocationUpdates = false
        manager.stopUpdatingLocation()
        speedKmh = 0
    }

    /// 授权状态变化统一处理（delegate 回调调用；测试可直接注入状态断言决策分支）。
    ///
    /// - 授权后且会话激活：开始更新（覆盖「弹窗刚被用户允许」的场景）；
    /// - 拒绝/受限：立即停止更新并归零速度。
    func handleAuthorizationChange(to status: CLAuthorizationStatus) {
        authorizationStatus = status
        guard isSessionActive else { return }
        updateBackgroundLocationAllowance()
        if status.isAuthorized {
            start()
        } else {
            stop()
        }
    }
}

extension LocationService: ForegroundSessionService {
    /// 前台会话启动：未决定时弹权限框（授权完成后由 `handleAuthorizationChange` 开始更新），
    /// 已授权时直接开始定位；已拒绝/受限时不启动（TODO(service) 通过 UI 引导去系统设置开启）。
    func startForegroundSession() {
        guard !isSessionActive else { return }
        isSessionActive = true
        switch authorizationStatus {
        case .notDetermined:
            requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            start()
        default:
            break
        }
    }

    func stopForegroundSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        stop()
    }
}

extension LocationService: SpeedProviding {
    var speedPublisher: AnyPublisher<Double, Never> { $speedKmh.eraseToAnyPublisher() }

    var authorizationPublisher: AnyPublisher<CLAuthorizationStatus, Never> {
        $authorizationStatus.eraseToAnyPublisher()
    }
}

extension LocationService: LocationSampleProviding {
    var samplePublisher: AnyPublisher<TripLocationSample, Never> {
        sampleSubject.eraseToAnyPublisher()
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorizationChange(to: manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isSessionActive, isUpdating, let location = locations.last else { return }
        // CLLocation.speed 单位为 m/s，换算为 km/h；负速度（未知）不覆盖已有速度。
        if location.speed >= 0 {
            speedKmh = location.speed * 3.6
        }
        // 行程采样与速度显示同源但独立发布：速度按 max(0, ·) 钳制（未知速度视为静止）。
        sampleSubject.send(TripLocationSample(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            speedKmh: max(0, location.speed * 3.6),
            horizontalAccuracyMeters: location.horizontalAccuracy))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // TODO(service): 错误上报到 UI（定位服务不可用、权限被拒绝等）。
        // 骨架阶段静默保留，避免日志噪音。
        speedKmh = 0
    }
}

private extension LocationService {
    func updateBackgroundLocationAllowance() {
        manager.allowsBackgroundLocationUpdates = backgroundTrackingEnabled
            && isBackgroundSessionActive
            && authorizationStatus == .authorizedAlways
    }
}

private extension CLAuthorizationStatus {
    /// 是否可启动定位更新（When-In-Use 与 Always 均视为授权）。
    var isAuthorized: Bool {
        self == .authorizedWhenInUse || self == .authorizedAlways
    }
}

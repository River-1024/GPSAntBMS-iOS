import Combine
import Foundation
import SwiftUI

/// 前台会话服务：由 App 根生命周期协调器统一驱动启动/停止。
///
/// 实现约定：
/// - `startForegroundSession()` / `stopForegroundSession()` 必须幂等；
/// - `stopForegroundSession()` 必须停止定位与 BLE 扫描，并包含轮询/重连取消点；
/// - 行程会话由同一协议驱动（前台恢复时钟、退后台冻结并保存历史）。
protocol ForegroundSessionService: AnyObject {
    func startForegroundSession()
    func stopForegroundSession()
}

/// App 根生命周期协调器：scenePhase 变化到前台会话开关的唯一映射。
///
/// 设计：
/// - `.active`：启动/恢复前台服务（定位 + BLE 扫描/轮询/重连 + 行程时钟），幂等；
/// - `.inactive`：保留摄像头录制与数据服务，允许控制中心等短暂系统转换；
/// - `.background`：后台行程开关打开时保留数据服务，否则停止并保存历史；
/// - 视图层（`onAppear`/`onDisappear`）不拥有服务生命周期，避免多重所有权。
final class AppLifecycleController: ObservableObject {
    /// 当前是否处于前台激活状态（仅 `scenePhase == .active`）。
    @Published private(set) var isForegroundActive = false

    private let locationService: ForegroundSessionService
    private let bluetoothService: ForegroundSessionService
    private let tripSession: ForegroundSessionService
    /// 独立续航池控制器（同一生命周期驱动：停止前台时 flush 池，回前台重建基线）。
    private let rangePool: ForegroundSessionService
    private let dashcamDidBecomeActive: () -> Void
    private let dashcamWillResignActive: () -> Void
    private let backgroundSessionEnabled: () -> Bool
    private let setBackgroundSessionActive: (Bool) -> Void
    private let setBackgroundKeepAliveActive: (Bool) -> Void
    private var servicesRunning = false
    private var dashcamIsActive = false

    /// - Parameters:
    ///   - locationService: 前台定位服务（**必传**：由 App 组合根注入单一实例，
    ///     与 `DashboardViewModel` 共享，保证 GPS 速度只有一份状态来源）。
    ///   - bluetoothService: 前台蓝牙服务（**必传**：由 App 组合根注入单一实例，
    ///     与 `DashboardViewModel` 共享，保证扫描/连接/快照只有一份状态来源）。
    ///   - tripSession: 前台行程会话（**必传**：由 App 组合根注入单一实例，
    ///     与 `RootView` 共享，保证行程记录只有一份状态来源）。
    ///   - rangePool: 独立续航池控制器（**必传**：由 App 组合根注入单一实例；
    ///     停止前台时 flush，恢复时重建 transient baseline）。
    init(locationService: ForegroundSessionService,
         bluetoothService: ForegroundSessionService,
         tripSession: ForegroundSessionService,
         rangePool: ForegroundSessionService,
         dashcamDidBecomeActive: @escaping () -> Void = {},
         dashcamWillResignActive: @escaping () -> Void = {},
         backgroundSessionEnabled: @escaping () -> Bool = { false },
         setBackgroundSessionActive: @escaping (Bool) -> Void = { _ in },
         setBackgroundKeepAliveActive: @escaping (Bool) -> Void = { _ in }) {
        self.locationService = locationService
        self.bluetoothService = bluetoothService
        self.tripSession = tripSession
        self.rangePool = rangePool
        self.dashcamDidBecomeActive = dashcamDidBecomeActive
        self.dashcamWillResignActive = dashcamWillResignActive
        self.backgroundSessionEnabled = backgroundSessionEnabled
        self.setBackgroundSessionActive = setBackgroundSessionActive
        self.setBackgroundKeepAliveActive = setBackgroundKeepAliveActive
    }

    /// 由 `GPSAntBMSApp` 的 `scenePhase` 变化唯一驱动。
    func scenePhaseDidChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            startForegroundSession()
        case .inactive:
            isForegroundActive = false
        case .background:
            isForegroundActive = false
            stopDashcamIfNeeded()
            let keepBackgroundSession = backgroundSessionEnabled()
            setBackgroundSessionActive(keepBackgroundSession)
            setBackgroundKeepAliveActive(keepBackgroundSession)
            if !keepBackgroundSession {
                stopForegroundSession()
            }
        @unknown default:
            // 未知未来状态一律按非激活处理，保证前台服务不会意外滞留。
            stopForegroundSession()
        }
    }

    /// 启动/恢复前台会话（幂等：重复 `.active` 不会重复启动）。
    /// 启动顺序：location → bluetooth → trip session → range pool
    /// （先恢复数据源，再恢复行程时钟与续航基线）。
    func startForegroundSession() {
        setBackgroundSessionActive(false)
        setBackgroundKeepAliveActive(false)
        isForegroundActive = true
        if !servicesRunning {
            servicesRunning = true
            locationService.startForegroundSession()
            bluetoothService.startForegroundSession()
            tripSession.startForegroundSession()
            rangePool.startForegroundSession()
        }
        if !dashcamIsActive {
            dashcamIsActive = true
            dashcamDidBecomeActive()
        }
    }

    /// 停止前台会话（幂等：`.inactive` 与 `.background` 连续到来不会重复停止）。
    /// 停止顺序：trip session → range pool → bluetooth → location
    /// （行程先冻结/持久化，续航池 flush，再停数据源）。
    func stopForegroundSession() {
        guard servicesRunning else { return }
        isForegroundActive = false
        stopDashcamIfNeeded()
        setBackgroundSessionActive(false)
        setBackgroundKeepAliveActive(false)
        servicesRunning = false
        tripSession.stopForegroundSession()
        rangePool.stopForegroundSession()
        bluetoothService.stopForegroundSession()
        locationService.stopForegroundSession()
    }

    private func stopDashcamIfNeeded() {
        guard dashcamIsActive else { return }
        dashcamIsActive = false
        dashcamWillResignActive()
    }
}

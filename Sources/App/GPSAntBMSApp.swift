import SwiftUI

@main
struct GPSAntBMSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(OrientationAppDelegate.self) private var orientationDelegate

    // 组合根：单一 BmsBluetoothService、单一 LocationService、单一
    // TripSessionController 与单一 RangePoolController 实例。同一组实例同时
    // 注入生命周期协调器与仪表盘/根视图，保证扫描/连接/快照、GPS 速度、行程
    // 记录与综合续航池各只有一份状态来源；所有 StateObject 均持有同一引用，
    // 由 App 组合根（init）一次性创建，避免任何一方重建出第二个实例。
    @StateObject private var bluetoothService: BmsBluetoothService
    @StateObject private var locationService: LocationService
    @StateObject private var tripSession: TripSessionController
    @StateObject private var rangePool: RangePoolController
    @StateObject private var logController: SoftwareLogController
    @StateObject private var lifecycle: AppLifecycleController
    @StateObject private var dashboardViewModel: DashboardViewModel
    @StateObject private var dashcamController: DashcamRecordingController

    init() {
        let bluetoothService = BmsBluetoothService()
        let locationService = LocationService()
        let backgroundKeepAlive = BackgroundKeepAliveService()
        let rangePool = RangePoolController(
            locationProvider: locationService,
            bmsProvider: bluetoothService)
        let tripSession = TripSessionController(
            locationProvider: locationService,
            bmsProvider: bluetoothService,
            pollingIntervalTarget: bluetoothService,
            rangePool: rangePool)
        locationService.setBackgroundTrackingEnabled(tripSession.settings.backgroundTrackingEnabled)
        let logController = SoftwareLogController(
            bluetoothService: bluetoothService,
            tripSession: tripSession)
        let dashcamController = DashcamRecordingController(
            capacityBytes: { [weak tripSession] in
                (tripSession?.settings.recordingCapacityLimit ?? .defaultValue).byteCount
            },
            log: { [weak logController] level, message in
                logController?.append(level: level, source: "行车记录", message: message)
            })
        _bluetoothService = StateObject(wrappedValue: bluetoothService)
        _locationService = StateObject(wrappedValue: locationService)
        _tripSession = StateObject(wrappedValue: tripSession)
        _rangePool = StateObject(wrappedValue: rangePool)
        _logController = StateObject(wrappedValue: logController)
        _dashcamController = StateObject(wrappedValue: dashcamController)
        _lifecycle = StateObject(wrappedValue: AppLifecycleController(
            locationService: locationService,
            bluetoothService: bluetoothService,
            tripSession: tripSession,
            rangePool: rangePool,
            dashcamDidBecomeActive: {
                Task { @MainActor in dashcamController.applicationDidBecomeActive() }
            },
            dashcamWillResignActive: {
                Task { @MainActor in dashcamController.applicationWillResignActive() }
            },
            backgroundSessionEnabled: { [weak tripSession] in
                guard let tripSession else { return false }
                return tripSession.settings.backgroundTrackingEnabled && tripSession.isRecording
            },
            setBackgroundSessionActive: { [weak locationService] active in
                locationService?.setBackgroundSessionActive(active)
            },
            setBackgroundKeepAliveActive: { active in
                if active {
                    backgroundKeepAlive.start()
                } else {
                    backgroundKeepAlive.stop()
                }
            }))
        _dashboardViewModel = StateObject(wrappedValue: DashboardViewModel(
            bluetoothService: bluetoothService,
            locationService: locationService))
    }

    var body: some Scene {
        WindowGroup {
            RootView(viewModel: dashboardViewModel,
                     tripSession: tripSession,
                     logController: logController,
                     dashcamController: dashcamController)
                // 初始交付：iOS 16 的 `onChange` 不保证首帧 scenePhase 回调，
                // 根内容出现时补发一次当前 phase。控制器幂等，与后续 `onChange`
                // 重复交付 `.active` 不会重复启动前台服务。
                .onAppear {
                    lifecycle.scenePhaseDidChange(scenePhase)
                }
        }
        // 前台生命周期驱动点：`.active` 启动/恢复前台服务（定位 + BLE 扫描/轮询/重连 +
        // 行程时钟），`.inactive` / `.background` 停止全部前台工作并冻结/保存行程。
        // 视图层不直接启停服务。
        .onChange(of: scenePhase) { phase in
            lifecycle.scenePhaseDidChange(phase)
        }
        .onChange(of: tripSession.settings.backgroundTrackingEnabled) { enabled in
            locationService.setBackgroundTrackingEnabled(enabled)
        }
    }
}

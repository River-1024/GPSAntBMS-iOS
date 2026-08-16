import SwiftUI

private enum RootTab: Hashable {
    case dashboard
    case devices
    case dashcam
    case trips
    case settings
}

/// 应用根视图：五个一级 Tab（仪表盘 / 设备 / 录像 / 行程 / 设置）。
///
/// 组合根（`GPSAntBMSApp`）注入共享 `DashboardViewModel` 与 `TripSessionController`，
/// 各 Tab 只消费同一实例，不构造、不拥有任何服务；本视图是唯一顶层组合点，
/// 每个 Tab 内独立 `NavigationStack`，无 coordinator/router。
struct RootView: View {
    /// 共享仪表盘视图模型（持有蓝牙/GPS 快照订阅的镜像状态）。
    let viewModel: DashboardViewModel

    /// 共享行程会话控制器（行程记录、历史、设置与续航估算的唯一来源）。
    @ObservedObject var tripSession: TripSessionController
    let logController: SoftwareLogController
    @ObservedObject var dashcamController: DashcamRecordingController
    @State private var selectedTab: RootTab = .dashboard

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DashboardView(viewModel: viewModel,
                              tripSession: tripSession,
                              logController: logController,
                              dashcamController: dashcamController)
                    .navigationTitle("GPS ANT BMS")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("仪表盘", systemImage: "gauge")
            }
            .tag(RootTab.dashboard)
            .accessibilityIdentifier("tab.dashboard")

            NavigationStack {
                DevicesView(viewModel: viewModel,
                            tripSession: tripSession,
                            logController: logController)
                    .navigationTitle("设备")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("设备", systemImage: "antenna.radiowaves.left.and.right")
            }
            .tag(RootTab.devices)
            .accessibilityIdentifier("tab.devices")

            NavigationStack {
                DashcamView(controller: dashcamController) {
                    selectedTab = .dashboard
                }
                .navigationTitle("录像")
                .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("录像", systemImage: "video.fill")
            }
            .tag(RootTab.dashcam)
            .accessibilityIdentifier("tab.dashcam")

            NavigationStack {
                TripsView(tripSession: tripSession)
                    .navigationTitle("行程")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("行程", systemImage: "map")
            }
            .tag(RootTab.trips)
            .accessibilityIdentifier("tab.trips")

            NavigationStack {
                SettingsView(tripSession: tripSession, logController: logController)
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("设置", systemImage: "gearshape")
            }
            .tag(RootTab.settings)
            .accessibilityIdentifier("tab.settings")
        }
        .preferredColorScheme(preferredColorScheme)
        .tint(Theme.Colors.accent)
        .toolbarBackground(.automatic, for: .navigationBar, .tabBar)
        .onAppear {
            OrientationAppDelegate.apply(tripSession.settings.screenOrientation)
        }
        .onChange(of: tripSession.settings.screenOrientation) { preference in
            OrientationAppDelegate.apply(preference)
        }
        .onChange(of: tripSession.settings.recordingCapacityLimit) { _ in
            dashcamController.enforceCapacityLimit()
        }
        .fullScreenCover(isPresented: $dashcamController.isPreviewPresented) {
            DashcamCalibrationView(controller: dashcamController)
        }
        .alert("行车记录", isPresented: Binding(
            get: { dashcamController.alertText != nil },
            set: { if !$0 { dashcamController.clearAlert() } }
        )) {
            if dashcamController.shouldOfferSettings {
                Button("打开设置") { dashcamController.openSystemSettings() }
            }
            Button("好", role: .cancel) { dashcamController.clearAlert() }
        } message: {
            Text(dashcamController.alertText ?? "")
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch tripSession.settings.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

#Preview {
    RootView(viewModel: DashboardViewModel(),
             tripSession: TripSessionController(),
             logController: SoftwareLogController(),
             dashcamController: DashcamRecordingController())
}

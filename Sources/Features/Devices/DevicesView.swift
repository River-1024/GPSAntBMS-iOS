import SwiftUI
import UIKit

/// 设备页：蓝牙适配器状态、扫描/连接状态、最近错误与已发现设备列表。
///
/// 全部控制仅经共享 `DashboardViewModel` 转发到真实蓝牙服务（单一事实来源），
/// 本视图不构造、不拥有任何服务，也不直接触碰 CoreBluetooth。
///
/// 按钮使能语义：
/// - 扫描：仅 `poweredOn` 且不在连接流程中（进行中/已就绪时禁止重新扫描）；
/// - 连接：仅 `poweredOn` 且当前空闲（已连接/连接中一律禁用）；
/// - 断开：连接状态非空闲时可用。
struct DevicesView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var tripSession: TripSessionController
    @ObservedObject var logController: SoftwareLogController
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            bluetoothSection
            if let error = viewModel.lastError {
                errorSection(error)
            }
            devicesSection
            if viewModel.currentDevice != nil {
                Section {
                    NavigationLink("查看当前设备 BMS 详情") {
                        BmsDetailView(viewModel: viewModel,
                                      tripSession: tripSession,
                                      logController: logController)
                    }
                    Button("立即重连") { viewModel.reconnect() }
                        .disabled(!canReconnect)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .appPageBackground()
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                scanButton
                disconnectButton
            }
        }
        .accessibilityIdentifier("devices.screen")
    }

    // MARK: - 蓝牙状态

    private var bluetoothSection: some View {
        Section("蓝牙") {
            statusRow(title: "适配器",
                      detail: viewModel.bluetoothState.displayText,
                      icon: bluetoothIcon,
                      color: adapterColor)
            statusRow(title: "连接状态",
                      detail: viewModel.connectionState.displayText,
                      icon: connectionIcon,
                      color: connectionColor,
                      showsProgress: isConnectingFlow)
            statusRow(title: "扫描",
                      detail: viewModel.isScanning ? "扫描中…" : "已停止",
                      icon: "dot.radiowaves.left.and.right",
                      color: viewModel.isScanning ? Theme.Colors.accent : Theme.Colors.textSecondary)
            if !viewModel.bluetoothState.isUsable {
                Label(bluetoothUnavailableHint, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.warning)
                if viewModel.bluetoothState == .unauthorized {
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    } label: {
                        Label("打开系统设置", systemImage: "gearshape")
                    }
                }
            }
        }
    }

    private var bluetoothIcon: String {
        switch viewModel.bluetoothState {
        case .poweredOn: return "checkmark.circle.fill"
        case .poweredOff: return "power.circle"
        case .unauthorized: return "lock.circle"
        case .unsupported: return "xmark.circle"
        default: return "questionmark.circle"
        }
    }

    private var adapterColor: Color {
        viewModel.bluetoothState.isUsable ? Theme.Colors.accent : Theme.Colors.warning
    }

    private var connectionIcon: String {
        switch viewModel.connectionState {
        case .ready: return "link.circle.fill"
        case .idle: return "circle.dashed"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var connectionColor: Color {
        switch viewModel.connectionState {
        case .ready: return Theme.Colors.accent
        case .idle: return Theme.Colors.textSecondary
        default: return Theme.Colors.warning
        }
    }

    /// 是否处于连接流程中（进行中阶段 → 状态行显示进度圈）。
    private var isConnectingFlow: Bool {
        switch viewModel.connectionState {
        case .connecting, .discoveringServices, .discoveringCharacteristics, .enablingNotify:
            return true
        case .idle, .ready:
            return false
        }
    }

    private var bluetoothUnavailableHint: String {
        switch viewModel.bluetoothState {
        case .unauthorized: return "蓝牙未授权，请在系统设置中允许后重试"
        case .poweredOff: return "请先开启蓝牙"
        default: return "蓝牙暂不可用"
        }
    }

    private func statusRow(title: String, detail: String, icon: String,
                           color: Color, showsProgress: Bool = false) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                HStack(spacing: 6) {
                    if showsProgress {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(detail)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 最近错误

    private func errorSection(_ error: BleTransportError) -> some View {
        Section("最近错误") {
            Label(error.displayText, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.Colors.warning)
        }
    }

    // MARK: - 已发现设备

    private var devicesSection: some View {
        Section("已发现设备") {
            if viewModel.discoveredDevices.isEmpty {
                emptyDevicesRow
            } else {
                ForEach(viewModel.discoveredDevices) { device in
                    deviceRow(device)
                }
            }
        }
    }

    private var emptyDevicesRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.bluetoothState.isUsable ? "未发现设备" : "无法扫描")
                .font(.body)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(viewModel.bluetoothState.isUsable ? "点击右上角「扫描设备」开始搜索附近的 ANT BMS。" : bluetoothUnavailableHint)
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private func deviceRow(_ device: BleDevice) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name ?? "未知设备")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("\(device.rssi) dBm")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer(minLength: 0)
            Button("连接") {
                viewModel.connect(to: device)
            }
            .font(.caption.weight(.semibold))
            .controlSize(.regular)
            .appGlassButtonStyle()
            .tint(Theme.Colors.accent)
            .disabled(!canConnect)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 操作按钮

    private var scanButton: some View {
        Button(viewModel.isScanning ? "停止扫描" : "扫描设备") {
            if viewModel.isScanning {
                viewModel.stopScan()
            } else {
                viewModel.startScan()
            }
        }
        // 扫描中允许停止；空闲时仅在蓝牙可用且不在连接流程中才允许发起扫描。
        .disabled(!viewModel.isScanning && !canStartScan)
        .accessibilityIdentifier("devices.scan")
    }

    private var disconnectButton: some View {
        Button("断开") {
            viewModel.disconnect()
        }
        .disabled(viewModel.connectionState == .idle)
        .accessibilityIdentifier("devices.disconnect")
    }

    // MARK: - 使能语义

    /// 连接流程中（连接/发现/开启通知）或已就绪时禁止重新扫描。
    private var isBusy: Bool {
        viewModel.connectionState != .idle
    }

    private var canStartScan: Bool {
        viewModel.bluetoothState.isUsable && !isBusy
    }

    private var canConnect: Bool {
        viewModel.bluetoothState.isUsable && !isBusy
    }

    private var canReconnect: Bool {
        viewModel.bluetoothState.isUsable && viewModel.connectionState == .idle
    }
}

#Preview {
    DevicesView(viewModel: DashboardViewModel(),
                tripSession: TripSessionController(),
                logController: SoftwareLogController())
}

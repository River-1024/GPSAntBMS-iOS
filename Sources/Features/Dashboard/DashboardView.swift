import CoreLocation
import Charts
import Foundation
import SwiftUI

/// 仪表盘主页：实时遥测大屏。
///
/// 展示（全部来自共享注入的 `DashboardViewModel` / `TripSessionController`）：
/// 连接状态、SOC、总压、电流、显示功率、GPS 速度（`viewModel.speedKmh`）、
/// 压差、温度汇总、剩余/设计容量、SOH、BMS 状态与续航估算（best-effort）。
///
/// 设计约定：
/// - 本视图不拥有任何服务，生命周期由 App 根 scenePhase 协调器统一驱动；
/// - 速度一律取 `DashboardViewModel.speedKmh`（GPS 独立于 BLE，未连接也可用）；
/// - BMS 遥测未连接时以「—」占位，避免误导为真实读数；
/// - 数值用等宽数字，主数值随 Dynamic Type 缩放，横竖屏网格自适应。
struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var tripSession: TripSessionController
    @ObservedObject var logController: SoftwareLogController
    @ObservedObject var dashcamController: DashcamRecordingController

    /// 主数值字号（随 Dynamic Type 缩放，最小为 0.6 倍压缩）。
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 64
    /// 卡片数值字号（随 Dynamic Type 缩放）。
    @ScaledMetric(relativeTo: .title3) private var cardValueSize: CGFloat = 20

    private var snapshot: BmsSnapshot { viewModel.snapshot }
    private var isConnected: Bool { snapshot.isConnected }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.large) {
                statusRow
                heroSection
                metricGrid
                rangeCard
                telemetryChart
                NavigationLink {
                    BmsDetailView(viewModel: viewModel,
                                  tripSession: tripSession,
                                  logController: logController)
                } label: {
                    Label("查看完整 BMS 详情", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .appFlatButtonStyle()
                .tint(Theme.Colors.accent)
            }
            .padding(Theme.Spacing.page)
        }
        .appPageBackground()
        .toolbar {
            if dashcamController.isRecording {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Label(dashcamDurationText, systemImage: "record.circle.fill")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.Colors.danger)
                        .accessibilityLabel("行车记录中，\(dashcamDurationText)")

                    Button { dashcamController.lockEvidence() } label: {
                        Image(systemName: "lock.fill")
                    }
                    .accessibilityLabel("锁定当前录像")
                    .accessibilityIdentifier("dashcam.dashboard.lock")
                }
            }
        }
        .accessibilityIdentifier("dashboard.screen")
    }

    private var dashcamDurationText: String {
        let seconds = Int(dashcamController.sessionDurationSeconds)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - 状态行

    private var statusRow: some View {
        HStack(spacing: Theme.Spacing.medium) {
            connectionBadge
            if isConnected {
                statusChip(text: "BMS · \(snapshot.bmsStatusText)",
                           icon: "battery.100",
                           color: Theme.Colors.textPrimary)
            }
            Spacer(minLength: Theme.Spacing.small)
            gpsChip
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? Theme.Colors.accent : Theme.Colors.warning)
                .frame(width: 8, height: 8)
            Text(isConnected ? "已连接" : "未连接")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .appFlatCapsule()
    }

    private var gpsChip: some View {
        let authorized = viewModel.authorizationStatus == .authorizedWhenInUse
            || viewModel.authorizationStatus == .authorizedAlways
        return statusChip(text: "GPS \(viewModel.authorizationStatus.displayText)",
                          icon: "location.fill",
                          color: authorized ? Theme.Colors.accent : Theme.Colors.textSecondary)
    }

    private func statusChip(text: String, icon: String, color: Color) -> some View {
        Label {
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .appFlatCapsule()
    }

    // MARK: - 主数值区（SOC + GPS 速度）

    private var heroSection: some View {
        HStack(spacing: Theme.Spacing.large) {
            heroBlock(
                value: isConnected ? "\(Int(snapshot.soc.rounded()))%" : "—",
                unit: "SOC",
                color: isConnected && snapshot.soc <= 20 ? Theme.Colors.warning : Theme.Colors.accent
            )
            Rectangle()
                .fill(Theme.Colors.divider)
                .frame(width: 1, height: 88)
            heroBlock(
                value: "\(Int(viewModel.speedKmh.rounded()))",
                unit: "km/h · GPS",
                color: Theme.Colors.textPrimary
            )
        }
        .padding(.vertical, Theme.Spacing.large)
        .padding(.horizontal, Theme.Spacing.medium)
        .frame(maxWidth: .infinity)
        .appFlatCard()
    }

    private func heroBlock(value: String, unit: String, color: Color) -> some View {
        VStack(spacing: Theme.Spacing.small / 2) {
            Text(value)
                .font(Theme.Fonts.metric(heroSize))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 遥测网格

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Theme.Spacing.medium)],
                  spacing: Theme.Spacing.medium) {
            MetricCard(title: "总压",
                       value: telemetry(String(format: "%.2f V", snapshot.totalVoltage)))
            MetricCard(title: "电流",
                       value: telemetry(String(format: "%.1f A", snapshot.current)))
            MetricCard(title: "功率",
                       value: telemetry(String(format: "%.0f W", snapshot.displayPower())))
            MetricCard(title: "压差",
                       value: telemetry("\(snapshot.voltageDiffMillivolts) mV"))
            MetricCard(title: "温度",
                       value: telemetry(temperatureSummary))
            MetricCard(title: "容量（剩余/设计）",
                       value: telemetry(String(format: "%.1f / %.1f Ah",
                                              snapshot.remainingChargeAh, snapshot.capacityAh)))
            MetricCard(title: "SOH",
                       value: telemetry(String(format: "%.0f%%", snapshot.soh)))
        }
    }

    /// 温度汇总：传感器最小–最大（°C）；无传感器数据时为「—」。
    private var temperatureSummary: String {
        let temps = snapshot.temperaturesCelsius
        guard let min = temps.min(), let max = temps.max() else { return "—" }
        return "\(min)–\(max) °C"
    }

    /// BMS 遥测未连接时以占位符展示（GPS 速度不在此列）。
    private func telemetry(_ value: String) -> String {
        isConnected ? value : "—"
    }

    // MARK: - 续航估算（best-effort）

    private var rangeCard: some View {
        let estimate = tripSession.rangeEstimate
        let values = estimate.displayValues(for: tripSession.settings.rangeDisplayMode)
        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(tripSession.settings.rangeDisplayMode == .both ? "续航估算" : values[0].source.displayText)
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            if values.count == 2 {
                HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                    ForEach(values, id: \.source) { value in
                        rangeValue(value, estimate: estimate, compact: true)
                    }
                }
            } else {
                rangeValue(values[0], estimate: estimate, compact: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.medium)
        .appFlatCard()
    }

    @ViewBuilder
    private func rangeValue(
        _ value: RangeDisplayValue,
        estimate: RangeEstimate,
        compact: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small / 2) {
            if compact {
                Text(value.source.displayText)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            if let km = value.estimatedRangeKm, km > 0 {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small / 2) {
                    Text("约 \(Int(km.rounded()))")
                        .font(Theme.Fonts.metric(compact ? cardValueSize * 0.72 : cardValueSize))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("km")
                        .font(.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                if let factor = value.factorKmPerAh {
                    Text(String(format: "系数 %.1f km/Ah", factor))
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                if value.source == .computed {
                    Text("\(estimate.segmentCount) 段 · "
                         + String(format: "窗口 %.1f km / %.1f Ah",
                                  estimate.windowDistanceKm, estimate.windowConsumedAh))
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    if let averageSpeed = estimate.averageEffectiveSpeedKmh {
                        Text(String(format: "平均有效速度 %.0f km/h", averageSpeed))
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            } else {
                Text(value.source == .computed ? "暂无综合续航" : "暂无手动续航")
                    .font(.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(value.source == .computed
                     ? "暂无可信综合观测，前台行驶且 BMS 连接后自动估算。"
                     : "连接 BMS 后按手动系数估算。")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
    }

    private var telemetryChart: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("前台实时曲线")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            if viewModel.telemetryHistory.count < 2 {
                Text("连接并收到至少两帧有效数据后显示曲线")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            } else {
                Chart {
                    ForEach(viewModel.telemetryHistory) { point in
                        LineMark(x: .value("时间", point.timestamp),
                                 y: .value("SOC", point.soc))
                            .foregroundStyle(Theme.Colors.accent)
                            .interpolationMethod(.catmullRom)
                    }
                }
                .frame(height: 180)
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("SOC %")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("前台实时 SOC 曲线")
                .accessibilityValue(telemetryChartAccessibilityValue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.medium)
        .appFlatCard()
    }

    private var telemetryChartAccessibilityValue: String {
        let values = viewModel.telemetryHistory.map(\.soc)
        guard let first = values.first, let last = values.last,
              let minimum = values.min(), let maximum = values.max() else {
            return "暂无足够数据"
        }
        return "\(values.count) 个样本，起始 \(Int(first.rounded()))%，当前 \(Int(last.rounded()))%，范围 \(Int(minimum.rounded()))% 至 \(Int(maximum.rounded()))%"
    }
}

/// 单个遥测指标卡片。
private struct MetricCard: View {
    let title: String
    let value: String
    @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small / 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text(value)
                .font(Theme.Fonts.metric(valueSize))
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.medium)
        .appFlatCard()
    }
}

#Preview {
    DashboardView(viewModel: DashboardViewModel(),
                  tripSession: TripSessionController(),
                  logController: SoftwareLogController(),
                  dashcamController: DashcamRecordingController())
}

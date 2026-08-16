import Foundation
import SwiftUI

/// 行程页：当前记录状态、距离/时长/均速、续航估算、开始/结束与历史管理。
///
/// 数据全部来自共享注入的 `TripSessionController`（后台保活开启时，后台行程也会继续记录）。
///
/// 时长显示约定：`currentDurationSeconds` 在接受采样/生命周期/操作时由控制器刷新，
/// 本视图**不添加定时器**，只渲染控制器发布的最新值。
struct TripsView: View {
    @ObservedObject var tripSession: TripSessionController
    @Environment(\.editMode) private var editMode
    @State private var showClearConfirmation = false
    @State private var showNamePrompt = false
    @State private var pendingName = ""
    @State private var selectedIDs = Set<UUID>()

    var body: some View {
        List(selection: $selectedIDs) {
            currentTripSection
            historySection
        }
        .scrollContentBackground(.hidden)
        .appPageBackground()
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !tripSession.history.isEmpty {
                    EditButton()
                        .accessibilityIdentifier("trips.manage")
                }
                if isManaging {
                    Button(selectedIDs.count == tripSession.history.count ? "取消全选" : "全选") {
                        toggleSelectAll()
                    }
                    Button(role: .destructive) { showClearConfirmation = true } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selectedIDs.isEmpty)
                    .accessibilityLabel("删除所选行程")
                } else if !tripSession.history.isEmpty {
                    Button(role: .destructive) { showClearConfirmation = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("清空历史")
                    .accessibilityIdentifier("trips.clear")
                }
            }
        }
        .confirmationDialog(isManaging ? "删除所选行程？" : "清空全部行程？",
                            isPresented: $showClearConfirmation,
                            titleVisibility: .visible) {
            Button(isManaging ? "删除所选" : "清空全部", role: .destructive) {
                if isManaging {
                    tripSession.deleteTrips(ids: selectedIDs)
                    selectedIDs.removeAll()
                    editMode?.wrappedValue = .inactive
                } else {
                    tripSession.clearTrips()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(isManaging ? "将删除当前选中的历史行程，此操作不可恢复。" : "将删除全部历史行程记录，此操作不可恢复。")
        }
        .alert("命名行程", isPresented: $showNamePrompt) {
            TextField("例如：回家", text: $pendingName)
            Button("保存并结束") {
                tripSession.stopTrip(name: pendingName)
                pendingName = ""
            }
            Button("直接结束") {
                tripSession.stopTrip()
                pendingName = ""
            }
            Button("继续记录", role: .cancel) {}
        } message: {
            Text("为这次前台行程添加一个便于查找的名称。")
        }
        .accessibilityIdentifier("trips.screen")
    }

    private var isManaging: Bool {
        editMode?.wrappedValue == .active
    }

    // MARK: - 当前行程

    private var currentTripSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                recordingHeader
                currentMetrics
                rangeRows
                actionButtons
            }
            .padding(.vertical, Theme.Spacing.small)
        } header: {
            Text("当前行程")
        }
    }

    private var recordingHeader: some View {
        HStack(spacing: Theme.Spacing.small) {
            Circle()
                .fill(tripSession.isRecording ? Theme.Colors.danger : Theme.Colors.textSecondary)
                .frame(width: 10, height: 10)
            Text(tripSession.isRecording ? "记录中" : "未开始")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.Colors.textPrimary)
            Spacer(minLength: 0)
            if tripSession.isRecording {
                Text(tripSession.settings.backgroundTrackingEnabled ? "后台保活开启时持续计入" : "仅前台激活时段计入")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var currentMetrics: some View {
        HStack(spacing: Theme.Spacing.medium) {
            metricBlock(title: "距离",
                        value: String(format: "%.2f", tripSession.currentDistanceKm),
                        unit: "km")
            metricBlock(title: "时长",
                        value: durationText(tripSession.currentDurationSeconds),
                        unit: "时分秒")
            metricBlock(title: "均速",
                        value: String(format: "%.1f", tripSession.currentAverageSpeedKmh),
                        unit: "km/h")
        }
    }

    private func metricBlock(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.Fonts.telemetry(22, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rangeRows: some View {
        let values = tripSession.rangeEstimate.displayValues(for: tripSession.settings.rangeDisplayMode)
        ForEach(values, id: \.source) { value in
            if let rangeKm = value.estimatedRangeKm, rangeKm > 0 {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "map")
                        .foregroundStyle(Theme.Colors.accent)
                    Text("\(value.source.displayText)约 \(Int(rangeKm.rounded())) km")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Button {
                tripSession.startTrip()
            } label: {
                Label("开始记录", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .appGlassButtonStyle(prominent: true)
            .tint(Theme.Colors.accent)
            .disabled(tripSession.isRecording)
            .accessibilityIdentifier("trips.start")

            Button(role: .destructive) {
                pendingName = "行程 \(Date().formatted(date: .abbreviated, time: .shortened))"
                showNamePrompt = true
            } label: {
                Label("结束记录", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .appGlassButtonStyle()
            .tint(Theme.Colors.danger)
            .disabled(!tripSession.isRecording)
            .accessibilityIdentifier("trips.stop")
        }
    }

    // MARK: - 历史记录

    private var historySection: some View {
        Section {
            if tripSession.history.isEmpty {
                emptyHistoryRow
            } else {
                ForEach(tripSession.history) { record in
                    if isManaging {
                        historyRow(record)
                            .tag(record.id)
                    } else {
                        NavigationLink {
                            TripDetailView(record: record)
                        } label: {
                            historyRow(record)
                        }
                    }
                }
                .onDelete { indexSet in
                    // 先收集再删除：deleteTrip 会同步变更历史数组。
                    let ids = indexSet.map { tripSession.history[$0].id }
                    ids.forEach(tripSession.deleteTrip)
                }
            }
        } header: {
            Text("历史记录（新 → 旧）")
        }
    }

    private var emptyHistoryRow: some View {
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: "map")
                .font(.largeTitle)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text("暂无行程记录")
                .font(.headline)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("点击「开始记录」后，前台行驶中的 GPS 采样会自动累计距离与时长；结束记录后归档到此。")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.large)
    }

    private func historyRow(_ record: TripRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.name.isEmpty
                     ? record.startedAt.formatted(date: .abbreviated, time: .shortened)
                     : record.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: Theme.Spacing.small)
                Text(durationText(record.durationSeconds))
                    .font(Theme.Fonts.telemetry(15, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            HStack(spacing: Theme.Spacing.medium) {
                Label(String(format: "%.2f km", record.distanceKm),
                      systemImage: "map")
                Label(String(format: "均速 %.1f km/h", record.averageSpeedKmh),
                      systemImage: "speedometer")
                if record.consumedAh > 0 {
                    Label(String(format: "%.1f Ah", record.consumedAh), systemImage: "bolt")
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private func toggleSelectAll() {
        if selectedIDs.count == tripSession.history.count {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(tripSession.history.map(\.id))
        }
    }

    // MARK: - 稳定时长格式（小时/分钟/秒）

    /// 稳定格式化：>= 1 小时输出 `H:MM:SS`，否则 `MM:SS`（等宽数字，避免跳位）。
    /// 注意：不添加定时器，仅格式化控制器发布的最新时长。
    private func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

#Preview {
    TripsView(tripSession: TripSessionController())
}

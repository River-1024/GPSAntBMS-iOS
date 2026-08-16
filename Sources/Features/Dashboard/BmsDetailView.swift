import SwiftUI

/// BMS 完整详情：连接、核心遥测、电芯、MOS/均衡、累计统计和协议诊断。
struct BmsDetailView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var tripSession: TripSessionController
    @ObservedObject var logController: SoftwareLogController

    private var snapshot: BmsSnapshot { viewModel.snapshot }

    var body: some View {
        List {
            connectionSection
            Section("工具") {
                NavigationLink("软件日志") {
                    SoftwareLogView(logController: logController)
                }
            }
            telemetrySection
            cellsSection
            mosSection
            capacitySection
            protocolSection
        }
        .scrollContentBackground(.hidden)
        .appPageBackground()
        .navigationTitle("BMS 详情")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("bms.details.screen")
    }

    private var connectionSection: some View {
        Section("连接") {
            detailRow("状态", viewModel.connectionState.displayText)
            detailRow("设备", viewModel.currentDevice?.name ?? "未知设备")
            detailRow("UUID", viewModel.currentDevice?.id.uuidString ?? "无")
            detailRow("RSSI", rssiText)
            detailRow("GPS 授权", viewModel.authorizationStatus.displayText)
            detailRow("GPS 速度", String(format: "%.1f km/h", viewModel.speedKmh))
            if let error = viewModel.lastError {
                Label(error.displayText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warning)
            }
        }
    }

    private var telemetrySection: some View {
        Section("核心遥测") {
            detailRow("保护板状态", live(snapshot.bmsStatusText))
            detailRow("总电压", live(String(format: "%.2f V", snapshot.totalVoltage)))
            detailRow("电流", live(String(format: "%.1f A", snapshot.current)))
            detailRow("功率", live(String(format: "%.0f W", snapshot.displayPower())))
            detailRow("SOC", live(String(format: "%.0f%%", snapshot.soc)))
            detailRow("SOH", live(String(format: "%.0f%%", snapshot.soh)))
            detailRow("容量", live(String(format: "%.2f / %.2f Ah", snapshot.remainingChargeAh, snapshot.capacityAh)))
            detailRow("续航", rangeText)
            detailRow("MOS 温度", live("\(snapshot.mosTemperatureCelsius) °C"))
            detailRow("均衡温度", live("\(snapshot.balancerTemperatureCelsius) °C"))
            detailRow("传感器温度", live(sensorTemperaturesText))
            detailRow("运行时间", live(durationText(snapshot.runtimeSeconds)))
        }
    }

    private var cellsSection: some View {
        Section("电芯诊断") {
            detailRow("串数", live("\(snapshot.cellVoltagesMillivolts.count) S"))
            detailRow("平均电压", live("\(snapshot.averageCellVoltageMillivolts) mV"))
            detailRow("最高电芯", live(cellExtreme(index: snapshot.maxCellIndex, voltage: snapshot.maxCellVoltageMillivolts)))
            detailRow("最低电芯", live(cellExtreme(index: snapshot.minCellIndex, voltage: snapshot.minCellVoltageMillivolts)))
            detailRow("最大压差", live("\(snapshot.voltageDiffMillivolts) mV"))
            ForEach(Array(snapshot.cellVoltagesMillivolts.enumerated()), id: \.offset) { index, voltage in
                detailRow("第 \(index + 1) 串", live(String(format: "%.0f mV", voltage)))
            }
        }
    }

    private var mosSection: some View {
        Section("MOS 与均衡") {
            detailRow("充电 MOS", live(switchText(snapshot.chargeMosOn)))
            detailRow("放电 MOS", live(switchText(snapshot.dischargeMosOn)))
            detailRow("均衡状态", live(balanceStatusText))
            detailRow("均衡电芯", live(balancedCellsText))
            detailRow("均衡掩码", live(String(format: "0x%016llX", CUnsignedLongLong(snapshot.balanceMask))))
        }
    }

    private var capacitySection: some View {
        Section("容量统计") {
            detailRow("循环容量", live(String(format: "%.3f Ah", snapshot.cycleCapacityAh)))
            detailRow("累计充电", live(String(format: "%.3f Ah", snapshot.totalChargeCapacityAh)))
            detailRow("累计放电", live(String(format: "%.3f Ah", snapshot.totalDischargeCapacityAh)))
            detailRow("累计充电时间", live(durationText(snapshot.totalChargeTimeSeconds)))
            detailRow("累计放电时间", live(durationText(snapshot.totalDischargeTimeSeconds)))
        }
    }

    private var protocolSection: some View {
        Section("协议诊断") {
            detailRow("状态码", snapshot.bmsStatusCode.map(String.init) ?? "未知")
            detailRow("帧长度", snapshot.frameLength > 0 ? "\(snapshot.frameLength) bytes" : "未知")
            detailRow("未解析字节", "\(snapshot.unparsedBytes) bytes")
            detailRow("最近有效数据", snapshot.lastUpdatedAt?.formatted(date: .abbreviated, time: .standard) ?? "无")
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(Theme.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(title)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private func live(_ value: String) -> String { snapshot.isConnected ? value : "—" }
    private var rssiText: String {
        guard let rssi = viewModel.currentDevice?.rssi, rssi != 0 else { return "未知" }
        return "\(rssi) dBm"
    }
    private var rangeText: String {
        guard snapshot.isConnected else { return "—" }
        let values = tripSession.rangeEstimate.displayValues(for: tripSession.settings.rangeDisplayMode)
        let texts = values.compactMap { value -> String? in
            guard let km = value.estimatedRangeKm else { return nil }
            return String(format: "%@ %.1f km", value.source.displayText, km)
        }
        return texts.isEmpty ? "—" : texts.joined(separator: " / ")
    }
    private var sensorTemperaturesText: String {
        snapshot.temperaturesCelsius.isEmpty ? "无" : snapshot.temperaturesCelsius.map { "\($0) °C" }.joined(separator: ", ")
    }
    private func cellExtreme(index: Int, voltage: Int) -> String {
        index > 0 ? "第 \(index) 串 · \(voltage) mV" : "未知"
    }
    private func switchText(_ value: Bool?) -> String { value.map { $0 ? "开启" : "关闭" } ?? "未知" }
    private var balanceStatusText: String { snapshot.balanceStatus == 0 ? "未均衡" : "状态 \(snapshot.balanceStatus)" }
    private var balancedCellsText: String {
        let cells = snapshot.cellVoltagesMillivolts.indices.compactMap { index in
            (snapshot.balanceMask & (UInt64(1) << index)) != 0 ? String(index + 1) : nil
        }
        return cells.isEmpty ? "无" : cells.joined(separator: ", ")
    }
    private func durationText(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        return days > 0 ? "\(days)天 \(hours)小时 \(minutes)分" : "\(hours)小时 \(minutes)分"
    }
}

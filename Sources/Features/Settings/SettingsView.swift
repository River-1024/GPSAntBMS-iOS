import Foundation
import SwiftUI

private enum SettingsInputField: Hashable {
    case pollingInterval
    case manualRangeFactor
    case effectiveSpeed
    case rangeWindow
    case rangeRefresh
    case newRangeWeight
    case powerYellow
    case powerRed
    case socYellow
    case socRed
    case voltageYellow
    case voltageRed
    case temperatureYellow
    case temperatureRed
}

/// 设置页：使用 iOS 原生分组列表布局，数值项同时支持键盘输入与步进微调。
struct SettingsView: View {
    @ObservedObject var tripSession: TripSessionController
    @ObservedObject var logController: SoftwareLogController
    @FocusState private var focusedField: SettingsInputField?

    var body: some View {
        Form {
            appearanceSection
            samplingSection
            rangeSection
            backgroundSection
            displaySection
            recordingSection
            thresholdSection
            diagnosticsSection
            if let warning = tripSession.storageWarning {
                storageWarningSection(warning)
            }
            if let rangeWarning = tripSession.rangeStorageWarning {
                storageWarningSection(rangeWarning)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .appPageBackground()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .accessibilityIdentifier("settings.screen")
    }

    private var appearanceSection: some View {
        Section("外观") {
            Picker(selection: appearanceBinding) {
                ForEach(AppearancePreference.allCases, id: \.self) { appearance in
                    Text(appearance.displayText).tag(appearance)
                }
            } label: {
                Label("外观", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.menu)
        }
    }

    private var samplingSection: some View {
        Section("采样与估算") {
            numericRow(
                "轮询间隔",
                value: pollingIntervalBinding,
                range: Double(PollInterval.minimumMilliseconds)...Double(PollInterval.maximumMilliseconds),
                step: 100,
                unit: "ms",
                field: .pollingInterval
            )
            numericRow(
                "手动续航系数",
                value: manualFactorBinding,
                range: AppSettings.minimumManualRangeKmPerAh...AppSettings.maximumManualRangeKmPerAh,
                step: 0.1,
                fractionDigits: 1,
                unit: "km/Ah",
                field: .manualRangeFactor
            )
            numericRow(
                "有效速度阈值",
                value: effectiveSpeedBinding,
                range: AppSettings.minimumEffectiveSpeedKmh...AppSettings.maximumEffectiveSpeedKmh,
                step: 1,
                unit: "km/h",
                field: .effectiveSpeed
            )
        }
    }

    private var rangeSection: some View {
        Section {
            Picker("续航显示", selection: rangeDisplayModeBinding) {
                ForEach(RangeDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayText).tag(mode)
                }
            }
            .pickerStyle(.menu)
            numericRow(
                "综合续航窗口",
                value: rangeWindowMinutesBinding,
                range: Double(AppSettings.minimumRangeWindowSeconds / 60)...Double(AppSettings.maximumRangeWindowSeconds / 60),
                step: 1,
                unit: "分钟",
                field: .rangeWindow
            )
            numericRow(
                "续航刷新频率",
                value: rangeRefreshBinding,
                range: Double(AppSettings.minimumRangeRefreshSeconds)...Double(AppSettings.maximumRangeRefreshSeconds),
                step: 5,
                unit: "秒",
                field: .rangeRefresh
            )
            numericRow(
                "新数据权重",
                value: newWeightPercentBinding,
                range: 0...100,
                step: 5,
                unit: "%",
                field: .newRangeWeight
            )
        } header: {
            Text("续航计算")
        } footer: {
            Text("旧数据权重自动保持为 \(Int((tripSession.settings.oldRangeWeight * 100).rounded()))%。")
        }
    }

    private var backgroundSection: some View {
        Section {
            Toggle(isOn: backgroundTrackingBinding) {
                Label("后台保活", systemImage: "location.fill")
            }
        } footer: {
            Text("仅在正在记录行程时保持定位、蓝牙和静音音频；首次开启会请求始终允许定位。")
        }
    }

    private var displaySection: some View {
        Section("显示") {
            Toggle(isOn: auxiliaryTextBinding) {
                Label("首页辅助文字", systemImage: "text.bubble")
            }
            Picker("仪表盘密度", selection: densityBinding) {
                ForEach(DashboardDensity.allCases, id: \.self) { density in
                    Text(density.displayText).tag(density)
                }
            }
            .pickerStyle(.menu)
            Picker("温度摘要来源", selection: temperatureSourceBinding) {
                ForEach(TemperatureSource.allCases, id: \.self) { source in
                    Text(source.displayText).tag(source)
                }
            }
            .pickerStyle(.menu)
            Picker("屏幕方向偏好", selection: orientationBinding) {
                ForEach(ScreenOrientationPreference.allCases, id: \.self) { value in
                    Text(value.displayText).tag(value)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var thresholdSection: some View {
        Section {
            numericRow("功率黄色", value: powerYellowBinding, range: 0...100_000, step: 100,
                       unit: "W", field: .powerYellow)
            numericRow("功率红色", value: powerRedBinding, range: 0...100_000, step: 100,
                       unit: "W", field: .powerRed)
            numericRow("SOC 黄色", value: socYellowBinding, range: 0...100, step: 1,
                       unit: "%", field: .socYellow)
            numericRow("SOC 红色", value: socRedBinding, range: 0...100, step: 1,
                       unit: "%", field: .socRed)
            numericRow("压差黄色", value: voltageYellowBinding, range: 0...1_000, step: 5,
                       unit: "mV", field: .voltageYellow)
            numericRow("压差红色", value: voltageRedBinding, range: 0...1_000, step: 5,
                       unit: "mV", field: .voltageRed)
            numericRow("温度黄色", value: temperatureYellowBinding, range: -40...150, step: 1,
                       unit: "°C", field: .temperatureYellow, allowsNegative: true)
            numericRow("温度红色", value: temperatureRedBinding, range: -40...150, step: 1,
                       unit: "°C", field: .temperatureRed, allowsNegative: true)
        } header: {
            Text("告警阈值")
        } footer: {
            Text("输入值会在提交时自动限制到合法范围，并保持黄色、红色阈值顺序有效。")
        }
    }

    private var recordingSection: some View {
        Section {
            Picker("录像库容量", selection: recordingCapacityBinding) {
                ForEach(RecordingCapacityLimit.allCases, id: \.self) { limit in
                    Text(limit.displayText).tag(limit)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("行车记录")
        } footer: {
            Text("默认 10 GB。达到上限后只覆盖最早的普通片段，锁定片段不会自动删除。")
        }
    }

    private var diagnosticsSection: some View {
        Section("诊断") {
            NavigationLink {
                SoftwareLogView(logController: logController)
            } label: {
                Label("软件日志", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    private func storageWarningSection(_ warning: String) -> some View {
        Section("存储提示") {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.Colors.warning)
        }
    }

    private func numericRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        fractionDigits: Int = 0,
        unit: String,
        field: SettingsInputField,
        allowsNegative: Bool = false
    ) -> some View {
        NumericSettingRow(
            title: title,
            value: value,
            range: range,
            step: step,
            fractionDigits: fractionDigits,
            unit: unit,
            field: field,
            focusedField: $focusedField,
            allowsNegative: allowsNegative
        )
    }

    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(get: { tripSession.settings.appearance }, set: { tripSession.updateAppearance($0) })
    }

    private var pollingIntervalBinding: Binding<Double> {
        Binding(
            get: { Double(tripSession.settings.pollingIntervalMilliseconds) },
            set: { tripSession.updatePollingInterval(Int($0.rounded())) }
        )
    }

    private var manualFactorBinding: Binding<Double> {
        Binding(get: { tripSession.settings.manualRangeKmPerAh }, set: { tripSession.updateManualRangeFactor($0) })
    }

    private var rangeDisplayModeBinding: Binding<RangeDisplayMode> {
        Binding(get: { tripSession.settings.rangeDisplayMode }, set: { tripSession.updateRangeDisplayMode($0) })
    }

    private var backgroundTrackingBinding: Binding<Bool> {
        Binding(get: { tripSession.settings.backgroundTrackingEnabled }, set: { tripSession.updateBackgroundTrackingEnabled($0) })
    }

    private var effectiveSpeedBinding: Binding<Double> {
        Binding(get: { tripSession.settings.effectiveSpeedKmh }, set: { tripSession.updateEffectiveSpeed($0) })
    }

    private var rangeWindowMinutesBinding: Binding<Double> {
        Binding(
            get: { Double(tripSession.settings.rangeWindowSeconds) / 60 },
            set: { tripSession.updateRangeWindowSeconds(Int(($0 * 60).rounded())) }
        )
    }

    private var rangeRefreshBinding: Binding<Double> {
        Binding(
            get: { Double(tripSession.settings.rangeRefreshSeconds) },
            set: { tripSession.updateRangeRefreshSeconds(Int($0.rounded())) }
        )
    }

    private var newWeightPercentBinding: Binding<Double> {
        Binding(
            get: { tripSession.settings.newRangeWeight * 100 },
            set: {
                let newWeight = min(max($0 / 100, 0), 1)
                tripSession.updateRangeWeights(old: 1 - newWeight, new: newWeight)
            }
        )
    }

    private var auxiliaryTextBinding: Binding<Bool> {
        Binding(get: { tripSession.settings.homeAuxiliaryTextEnabled }, set: { tripSession.updateHomeAuxiliaryTextEnabled($0) })
    }

    private var densityBinding: Binding<DashboardDensity> {
        Binding(get: { tripSession.settings.dashboardDensity }, set: { tripSession.updateDashboardDensity($0) })
    }

    private var temperatureSourceBinding: Binding<TemperatureSource> {
        Binding(get: { tripSession.settings.temperatureSource }, set: { tripSession.updateTemperatureSource($0) })
    }

    private var orientationBinding: Binding<ScreenOrientationPreference> {
        Binding(get: { tripSession.settings.screenOrientation }, set: { tripSession.updateScreenOrientation($0) })
    }

    private var recordingCapacityBinding: Binding<RecordingCapacityLimit> {
        Binding(get: { tripSession.settings.recordingCapacityLimit },
                set: { tripSession.updateRecordingCapacityLimit($0) })
    }

    private var powerYellowBinding: Binding<Double> {
        Binding(get: { tripSession.settings.powerYellowThresholdWatts }, set: { tripSession.updateThresholds(powerYellow: $0) })
    }

    private var powerRedBinding: Binding<Double> {
        Binding(get: { tripSession.settings.powerRedThresholdWatts }, set: { tripSession.updateThresholds(powerRed: $0) })
    }

    private var socYellowBinding: Binding<Double> {
        Binding(get: { tripSession.settings.socYellowThreshold }, set: { tripSession.updateThresholds(socYellow: $0) })
    }

    private var socRedBinding: Binding<Double> {
        Binding(get: { tripSession.settings.socRedThreshold }, set: { tripSession.updateThresholds(socRed: $0) })
    }

    private var voltageYellowBinding: Binding<Double> {
        Binding(get: { tripSession.settings.voltageDiffYellowMillivolts }, set: { tripSession.updateThresholds(voltageYellow: $0) })
    }

    private var voltageRedBinding: Binding<Double> {
        Binding(get: { tripSession.settings.voltageDiffRedMillivolts }, set: { tripSession.updateThresholds(voltageRed: $0) })
    }

    private var temperatureYellowBinding: Binding<Double> {
        Binding(get: { tripSession.settings.temperatureYellowCelsius }, set: { tripSession.updateThresholds(temperatureYellow: $0) })
    }

    private var temperatureRedBinding: Binding<Double> {
        Binding(get: { tripSession.settings.temperatureRedCelsius }, set: { tripSession.updateThresholds(temperatureRed: $0) })
    }
}

private struct NumericSettingRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    let unit: String
    let field: SettingsInputField
    var focusedField: FocusState<SettingsInputField?>.Binding
    let allowsNegative: Bool

    @State private var text = ""

    var body: some View {
        ViewThatFits(in: .horizontal) {
            LabeledContent {
                controls
            } label: {
                Text(title)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                controls
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .onAppear(perform: synchronizeText)
        .onChange(of: value) { _ in
            guard focusedField.wrappedValue != field else { return }
            synchronizeText()
        }
        .onChange(of: focusedField.wrappedValue) { newValue in
            if newValue != field {
                commit()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                TextField("数值", text: $text)
                    .keyboardType(allowsNegative ? .numbersAndPunctuation : .decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .dynamicTypeSize(...DynamicTypeSize.accessibility5)
                    .focused(focusedField, equals: field)
                    .onSubmit(commit)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 132, minHeight: 44)
            .settingsFlatControlSurface()

            HStack(spacing: 0) {
                Button {
                    adjustValue(by: -step)
                } label: {
                    Image(systemName: "minus")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(value <= range.lowerBound)
                .accessibilityLabel("减小\(title)")

                Divider()
                    .frame(height: 24)

                Button {
                    adjustValue(by: step)
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(value >= range.upperBound)
                .accessibilityLabel("增大\(title)")
            }
            .settingsFlatControlSurface()
        }
    }

    private func adjustValue(by delta: Double) {
        let adjusted = min(max(value + delta, range.lowerBound), range.upperBound)
        value = fractionDigits == 0 ? adjusted.rounded() : adjusted
        synchronizeText()
    }

    private func commit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            synchronizeText()
            return
        }

        guard let parsed = parsedTextValue() else {
            synchronizeText()
            return
        }

        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        value = fractionDigits == 0 ? clamped.rounded() : clamped
        synchronizeText()
    }

    private func parsedTextValue() -> Double? {
        makeFormatter().number(from: text)?.doubleValue
            ?? Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private func synchronizeText() {
        text = makeFormatter().string(from: NSNumber(value: value)) ?? String(value)
    }

    private func makeFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter
    }
}

#Preview {
    NavigationStack {
        SettingsView(tripSession: TripSessionController(), logController: SoftwareLogController())
            .navigationTitle("设置")
    }
}

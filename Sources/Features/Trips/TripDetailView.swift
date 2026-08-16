import Charts
import SwiftUI

struct TripDetailView: View {
    let record: TripRecord
    @State private var metric: Metric = .speed
    @State private var range: SampleRange = .all
    @State private var customSeconds = 300

    private enum Metric: String, CaseIterable {
        case speed = "速度"
        case power = "功率"
    }

    private enum SampleRange: Hashable {
        case all
        case seconds(Int)
        case custom

        var title: String {
            switch self {
            case .all: return "全部"
            case .seconds(let value): return "最近 \(value / 60) 分钟"
            case .custom: return "自定义"
            }
        }
    }

    private var samples: [TripLocationSample] {
        guard !record.samples.isEmpty else { return [] }
        let seconds: TimeInterval?
        switch range {
        case .all: seconds = nil
        case .seconds(let value): seconds = TimeInterval(value)
        case .custom: seconds = TimeInterval(customSeconds)
        }
        guard let seconds else { return record.samples }
        let cutoff = record.endedAt.addingTimeInterval(-seconds)
        return record.samples.filter { $0.timestamp >= cutoff }
    }

    var body: some View {
        List {
            summarySection
            chartSection
        }
        .scrollContentBackground(.hidden)
        .appPageBackground()
        .navigationTitle(record.name.isEmpty ? "行程详情" : record.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("trip.detail.screen")
    }

    private var summarySection: some View {
        Section("摘要") {
            row("开始", record.startedAt.formatted(date: .abbreviated, time: .standard))
            row("结束", record.endedAt.formatted(date: .abbreviated, time: .standard))
            row("前台时长", durationText(record.durationSeconds))
            row("距离", String(format: "%.2f km", record.distanceKm))
            row("平均速度", String(format: "%.1f km/h", record.averageSpeedKmh))
            row("开始剩余容量", record.startRemainingAh.map { String(format: "%.2f Ah", $0) } ?? "无数据")
            row("结束剩余容量", record.endRemainingAh.map { String(format: "%.2f Ah", $0) } ?? "无数据")
            row("消耗容量", record.consumedAh > 0 ? String(format: "%.2f Ah", record.consumedAh) : "无数据")
            row("平均能耗", record.energyAhPer100Km > 0 ? String(format: "%.2f Ah/100km", record.energyAhPer100Km) : "无数据")
        }
    }

    private var chartSection: some View {
        Section("曲线") {
            Picker("指标", selection: $metric) {
                ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("范围", selection: $range) {
                Text("全部").tag(SampleRange.all)
                Text("1 分钟").tag(SampleRange.seconds(60))
                Text("5 分钟").tag(SampleRange.seconds(300))
                Text("15 分钟").tag(SampleRange.seconds(900))
                Text("自定义").tag(SampleRange.custom)
            }
            if range == .custom {
                Stepper("最近 \(customSeconds) 秒", value: $customSeconds, in: 10...86_400, step: 10)
            }
            if samples.isEmpty {
                Text("该行程没有可用于绘图的采样数据")
                    .foregroundStyle(Theme.Colors.textSecondary)
            } else {
                Chart {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                        LineMark(
                            x: .value("时间", sample.timestamp),
                            y: .value(metric.rawValue, metric == .speed ? sample.speedKmh : (sample.powerW ?? 0)))
                            .foregroundStyle(metric == .speed ? Theme.Colors.accent : Theme.Colors.warning)
                    }
                }
                .frame(height: 220)
                .chartYAxisLabel(metric == .speed ? "km/h" : "W")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("行程\(metric.rawValue)曲线")
                .accessibilityValue(chartAccessibilityValue)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
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

    private var chartAccessibilityValue: String {
        let values = samples.map { metric == .speed ? $0.speedKmh : ($0.powerW ?? 0) }
        guard let first = values.first, let last = values.last,
              let minimum = values.min(), let maximum = values.max() else {
            return "暂无数据"
        }
        let unit = metric == .speed ? "公里每小时" : "瓦"
        return "\(values.count) 个样本，起始 \(String(format: "%.1f", first))\(unit)，当前 \(String(format: "%.1f", last))\(unit)，范围 \(String(format: "%.1f", minimum)) 至 \(String(format: "%.1f", maximum))"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

import SwiftUI
import UIKit

struct SoftwareLogView: View {
    @ObservedObject var logController: SoftwareLogController
    @State private var minimumLevel = SoftwareLogLevel.info
    @State private var showClearConfirmation = false
    @State private var copied = false
    @State private var searchText = ""

    private var visibleEntries: [SoftwareLogEntry] {
        Array(logController.entries.filter {
            guard $0.level >= minimumLevel else { return false }
            guard !searchText.isEmpty else { return true }
            return $0.source.localizedCaseInsensitiveContains(searchText)
                || $0.message.localizedCaseInsensitiveContains(searchText)
        }.reversed())
    }

    var body: some View {
        List {
            controlsSection
            if let warning = logController.storageWarning {
                Section("存储提示") {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.warning)
                }
            }
            logsSection
        }
        .scrollContentBackground(.hidden)
        .appPageBackground()
        .navigationTitle("软件日志")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索来源或内容")
        .confirmationDialog("清空全部软件日志？", isPresented: $showClearConfirmation) {
            Button("清空", role: .destructive) { logController.clear() }
            Button("取消", role: .cancel) {}
        }
        .accessibilityIdentifier("logs.screen")
    }

    private var controlsSection: some View {
        Section("操作") {
            Picker("最低等级", selection: $minimumLevel) {
                ForEach(SoftwareLogLevel.allCases, id: \.self) { level in
                    Text(level.displayText).tag(level)
                }
            }
            Button {
                UIPasteboard.general.string = logController.copyText(minimumLevel: minimumLevel)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Label(copied ? "已复制" : "复制当前等级日志", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(visibleEntries.isEmpty)
            Button(role: .destructive) { showClearConfirmation = true } label: {
                Label("清空日志", systemImage: "trash")
            }
            .disabled(logController.entries.isEmpty)
        }
    }

    private var logsSection: some View {
        Section("日志（新 → 旧）") {
            if visibleEntries.isEmpty {
                Text("当前等级下暂无日志")
                    .foregroundStyle(Theme.Colors.textSecondary)
            } else {
                ForEach(visibleEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.timestamp.formatted(date: .numeric, time: .standard))
                            Spacer(minLength: 8)
                            Text(entry.level.displayText)
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(levelColor(entry.level))
                        Text(entry.source)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Text(entry.message)
                            .font(.body)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func levelColor(_ level: SoftwareLogLevel) -> Color {
        switch level {
        case .debug: return Theme.Colors.textSecondary
        case .info: return Theme.Colors.accent
        case .warning: return Theme.Colors.warning
        case .error: return Theme.Colors.danger
        }
    }
}

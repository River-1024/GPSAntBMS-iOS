import SwiftUI

struct DashcamStatusControls: View {
    @ObservedObject var controller: DashcamRecordingController

    var body: some View {
        VStack(spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                statusLabel
                Spacer(minLength: Theme.Spacing.small)
                NavigationLink {
                    RecordingLibraryView(controller: controller)
                } label: {
                    Image(systemName: "film.stack")
                        .frame(width: 44, height: 44)
                }
                .appGlassButtonStyle()
                .accessibilityLabel("录像库")
                .accessibilityIdentifier("dashcam.library")
            }

            HStack(spacing: Theme.Spacing.small) {
                if controller.isRecording {
                    Button { controller.lockEvidence() } label: {
                        Label("锁定", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .appGlassButtonStyle()
                    .accessibilityIdentifier("dashcam.lock")

                    Button { controller.openCalibration() } label: {
                        Image(systemName: "camera.viewfinder")
                            .frame(width: 44, height: 44)
                    }
                    .appGlassButtonStyle()
                    .accessibilityLabel("查看取景")

                    Button { controller.stop() } label: {
                        Label("停止", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .appGlassButtonStyle(prominent: true)
                    .tint(Theme.Colors.danger)
                    .accessibilityIdentifier("dashcam.stop")
                } else {
                    Button { controller.openCalibration() } label: {
                        Label("行车记录", systemImage: "video.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .appGlassButtonStyle(prominent: true)
                    .tint(Theme.Colors.danger)
                    .disabled(isBusy)
                    .accessibilityIdentifier("dashcam.open")
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .appGlassCard()
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var isBusy: Bool {
        switch controller.state {
        case .authorizing, .starting, .finalizing: return true
        default: return false
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .recording: return Theme.Colors.danger
        case .failed, .interrupted: return Theme.Colors.warning
        default: return Theme.Colors.textSecondary
        }
    }

    private var statusText: String {
        switch controller.state {
        case .recording: return "录像中 · \(durationText) · 有声音"
        case .authorizing: return "正在请求权限"
        case .preview: return "正在校准画面"
        case .starting: return "正在开始录像"
        case .finalizing: return "正在保存片段"
        case .interrupted(let reason): return "录像中断 · \(reason)"
        case .failed(let failure): return failure.displayText
        case .idle: return controller.segments.isEmpty ? "未录像" : "已保存 \(controller.segments.count) 段"
        }
    }

    private var durationText: String {
        let seconds = Int(controller.sessionDurationSeconds)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

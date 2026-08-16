import SwiftUI

struct DashcamCalibrationView: View {
    @ObservedObject var controller: DashcamRecordingController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            DashcamPreviewView(session: controller.captureSession)
                .ignoresSafeArea()

            HStack(spacing: Theme.Spacing.medium) {
                Button {
                    controller.cancelCalibration()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 48, height: 48)
                }
                .appGlassButtonStyle()
                .accessibilityLabel("关闭取景")

                Spacer()

                if controller.isRecording {
                    Button {
                        controller.isPreviewPresented = false
                        dismiss()
                    } label: {
                        Label("返回仪表盘", systemImage: "gauge")
                            .frame(minHeight: 48)
                    }
                    .appGlassButtonStyle(prominent: true)
                } else {
                    Button {
                        controller.confirmStart()
                        dismiss()
                    } label: {
                        Label("开始录像", systemImage: "record.circle")
                            .frame(minHeight: 48)
                    }
                    .appGlassButtonStyle(prominent: true)
                    .tint(Theme.Colors.danger)
                    .accessibilityIdentifier("dashcam.confirmStart")
                }
            }
            .padding(Theme.Spacing.page)
        }
        .statusBarHidden(true)
        .interactiveDismissDisabled(controller.isRecording)
        .accessibilityIdentifier("dashcam.preview")
    }
}

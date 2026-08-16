import SwiftUI

struct DashcamView: View {
    @ObservedObject var controller: DashcamRecordingController
    let recordingDidStart: () -> Void

    var body: some View {
        ScrollView {
            DashcamStatusControls(controller: controller)
                .padding(Theme.Spacing.page)
        }
        .appPageBackground()
        .onChange(of: controller.isRecording) { isRecording in
            if isRecording { recordingDidStart() }
        }
        .accessibilityIdentifier("dashcam.screen")
    }
}

#Preview {
    NavigationStack {
        DashcamView(controller: DashcamRecordingController(), recordingDidStart: {})
            .navigationTitle("录像")
    }
}

import SwiftUI

struct RecordingLibraryView: View {
    @ObservedObject var controller: DashcamRecordingController
    @State private var pendingDelete: RecordingSegment?

    var body: some View {
        Group {
            if controller.segments.isEmpty {
                ScrollView {
                    VStack(spacing: Theme.Spacing.medium) {
                        Image(systemName: "film")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Text("暂无录像")
                            .font(.headline)
                        Text("开始行车记录后，完成的片段会显示在这里。")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
            } else {
                List(controller.segments) { segment in
                    NavigationLink {
                        RecordingPlayerView(url: controller.fileURL(for: segment))
                    } label: {
                        segmentRow(segment)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDelete = segment } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        ShareLink(item: controller.fileURL(for: segment)) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        Button { controller.exportToPhotos(segment) } label: {
                            Label("导出到照片", systemImage: "photo.badge.plus")
                        }
                    }
                }
            }
        }
        .navigationTitle("录像库")
        .navigationBarTitleDisplayMode(.inline)
        .appPageBackground()
        .confirmationDialog("删除这段录像？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let pendingDelete { controller.deleteSegment(pendingDelete) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
        .accessibilityIdentifier("dashcam.library.screen")
    }

    private func segmentRow(_ segment: RecordingSegment) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: segment.kind == .locked ? "lock.fill" : "film")
                .foregroundStyle(segment.kind == .locked ? Theme.Colors.warning : Theme.Colors.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(segment.startedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.body)
                Text("\(durationText(segment.durationSeconds)) · \(sizeText(segment.byteCount))")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

import SwiftUI

struct RecordingLibraryView: View {
    @ObservedObject var controller: DashcamRecordingController
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs = Set<UUID>()
    @State private var pendingDeleteIDs = Set<UUID>()
    @State private var shareURLs: [URL] = []

    var body: some View {
        Group {
            if controller.segments.isEmpty {
                emptyLibrary
            } else {
                recordingList
            }
        }
        .navigationTitle("录像库")
        .navigationBarTitleDisplayMode(.inline)
        .appPageBackground()
        .toolbar { libraryToolbar }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionActionBar
            }
        }
        .confirmationDialog(deleteDialogTitle, isPresented: Binding(
            get: { !pendingDeleteIDs.isEmpty },
            set: { if !$0 { pendingDeleteIDs.removeAll() } }
        ), titleVisibility: .visible) {
            Button("删除 \(deletablePendingSegments.count) 段录像", role: .destructive) {
                let result = controller.deleteSegments(ids: pendingDeleteIDs)
                selectedIDs.subtract(result.deletedIDs)
                pendingDeleteIDs.removeAll()
                if isSelecting, selectedIDs.isEmpty {
                    finishSelecting()
                }
            }
            Button("取消", role: .cancel) { pendingDeleteIDs.removeAll() }
        } message: {
            if protectedPendingSegments.count > 0 {
                Text("将删除 \(deletablePendingSegments.count) 段普通录像；\(protectedPendingSegments.count) 段锁定录像会保留，需先明确解锁。")
            } else {
                Text("删除后无法恢复。")
            }
        }
        .sheet(isPresented: Binding(
            get: { !shareURLs.isEmpty },
            set: { if !$0 { shareURLs.removeAll() } }
        )) {
            RecordingLibraryShareSheet(urls: shareURLs) { completed, error in
                shareURLs.removeAll()
                if let error {
                    controller.showAlert("分享失败：\(error.localizedDescription)")
                } else {
                    controller.showAlert(completed ? "分享已完成" : "已取消分享")
                }
            }
        }
        .onChange(of: controller.segments.map(\.id)) { _ in
            selectedIDs.formIntersection(Set(controller.segments.map(\.id)))
        }
        .accessibilityIdentifier("dashcam.library.screen")
    }

    private var recordingList: some View {
        List(selection: $selectedIDs) {
            ForEach(controller.segments) { segment in
                if isSelecting {
                    segmentRow(segment)
                        .tag(segment.id)
                        .accessibilityIdentifier("dashcam.library.row.\(segment.id.uuidString)")
                } else {
                    HStack(spacing: Theme.Spacing.small) {
                        NavigationLink {
                            RecordingPlayerView(url: controller.fileURL(for: segment))
                        } label: {
                            segmentRow(segment)
                        }
                        .contentShape(Rectangle())

                        Menu {
                            Button {
                                presentShare(for: [segment])
                            } label: {
                                Label("分享", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                controller.exportToPhotos(segment)
                            } label: {
                                Label("导出到照片", systemImage: "photo.badge.plus")
                            }
                            Divider()
                            if segment.kind == .locked {
                                Button {
                                    showMutationResult(controller.unlockSegments(ids: [segment.id]),
                                                       successText: "录像已解锁",
                                                       unchangedText: "录像已解锁")
                                } label: {
                                    Label("解锁", systemImage: "lock.open")
                                }
                            } else {
                                Button {
                                    showMutationResult(controller.lockSegments(ids: [segment.id]),
                                                       successText: "录像已锁定",
                                                       unchangedText: "录像已锁定")
                                } label: {
                                    Label("锁定", systemImage: "lock")
                                }
                            }
                            Button(role: .destructive) {
                                requestDeletion(ids: [segment.id])
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .disabled(segment.kind == .locked)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("录像操作")
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if segment.kind == .normal {
                            Button(role: .destructive) {
                                requestDeletion(ids: [segment.id])
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.45)
                            .onEnded { _ in beginSelecting(segment) }
                    )
                    .accessibilityIdentifier("dashcam.library.row.\(segment.id.uuidString)")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .accessibilityIdentifier("dashcam.library.list")
    }

    private var emptyLibrary: some View {
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
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isSelecting {
                Button(allSegmentsSelected ? "取消全选" : "全选") {
                    if allSegmentsSelected {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(controller.segments.map(\.id))
                    }
                }
                .accessibilityIdentifier("dashcam.library.select-all")

                Button("完成") {
                    finishSelecting()
                }
                .accessibilityIdentifier("dashcam.library.done")
            } else if !controller.segments.isEmpty {
                Button {
                    editMode = .active
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .accessibilityLabel("选择录像")
                .accessibilityIdentifier("dashcam.library.manage")
            }
        }
    }

    private var selectionActionBar: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text("已选 \(selectedIDs.count) 段")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.Colors.textSecondary)
                .accessibilityIdentifier("dashcam.library.selection-count")
            Spacer(minLength: 0)
            Button {
                presentShare(for: selectedSegments)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 44, height: 44)
            }
            .disabled(selectedSegments.isEmpty)
            .accessibilityLabel("分享所选录像")
            .accessibilityIdentifier("dashcam.library.share")

            Button {
                controller.exportToPhotos(selectedSegments)
            } label: {
                Image(systemName: "photo.badge.plus")
                    .frame(width: 44, height: 44)
            }
            .disabled(selectedSegments.isEmpty)
            .accessibilityLabel("导出所选录像到照片")
            .accessibilityIdentifier("dashcam.library.export")

            Menu {
                Button {
                    let result = controller.lockSegments(ids: selectedIDs)
                    showMutationResult(result,
                                       successText: "已锁定 \(result.changedCount) 段录像",
                                       unchangedText: "所选录像已锁定")
                } label: {
                    Label("锁定", systemImage: "lock")
                }
                .disabled(selectedSegments.allSatisfy { $0.kind == .locked })
                Button {
                    let result = controller.unlockSegments(ids: selectedIDs)
                    showMutationResult(result,
                                       successText: "已解锁 \(result.changedCount) 段录像",
                                       unchangedText: "所选录像已解锁")
                } label: {
                    Label("解锁", systemImage: "lock.open")
                }
                .disabled(selectedSegments.allSatisfy { $0.kind == .normal })
            } label: {
                Image(systemName: "lock")
                    .frame(width: 44, height: 44)
            }
            .disabled(selectedSegments.isEmpty)
            .accessibilityLabel("锁定或解锁所选录像")
            .accessibilityIdentifier("dashcam.library.lock-menu")

            Button(role: .destructive) {
                requestDeletion(ids: selectedIDs)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
            }
            .disabled(deletableSelectedSegments.isEmpty)
            .accessibilityLabel("删除所选录像")
            .accessibilityIdentifier("dashcam.library.delete")
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, Theme.Spacing.small)
        .background(.bar)
    }

    private var isSelecting: Bool { editMode == .active }
    private var allSegmentsSelected: Bool {
        !controller.segments.isEmpty && selectedIDs.count == controller.segments.count
    }
    private var selectedSegments: [RecordingSegment] {
        controller.segments.filter { selectedIDs.contains($0.id) }
    }
    private var deletableSelectedSegments: [RecordingSegment] {
        selectedSegments.filter { $0.kind == .normal }
    }
    private var deletablePendingSegments: [RecordingSegment] {
        controller.segments.filter { pendingDeleteIDs.contains($0.id) && $0.kind == .normal }
    }
    private var protectedPendingSegments: [RecordingSegment] {
        controller.segments.filter { pendingDeleteIDs.contains($0.id) && $0.kind == .locked }
    }
    private var deleteDialogTitle: String {
        "删除 \(deletablePendingSegments.count) 段录像？"
    }
    private func beginSelecting(_ segment: RecordingSegment) {
        selectedIDs = [segment.id]
        editMode = .active
    }

    private func finishSelecting() {
        selectedIDs.removeAll()
        editMode = .inactive
    }

    private func requestDeletion(ids: Set<UUID>) {
        let deletable = controller.segments.filter { ids.contains($0.id) && $0.kind == .normal }
        guard !deletable.isEmpty else {
            controller.showAlert("锁定录像需先解锁后才能删除")
            return
        }
        pendingDeleteIDs = ids
    }

    private func presentShare(for segments: [RecordingSegment]) {
        let urls = controller.readableFileURLs(for: segments)
        guard !urls.isEmpty else {
            controller.showAlert("所选录像文件不可读，无法分享")
            return
        }
        shareURLs = urls
    }

    private func showMutationResult(
        _ result: RecordingBatchMutationResult,
        successText: String,
        unchangedText: String
    ) {
        guard result.failedIDs.isEmpty else { return }
        controller.showAlert(result.changedCount > 0 ? successText : unchangedText)
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

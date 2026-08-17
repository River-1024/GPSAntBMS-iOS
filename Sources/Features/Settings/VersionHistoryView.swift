import SwiftUI

struct VersionHistoryView: View {
    @State private var result: Result<AppVersionHistory, Error>?

    var body: some View {
        Group {
            switch result {
            case .some(.success(let history)):
                List(history.releases) { release in
                    DisclosureGroup {
                        ForEach(release.changes, id: \.self) { change in
                            Text(change)
                                .font(.body)
                                .padding(.vertical, 2)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("版本 \(release.version)")
                                .font(.body.weight(.semibold))
                            Text("构建 \(release.build) · \(release.releaseDate)")
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .accessibilityIdentifier("version-history.row.\(release.version)")
                    }
                }
            case .some(.failure):
                VStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.Colors.warning)
                    Text("版本记录暂时不可用")
                        .font(.headline)
                    Text("请在下次更新应用后重试。")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .accessibilityIdentifier("version-history.error")
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("版本更新记录")
        .navigationBarTitleDisplayMode(.inline)
        .appPageBackground()
        .task {
            guard case nil = result else { return }
            result = AppVersionHistoryLoader.load()
        }
    }
}

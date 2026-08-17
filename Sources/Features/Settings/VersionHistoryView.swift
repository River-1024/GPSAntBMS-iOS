import SwiftUI

struct VersionHistoryView: View {
    private let result: Result<AppVersionHistory, Error>

    init() {
        result = AppVersionHistoryLoader.load()
    }

    var body: some View {
        Group {
            switch result {
            case .success(let history):
                List(history.releases) { release in
                    DisclosureGroup {
                        ForEach(Array(release.changes.enumerated()), id: \.offset) { index, change in
                            Text(change)
                                .font(.body)
                                .padding(.vertical, 2)
                                .accessibilityIdentifier(
                                    "version-history.change.\(release.version).\(index)"
                                )
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("版本 \(release.version)")
                                .font(.body.weight(.semibold))
                            Text("构建 \(release.build) · \(release.releaseDate)")
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("version-history.row.\(release.version)")
                    .accessibilityLabel(
                        "版本 \(release.version)，构建 \(release.build)，发布日期 \(release.releaseDate)"
                    )
                }
            case .failure:
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
            }
        }
        .navigationTitle("版本更新记录")
        .navigationBarTitleDisplayMode(.inline)
        .appPageBackground()
    }
}

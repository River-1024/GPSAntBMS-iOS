import Foundation

/// 随 App 打包的版本更新记录。记录必须按新到旧排列，且每个版本号仅出现一次。
struct AppVersionHistory: Codable, Equatable {
    let releases: [AppVersionRelease]

    init(releases: [AppVersionRelease]) throws {
        self.releases = releases
        try validate()
    }

    init(data: Data, decoder: JSONDecoder = JSONDecoder()) throws {
        self = try decoder.decode(Self.self, from: data)
        try validate()
    }

    func validate() throws {
        guard !releases.isEmpty else { throw AppVersionHistoryError.emptyHistory }

        var knownVersions = Set<String>()
        var previousVersion: AppSemanticVersion?
        for release in releases {
            guard !release.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !release.build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !release.changes.isEmpty,
                  release.changes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                throw AppVersionHistoryError.invalidRelease
            }
            guard knownVersions.insert(release.version).inserted else {
                throw AppVersionHistoryError.duplicateVersion
            }
            guard release.parsedReleaseDate != nil else {
                throw AppVersionHistoryError.invalidDate
            }
            guard let version = AppSemanticVersion(release.version) else {
                throw AppVersionHistoryError.invalidVersion
            }
            if let previousVersion, previousVersion <= version {
                throw AppVersionHistoryError.outOfOrder
            }
            previousVersion = version
        }
    }

    func validate(currentVersion: String, build: String) throws {
        try validate()
        guard releases.contains(where: { $0.version == currentVersion && $0.build == build }) else {
            throw AppVersionHistoryError.currentVersionMissing
        }
    }
}

struct AppVersionRelease: Codable, Equatable, Identifiable {
    let version: String
    let build: String
    let releaseDate: String
    let changes: [String]

    var id: String { "\(version)-\(build)" }

    var parsedReleaseDate: Date? {
        guard releaseDate.range(
            of: #"^\d{4}-\d{2}-\d{2}$"#,
            options: .regularExpression
        ) != nil,
        let date = Self.dateFormatter.date(from: releaseDate),
        Self.dateFormatter.string(from: date) == releaseDate
        else {
            return nil
        }
        return date
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}

enum AppVersionHistoryError: Error, Equatable {
    case emptyHistory
    case invalidRelease
    case invalidDate
    case invalidVersion
    case duplicateVersion
    case outOfOrder
    case currentVersionMissing
}

private struct AppSemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0
        else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

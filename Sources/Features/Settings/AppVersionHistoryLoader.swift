import Foundation

enum AppVersionHistoryLoader {
    static func load(from bundle: Bundle = .main) -> Result<AppVersionHistory, Error> {
        guard let url = bundle.url(forResource: "VersionHistory", withExtension: "json") else {
            return .failure(AppVersionHistoryLoaderError.resourceMissing)
        }
        do {
            let history = try AppVersionHistory(data: Data(contentsOf: url))
            guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            else {
                return .failure(AppVersionHistoryLoaderError.currentVersionUnavailable)
            }
            try history.validate(currentVersion: version, build: build)
            return .success(history)
        } catch {
            return .failure(error)
        }
    }
}

enum AppVersionHistoryLoaderError: Error {
    case resourceMissing
    case currentVersionUnavailable
}

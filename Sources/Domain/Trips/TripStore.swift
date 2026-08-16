import Foundation

/// 行程历史 JSON 持久化（Application Support + 原子写入）。
///
/// 设计约束：
/// - 仅依赖 Foundation（位于 `Sources/Domain`，自动纳入 SPM 目标）；
/// - 目录 URL 可注入（测试传入临时目录），默认使用 Application Support；
/// - 加载损坏/缺失文件返回「空历史 + 类型化失败」，绝不崩溃；
/// - 写入使用 `Data.write(to:options: .atomic)`，失败抛错且不破坏旧文件。
final class TripStore {
    /// 加载失败类型（非致命，供调用方提示）。
    enum LoadFailure: Error, Equatable {
        /// 文件存在但无法读取
        case unreadable
        /// 内容损坏，无法解码为行程数组
        case decodingFailed
    }

    /// 加载结果：始终携带历史（损坏时为空），失败时附带原因。
    struct LoadResult: Equatable {
        let history: [TripRecord]
        let failure: LoadFailure?

        static let empty = LoadResult(history: [], failure: nil)
    }

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// - Parameters:
    ///   - directoryURL: 持久化目录（测试注入临时目录）。
    ///   - fileName: 历史文件名。
    init(directoryURL: URL, fileName: String = "tripHistory.json") {
        fileURL = directoryURL.appendingPathComponent(fileName)
    }

    /// 默认持久化到 Application Support 目录；目录不可用时返回 nil。
    convenience init?(fileName: String = "tripHistory.json") {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else { return nil }
        self.init(directoryURL: base, fileName: fileName)
    }

    /// 加载行程历史。文件缺失 → 空历史无失败；损坏 → 空历史 + 类型化失败。
    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: fileURL)
            do {
                let history = try decoder.decode([TripRecord].self, from: data)
                return LoadResult(history: history, failure: nil)
            } catch {
                return LoadResult(history: [], failure: .decodingFailed)
            }
        } catch {
            return LoadResult(history: [], failure: .unreadable)
        }
    }

    /// 原子写入整个历史（自动创建目录；失败抛错，旧文件保持不变）。
    func save(_ history: [TripRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(history)
        try data.write(to: fileURL, options: .atomic)
    }
}

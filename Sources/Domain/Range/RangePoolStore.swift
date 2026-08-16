import Foundation

/// 综合续航计算池 JSON 持久化（Application Support + 原子写入）。
///
/// 与 `TripStore` 同模式，schema 对齐 Android `RangePoolStore.kt`：
/// - 默认文件 `range-computation-pool.json`，目录 URL 可注入（测试传临时目录）；
/// - 编码完整 `RangePoolState`（含 schema version）；解码后经 `sanitized()`
///   过滤无效分段并从分段重新计算聚合值（聚合不一致被纠正而非拒绝文件）；
/// - 文件缺失 → 空池无失败；不可读/空文件/JSON 损坏/schema 不支持 →
///   空池 + 类型化 warning，绝不崩溃；
/// - 写入使用 `Data.write(to:options: .atomic)`，失败抛错且不破坏旧文件；
/// - transient previous snapshot 永不写入（引擎状态本身不含快照字段）。
final class RangePoolStore {
    /// 加载失败类型（非致命，供 UI 提示）。
    enum LoadFailure: Error, Equatable {
        /// 文件存在但无法读取
        case unreadable
        /// 内容为空
        case emptyFile
        /// schema 不支持
        case unsupportedSchema
        /// 内容损坏或聚合校验失败
        case decodingFailed
    }

    /// 加载结果：始终携带状态（损坏时为空池），失败时附带原因。
    struct LoadResult: Equatable {
        let state: RangePoolState
        let failure: LoadFailure?

        static let empty = LoadResult(state: .empty(), failure: nil)
    }

    /// 当前 schema 版本（与 Android `RangePoolCodec.SCHEMA_VERSION` 对齐）。
    static let schemaVersion = 1

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// - Parameters:
    ///   - directoryURL: 持久化目录（测试注入临时目录）。
    ///   - fileName: 池文件名。
    init(directoryURL: URL, fileName: String = "range-computation-pool.json") {
        fileURL = directoryURL.appendingPathComponent(fileName)
    }

    /// 默认持久化到 Application Support 目录；目录不可用时返回 nil。
    convenience init?(fileName: String = "range-computation-pool.json") {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else { return nil }
        self.init(directoryURL: base, fileName: fileName)
    }

    /// 加载计算池。文件缺失 → 空池无失败；损坏 → 空池 + 类型化失败。
    /// 解码后经 `sanitized()` 校验：无效分段被剔除、聚合值重新计算、
    /// 配置钳制（与 Android `RangePoolCodec.decode` 的防御目标一致）。
    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else {
                return LoadResult(state: .empty(), failure: .emptyFile)
            }
            do {
                let wrapper = try decoder.decode(RangePoolFile.self, from: data)
                guard wrapper.schemaVersion == Self.schemaVersion else {
                    return LoadResult(state: .empty(), failure: .unsupportedSchema)
                }
                let state = wrapper.state.sanitized()
                return LoadResult(state: state, failure: nil)
            } catch {
                return LoadResult(state: .empty(), failure: .decodingFailed)
            }
        } catch {
            return LoadResult(state: .empty(), failure: .unreadable)
        }
    }

    /// 原子写入整个计算池（自动创建目录；失败抛错，旧文件保持不变）。
    func save(_ state: RangePoolState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let wrapper = RangePoolFile(schemaVersion: Self.schemaVersion, state: state)
        let data = try encoder.encode(wrapper)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// 池文件顶层结构（含 schema version，与 Android `RangePoolCodec` 对齐）。
private struct RangePoolFile: Codable {
    let schemaVersion: Int
    let state: RangePoolState
}

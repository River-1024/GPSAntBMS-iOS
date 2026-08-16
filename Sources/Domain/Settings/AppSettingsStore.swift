import Foundation

/// 应用设置持久化存储（UserDefaults，JSON 编码为单个 Data 值）。
///
/// `UserDefaults` 与 key 均可注入：App 组合根使用 `.standard`，
/// 测试使用独立 suite 隔离真实存储（与 `UserDefaultsPeripheralUUIDStore`
/// 相同的注入约定）。
final class AppSettingsStore {
    private let userDefaults: UserDefaults
    private let key: String

    init(userDefaults: UserDefaults = .standard, key: String = "appSettings") {
        self.userDefaults = userDefaults
        self.key = key
    }

    /// 读取设置；无数据、非 Data 或 JSON 损坏/字段缺失时返回默认值。
    func load() -> AppSettings {
        guard let data = userDefaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .defaults
        }
        return settings
    }

    /// 保存设置（编码失败时静默忽略，保持现有存储不变）。
    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: key)
    }

    /// 清除已存设置，下次 `load()` 返回默认值。
    func reset() {
        userDefaults.removeObject(forKey: key)
    }
}

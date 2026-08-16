import Foundation

/// 已记住保护板的标识持久化契约（自动重连的依据）。
///
/// 前台约束说明：停止前台会话只停止扫描/轮询/连接等实时工作，
/// 记忆的设备标识**必须保留**，回到前台时才能恢复连接（对齐
/// `MIGRATION_PLAN.md` 第 4 节「检查 BLE 连接，断开则自动重连上次设备」）。
protocol PeripheralUUIDPersisting {
    /// 读取上次连接的设备标识；从未记住时返回 nil。
    func load() -> UUID?
    /// 记住一个设备标识。
    func save(_ uuid: UUID)
    /// 清除记忆（用户显式「忘记设备」时使用；当前阶段无 UI，保留 API 供后续设置页）。
    func clear()
}

/// `UserDefaults` 实现（App 进程内持久化）。
final class UserDefaultsPeripheralUUIDStore: PeripheralUUIDPersisting {
    private let userDefaults: UserDefaults
    private let key: String

    init(userDefaults: UserDefaults = .standard, key: String = "rememberedPeripheralUUID") {
        self.userDefaults = userDefaults
        self.key = key
    }

    func load() -> UUID? {
        userDefaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    func save(_ uuid: UUID) {
        userDefaults.set(uuid.uuidString, forKey: key)
    }

    func clear() {
        userDefaults.removeObject(forKey: key)
    }
}

/// 内存实现（测试注入用，保证服务测试不触碰真实 UserDefaults）。
final class InMemoryPeripheralUUIDStore: PeripheralUUIDPersisting {
    private var stored: UUID?

    func load() -> UUID? { stored }

    func save(_ uuid: UUID) { stored = uuid }

    func clear() { stored = nil }
}

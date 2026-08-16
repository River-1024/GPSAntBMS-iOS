import Foundation

/// 蓝牙适配器状态（映射自 CoreBluetooth `CBManagerState` 的纯值类型）。
///
/// 放在 Domain 层保持与系统框架解耦：服务层在 `centralManagerDidUpdateState`
/// 中把 `CBManagerState` 映射为这里的枚举，UI / 测试可直接消费。
enum BluetoothState: Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    /// 当前状态是否可执行扫描 / 连接（仅 poweredOn）。
    var isUsable: Bool { self == .poweredOn }

    /// 面向 UI 的中文描述（与 Android 端「蓝牙未开启/未授权时通过 UI 提示」对应）。
    var displayText: String {
        switch self {
        case .poweredOn: return "蓝牙已开启"
        case .poweredOff: return "蓝牙未开启"
        case .unauthorized: return "蓝牙未授权"
        case .unsupported: return "设备不支持蓝牙"
        case .resetting: return "蓝牙正在重置"
        case .unknown: return "蓝牙状态未知"
        }
    }
}

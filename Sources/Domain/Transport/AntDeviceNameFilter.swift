import Foundation

/// ANT BMS 设备名过滤规则（对齐 Android `BleScanner` 的
/// `deviceName?.startsWith("ANT", ignoreCase = true)`）。
///
/// iOS 端广播数据中，完整设备名可能只出现在广告的 local name
/// （`CBAdvertisementDataLocalNameKey`）或 `CBPeripheral.name`（系统按需填充）之一，
/// 因此先取广播名，缺失时回退到 peripheral 名；两者都缺失时视为不匹配。
enum AntDeviceNameFilter {
    /// 过滤前缀（大小写不敏感，与 Android 样本设备名 `ANT@BLE24CBUB-8FQR` 对应）。
    static let prefix = "ANT"

    /// 广播名优先、peripheral 名回退的大小写不敏感前缀匹配。
    ///
    /// - Parameters:
    ///   - localName: 广播数据中的 local name（`CBAdvertisementDataLocalNameKey`）。
    ///   - peripheralName: `CBPeripheral.name`。
    /// - Returns: 是否为可连接的 ANT BMS 设备。
    static func matches(localName: String?, peripheralName: String?) -> Bool {
        guard let candidate = localName ?? peripheralName else { return false }
        return candidate.lowercased().hasPrefix(prefix.lowercased())
    }
}

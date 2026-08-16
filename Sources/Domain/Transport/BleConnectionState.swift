import Foundation

/// BLE 连接流程状态机（前台连接链路的阶段标记，供 UI / 测试区分）。
///
/// 与 Android `BmsBluetoothManager` 的连接顺序一一对应：
/// connect → discoverServices（FFE0）→ discoverCharacteristics（FFE1）
/// → `setNotifyValue(true)` → `didUpdateNotificationStateFor` 确认后进入 `.ready` 并启动轮询。
enum BleConnectionState: Equatable {
    /// 空闲：未连接，无进行中的连接流程。
    case idle
    /// 已发起 GATT 连接（`central.connect` 之后）。
    case connecting
    /// 正在发现 FFE0 服务。
    case discoveringServices
    /// 正在发现 FFE1 特征。
    case discoveringCharacteristics
    /// 已调用 `setNotifyValue(true)`，等待栈确认（CCCD 由 CoreBluetooth 托管写入）。
    case enablingNotify
    /// Notify 就绪，周期轮询已启动。
    case ready
}

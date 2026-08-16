import Foundation

/// BLE 传输层类型化错误（服务层 `lastError` 的唯一表达类型）。
///
/// 区分「环境不可用」（蓝牙关闭/未授权/非活跃）、「链路异常」（连接/发现/Notify/写入失败）
/// 与「数据异常」（合包溢出 / 解析失败），便于 UI 提示与测试断言。
enum BleTransportError: Error, Equatable {
    /// 蓝牙适配器不可用（未开启 / 未授权 / 不支持 / 重置中 / 未知）。
    case bluetoothUnavailable(BluetoothState)
    /// 尝试在非活跃（inactive/background）状态下执行前台工作。
    case notActive
    /// 目标设备不可达（不在已发现列表，系统也不认识该 UUID）。
    case peripheralNotAvailable
    /// 已连接但未找到 FFE0 服务（能力不匹配，不支持 ANT BMS 协议）。
    case serviceNotFound
    /// 已找到 FFE0 服务但未找到 FFE1 特征。
    case characteristicNotFound
    /// FFE1 特征属性不满足要求（缺少 Notify 或 Write）。
    case capabilityMissing(required: String)
    /// 开启 Notify 失败（`didUpdateNotificationStateFor` 携带错误或未进入 isNotifying）。
    case notifyFailed(String?)
    /// GATT 连接失败（`didFailToConnect`）。
    case connectFailed(String?)
    /// 查询命令写入失败（`didWriteValueFor` 携带错误）。
    case writeFailed(String?)
    /// 响应帧解析失败（转发 `AntProtocol` 的类型化错误）。
    case parseFailed(AntProtocolError)
    /// 帧合包失败（转发 `FrameAssemblerError`，当前仅溢出）。
    case frameAssemblyFailed(FrameAssemblerError)
}

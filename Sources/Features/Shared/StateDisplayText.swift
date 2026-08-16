import CoreLocation
import Foundation

/// 传输/定位/续航状态 → 简洁中文展示文本（仅 UI 层本地翻译）。
///
/// 不改动领域模型：`BluetoothState` 已在领域层自带 `displayText`，
/// 其余枚举的展示文本一律收敛到本文件，供各功能页复用。
extension BleConnectionState {
    /// 连接流程阶段的中文描述。
    var displayText: String {
        switch self {
        case .idle: return "未连接"
        case .connecting: return "连接中"
        case .discoveringServices: return "正在发现服务"
        case .discoveringCharacteristics: return "正在发现特征"
        case .enablingNotify: return "正在开启数据通道"
        case .ready: return "已就绪"
        }
    }
}

extension BleTransportError {
    /// 传输层错误的中文提示（UI 展示用，不携带原始错误细节之外的噪音）。
    var displayText: String {
        switch self {
        case .bluetoothUnavailable(let state):
            switch state {
            case .unauthorized: return "蓝牙未授权，请在系统设置中允许"
            case .poweredOff: return "蓝牙未开启，请先开启蓝牙"
            default: return "蓝牙不可用（\(state.displayText)）"
            }
        case .notActive: return "App 不在前台，操作被拒绝"
        case .peripheralNotAvailable: return "目标设备不可达，请重新扫描"
        case .serviceNotFound: return "设备不支持 ANT BMS 协议（未找到 FFE0 服务）"
        case .characteristicNotFound: return "未找到数据特征（FFE1）"
        case .capabilityMissing(let required): return "设备特征能力不足（缺少 \(required)）"
        case .notifyFailed: return "开启数据通知失败"
        case .connectFailed: return "连接失败"
        case .writeFailed: return "写入查询命令失败"
        case .parseFailed: return "BMS 数据解析失败"
        case .frameAssemblyFailed: return "BMS 数据帧异常"
        }
    }
}

extension CLAuthorizationStatus {
    /// 定位授权状态的中文描述。
    var displayText: String {
        switch self {
        case .notDetermined: return "未授权"
        case .restricted: return "受限"
        case .denied: return "定位被拒绝"
        case .authorizedWhenInUse: return "已授权"
        case .authorizedAlways: return "已授权"
        @unknown default: return "未知"
        }
    }
}

extension RangeFactorSource {
    /// 续航因子来源的中文描述。
    var displayText: String {
        switch self {
        case .computed: return "实测系数"
        case .manual: return "手动系数"
        case .unavailable: return "暂不可用"
        }
    }
}

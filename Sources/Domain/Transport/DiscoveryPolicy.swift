import Foundation

/// 扫描发现事件的处理决策（纯逻辑，供服务层 `didDiscover` 使用，SPM 可测）。
///
/// 决策顺序（修复：重连目标 UUID 命中**优先于** ANT 名称过滤）：
/// 1. 若存在重连目标（`reconnectTargetID`）且 peripheral UUID 精确匹配、当前未连接
///    且不在连接流程中 → `.autoConnect`：无条件发起连接——**不要求**广播名/设备名
///    存在或匹配 ANT（记住的设备可能改名或广播名缺失，UUID 是唯一可靠依据）；
/// 2. 其余情况按 ANT 名称过滤决定是否进入展示列表——普通发现展示仍保持名称过滤，
///    不会把无关的无名设备加入列表。
enum DiscoveryPolicy {
    enum Decision: Equatable {
        /// 重连目标命中：立即连接（名称不参与过滤，也不进入展示列表）。
        case autoConnect
        /// 名称匹配 ANT：进入展示列表。
        case display
        /// 名称不匹配且非重连目标：仅由服务层记录对象索引，不展示。
        case ignore
    }

    /// - Parameters:
    ///   - peripheralID: 本次发现的 peripheral UUID。
    ///   - reconnectTargetID: 当前等待自动连接的目标 UUID（nil 表示无重连目标）。
    ///   - isConnected: 服务当前是否已连接（Notify 就绪）。
    ///   - isConnecting: 服务当前是否处于连接流程（`.connecting`）。
    ///   - localName: 广播数据中的 local name（`CBAdvertisementDataLocalNameKey`）。
    ///   - peripheralName: `CBPeripheral.name`。
    static func decide(peripheralID: UUID,
                       reconnectTargetID: UUID?,
                       isConnected: Bool,
                       isConnecting: Bool,
                       localName: String?,
                       peripheralName: String?) -> Decision {
        if let target = reconnectTargetID, target == peripheralID,
           !isConnected, !isConnecting {
            return .autoConnect
        }
        return AntDeviceNameFilter.matches(localName: localName, peripheralName: peripheralName)
            ? .display
            : .ignore
    }
}

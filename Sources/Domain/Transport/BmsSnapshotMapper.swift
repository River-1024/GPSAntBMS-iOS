import Foundation

/// 协议解析结果 → 仪表盘快照的映射（纯函数）。
///
/// `BmsStatusResponse`（协议域，单位与 Android `BmsData` 一致）→ `BmsSnapshot`
/// （仪表盘模型）。**映射器保持连接中立**：只映射遥测字段，不表达连接状态——
/// `isConnected` 由服务层按实际传输就绪状态（Notify 就绪/断开/蓝牙不可用等路径）
/// 设置，解析到遥测本身不构成「已连接」的证据。
enum BmsSnapshotMapper {
    /// 映射完整解析结果到仪表盘快照（`isConnected` 保持默认 false，由服务层按实际状态覆盖）。
    static func map(_ response: BmsStatusResponse) -> BmsSnapshot {
        var snapshot = BmsSnapshot()
        snapshot.totalVoltage = response.totalVoltage
        snapshot.current = response.current
        snapshot.soc = Double(response.soc)
        snapshot.soh = Double(response.soh)
        snapshot.power = response.power
        snapshot.cellVoltagesMillivolts = response.cellVoltages.map(Double.init)
        snapshot.temperaturesCelsius = response.temperatures
        snapshot.mosTemperatureCelsius = response.mosTemp
        snapshot.balancerTemperatureCelsius = response.balancerTemp
        snapshot.voltageDiffMillivolts = response.voltageDiff
        snapshot.maxCellVoltageMillivolts = response.maxCellVoltage ?? 0
        snapshot.maxCellIndex = response.maxCellIndex ?? 0
        snapshot.minCellVoltageMillivolts = response.minCellVoltage ?? 0
        snapshot.minCellIndex = response.minCellIndex ?? 0
        snapshot.averageCellVoltageMillivolts = response.averageCellVoltage ?? 0
        snapshot.balanceMask = response.balanceMask
        snapshot.balanceStatus = response.balanceStatus ?? 0
        snapshot.chargeMosOn = response.chargeMosOn
        snapshot.dischargeMosOn = response.dischargeMosOn
        snapshot.capacityAh = response.capacity
        snapshot.remainingChargeAh = response.remainingCharge
        snapshot.cycleCapacityAh = response.cycleCapacity
        snapshot.runtimeSeconds = response.runtime
        snapshot.totalDischargeCapacityAh = response.totalDischargeCapacity
        snapshot.totalChargeCapacityAh = response.totalChargeCapacity
        snapshot.totalDischargeTimeSeconds = response.totalDischargeTime
        snapshot.totalChargeTimeSeconds = response.totalChargeTime
        snapshot.bmsStatusText = response.bmsStatusText
        snapshot.bmsStatusCode = response.bmsStatusCode
        snapshot.frameLength = response.frameLength
        snapshot.unparsedBytes = response.unparsedBytes
        return snapshot
    }
}

import XCTest
@testable import GPSAntBMS

/// 协议解析结果 → 仪表盘快照映射（Notify → 合包 → 解析 → 快照链路的最后一段）。
/// 映射器保持**连接中立**：只映射遥测字段，`isConnected` 由服务层按实际连接状态设置。
final class BmsSnapshotMapperTests: XCTestCase {
    /// Android REAL_FRAME_1（174 字节）逐字段映射到快照。
    func testMapsRealFrame1IntoSnapshot() throws {
        let response = try AntProtocol.processStatusResponse(TestFixtures.realFrame1)
        let snapshot = BmsSnapshotMapper.map(response)

        // 解析出遥测不代表已连接：连接标记必须由服务层按实际传输就绪状态设置。
        XCTAssertFalse(snapshot.isConnected)
        XCTAssertEqual(snapshot.totalVoltage, 72.698, accuracy: 0.001)
        XCTAssertEqual(snapshot.current, 0.1, accuracy: 0.001)
        XCTAssertEqual(snapshot.soc, 42, accuracy: 0.001)
        XCTAssertEqual(snapshot.soh, 100, accuracy: 0.001)
        XCTAssertEqual(snapshot.power, 7.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.cellVoltagesMillivolts.count, 20)
        XCTAssertEqual(snapshot.temperaturesCelsius, [29, 29])
        XCTAssertEqual(snapshot.mosTemperatureCelsius, 32)
        XCTAssertEqual(snapshot.balancerTemperatureCelsius, 33)
        XCTAssertEqual(snapshot.voltageDiffMillivolts, 2)
        XCTAssertEqual(snapshot.maxCellVoltageMillivolts, 3636)
        XCTAssertEqual(snapshot.maxCellIndex, 4)
        XCTAssertEqual(snapshot.minCellVoltageMillivolts, 3634)
        XCTAssertEqual(snapshot.minCellIndex, 1)
        XCTAssertEqual(snapshot.averageCellVoltageMillivolts, 3634)
        XCTAssertEqual(snapshot.balanceMask, 0)
        XCTAssertEqual(snapshot.balanceStatus, 0)
        XCTAssertEqual(snapshot.chargeMosOn, true)
        XCTAssertEqual(snapshot.dischargeMosOn, true)
        XCTAssertEqual(snapshot.capacityAh, 134.0, accuracy: 0.000001)
        XCTAssertEqual(snapshot.remainingChargeAh, 57.559335, accuracy: 0.000001)
        XCTAssertEqual(snapshot.cycleCapacityAh, 1350.87, accuracy: 0.000001)
        XCTAssertEqual(snapshot.runtimeSeconds, 2_163_312)
        XCTAssertEqual(snapshot.totalDischargeCapacityAh, 1354.431, accuracy: 0.000001)
        XCTAssertEqual(snapshot.totalChargeCapacityAh, 1347.31, accuracy: 0.000001)
        XCTAssertEqual(snapshot.totalDischargeTimeSeconds, 207_714)
        XCTAssertEqual(snapshot.totalChargeTimeSeconds, 179_405)
        XCTAssertEqual(snapshot.bmsStatusText, "待机")
        XCTAssertEqual(snapshot.bmsStatusCode, 1)
        XCTAssertEqual(snapshot.frameLength, 174)
        XCTAssertEqual(snapshot.unparsedBytes, 14)
        XCTAssertNil(snapshot.lastUpdatedAt)
        // 协议功率非 0 → 展示功率直接使用协议值
        XCTAssertEqual(snapshot.displayPower(), 7.0, accuracy: 0.001)
    }

    /// message.txt 合包帧（178 字节）映射结果与父仓库 README 记录一致。
    func testMapsMessageTxtFrameIntoSnapshot() throws {
        let response = try AntProtocol.processStatusResponse(TestFixtures.messageTxtAssembledFrame)
        let snapshot = BmsSnapshotMapper.map(response)

        XCTAssertFalse(snapshot.isConnected) // 映射器连接中立：遥测不携带连接状态
        XCTAssertEqual(snapshot.totalVoltage, 81.602, accuracy: 0.001)
        XCTAssertEqual(snapshot.current, 0.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.soc, 93, accuracy: 0.001)
        XCTAssertEqual(snapshot.temperaturesCelsius, [15, 14, -40, -40])
        XCTAssertEqual(snapshot.mosTemperatureCelsius, 15)
        XCTAssertEqual(snapshot.balancerTemperatureCelsius, 16)
        XCTAssertEqual(snapshot.voltageDiffMillivolts, 2)
        XCTAssertEqual(snapshot.maxCellVoltageMillivolts, 4081)
        XCTAssertEqual(snapshot.maxCellIndex, 4)
        XCTAssertEqual(snapshot.minCellVoltageMillivolts, 4079)
        XCTAssertEqual(snapshot.minCellIndex, 9)
        XCTAssertEqual(snapshot.averageCellVoltageMillivolts, 4080)
        XCTAssertEqual(snapshot.capacityAh, 170.0, accuracy: 0.000001)
        XCTAssertEqual(snapshot.remainingChargeAh, 156.163966, accuracy: 0.000001)
        XCTAssertEqual(snapshot.runtimeSeconds, 11_796_101)
        XCTAssertEqual(snapshot.bmsStatusText, "待机")
        XCTAssertEqual(snapshot.bmsStatusCode, 1)
        XCTAssertEqual(snapshot.frameLength, 178)
        XCTAssertEqual(snapshot.unparsedBytes, 14)
        // 协议功率为 0 → 展示功率回退为 总压 × 电流 = 0
        XCTAssertEqual(snapshot.displayPower(), 0, accuracy: 0.001)
    }

    /// 回归：映射器永远不表达「已连接」——即使映射多次或带上完整遥测，
    /// `isConnected` 保持默认 false，连接状态只能由服务层按实际传输就绪状态写入。
    func testMapperNeverClaimsConnection() throws {
        let response = try AntProtocol.processStatusResponse(TestFixtures.realFrame1)
        let first = BmsSnapshotMapper.map(response)
        let second = BmsSnapshotMapper.map(try AntProtocol.processStatusResponse(TestFixtures.realFrame2))

        XCTAssertFalse(first.isConnected)
        XCTAssertFalse(second.isConnected)
        XCTAssertEqual(first.isConnected, BmsSnapshot().isConnected)
    }
}

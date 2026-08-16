import XCTest
@testable import GPSAntBMS

/// `BmsSnapshot` 纯逻辑单元测试。
///
/// TODO(domain): 协议解析接入后，为响应帧解析（帧头/帧尾/分片合包/字段偏移）补充测试。
final class BmsSnapshotTests: XCTestCase {

    /// 协议功率为 0 时，展示功率回退为 总压 × 电流（与 Android 端 displayPower 一致）。
    func testDisplayPowerFallsBackToVoltageTimesCurrentWhenProtocolPowerIsZero() {
        var snapshot = BmsSnapshot()
        snapshot.power = 0
        snapshot.totalVoltage = 81.6
        snapshot.current = -12.5

        XCTAssertEqual(snapshot.displayPower(), 81.6 * -12.5, accuracy: 0.001)
    }

    /// 协议功率非 0 时，优先展示协议功率。
    func testDisplayPowerPrefersProtocolPowerWhenNonZero() {
        var snapshot = BmsSnapshot()
        snapshot.power = 1020
        snapshot.totalVoltage = 81.6
        snapshot.current = 12.5

        XCTAssertEqual(snapshot.displayPower(), 1020, accuracy: 0.001)
    }

    /// 未接入任何数据时，默认快照所有指标为 0。
    func testDefaultSnapshotIsZeroed() {
        let snapshot = BmsSnapshot()

        XCTAssertEqual(snapshot.totalVoltage, 0)
        XCTAssertEqual(snapshot.soc, 0)
        XCTAssertFalse(snapshot.isConnected)
        XCTAssertTrue(snapshot.cellVoltagesMillivolts.isEmpty)
    }
}

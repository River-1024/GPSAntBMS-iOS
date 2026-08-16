import XCTest
@testable import GPSAntBMS

/// 扫描发现决策：重连目标 UUID 命中**优先于** ANT 名称过滤。
/// 回归缺陷：记住的设备广播名缺失或已改名（非 ANT 前缀）时仍能自动重连，
/// 而普通发现展示保持名称过滤（无关无名设备不进入列表）。
final class DiscoveryPolicyTests: XCTestCase {
    // MARK: - 重连目标命中（无条件连接，名称不参与过滤）

    /// 目标命中但广播名/设备名均缺失 → 仍应自动连接。
    func testReconnectTargetWithMissingNameAutoConnects() {
        let target = UUID()
        XCTAssertEqual(
            DiscoveryPolicy.decide(peripheralID: target,
                                   reconnectTargetID: target,
                                   isConnected: false,
                                   isConnecting: false,
                                   localName: nil,
                                   peripheralName: nil),
            .autoConnect
        )
    }

    /// 目标命中但设备名非 ANT 前缀（记住的设备已改名）→ 仍应自动连接。
    func testReconnectTargetWithNonAntNameAutoConnects() {
        let target = UUID()
        XCTAssertEqual(
            DiscoveryPolicy.decide(peripheralID: target,
                                   reconnectTargetID: target,
                                   isConnected: false,
                                   isConnecting: false,
                                   localName: "BLE24CBUB-8FQR",
                                   peripheralName: "BLE24CBUB-8FQR"),
            .autoConnect
        )
    }

    /// 其他设备与目标 UUID 不同，即使名字是 ANT → 不触发自动连接（回到名称过滤展示）。
    func testDifferentDeviceDoesNotAutoConnect() {
        let target = UUID()
        XCTAssertEqual(
            DiscoveryPolicy.decide(peripheralID: UUID(),
                                   reconnectTargetID: target,
                                   isConnected: false,
                                   isConnecting: false,
                                   localName: "ANT@BLE24",
                                   peripheralName: nil),
            .display
        )
    }

    /// 目标命中但服务已连接/连接中 → 不触发自动连接（防御：回落名称过滤）。
    func testReconnectTargetWhileConnectedOrConnectingFallsBackToNameFilter() {
        let target = UUID()
        XCTAssertEqual(
            DiscoveryPolicy.decide(peripheralID: target,
                                   reconnectTargetID: target,
                                   isConnected: true,
                                   isConnecting: false,
                                   localName: "OTHER",
                                   peripheralName: nil),
            .ignore
        )
        XCTAssertEqual(
            DiscoveryPolicy.decide(peripheralID: target,
                                   reconnectTargetID: target,
                                   isConnected: false,
                                   isConnecting: true,
                                   localName: "ANT@BLE24",
                                   peripheralName: nil),
            .display
        )
    }

    // MARK: - 普通发现（展示仍按 ANT 名称过滤）

    /// 非重连目标、名称匹配 ANT → 展示。
    func testNonTargetAntNameDisplays() {
        XCTAssertEqual(
            DiscoveryPolicy.decide(peripheralID: UUID(),
                                   reconnectTargetID: nil,
                                   isConnected: false,
                                   isConnecting: false,
                                   localName: "ANT@BLE24CBUB-8FQR",
                                   peripheralName: nil),
            .display
        )
    }

    /// 非重连目标、名称不匹配 → 忽略（不展示）。
    func testNonTargetNonAntNameIgnored() {
        XCTAssertEqual(
            DiscoveryPolicy.decide(peripheralID: UUID(),
                                   reconnectTargetID: nil,
                                   isConnected: false,
                                   isConnecting: false,
                                   localName: "OTHER",
                                   peripheralName: "OTHER"),
            .ignore
        )
    }

    /// 非重连目标、名称缺失 → 忽略（无关无名设备不进入展示列表）。
    func testUnnamedNonTargetIgnored() {
        XCTAssertEqual(
            DiscoveryPolicy.decide(peripheralID: UUID(),
                                   reconnectTargetID: nil,
                                   isConnected: false,
                                   isConnecting: false,
                                   localName: nil,
                                   peripheralName: nil),
            .ignore
        )
    }
}

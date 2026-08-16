import XCTest
@testable import GPSAntBMS

/// 设备名过滤规则：广播名优先、peripheral 名回退、大小写不敏感 `ANT` 前缀。
final class AntDeviceNameFilterTests: XCTestCase {
    /// 广播名匹配（大小写不敏感），peripheral 名为空。
    func testMatchesLocalNameCaseInsensitively() {
        XCTAssertTrue(AntDeviceNameFilter.matches(localName: "ANT@BLE24CBUB-8FQR", peripheralName: nil))
        XCTAssertTrue(AntDeviceNameFilter.matches(localName: "ant@ble24cbub-8fqr", peripheralName: nil))
        XCTAssertTrue(AntDeviceNameFilter.matches(localName: "Ant BMS 8S", peripheralName: nil))
    }

    /// 广播名缺失时回退到 peripheral 名。
    func testFallsBackToPeripheralNameWhenLocalNameMissing() {
        XCTAssertTrue(AntDeviceNameFilter.matches(localName: nil, peripheralName: "ANT@BLE24CBUB-8FQR"))
        XCTAssertTrue(AntDeviceNameFilter.matches(localName: nil, peripheralName: "ant-device-01"))
    }

    /// 广播名优先于 peripheral 名（广播名匹配即通过，不再检查 peripheral 名）。
    func testLocalNameTakesPrecedence() {
        XCTAssertTrue(AntDeviceNameFilter.matches(localName: "ANT", peripheralName: "not-ant"))
    }

    /// 非 ANT 前缀设备不匹配。
    func testRejectsNonAntNames() {
        XCTAssertFalse(AntDeviceNameFilter.matches(localName: "BLE24CBUB-8FQR", peripheralName: "BLE24CBUB-8FQR"))
        XCTAssertFalse(AntDeviceNameFilter.matches(localName: nil, peripheralName: "XANT@BLE24"))
        XCTAssertFalse(AntDeviceNameFilter.matches(localName: "MyANTBMS", peripheralName: nil))
    }

    /// 前缀必须是单词起始（`MyANT` 不是 `ANT` 前缀匹配）。
    func testPrefixMustMatchFromStart() {
        XCTAssertFalse(AntDeviceNameFilter.matches(localName: "MyANTBMS", peripheralName: nil))
    }

    /// 空串与双 nil 均不匹配。
    func testRejectsEmptyOrMissingNames() {
        XCTAssertFalse(AntDeviceNameFilter.matches(localName: "", peripheralName: nil))
        XCTAssertFalse(AntDeviceNameFilter.matches(localName: nil, peripheralName: ""))
        XCTAssertFalse(AntDeviceNameFilter.matches(localName: nil, peripheralName: nil))
    }
}

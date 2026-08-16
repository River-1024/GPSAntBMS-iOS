import XCTest
@testable import GPSAntBMS

/// 扫描结果注册表：UUID 去重 + 确定性 RSSI 排序。
final class ScanResultRegistryTests: XCTestCase {
    /// 同一 UUID 重复发现只保留一个条目，RSSI 取最新。
    func testDedupeByIDKeepsLatestRSSI() {
        var registry = ScanResultRegistry()
        let id = UUID()
        registry.upsert(id: id, name: "ANT@1", rssi: -60)
        registry.upsert(id: id, name: "ANT@1", rssi: -45)

        XCTAssertEqual(registry.entries.count, 1)
        XCTAssertEqual(registry.sortedForDisplay().first?.rssi, -45)
    }

    /// 首次发现带名称、后续广播无名称时，保留首个非空名称。
    func testKeepsFirstNonNilNameAcrossDuplicates() {
        var registry = ScanResultRegistry()
        let id = UUID()
        registry.upsert(id: id, name: "ANT@1", rssi: -60)
        registry.upsert(id: id, name: nil, rssi: -55)

        XCTAssertEqual(registry.sortedForDisplay().first?.name, "ANT@1")
    }

    /// 按 RSSI 降序排列。
    func testSortsRSSIDescending() {
        var registry = ScanResultRegistry()
        registry.upsert(id: UUID(), name: "a", rssi: -70)
        registry.upsert(id: UUID(), name: "b", rssi: -40)
        registry.upsert(id: UUID(), name: "c", rssi: -90)

        XCTAssertEqual(registry.sortedForDisplay().map(\.rssi), [-40, -70, -90])
    }

    /// RSSI 相同时按名称升序（确定性 tie-break）。
    func testDeterministicTieBreakByName() {
        var registry = ScanResultRegistry()
        let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
        let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
        registry.upsert(id: idA, name: "beta", rssi: -50)
        registry.upsert(id: idB, name: "alpha", rssi: -50)

        XCTAssertEqual(registry.sortedForDisplay().map(\.name), ["alpha", "beta"])
    }

    /// RSSI 与名称均相同时按 UUID 字符串升序（完全确定性）。
    func testDeterministicTieBreakByUUID() {
        var registry = ScanResultRegistry()
        let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
        let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
        registry.upsert(id: idB, name: "same", rssi: -50)
        registry.upsert(id: idA, name: "same", rssi: -50)

        XCTAssertEqual(registry.sortedForDisplay().map(\.id), [idA, idB])
    }

    /// RSSI 相同时，nil 名称排在非空名称之后（无名设备靠后展示）。
    func testNilNameSortsAfterNonNilName() {
        var registry = ScanResultRegistry()
        registry.upsert(id: UUID(), name: nil, rssi: -50)
        registry.upsert(id: UUID(), name: "ANT@1", rssi: -50)

        let sorted = registry.sortedForDisplay()
        XCTAssertEqual(sorted[0].name, "ANT@1")
        XCTAssertNil(sorted[1].name)
    }

    /// removeAll 清空全部条目（扫描重启时调用）。
    func testRemoveAllClearsEntries() {
        var registry = ScanResultRegistry()
        registry.upsert(id: UUID(), name: "ANT@1", rssi: -50)

        registry.removeAll()

        XCTAssertTrue(registry.entries.isEmpty)
        XCTAssertTrue(registry.sortedForDisplay().isEmpty)
    }
}

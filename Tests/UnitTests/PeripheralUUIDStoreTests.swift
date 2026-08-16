import XCTest
@testable import GPSAntBMS

/// 已记住保护板标识的持久化存储。
final class PeripheralUUIDStoreTests: XCTestCase {
    /// 内存实现：保存/读取/清除往返。
    func testInMemoryStoreRoundTrip() {
        let store = InMemoryPeripheralUUIDStore()
        let id = UUID()

        XCTAssertNil(store.load())

        store.save(id)
        XCTAssertEqual(store.load(), id)

        store.clear()
        XCTAssertNil(store.load())
    }

    /// 内存实现：重复保存覆盖旧值。
    func testInMemoryStoreOverwritesOnRepeatedSave() {
        let store = InMemoryPeripheralUUIDStore()
        store.save(UUID())
        let latest = UUID()
        store.save(latest)

        XCTAssertEqual(store.load(), latest)
    }

    /// UserDefaults 实现：独立 suite 内的保存/读取/清除往返。
    func testUserDefaultsStoreRoundTrip() {
        let suiteName = "PeripheralUUIDStoreTests-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            return XCTFail("无法创建 UserDefaults suite")
        }
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsPeripheralUUIDStore(userDefaults: suite, key: "testRememberedUUID")
        let id = UUID()

        XCTAssertNil(store.load())

        store.save(id)
        XCTAssertEqual(store.load(), id)

        store.clear()
        XCTAssertNil(store.load())
    }
}

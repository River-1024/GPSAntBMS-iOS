import XCTest
@testable import GPSAntBMS

/// 应用设置：默认值、钳制、持久化往返、损坏回退与重置。
final class AppSettingsTests: XCTestCase {
    /// 在独立 suite 中执行用例体，结束后清理持久域（不触碰真实 UserDefaults）。
    private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("无法创建 UserDefaults suite")
            return
        }
        defer { suite.removePersistentDomain(forName: suiteName) }
        try body(suite)
    }

    // MARK: - 默认值

    func testDefaults() {
        let defaults = AppSettings()

        XCTAssertEqual(defaults.pollingIntervalMilliseconds, 1_000)
        XCTAssertEqual(defaults.manualRangeKmPerAh, 1.0)
        XCTAssertEqual(defaults.effectiveSpeedKmh, 30.0)
        XCTAssertEqual(defaults.rangeDisplayMode, .computed)
        XCTAssertFalse(defaults.backgroundTrackingEnabled)
        XCTAssertEqual(defaults.appearance, .system)
        XCTAssertEqual(defaults.recordingCapacityLimit, .tenGB)
        XCTAssertEqual(AppSettings.defaults, defaults)
        XCTAssertEqual(defaults.oldRangeWeight + defaults.newRangeWeight, 1.0, accuracy: 0.0001)
    }

    /// Android 对齐默认值：15 分钟窗口 / 60 秒刷新 / 70/30 权重（R10）。
    func testAndroidAlignedRangeDefaults() {
        let defaults = AppSettings()

        XCTAssertEqual(defaults.rangeWindowSeconds, 900, "窗口默认 15 分钟（内部秒存储）")
        XCTAssertEqual(defaults.rangeRefreshSeconds, 60, "刷新默认 60 秒")
        XCTAssertEqual(defaults.oldRangeWeight, 0.7, accuracy: 1e-9, "旧权重默认 70%")
        XCTAssertEqual(defaults.newRangeWeight, 0.3, accuracy: 1e-9, "新权重默认 30%")
        XCTAssertEqual(defaults.effectiveSpeedKmh, 30.0, accuracy: 1e-9, "有效速度默认 30 km/h")
    }

    // MARK: - 钳制

    func testPollingIntervalIsClamped() {
        XCTAssertEqual(AppSettings(pollingIntervalMilliseconds: 50).pollingIntervalMilliseconds, 200)
        XCTAssertEqual(AppSettings(pollingIntervalMilliseconds: 999_999).pollingIntervalMilliseconds, 60_000)
        XCTAssertEqual(AppSettings(pollingIntervalMilliseconds: 200).pollingIntervalMilliseconds, 200)
        XCTAssertEqual(AppSettings(pollingIntervalMilliseconds: 60_000).pollingIntervalMilliseconds, 60_000)
        XCTAssertEqual(AppSettings(pollingIntervalMilliseconds: 2_500).pollingIntervalMilliseconds, 2_500)
    }

    func testManualRangeKmPerAhIsClamped() {
        XCTAssertEqual(AppSettings(manualRangeKmPerAh: 0.01).manualRangeKmPerAh, 0.1)
        XCTAssertEqual(AppSettings(manualRangeKmPerAh: 500.0).manualRangeKmPerAh, 100.0)
        XCTAssertEqual(AppSettings(manualRangeKmPerAh: 0.1).manualRangeKmPerAh, 0.1)
        XCTAssertEqual(AppSettings(manualRangeKmPerAh: 100.0).manualRangeKmPerAh, 100.0)
        XCTAssertEqual(AppSettings(manualRangeKmPerAh: 2.5).manualRangeKmPerAh, 2.5)
    }

    func testEffectiveSpeedKmhIsClamped() {
        XCTAssertEqual(AppSettings(effectiveSpeedKmh: -10.0).effectiveSpeedKmh, 0.0)
        XCTAssertEqual(AppSettings(effectiveSpeedKmh: 300.0).effectiveSpeedKmh, 120.0)
        XCTAssertEqual(AppSettings(effectiveSpeedKmh: 0.0).effectiveSpeedKmh, 0.0)
        XCTAssertEqual(AppSettings(effectiveSpeedKmh: 120.0).effectiveSpeedKmh, 120.0)
        XCTAssertEqual(AppSettings(effectiveSpeedKmh: 45.0).effectiveSpeedKmh, 45.0)
    }

    /// 窗口范围 60...7200 秒（1...120 分钟），越界钳制（R10）。
    func testRangeWindowSecondsIsClamped() {
        XCTAssertEqual(AppSettings(rangeWindowSeconds: 30).rangeWindowSeconds, 60)
        XCTAssertEqual(AppSettings(rangeWindowSeconds: 9_999).rangeWindowSeconds, 7_200)
        XCTAssertEqual(AppSettings(rangeWindowSeconds: 900).rangeWindowSeconds, 900)
        XCTAssertEqual(AppSettings(rangeWindowSeconds: 60).rangeWindowSeconds, 60)
    }

    /// 刷新范围 30...600 秒，越界钳制（R10）。
    func testRangeRefreshSecondsIsClamped() {
        XCTAssertEqual(AppSettings(rangeRefreshSeconds: 1).rangeRefreshSeconds, 30)
        XCTAssertEqual(AppSettings(rangeRefreshSeconds: 9_999).rangeRefreshSeconds, 600)
        XCTAssertEqual(AppSettings(rangeRefreshSeconds: 60).rangeRefreshSeconds, 60)
        XCTAssertEqual(AppSettings(rangeRefreshSeconds: 30).rangeRefreshSeconds, 30)
    }

    /// 权重越界钳制并归一化（R10）：init 先钳制到 [0,1] 再归一化。
    func testRangeWeightsClampedAndNormalized() {
        // 2.0/1.0 先钳制为 1.0/1.0，归一化为 0.5/0.5
        let settings = AppSettings(oldRangeWeight: 2.0, newRangeWeight: 1.0)
        XCTAssertEqual(settings.oldRangeWeight, 0.5, accuracy: 1e-9)
        XCTAssertEqual(settings.newRangeWeight, 0.5, accuracy: 1e-9)

        // 合法非归一输入：0.8/0.4 → 2/3、1/3
        let normalized = AppSettings(oldRangeWeight: 0.8, newRangeWeight: 0.4)
        XCTAssertEqual(normalized.oldRangeWeight, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(normalized.newRangeWeight, 1.0 / 3.0, accuracy: 1e-9)

        let allZero = AppSettings(oldRangeWeight: 0.0, newRangeWeight: 0.0)
        XCTAssertEqual(allZero.oldRangeWeight, 0.7, accuracy: 1e-9, "全零回退 Android 默认 70/30")
        XCTAssertEqual(allZero.newRangeWeight, 0.3, accuracy: 1e-9)

        let outOfRange = AppSettings(oldRangeWeight: 5.0, newRangeWeight: -1.0)
        XCTAssertEqual(outOfRange.oldRangeWeight, 1.0, accuracy: 1e-9)
        XCTAssertEqual(outOfRange.newRangeWeight, 0.0, accuracy: 1e-9)
    }

    func testUpperThresholdsAreClamped() {
        let settings = AppSettings(
            powerRedThresholdWatts: 500_000,
            voltageDiffRedMillivolts: 5_000,
            temperatureRedCelsius: 500
        )

        XCTAssertEqual(settings.powerRedThresholdWatts, 100_000)
        XCTAssertEqual(settings.voltageDiffRedMillivolts, 1_000)
        XCTAssertEqual(settings.temperatureRedCelsius, 150)
    }

    // MARK: - 持久化往返

    func testUserDefaultsRoundTrip() {
        withSuite { suite in
            let original = AppSettings(
                pollingIntervalMilliseconds: 3_000,
                manualRangeKmPerAh: 1.5,
                rangeDisplayMode: .both,
                effectiveSpeedKmh: 55.0,
                appearance: .dark,
                backgroundTrackingEnabled: true
            )
            let store = AppSettingsStore(userDefaults: suite, key: "testSettings")

            store.save(original)

            let reloaded = AppSettingsStore(userDefaults: suite, key: "testSettings").load()
            XCTAssertEqual(reloaded, original)
        }
    }

    func testLoadReturnsDefaultsWhenNothingStored() {
        withSuite { suite in
            let settings = AppSettingsStore(userDefaults: suite, key: "testSettings").load()
            XCTAssertEqual(settings, .defaults)
        }
    }

    // MARK: - 损坏/无效数据回退

    func testLoadReturnsDefaultsForNonJSONData() {
        withSuite { suite in
            suite.set(Data("not json at all".utf8), forKey: "testSettings")

            let settings = AppSettingsStore(userDefaults: suite, key: "testSettings").load()
            XCTAssertEqual(settings, .defaults)
        }
    }

    func testLoadReturnsDefaultsForMalformedJSON() {
        withSuite { suite in
            // 旧版本 JSON 只包含早期字段：新增字段应补默认值而不是整体回退。
            suite.set(Data(#"{"pollingIntervalMilliseconds": 1500}"#.utf8), forKey: "testSettings")

            let settings = AppSettingsStore(userDefaults: suite, key: "testSettings").load()
            XCTAssertEqual(settings.pollingIntervalMilliseconds, 1500)
            XCTAssertEqual(settings.manualRangeKmPerAh, 1.0)
            XCTAssertEqual(settings.effectiveSpeedKmh, 30.0)
            XCTAssertEqual(settings.rangeWindowSeconds, 900)
            XCTAssertEqual(settings.rangeRefreshSeconds, 60)
            XCTAssertEqual(settings.oldRangeWeight, 0.7, accuracy: 1e-9)
            XCTAssertEqual(settings.newRangeWeight, 0.3, accuracy: 1e-9)
            XCTAssertEqual(settings.rangeDisplayMode, .computed)
            XCTAssertFalse(settings.backgroundTrackingEnabled)
        }
    }

    func testLoadReturnsDefaultsForWrongValueType() {
        withSuite { suite in
            // 字段类型错误（字符串而不是数字）：解码失败 → 回退默认值。
            suite.set(
                Data(#"{"pollingIntervalMilliseconds": "fast", "manualRangeKmPerAh": 1.0, "effectiveSpeedKmh": 30.0}"#.utf8),
                forKey: "testSettings"
            )

            let settings = AppSettingsStore(userDefaults: suite, key: "testSettings").load()
            XCTAssertEqual(settings, .defaults)
        }
    }

    func testLoadClampsOutOfRangeStoredValues() {
        withSuite { suite in
            // 结构合法但数值越界：解码成功 → 钳制而非回退默认值。
            suite.set(
                Data(#"{"pollingIntervalMilliseconds": 10, "manualRangeKmPerAh": 0.001, "effectiveSpeedKmh": 999.0}"#.utf8),
                forKey: "testSettings"
            )

            let settings = AppSettingsStore(userDefaults: suite, key: "testSettings").load()
            XCTAssertEqual(settings.pollingIntervalMilliseconds, 200)
            XCTAssertEqual(settings.manualRangeKmPerAh, 0.1)
            XCTAssertEqual(settings.effectiveSpeedKmh, AppSettings.maximumEffectiveSpeedKmh)
        }
    }

    func testLegacySettingsDecodeWithNewDefaults() throws {
        let data = Data(#"{"pollingIntervalMilliseconds":1500,"manualRangeKmPerAh":2.0,"effectiveSpeedKmh":40.0}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.pollingIntervalMilliseconds, 1500)
        XCTAssertEqual(settings.manualRangeKmPerAh, 2.0)
        XCTAssertEqual(settings.effectiveSpeedKmh, 40.0)
        XCTAssertEqual(settings.rangeWindowSeconds, 900)
        XCTAssertEqual(settings.rangeRefreshSeconds, 60)
        XCTAssertEqual(settings.oldRangeWeight, 0.7, accuracy: 1e-9)
        XCTAssertEqual(settings.newRangeWeight, 0.3, accuracy: 1e-9)
        XCTAssertEqual(settings.temperatureSource, .sensors)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.recordingCapacityLimit, .tenGB)
        XCTAssertEqual(settings.rangeDisplayMode, .computed)
        XCTAssertFalse(settings.backgroundTrackingEnabled)
    }

    /// 旧 JSON 只有旧三项续航字段（窗口 1800/刷新 10/权重反方向）时，
    /// 缺失字段补 Android 对齐默认，旧值仍按新范围钳制。
    func testLegacyRangeFieldsDecodeWithAndroidDefaultsAndClamp() throws {
        let data = Data(#"{"rangeWindowSeconds":1800,"rangeRefreshSeconds":10,"oldRangeWeight":0.3,"newRangeWeight":0.7}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        // 旧窗口 1800 s（30 分钟）在 60...7200 范围内：保留
        XCTAssertEqual(settings.rangeWindowSeconds, 1800)
        // 旧刷新 10 s 低于新下限 30：钳制到 30
        XCTAssertEqual(settings.rangeRefreshSeconds, 30)
        // 旧权重反方向 30/70：保留用户旧值（0.3+0.7 归一化不变），
        // 引擎侧默认仅对缺失字段生效
        XCTAssertEqual(settings.oldRangeWeight, 0.3, accuracy: 1e-9)
        XCTAssertEqual(settings.newRangeWeight, 0.7, accuracy: 1e-9)
    }

    func testRecordingCapacityRoundTrip() {
        withSuite { suite in
            let store = AppSettingsStore(userDefaults: suite, key: "recordingSettings")
            store.save(AppSettings(recordingCapacityLimit: .twentyGB))
            XCTAssertEqual(store.load().recordingCapacityLimit, .twentyGB)
        }
    }

    // MARK: - 重置

    func testResetClearsStoredSettings() {
        withSuite { suite in
            let store = AppSettingsStore(userDefaults: suite, key: "testSettings")
            store.save(AppSettings(pollingIntervalMilliseconds: 5_000))

            store.reset()

            XCTAssertEqual(store.load(), .defaults)
        }
    }
}

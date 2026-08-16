import XCTest
@testable import GPSAntBMS

/// `AntProtocol` 解析逻辑单元测试。
/// 覆盖：Android `AntProtocolTest.kt` 的三条真实帧向量、message.txt 合包帧、
/// 畸形帧（长度不足 / 类型不符 / 字段越界）与可选尾部字段的长度保护。
final class AntProtocolParserTests: XCTestCase {

    /// 固定查询命令与 message.txt 抓包写入命令（0x7EA1010000BE1855AA55）一致。
    func testQueryStatusCommandMatchesCapturedBytes() {
        XCTAssertEqual(
            AntProtocol.queryStatusCommand,
            [0x7E, 0xA1, 0x01, 0x00, 0x00, 0xBE, 0x18, 0x55, 0xAA, 0x55]
        )
        XCTAssertEqual(AntProtocol.queryStatusCommand.count, 10)
    }

    /// Android `AntProtocolTest.kt` 三条真实帧向量：帧长、总压、电流、SOC、温度、状态码与文本。
    func testRealAndroidFixtureVectors() throws {
        let fixtures: [(frame: [UInt8], totalVoltage: Double, current: Double, soc: Int, mosTemp: Int, balancerTemp: Int, statusCode: Int, statusText: String)] = [
            (TestFixtures.realFrame1, 72.698, 0.1, 42, 32, 33, 1, "待机"),
            (TestFixtures.realFrame2, 72.779, 0.1, 42, 33, 34, 1, "待机"),
            (TestFixtures.realFrame3, 73.410, -33.1, 45, 34, 35, 2, "充电中")
        ]

        for fixture in fixtures {
            XCTAssertEqual(fixture.frame.count, 174, "真实抓包帧应为 174 字节")
            let parsed = try AntProtocol.processStatusResponse(fixture.frame)
            XCTAssertEqual(parsed.totalVoltage, fixture.totalVoltage, accuracy: 0.0001)
            XCTAssertEqual(parsed.current, fixture.current, accuracy: 0.0001)
            XCTAssertEqual(parsed.soc, fixture.soc)
            XCTAssertEqual(parsed.mosTemp, fixture.mosTemp)
            XCTAssertEqual(parsed.balancerTemp, fixture.balancerTemp)
            XCTAssertEqual(parsed.bmsStatusCode, fixture.statusCode)
            XCTAssertEqual(parsed.bmsStatusText, fixture.statusText)
        }
    }

    /// 帧 1 的完整字段级断言（期望值按 README 偏移表手工推导验证）。
    func testRealFrame1DetailedFieldValues() throws {
        let parsed = try AntProtocol.processStatusResponse(TestFixtures.realFrame1)

        XCTAssertEqual(parsed.frameLength, 174)
        XCTAssertEqual(parsed.cellVoltages.count, 20)
        XCTAssertEqual(parsed.temperatures, [29, 29])
        XCTAssertEqual(parsed.soh, 100)
        XCTAssertEqual(parsed.chargeMosOn, true)
        XCTAssertEqual(parsed.dischargeMosOn, true)
        XCTAssertEqual(parsed.balanceStatus, 0)
        XCTAssertEqual(parsed.voltageDiff, 2)
        XCTAssertEqual(parsed.maxCellVoltage, 3636)
        XCTAssertEqual(parsed.maxCellIndex, 4)
        XCTAssertEqual(parsed.minCellVoltage, 3634)
        XCTAssertEqual(parsed.minCellIndex, 1)
        XCTAssertEqual(parsed.averageCellVoltage, 3634)
        XCTAssertEqual(parsed.power, 7.0, accuracy: 0.0001)
        XCTAssertEqual(parsed.runtime, 2_163_312)
        XCTAssertEqual(parsed.capacity, 134.0, accuracy: 0.000001)
        XCTAssertEqual(parsed.remainingCharge, 57.559335, accuracy: 0.000001)
        XCTAssertEqual(parsed.cycleCapacity, 1350.87, accuracy: 0.000001)
        XCTAssertEqual(parsed.totalDischargeCapacity, 1354.431, accuracy: 0.000001)
        XCTAssertEqual(parsed.totalChargeCapacity, 1347.31, accuracy: 0.000001)
        XCTAssertEqual(parsed.totalDischargeTime, 207_714)
        XCTAssertEqual(parsed.totalChargeTime, 179_405)
        XCTAssertEqual(parsed.balanceMask, 0)
        XCTAssertEqual(parsed.unparsedBytes, 14)
    }

    /// message.txt 合包帧（178 字节）解析结果与父仓库 README 记录一致。
    func testMessageTxtAssembledFrameParsesToDocumentedValues() throws {
        let parsed = try AntProtocol.processStatusResponse(TestFixtures.messageTxtAssembledFrame)

        XCTAssertEqual(parsed.frameLength, 178)
        XCTAssertEqual(parsed.cellVoltages.count, 20)
        XCTAssertEqual(parsed.temperatures, [15, 14, -40, -40])
        XCTAssertEqual(parsed.totalVoltage, 81.602, accuracy: 0.0001)
        XCTAssertEqual(parsed.current, 0.0, accuracy: 0.0001)
        XCTAssertEqual(parsed.soc, 93)
        XCTAssertEqual(parsed.soh, 100)
        XCTAssertEqual(parsed.chargeMosOn, true)
        XCTAssertEqual(parsed.dischargeMosOn, true)
        XCTAssertEqual(parsed.balanceStatus, 0)
        XCTAssertEqual(parsed.mosTemp, 15)
        XCTAssertEqual(parsed.balancerTemp, 16)
        XCTAssertEqual(parsed.capacity, 170.0, accuracy: 0.000001)
        XCTAssertEqual(parsed.remainingCharge, 156.163966, accuracy: 0.000001)
        XCTAssertEqual(parsed.power, 0.0, accuracy: 0.0001)
        XCTAssertEqual(parsed.runtime, 11_796_101)
        XCTAssertEqual(parsed.maxCellVoltage, 4081)
        XCTAssertEqual(parsed.maxCellIndex, 4)
        XCTAssertEqual(parsed.minCellVoltage, 4079)
        XCTAssertEqual(parsed.minCellIndex, 9)
        XCTAssertEqual(parsed.voltageDiff, 2)
        XCTAssertEqual(parsed.averageCellVoltage, 4080)
        XCTAssertEqual(parsed.balanceMask, 0)
        XCTAssertEqual(parsed.totalDischargeCapacity, 1256.094, accuracy: 0.000001)
        XCTAssertEqual(parsed.totalChargeCapacity, 1458.991, accuracy: 0.000001)
        XCTAssertEqual(parsed.totalDischargeTime, 221_738)
        XCTAssertEqual(parsed.totalChargeTime, 612_402)
        XCTAssertEqual(parsed.bmsStatusCode, 1)
        XCTAssertEqual(parsed.bmsStatusText, "待机")
        XCTAssertEqual(parsed.unparsedBytes, 14)
    }

    /// 状态码 → 文本映射与 Android `when` 分支一致。
    func testStatusTextMapping() {
        XCTAssertEqual(BmsStatusResponse.statusText(for: 1), "待机")
        XCTAssertEqual(BmsStatusResponse.statusText(for: 2), "充电中")
        XCTAssertEqual(BmsStatusResponse.statusText(for: 3), "放电中")
        XCTAssertEqual(BmsStatusResponse.statusText(for: 4), "休眠")
        XCTAssertEqual(BmsStatusResponse.statusText(for: 5), "错误")
        XCTAssertEqual(BmsStatusResponse.statusText(for: 6), "未知")
        XCTAssertEqual(BmsStatusResponse.statusText(for: 0), "未知")
        XCTAssertEqual(BmsStatusResponse.statusText(for: nil), "未知")
    }

    // MARK: - 畸形帧

    /// 长度不足 100 字节抛 `frameTooShort`（Android 返回 null）。
    func testFrameShorterThan100BytesThrows() {
        var short = TestFixtures.realFrame1
        short.removeLast(75) // 99 字节

        XCTAssertThrowsError(try AntProtocol.processStatusResponse(short)) { error in
            XCTAssertEqual(error as? AntProtocolError, .frameTooShort(actual: 99, minimum: 100))
        }
    }

    /// 空帧同样视为长度不足。
    func testEmptyFrameThrowsFrameTooShort() {
        XCTAssertThrowsError(try AntProtocol.processStatusResponse([])) { error in
            XCTAssertEqual(error as? AntProtocolError, .frameTooShort(actual: 0, minimum: 100))
        }
    }

    /// 帧第 3 字节不是 0x11 抛 `unexpectedResponseType`（Android 返回 null）。
    func testNonStatusResponseTypeThrows() {
        var frame = TestFixtures.realFrame1
        frame[2] = 0x10

        XCTAssertThrowsError(try AntProtocol.processStatusResponse(frame)) { error in
            XCTAssertEqual(error as? AntProtocolError, .unexpectedResponseType(actual: 0x10, expected: 0x11))
        }
    }

    /// 长度检查先于类型检查，与 Android 判断顺序一致。
    func testLengthCheckPrecedesTypeCheck() {
        var frame = TestFixtures.realFrame1
        frame[2] = 0x10
        frame.removeLast(80) // 94 字节

        XCTAssertThrowsError(try AntProtocol.processStatusResponse(frame)) { error in
            XCTAssertEqual(error as? AntProtocolError, .frameTooShort(actual: 94, minimum: 100))
        }
    }

    /// 电芯数量声明过大导致读取越界（Android 中为数组越界被 catch 后返回 null）。
    func testHugeCellCountThrowsTruncatedField() {
        var frame = TestFixtures.realFrame1
        frame[9] = 200 // numCell = 200，需要 400 字节，超出帧长

        XCTAssertThrowsError(try AntProtocol.processStatusResponse(frame)) { error in
            guard case .truncatedField? = error as? AntProtocolError else {
                return XCTFail("预期 truncatedField，实际得到 \(error)")
            }
        }
    }

    /// 温度数量声明过大导致读取越界。
    func testHugeTemperatureCountThrowsTruncatedField() {
        var frame = TestFixtures.realFrame1
        frame[8] = 100 // numTemp = 100

        XCTAssertThrowsError(try AntProtocol.processStatusResponse(frame)) { error in
            guard case .truncatedField? = error as? AntProtocolError else {
                return XCTFail("预期 truncatedField，实际得到 \(error)")
            }
        }
    }

    /// 尾部可选字段缺失时由长度保护跳过，不抛错；缺失值保持默认（Android 行为）。
    func testGuardedOptionalSectionsTolerateShortTail() throws {
        var frame = [UInt8](repeating: 0, count: 100)
        frame[0] = 0x7E
        frame[1] = 0xA1
        frame[2] = 0x11
        frame[5] = 0xA4 // 数据区长度声明
        frame[8] = 0    // numTemp = 0
        frame[9] = 20   // numCell = 20
        for index in 0..<20 {
            frame[34 + index * 2] = 0x10
            frame[35 + index * 2] = 0x0E // 0x0E10 = 3600 mV
        }

        let parsed = try AntProtocol.processStatusResponse(frame)

        XCTAssertEqual(parsed.frameLength, 100)
        XCTAssertEqual(parsed.cellVoltages.count, 20)
        XCTAssertEqual(parsed.totalVoltage, 72.0, accuracy: 0.0001)
        XCTAssertEqual(parsed.voltageDiff, 0)       // 协议字段缺失 → 回退计算 0
        XCTAssertEqual(parsed.maxCellVoltage, 3600) // 协议字段缺失 → 回退计算
        XCTAssertEqual(parsed.maxCellIndex, 1)
        XCTAssertEqual(parsed.minCellVoltage, 3600)
        XCTAssertEqual(parsed.minCellIndex, 1)
        XCTAssertEqual(parsed.averageCellVoltage, 3600)
        XCTAssertEqual(parsed.chargeMosOn, false)   // 该段存在（长度足够），值为 0
        XCTAssertEqual(parsed.dischargeMosOn, false)
        XCTAssertEqual(parsed.balanceStatus, 0)
        XCTAssertEqual(parsed.bmsStatusText, "未知") // statusCode = 0
        XCTAssertEqual(parsed.unparsedBytes, 6)     // dataEnd = 100，解析游标停在 94
    }
}

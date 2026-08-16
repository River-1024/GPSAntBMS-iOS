import XCTest
@testable import GPSAntBMS

/// `BmsFrameAssembler` 合包逻辑单元测试。
/// 覆盖：真实抓包 9 段分片重组、20 字节/逐字节分片、7E A1 重开帧、
/// 空分片、残帧挂起、512 字节溢出保护与 AA 55 提前完成（Android 已知行为）。
final class BmsFrameAssemblerTests: XCTestCase {

    /// message.txt 真实抓包的 9 段 Notify 分片按序合包，得到 178 字节完整帧。
    func testAssemblesMessageTxtCaptureSegments() throws {
        var assembler = BmsFrameAssembler()

        for (index, segment) in TestFixtures.messageTxtSegments.enumerated() {
            let frame = try assembler.append(segment)
            if index < TestFixtures.messageTxtSegments.count - 1 {
                XCTAssertNil(frame, "第 \(index + 1) 段之后不应完成帧")
            } else {
                XCTAssertEqual(frame, TestFixtures.messageTxtAssembledFrame)
            }
        }

        XCTAssertTrue(assembler.isEmpty, "完整帧交付后缓存应清空")
    }

    /// 20 字节分片重组 REAL_FRAME_1，解析结果与整帧直接解析完全一致。
    func testChunkedRealFrameReassemblesAndParsesIdentically() throws {
        let expected = try AntProtocol.processStatusResponse(TestFixtures.realFrame1)

        var assembler = BmsFrameAssembler()
        var completed: [UInt8]?
        for start in stride(from: 0, to: TestFixtures.realFrame1.count, by: 20) {
            let end = min(start + 20, TestFixtures.realFrame1.count)
            completed = try assembler.append(Array(TestFixtures.realFrame1[start..<end]))
        }

        let frame = try XCTUnwrap(completed)
        XCTAssertEqual(frame, TestFixtures.realFrame1)
        XCTAssertTrue(assembler.isEmpty)

        let reassembled = try AntProtocol.processStatusResponse(frame)
        XCTAssertEqual(reassembled, expected)
    }

    /// 单次完整帧（无分片）直接交付。
    func testWholeFrameInSingleChunk() throws {
        var assembler = BmsFrameAssembler()

        XCTAssertEqual(try assembler.append(TestFixtures.realFrame1), TestFixtures.realFrame1)
        XCTAssertTrue(assembler.isEmpty)
    }

    /// 逐字节分片同样能完成合包（覆盖极端分片边界）。
    func testSingleByteChunksAssembleFrame() throws {
        var assembler = BmsFrameAssembler()

        var completed: [UInt8]?
        for byte in TestFixtures.realFrame2 {
            completed = try assembler.append([byte])
        }

        XCTAssertEqual(completed, TestFixtures.realFrame2)
        XCTAssertTrue(assembler.isEmpty)
    }

    /// 新分片以 7E A1 开头时丢弃旧缓存，开始新帧（Android 行为）。
    func testStartMarkerResetsPartialBuffer() throws {
        var assembler = BmsFrameAssembler()

        // 先塞入一段残帧（不以 7E A1 开头、不以 AA 55 结尾）
        let garbage: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x04]
        XCTAssertNil(try assembler.append(garbage))
        XCTAssertEqual(assembler.pendingCount, 5)

        // 新分片以帧头 7E A1 开头 → 丢弃旧缓存
        let firstChunk = Array(TestFixtures.realFrame1[0..<20])
        XCTAssertNil(try assembler.append(firstChunk))
        XCTAssertEqual(assembler.pendingCount, 20, "旧缓存应被丢弃")

        // 剩余分片送达 → 完整帧不含垃圾字节
        let rest = Array(TestFixtures.realFrame1[20...])
        XCTAssertEqual(try assembler.append(rest), TestFixtures.realFrame1)
    }

    /// 分片中间出现 7E A1 不触发重置（仅分片开头触发，Android 行为）。
    func testMidChunkMarkerDoesNotReset() throws {
        var assembler = BmsFrameAssembler()

        // message.txt 第 6 段：0x21 0x0A 0x7E 0xDF ... 帧内 7E 不重置
        let midChunk = TestFixtures.messageTxtSegments[5]
        XCTAssertEqual(midChunk[2], 0x7E)
        XCTAssertNotEqual(midChunk[3], 0xA1)

        XCTAssertNil(try assembler.append(midChunk))
        XCTAssertEqual(assembler.pendingCount, midChunk.count)
    }

    /// 空分片被忽略，不影响缓存（Android `if (data.isEmpty()) return`）。
    func testEmptyChunkIsIgnored() throws {
        var assembler = BmsFrameAssembler()

        XCTAssertNil(try assembler.append([]))
        XCTAssertTrue(assembler.isEmpty)

        try assembler.append([0x01, 0x02])
        XCTAssertNil(try assembler.append([]))
        XCTAssertEqual(assembler.pendingCount, 2)
    }

    /// 未以 AA 55 结尾的残帧保持挂起，不交付。
    func testIncompleteFrameRemainsPending() throws {
        var assembler = BmsFrameAssembler()

        let partial = Array(TestFixtures.realFrame1[0..<100])
        XCTAssertNil(try assembler.append(partial))
        XCTAssertEqual(assembler.pendingCount, 100)
    }

    /// 分片超过 512 字节：清空缓冲区并抛 `bufferOverflow`（Android 清空后静默丢弃）。
    func testChunkBeyond512BytesClearsAndThrows() {
        var assembler = BmsFrameAssembler()

        XCTAssertThrowsError(try assembler.append([UInt8](repeating: 0x11, count: 513))) { error in
            XCTAssertEqual(error as? FrameAssemblerError, .bufferOverflow(limit: 512))
        }
        XCTAssertTrue(assembler.isEmpty, "溢出后缓存应被清空（Android 行为）")
    }

    /// 多分片累计超过 512 字节时，在越界的分片上抛错并清空。
    func testAccumulatedOverflowThrowsOnCrossingChunk() {
        var assembler = BmsFrameAssembler()

        XCTAssertNil(try assembler.append([UInt8](repeating: 0x11, count: 300)))
        XCTAssertEqual(assembler.pendingCount, 300)

        XCTAssertThrowsError(try assembler.append([UInt8](repeating: 0x22, count: 213))) { error in
            XCTAssertEqual(error as? FrameAssemblerError, .bufferOverflow(limit: 512))
        }
        XCTAssertTrue(assembler.isEmpty)
    }

    /// 恰好 512 字节不视为溢出（Android `> 512` 判断，不含等号）。
    func testExactly512BytesDoesNotOverflow() throws {
        var assembler = BmsFrameAssembler()

        XCTAssertNil(try assembler.append([UInt8](repeating: 0x11, count: 512)))
        XCTAssertEqual(assembler.pendingCount, 512)
    }

    /// 已知限制（与 Android 一致）：帧内 AA 55 恰好落在分片末尾时会被提前当作帧尾完成。
    func testInternalAA55AtChunkEndCompletesEarlyLikeAndroid() throws {
        var assembler = BmsFrameAssembler()

        try assembler.append([0x7E, 0xA1, 0x11, 0x00])
        let early = try assembler.append([0x00, 0xAA, 0x55])
        XCTAssertEqual(early, [0x7E, 0xA1, 0x11, 0x00, 0x00, 0xAA, 0x55])
        XCTAssertTrue(assembler.isEmpty, "提前完成后缓存应清空")

        // 后续数据按新帧处理
        let next = try assembler.append([0x01, 0x02, 0xAA, 0x55])
        XCTAssertEqual(next, [0x01, 0x02, 0xAA, 0x55])
    }

    /// 手动 reset 清空缓存。
    func testResetClearsBuffer() throws {
        var assembler = BmsFrameAssembler()

        try assembler.append([0x7E, 0xA1])
        XCTAssertEqual(assembler.pendingCount, 2)

        assembler.reset()
        XCTAssertTrue(assembler.isEmpty)
    }
}

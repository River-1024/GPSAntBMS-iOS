import Foundation

/// 测试夹具：父仓库真实抓包数据。
/// - 三条 174 字节响应帧：来源 Android `AntProtocolTest.kt`（REAL_FRAME_1/2/3）。
/// - 九段 Notify 分片：来源父仓库 `message.txt`（NRF Connect 抓包），合包后 178 字节。
enum TestFixtures {
    /// hex 字符串（可含空白）转字节数组。
    static func hexToBytes(_ hex: String) -> [UInt8] {
        let compact = hex.filter { !$0.isWhitespace }
        precondition(compact.count.isMultiple(of: 2), "hex 字符串长度必须为偶数")
        var bytes: [UInt8] = []
        bytes.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            bytes.append(UInt8(compact[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    // MARK: - Android AntProtocolTest.kt 真实响应帧（各 174 字节）

    static let realFrame1 = hexToBytes("""
        7E A1 11 00 00 A4 01 01 02 14 00 00 00 00 00 00
        00 00 00 00 80 01 00 00 00 00 00 00 00 00 00 00
        00 00 32 0E 33 0E 32 0E 34 0E 32 0E 34 0E 32 0E
        34 0E 32 0E 34 0E 32 0E 34 0E 32 0E 33 0E 33 0E
        33 0E 33 0E 34 0E 32 0E 33 0E 1D 00 1D 00 20 00
        21 00 6D 1C 01 00 2A 00 64 00 01 01 00 00 80 AD
        FC 07 27 49 6E 03 D6 9C 14 00 07 00 00 00 70 02
        21 00 00 00 00 00 34 0E 04 00 32 0E 01 00 02 00
        32 0E 00 00 7B 00 78 00 AE 02 F1 FA BF AA 14 00
        EE 8E 14 00 62 2B 03 00 CD BC 02 00 00 00 00 00
        8B 4F 02 00 00 00 53 01 00 00 0E 13 AA 55
        """)

    static let realFrame2 = hexToBytes("""
        7E A1 11 00 00 A4 01 01 02 14 00 00 00 00 00 00
        00 00 00 00 80 01 00 00 00 00 00 00 00 00 00 00
        00 00 36 0E 37 0E 37 0E 38 0E 36 0E 38 0E 37 0E
        38 0E 36 0E 38 0E 35 0E 38 0E 36 0E 37 0E 37 0E
        37 0E 37 0E 38 0E 36 0E 37 0E 1F 00 1F 00 21 00
        22 00 73 1C 01 00 2A 00 64 00 01 01 00 00 80 AD
        FC 07 22 18 70 03 11 9D 14 00 07 00 00 00 DB 3A
        21 00 00 00 00 00 38 0E 04 00 35 0E 0B 00 03 00
        36 0E 00 00 7C 00 78 00 AE 02 F1 FA 35 AB 14 00
        EE 8E 14 00 AF 2B 03 00 CD BC 02 00 00 00 00 00
        F6 87 02 00 00 00 53 13 00 00 C7 2F AA 55
        """)

    static let realFrame3 = hexToBytes("""
        7E A1 11 00 00 A4 01 02 02 14 00 00 00 00 00 00
        00 00 00 00 C4 01 00 00 00 00 00 00 00 00 00 00
        00 00 57 0E 59 0E 57 0E 59 0E 55 0E 57 0E 56 0E
        57 0E 55 0E 57 0E 55 0E 57 0E 55 0E 57 0E 56 0E
        57 0E 56 0E 57 0E 55 0E 56 0E 1F 00 1F 00 22 00
        23 00 B4 1C B5 FE 2D 00 64 00 01 01 00 00 80 AD
        FC 07 66 20 A2 03 8A A3 14 00 80 F6 FF FF BC 3C
        21 00 00 00 00 00 59 0E 02 00 55 0E 05 00 04 00
        56 0E 00 00 7C 00 78 00 AE 02 F1 FA 35 AB 14 00
        DF 9B 14 00 AF 2B 03 00 3A BE 02 00 6E 01 00 00
        6A 88 02 00 85 00 53 13 B3 FE BD 08 AA 55
        """)

    // MARK: - message.txt（NRF Connect 抓包）9 段 Notify 分片

    /// 分片按序合包后得到 `messageTxtAssembledFrame`（178 字节）。
    static let messageTxtSegments: [[UInt8]] = [
        [0x7E, 0xA1, 0x11, 0x00, 0x00, 0xA8, 0x01, 0x01, 0x04, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F],
        [0xF1, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xEF, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F],
        [0xF0, 0x0F, 0xF1, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF1, 0x0F, 0x0F, 0x00, 0x0E, 0x00, 0xD8, 0xFF],
        [0xD8, 0xFF, 0x0F, 0x00, 0x10, 0x00, 0xE0, 0x1F, 0x00, 0x00, 0x5D, 0x00, 0x64, 0x00, 0x01, 0x01, 0x00, 0x00, 0x80, 0xFE],
        [0x21, 0x0A, 0x7E, 0xDF, 0x4E, 0x09, 0xE7, 0xB6, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x85, 0xFE, 0xB3, 0x00, 0x00, 0x00],
        [0x00, 0x00, 0xF1, 0x0F, 0x04, 0x00, 0xEF, 0x0F, 0x09, 0x00, 0x02, 0x00, 0xF0, 0x0F, 0x00, 0x00, 0x7D, 0x00, 0x79, 0x00],
        [0xAA, 0x02, 0xF1, 0xFA, 0x9E, 0x2A, 0x13, 0x00, 0x2F, 0x43, 0x16, 0x00, 0x2A, 0x62, 0x03, 0x00, 0x32, 0x58, 0x09, 0x00],
        [0x00, 0x00, 0x00, 0x00, 0x46, 0x63, 0x03, 0x00, 0x00, 0x00, 0xC4, 0x07, 0x00, 0x00, 0xA7, 0x7F, 0xAA, 0x55]
    ]

    /// 9 段分片按序合并的完整响应帧（与父仓库 README「样本完整响应帧拆解」一致，178 字节）。
    static let messageTxtAssembledFrame = hexToBytes("""
        7E A1 11 00 00 A8 01 01 04 14 00 00 00 00 00 00
        00 00 00 00 80 01 00 00 00 00 00 00 00 00 00 00
        00 00 F0 0F F0 0F F0 0F F1 0F F0 0F F0 0F F0 0F
        F0 0F EF 0F F0 0F F0 0F F0 0F F0 0F F0 0F F1 0F
        F0 0F F0 0F F0 0F F0 0F F1 0F 0F 00 0E 00 D8 FF
        D8 FF 0F 00 10 00 E0 1F 00 00 5D 00 64 00 01 01
        00 00 80 FE 21 0A 7E DF 4E 09 E7 B6 14 00 00 00
        00 00 85 FE B3 00 00 00 00 00 F1 0F 04 00 EF 0F
        09 00 02 00 F0 0F 00 00 7D 00 79 00 AA 02 F1 FA
        9E 2A 13 00 2F 43 16 00 2A 62 03 00 32 58 09 00
        00 00 00 00 46 63 03 00 00 00 C4 07 00 00 A7 7F
        AA 55
        """)
}

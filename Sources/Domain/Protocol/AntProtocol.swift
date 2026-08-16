import Foundation

/// ANT BMS 协议错误。
/// Android 端解析失败（长度不足 / 类型不符 / 越界）统一返回 null，这里用类型化错误替代，
/// 便于测试断言与调用方区分失败原因。
enum AntProtocolError: Error, Equatable {
    /// 响应帧长度不足 100 字节（Android：`data.size < 100` 返回 null）
    case frameTooShort(actual: Int, minimum: Int)

    /// 帧第 3 字节不是 0x11（Android：`data[2] != 0x11` 返回 null）
    case unexpectedResponseType(actual: UInt8, expected: UInt8)

    /// 按帧头声明的数量（numCell / numTemp）读取字段时越界
    /// （Android：数组越界异常被 catch 后返回 null）
    case truncatedField(offset: Int, byteCount: Int)
}

/// ANT BMS 协议域（移植自 Android `AntProtocol.kt`）。
///
/// 行为约定（与 Android 一致）：
/// - 不实现任何校验算法，只依赖帧头 7E A1、响应类型 0x11、长度下限 100 与帧尾 AA 55。
/// - 多字节字段一律小端序（u16 / i16 / u32 / i32 与 Kotlin 辅助函数逐位等价）。
/// - 可选尾部字段用 `hasBytes` 长度保护，缺失时保持默认值（0 / nil），不抛错。
enum AntProtocol {
    /// 状态响应类型字节（帧第 3 字节）
    static let statusResponseType: UInt8 = 0x11

    /// 解析器要求的最小响应长度（Android 硬编码 100 字节）
    static let minimumStatusResponseLength = 100

    /// 固定查询命令（Android 固定发送，不动态计算校验值）。
    /// 来源：父仓库 README「查询命令帧」与 message.txt 抓包 `0x7EA1010000BE1855AA55`。
    static let queryStatusCommand: [UInt8] = [0x7E, 0xA1, 0x01, 0x00, 0x00, 0xBE, 0x18, 0x55, 0xAA, 0x55]

    /// 解析 0x11 状态响应帧（逻辑与 Android `processAntData` 一致）。
    ///
    /// 入参约定：`data` 必须是**已合包完成的完整帧**——BLE Notify 分片的
    /// 合包（`7E A1` 帧头起帧、`AA 55` 帧尾判完）由 `BmsFrameAssembler` 负责，
    /// 本函数不参与帧组装，也不校验帧头/帧尾。
    /// 本函数自身只做两项检查：长度下限（`data.count >= 100`）与
    /// 响应类型字节（第 3 字节为 `0x11`），其余字段均以长度保护的方式容错解析。
    ///
    /// - Parameter data: 完整响应帧（通常由 `BmsFrameAssembler` 合包产出）。
    /// - Returns: 解析结果。
    /// - Throws: `AntProtocolError`（Android 中对应返回 null 的场景）。
    static func processStatusResponse(_ data: [UInt8]) throws -> BmsStatusResponse {
        // 数据长度检查（Android 要求 100 字节以上）
        guard data.count >= minimumStatusResponseLength else {
            throw AntProtocolError.frameTooShort(actual: data.count, minimum: minimumStatusResponseLength)
        }

        // 帧类型检查：第 3 字节必须是 0x11
        guard data[2] == statusResponseType else {
            throw AntProtocolError.unexpectedResponseType(actual: data[2], expected: statusResponseType)
        }

        // 1. 读取基本配置：温度传感器数量与电芯串数
        let numTemp = Int(data[8])
        let numCell = Int(data[9])

        // 2. 解析各单体电压（从偏移 34 开始，每串 2 字节 u16，单位 mV）
        var offset = 34
        var cellVoltages: [Int] = []
        cellVoltages.reserveCapacity(numCell)
        for _ in 0..<numCell {
            cellVoltages.append(Int(try u16(data, offset)))
            offset += 2
        }

        // 3. 解析传感器温度（numTemp 个 i16，单位 °C）
        var temperatures: [Int] = []
        temperatures.reserveCapacity(numTemp)
        for _ in 0..<numTemp {
            temperatures.append(Int(try i16(data, offset)))
            offset += 2
        }

        // 4. MOSFET 温度与均衡器温度
        let mosTemp = Int(try i16(data, offset))
        let balancerTemp = Int(try i16(data, offset + 2))
        offset += 4

        // 5. 跳过原始总电压字段（u16 × 0.01 V），总压使用单体求和值
        offset += 2
        let current = Double(try i16(data, offset)) * 0.1 // A
        offset += 2
        let soc = Int(try u16(data, offset)) // %
        offset += 2

        // 6. SOH、MOS 状态、均衡状态（长度允许时）
        var soh = 0
        var chargeMosOn: Bool?
        var dischargeMosOn: Bool?
        var balanceStatus: Int?
        if hasBytes(data, offset, 6) {
            soh = Int(try u16(data, offset))
            offset += 2
            chargeMosOn = (try u8(data, offset)) != 0
            offset += 1
            dischargeMosOn = (try u8(data, offset)) != 0
            offset += 1
            balanceStatus = Int(try u8(data, offset))
            offset += 1
            offset += 1 // 保留字节
        }

        // 7. 容量与运行时间（长度允许时）
        var capacity = 0.0
        var remainingCharge = 0.0
        var cycleCapacity = 0.0
        var power = 0.0
        var runtime: UInt64 = 0
        if hasBytes(data, offset, 20) {
            capacity = Double(try u32(data, offset)) * 0.000001 // Ah
            offset += 4
            remainingCharge = Double(try u32(data, offset)) * 0.000001 // Ah
            offset += 4
            cycleCapacity = Double(try u32(data, offset)) * 0.001 // Ah
            offset += 4
            power = Double(try i32(data, offset)) // W，BMS 反馈的当前功率
            offset += 4
            runtime = UInt64(try u32(data, offset)) // 秒
            offset += 4
        }

        // 8. 均衡位图（长度允许时）
        var balanceMask: UInt64 = 0
        if hasBytes(data, offset, 4) {
            balanceMask = UInt64(try u32(data, offset))
            offset += 4
        }

        // 9. 协议字段：最高/最低单体电压与串号、最大压差、平均单体电压（长度允许时）
        var protocolMaxCellVoltage: Int?
        var protocolMaxCellIndex: Int?
        var protocolMinCellVoltage: Int?
        var protocolMinCellIndex: Int?
        var protocolVoltageDiff: Int?
        var protocolAverageCellVoltage: Int?
        if hasBytes(data, offset, 12) {
            protocolMaxCellVoltage = Int(try u16(data, offset))
            offset += 2
            let maxIndex = Int(try u16(data, offset))
            protocolMaxCellIndex = maxIndex > 0 ? maxIndex : nil
            offset += 2
            protocolMinCellVoltage = Int(try u16(data, offset))
            offset += 2
            let minIndex = Int(try u16(data, offset))
            protocolMinCellIndex = minIndex > 0 ? minIndex : nil
            offset += 2
            protocolVoltageDiff = Int(try u16(data, offset))
            offset += 2
            protocolAverageCellVoltage = Int(try u16(data, offset))
            offset += 2
        }

        // 10. 放 MOS Vds、放 MOS 驱动电压、充 MOS 驱动电压、通讯状态、电池类型等扩展字段（长度允许时跳过）
        if hasBytes(data, offset, 10) {
            offset += 10
        }

        // 11. 累计放电/充电容量与时间（长度允许时）
        var totalDischargeCapacity = 0.0
        var totalChargeCapacity = 0.0
        var totalDischargeTime: UInt64 = 0
        var totalChargeTime: UInt64 = 0
        if hasBytes(data, offset, 16) {
            totalDischargeCapacity = Double(try u32(data, offset)) * 0.001 // Ah
            offset += 4
            totalChargeCapacity = Double(try u32(data, offset)) * 0.001 // Ah
            offset += 4
            totalDischargeTime = UInt64(try u32(data, offset)) // 秒
            offset += 4
            totalChargeTime = UInt64(try u32(data, offset)) // 秒
            offset += 4
        }

        // 12. 数据区长度声明与未解析字节数
        let dataLength = data.count > 5 ? Int(data[5]) : nil
        let dataEnd = dataLength.map { min(6 + $0, data.count) } ?? data.count
        let unparsedBytes = max(dataEnd - offset, 0)

        // 13. 状态码与文本
        let statusCode = data.count > 7 ? Int(data[7]) : nil
        let statusText = BmsStatusResponse.statusText(for: statusCode)

        // 14. 派生值：总压（单体求和）、压差/最高/最低/平均（协议字段缺失时回退计算）
        let cellSum = cellVoltages.reduce(0, +)
        let calculatedTotalVoltage = Double(cellSum) / 1000.0 // V
        let maxV = cellVoltages.max() ?? 0
        let minV = cellVoltages.min() ?? 0
        let voltageDiff = maxV - minV
        let calculatedMaxCellIndex = cellVoltages.firstIndex(of: maxV).map { $0 + 1 }
        let calculatedMinCellIndex = cellVoltages.firstIndex(of: minV).map { $0 + 1 }
        let calculatedAverageCellVoltage = cellVoltages.isEmpty ? nil : cellSum / cellVoltages.count

        return BmsStatusResponse(
            totalVoltage: calculatedTotalVoltage,
            current: current,
            soc: soc,
            capacity: capacity,
            remainingCharge: remainingCharge,
            mosTemp: mosTemp,
            balancerTemp: balancerTemp,
            cellVoltages: cellVoltages,
            temperatures: temperatures,
            soh: soh,
            power: power,
            runtime: runtime,
            voltageDiff: protocolVoltageDiff ?? voltageDiff,
            chargeMosOn: chargeMosOn,
            dischargeMosOn: dischargeMosOn,
            balanceStatus: balanceStatus,
            balanceMask: balanceMask,
            maxCellVoltage: protocolMaxCellVoltage ?? (maxV > 0 ? maxV : nil),
            maxCellIndex: protocolMaxCellIndex ?? calculatedMaxCellIndex,
            minCellVoltage: protocolMinCellVoltage ?? (minV > 0 ? minV : nil),
            minCellIndex: protocolMinCellIndex ?? calculatedMinCellIndex,
            averageCellVoltage: protocolAverageCellVoltage ?? calculatedAverageCellVoltage,
            cycleCapacity: cycleCapacity,
            totalDischargeCapacity: totalDischargeCapacity,
            totalChargeCapacity: totalChargeCapacity,
            totalDischargeTime: totalDischargeTime,
            totalChargeTime: totalChargeTime,
            bmsStatusCode: statusCode,
            bmsStatusText: statusText,
            frameLength: data.count,
            unparsedBytes: unparsedBytes
        )
    }

    // MARK: - 小端读取辅助（与 Kotlin u16 / i16 / u32 / i32 逐位等价）

    /// u16 小端读取：`(data[i] & 0xFF) | ((data[i + 1] & 0xFF) << 8)`
    private static func u16(_ data: [UInt8], _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw AntProtocolError.truncatedField(offset: offset, byteCount: 2)
        }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    /// i16 小端读取：u16 按 16 位有符号解释（Kotlin `u16(i).toShort().toInt()`）
    private static func i16(_ data: [UInt8], _ offset: Int) throws -> Int16 {
        Int16(bitPattern: try u16(data, offset))
    }

    /// u32 小端读取：两个 u16 组合（Kotlin 逻辑逐位一致）
    private static func u32(_ data: [UInt8], _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw AntProtocolError.truncatedField(offset: offset, byteCount: 4)
        }
        let low = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
        let high = UInt32(data[offset + 2]) | (UInt32(data[offset + 3]) << 8)
        return low | (high << 16)
    }

    /// i32 小端读取：u32 按 32 位有符号解释（Kotlin `u32(i).toInt()`）
    private static func i32(_ data: [UInt8], _ offset: Int) throws -> Int32 {
        Int32(bitPattern: try u32(data, offset))
    }

    /// 单字节读取
    private static func u8(_ data: [UInt8], _ offset: Int) throws -> UInt8 {
        guard offset >= 0, offset + 1 <= data.count else {
            throw AntProtocolError.truncatedField(offset: offset, byteCount: 1)
        }
        return data[offset]
    }

    /// 长度保护（对应 Kotlin `hasBytes`，用于可选尾部字段）
    private static func hasBytes(_ data: [UInt8], _ offset: Int, _ count: Int) -> Bool {
        offset >= 0 && offset + count <= data.count
    }
}

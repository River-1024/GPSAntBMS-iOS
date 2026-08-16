import Foundation

/// ANT BMS 状态响应（0x11 帧）解析结果（值类型）。
/// 字段、单位与 Android 端 `AntProtocol.kt` 的 `BmsData` 保持一致。
struct BmsStatusResponse: Equatable {
    /// 总电压（V）：所有单体电压求和 / 1000（Android 计算方式，不使用协议原始总压字段）
    let totalVoltage: Double

    /// 电流（A）：i16 × 0.1
    let current: Double

    /// SOC（%）
    let soc: Int

    /// 设计容量（Ah）：u32 × 0.000001
    let capacity: Double

    /// 剩余容量（Ah）：u32 × 0.000001
    let remainingCharge: Double

    /// MOS 温度（°C）
    let mosTemp: Int

    /// 均衡器温度（°C）
    let balancerTemp: Int

    /// 单体电压（mV）列表，顺序对应串号
    let cellVoltages: [Int]

    /// 传感器温度（°C）列表
    let temperatures: [Int]

    /// SOH（%）
    let soh: Int

    /// 协议实时功率（W）
    let power: Double

    /// 累计运行时间（秒）
    let runtime: UInt64

    /// 最大压差（mV）：优先协议字段，缺失时用 最高 - 最低
    let voltageDiff: Int

    /// 充电 MOS 是否打开（字段缺失时为 nil）
    let chargeMosOn: Bool?

    /// 放电 MOS 是否打开（字段缺失时为 nil）
    let dischargeMosOn: Bool?

    /// 均衡状态原始枚举值（字段缺失时为 nil）
    let balanceStatus: Int?

    /// 均衡位图（每 bit 对应一个电芯的均衡状态）
    let balanceMask: UInt64

    /// 最高单体电压（mV，协议字段缺失时由列表计算）
    let maxCellVoltage: Int?

    /// 最高单体串号（从 1 开始；协议值为 0 或字段缺失时为 nil）
    let maxCellIndex: Int?

    /// 最低单体电压（mV，协议字段缺失时由列表计算）
    let minCellVoltage: Int?

    /// 最低单体串号（从 1 开始；协议值为 0 或字段缺失时为 nil）
    let minCellIndex: Int?

    /// 平均单体电压（mV，协议字段缺失时由列表计算）
    let averageCellVoltage: Int?

    /// 循环容量（Ah）：u32 × 0.001
    let cycleCapacity: Double

    /// 累计放电容量（Ah）：u32 × 0.001
    let totalDischargeCapacity: Double

    /// 累计充电容量（Ah）：u32 × 0.001
    let totalChargeCapacity: Double

    /// 累计放电时间（秒）
    let totalDischargeTime: UInt64

    /// 累计充电时间（秒）
    let totalChargeTime: UInt64

    /// BMS 状态码（帧第 8 字节，缺失时为 nil）
    let bmsStatusCode: Int?

    /// 状态码对应文本（与 Android 端映射表一致）
    let bmsStatusText: String

    /// 帧总长度（字节）
    let frameLength: Int

    /// 数据区长度声明与实际解析游标之间未解析的字节数
    let unparsedBytes: Int
}

extension BmsStatusResponse {
    /// 状态码 → 文本映射（与 Android `AntProtocol.kt` 的 `when` 分支完全一致）。
    static func statusText(for code: Int?) -> String {
        switch code {
        case 1: return "待机"
        case 2: return "充电中"
        case 3: return "放电中"
        case 4: return "休眠"
        case 5: return "错误"
        default: return "未知"
        }
    }
}

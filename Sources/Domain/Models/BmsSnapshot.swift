import Foundation

/// 一次 BMS 状态快照（值类型）。
/// 字段与 Android 端 `AntProtocol.kt` 的解析结果对应，单位保持一致。
/// 由 `BmsSnapshotMapper` 从 `BmsStatusResponse` 映射填充（服务层 Notify → 合包 → 解析 → 快照链路）。
struct BmsSnapshot: Equatable {
    /// 是否已连接保护板
    var isConnected = false

    /// 总电压（V）
    var totalVoltage: Double = 0

    /// 电流（A），放电为正
    var current: Double = 0

    /// SOC（%）
    var soc: Double = 0

    /// SOH（%）
    var soh: Double = 0

    /// 协议实时功率（W）
    var power: Double = 0

    /// GPS 速度（km/h），由 LocationService 写入
    var speedKmh: Double = 0

    /// 单体电压（mV）列表
    var cellVoltagesMillivolts: [Double] = []

    /// 最大压差（mV）：优先协议字段，缺失时由单体列表计算
    var voltageDiffMillivolts: Int = 0

    /// 传感器温度（°C）列表
    var temperaturesCelsius: [Int] = []

    /// MOS 温度（°C）
    var mosTemperatureCelsius: Int = 0

    /// 均衡器温度（°C）
    var balancerTemperatureCelsius: Int = 0

    /// 最高单体电压（mV，协议字段缺失时为 0）
    var maxCellVoltageMillivolts: Int = 0

    /// 最高单体串号（从 1 开始，未知为 0）
    var maxCellIndex: Int = 0

    /// 最低单体电压（mV，协议字段缺失时为 0）
    var minCellVoltageMillivolts: Int = 0

    /// 最低单体串号（从 1 开始，未知为 0）
    var minCellIndex: Int = 0

    /// 平均单体电压（mV，协议字段缺失时为 0）
    var averageCellVoltageMillivolts: Int = 0

    /// 均衡位图（每 bit 对应一个电芯的均衡状态）
    var balanceMask: UInt64 = 0

    /// 均衡状态原始枚举值（未知为 0）
    var balanceStatus: Int = 0

    /// 充电 MOS 状态（协议字段缺失时为 nil）
    var chargeMosOn: Bool?

    /// 放电 MOS 状态（协议字段缺失时为 nil）
    var dischargeMosOn: Bool?

    /// 设计容量（Ah）
    var capacityAh: Double = 0

    /// 剩余容量（Ah）
    var remainingChargeAh: Double = 0

    /// 循环容量（Ah）
    var cycleCapacityAh: Double = 0

    /// 累计运行时间（秒）
    var runtimeSeconds: UInt64 = 0

    /// 累计放电容量（Ah）
    var totalDischargeCapacityAh: Double = 0

    /// 累计充电容量（Ah）
    var totalChargeCapacityAh: Double = 0

    /// 累计放电时间（秒）
    var totalDischargeTimeSeconds: UInt64 = 0

    /// 累计充电时间（秒）
    var totalChargeTimeSeconds: UInt64 = 0

    /// BMS 状态码对应文本（待机/充电中/放电中/休眠/错误/未知；未连接为「未连接」）
    var bmsStatusText: String = "未连接"

    /// BMS 原始状态码（字段缺失时为 nil）
    var bmsStatusCode: Int?

    /// 最近完整响应帧长度（字节）
    var frameLength: Int = 0

    /// 数据区中尚未解析的字节数
    var unparsedBytes: Int = 0

    /// 最近一次成功解析完整帧的时间；由服务层写入。
    var lastUpdatedAt: Date?

    /// 展示功率：协议功率非 0 时用协议值，否则回退为 总压 × 电流。
    /// 与 Android 端 `displayPower()` 逻辑一致。
    func displayPower() -> Double {
        power != 0 ? power : totalVoltage * current
    }
}

import Foundation

enum AppearancePreference: String, Codable, CaseIterable, Hashable {
    case system
    case light
    case dark

    var displayText: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

enum TemperatureSource: String, Codable, CaseIterable, Hashable {
    case sensors
    case mos
    case average

    var displayText: String {
        switch self {
        case .sensors: return "传感器"
        case .mos: return "MOS"
        case .average: return "平均值"
        }
    }
}

enum DashboardDensity: String, Codable, CaseIterable, Hashable {
    case compact
    case standard
    case large

    var displayText: String {
        switch self {
        case .compact: return "紧凑"
        case .standard: return "标准"
        case .large: return "放大"
        }
    }
}

enum ScreenOrientationPreference: String, Codable, CaseIterable, Hashable {
    case system
    case portrait
    case landscape

    var displayText: String {
        switch self {
        case .system: return "跟随系统"
        case .portrait: return "竖屏"
        case .landscape: return "横屏"
        }
    }
}

/// 应用设置。所有新增字段都通过 `decodeIfPresent` 解码，兼容早期版本 JSON。
struct AppSettings: Codable, Equatable {
    var pollingIntervalMilliseconds: Int
    var manualRangeKmPerAh: Double
    var rangeDisplayMode: RangeDisplayMode
    var effectiveSpeedKmh: Double
    var rangeWindowSeconds: Int
    var rangeRefreshSeconds: Int
    var oldRangeWeight: Double
    var newRangeWeight: Double
    var homeAuxiliaryTextEnabled: Bool
    var dashboardDensity: DashboardDensity
    var temperatureSource: TemperatureSource
    var powerDisplayBaseWatts: Double
    var powerYellowThresholdWatts: Double
    var powerRedThresholdWatts: Double
    var socYellowThreshold: Double
    var socRedThreshold: Double
    var voltageDiffYellowMillivolts: Double
    var voltageDiffRedMillivolts: Double
    var temperatureYellowCelsius: Double
    var temperatureRedCelsius: Double
    var screenOrientation: ScreenOrientationPreference
    var appearance: AppearancePreference
    var recordingCapacityLimit: RecordingCapacityLimit
    var backgroundTrackingEnabled: Bool

    static let minimumManualRangeKmPerAh = 0.1
    static let maximumManualRangeKmPerAh = 100.0
    static let minimumEffectiveSpeedKmh = 0.0
    static let maximumEffectiveSpeedKmh = 120.0
    /// 综合窗口范围（秒）：对应 Android 1...120 分钟。
    static let minimumRangeWindowSeconds = 60
    static let maximumRangeWindowSeconds = 7_200
    /// 刷新频率范围（秒）：对应 Android 30...600 秒。
    static let minimumRangeRefreshSeconds = 30
    static let maximumRangeRefreshSeconds = 600

    static let defaults = AppSettings()

    init(
        pollingIntervalMilliseconds: Int = PollInterval.defaultMilliseconds,
        manualRangeKmPerAh: Double = 1.0,
        rangeDisplayMode: RangeDisplayMode = .computed,
        effectiveSpeedKmh: Double = 30.0,
        rangeWindowSeconds: Int = 900,
        rangeRefreshSeconds: Int = 60,
        oldRangeWeight: Double = 0.7,
        newRangeWeight: Double = 0.3,
        homeAuxiliaryTextEnabled: Bool = true,
        dashboardDensity: DashboardDensity = .standard,
        temperatureSource: TemperatureSource = .sensors,
        powerDisplayBaseWatts: Double = 1_000,
        powerYellowThresholdWatts: Double = 1_000,
        powerRedThresholdWatts: Double = 2_000,
        socYellowThreshold: Double = 30,
        socRedThreshold: Double = 15,
        voltageDiffYellowMillivolts: Double = 30,
        voltageDiffRedMillivolts: Double = 80,
        temperatureYellowCelsius: Double = 45,
        temperatureRedCelsius: Double = 60,
        screenOrientation: ScreenOrientationPreference = .system,
        appearance: AppearancePreference = .system,
        recordingCapacityLimit: RecordingCapacityLimit = .defaultValue,
        backgroundTrackingEnabled: Bool = false
    ) {
        self.pollingIntervalMilliseconds = PollInterval.clamped(pollingIntervalMilliseconds)
        self.manualRangeKmPerAh = min(max(manualRangeKmPerAh, Self.minimumManualRangeKmPerAh), Self.maximumManualRangeKmPerAh)
        self.rangeDisplayMode = rangeDisplayMode
        self.effectiveSpeedKmh = min(max(effectiveSpeedKmh, Self.minimumEffectiveSpeedKmh), Self.maximumEffectiveSpeedKmh)
        self.rangeWindowSeconds = min(max(rangeWindowSeconds, Self.minimumRangeWindowSeconds), Self.maximumRangeWindowSeconds)
        self.rangeRefreshSeconds = min(max(rangeRefreshSeconds, Self.minimumRangeRefreshSeconds), Self.maximumRangeRefreshSeconds)
        let old = min(max(oldRangeWeight, 0), 1)
        let new = min(max(newRangeWeight, 0), 1)
        let total = old + new
        self.oldRangeWeight = total > 0 ? old / total : 0.7
        self.newRangeWeight = total > 0 ? new / total : 0.3
        self.homeAuxiliaryTextEnabled = homeAuxiliaryTextEnabled
        self.dashboardDensity = dashboardDensity
        self.temperatureSource = temperatureSource
        self.powerDisplayBaseWatts = min(max(powerDisplayBaseWatts, 1), 100_000)
        let normalizedPowerYellow = min(max(powerYellowThresholdWatts, 0), 100_000)
        self.powerYellowThresholdWatts = normalizedPowerYellow
        self.powerRedThresholdWatts = min(max(powerRedThresholdWatts, normalizedPowerYellow), 100_000)
        let normalizedSocYellow = min(max(socYellowThreshold, 0), 100)
        self.socYellowThreshold = normalizedSocYellow
        self.socRedThreshold = min(max(socRedThreshold, 0), normalizedSocYellow)
        let normalizedVoltageYellow = min(max(voltageDiffYellowMillivolts, 0), 1_000)
        self.voltageDiffYellowMillivolts = normalizedVoltageYellow
        self.voltageDiffRedMillivolts = min(max(voltageDiffRedMillivolts, normalizedVoltageYellow), 1_000)
        let normalizedTemperatureYellow = min(max(temperatureYellowCelsius, -40), 150)
        self.temperatureYellowCelsius = normalizedTemperatureYellow
        self.temperatureRedCelsius = min(max(temperatureRedCelsius, normalizedTemperatureYellow), 150)
        self.screenOrientation = screenOrientation
        self.appearance = appearance
        self.recordingCapacityLimit = recordingCapacityLimit
        self.backgroundTrackingEnabled = backgroundTrackingEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case pollingIntervalMilliseconds, manualRangeKmPerAh, rangeDisplayMode, effectiveSpeedKmh
        case rangeWindowSeconds, rangeRefreshSeconds, oldRangeWeight, newRangeWeight
        case homeAuxiliaryTextEnabled, dashboardDensity, temperatureSource
        case powerDisplayBaseWatts, powerYellowThresholdWatts, powerRedThresholdWatts
        case socYellowThreshold, socRedThreshold, voltageDiffYellowMillivolts, voltageDiffRedMillivolts
        case temperatureYellowCelsius, temperatureRedCelsius, screenOrientation, appearance
        case recordingCapacityLimit, backgroundTrackingEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pollingIntervalMilliseconds: try c.decodeIfPresent(Int.self, forKey: .pollingIntervalMilliseconds) ?? PollInterval.defaultMilliseconds,
            manualRangeKmPerAh: try c.decodeIfPresent(Double.self, forKey: .manualRangeKmPerAh) ?? 1,
            rangeDisplayMode: try c.decodeIfPresent(RangeDisplayMode.self, forKey: .rangeDisplayMode) ?? .computed,
            effectiveSpeedKmh: try c.decodeIfPresent(Double.self, forKey: .effectiveSpeedKmh) ?? 30,
            rangeWindowSeconds: try c.decodeIfPresent(Int.self, forKey: .rangeWindowSeconds) ?? 900,
            rangeRefreshSeconds: try c.decodeIfPresent(Int.self, forKey: .rangeRefreshSeconds) ?? 60,
            oldRangeWeight: try c.decodeIfPresent(Double.self, forKey: .oldRangeWeight) ?? 0.7,
            newRangeWeight: try c.decodeIfPresent(Double.self, forKey: .newRangeWeight) ?? 0.3,
            homeAuxiliaryTextEnabled: try c.decodeIfPresent(Bool.self, forKey: .homeAuxiliaryTextEnabled) ?? true,
            dashboardDensity: try c.decodeIfPresent(DashboardDensity.self, forKey: .dashboardDensity) ?? .standard,
            temperatureSource: try c.decodeIfPresent(TemperatureSource.self, forKey: .temperatureSource) ?? .sensors,
            powerDisplayBaseWatts: try c.decodeIfPresent(Double.self, forKey: .powerDisplayBaseWatts) ?? 1_000,
            powerYellowThresholdWatts: try c.decodeIfPresent(Double.self, forKey: .powerYellowThresholdWatts) ?? 1_000,
            powerRedThresholdWatts: try c.decodeIfPresent(Double.self, forKey: .powerRedThresholdWatts) ?? 2_000,
            socYellowThreshold: try c.decodeIfPresent(Double.self, forKey: .socYellowThreshold) ?? 30,
            socRedThreshold: try c.decodeIfPresent(Double.self, forKey: .socRedThreshold) ?? 15,
            voltageDiffYellowMillivolts: try c.decodeIfPresent(Double.self, forKey: .voltageDiffYellowMillivolts) ?? 30,
            voltageDiffRedMillivolts: try c.decodeIfPresent(Double.self, forKey: .voltageDiffRedMillivolts) ?? 80,
            temperatureYellowCelsius: try c.decodeIfPresent(Double.self, forKey: .temperatureYellowCelsius) ?? 45,
            temperatureRedCelsius: try c.decodeIfPresent(Double.self, forKey: .temperatureRedCelsius) ?? 60,
            screenOrientation: try c.decodeIfPresent(ScreenOrientationPreference.self, forKey: .screenOrientation) ?? .system,
            appearance: try c.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system,
            recordingCapacityLimit: try c.decodeIfPresent(RecordingCapacityLimit.self, forKey: .recordingCapacityLimit) ?? .defaultValue,
            backgroundTrackingEnabled: try c.decodeIfPresent(Bool.self, forKey: .backgroundTrackingEnabled) ?? false)
    }
}

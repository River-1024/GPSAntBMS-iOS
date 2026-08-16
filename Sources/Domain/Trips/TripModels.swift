import Foundation

/// 行程中的一次位置采样（纯值类型，不依赖 CoreLocation）。
/// 由调用方（未来的 LocationService 集成）在前台激活期间提供；
/// BMS 可选字段仅限剩余容量与实时功率。
struct TripLocationSample: Codable, Equatable {
    /// 采样时间（确定性：测试直接注入具体时间戳）
    let timestamp: Date

    /// 纬度（度）
    let latitude: Double

    /// 经度（度）
    let longitude: Double

    /// 速度（km/h），必须为非负有限值
    let speedKmh: Double

    /// 水平精度（m），有效范围 (0, 100]
    let horizontalAccuracyMeters: Double

    /// 可选：BMS 剩余容量（Ah）
    /// 用 `var` 带默认值：`let` + 默认值不进入 memberwise init 且 Codable 解码时
    /// 无法覆盖（JSON 中的值会被丢弃）；`var` 两者皆可。
    var remainingAh: Double? = nil

    /// 可选：BMS 实时功率（W）
    var powerW: Double? = nil

    /// 与另一采样的 haversine 距离（km）。
    /// 地球半径取均值 6371 km，输入为十进制度。
    func distanceKm(to other: TripLocationSample) -> Double {
        TripLocationSample.haversineKm(
            lat1: latitude, lon1: longitude,
            lat2: other.latitude, lon2: other.longitude
        )
    }

    /// haversine 公式：十进制度输入，返回 km。
    static func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadiusKm = 6371.0
        let lat1Rad = lat1 * .pi / 180
        let lat2Rad = lat2 * .pi / 180
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1Rad) * cos(lat2Rad) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusKm * c
    }
}

/// 已归档行程记录（不可变，由 `TripRecorder.stop()` 一次性产生）。
/// 与 Android 端格式不兼容；`durationSeconds` 只累计前台激活时长，
/// 后台/非活跃时间与距离不计入。
/// `Identifiable`：`id` 为持久化主键，供 SwiftUI `ForEach` 直接使用。
struct TripRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let startedAt: Date
    let endedAt: Date
    /// 前台激活累计时长（s）
    let durationSeconds: TimeInterval
    /// 累计分段距离（km）
    let distanceKm: Double
    /// 平均速度（km/h）= distanceKm / (durationSeconds / 3600)
    let averageSpeedKmh: Double
    let startRemainingAh: Double?
    let endRemainingAh: Double?
    let consumedAh: Double
    let energyAhPer100Km: Double
    /// 全部被接受的采样
    let samples: [TripLocationSample]

    var kmPerAh: Double {
        consumedAh > 0 ? distanceKm / consumedAh : 0
    }

    init(
        id: UUID,
        name: String = "",
        startedAt: Date,
        endedAt: Date,
        durationSeconds: TimeInterval,
        distanceKm: Double,
        averageSpeedKmh: Double,
        startRemainingAh: Double? = nil,
        endRemainingAh: Double? = nil,
        consumedAh: Double = 0,
        energyAhPer100Km: Double = 0,
        samples: [TripLocationSample]
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = max(0, durationSeconds)
        self.distanceKm = max(0, distanceKm)
        self.averageSpeedKmh = max(0, averageSpeedKmh)
        self.startRemainingAh = startRemainingAh
        self.endRemainingAh = endRemainingAh
        self.consumedAh = max(0, consumedAh)
        self.energyAhPer100Km = max(0, energyAhPer100Km)
        self.samples = samples
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, startedAt, endedAt, durationSeconds, distanceKm, averageSpeedKmh
        case startRemainingAh, endRemainingAh, consumedAh, energyAhPer100Km, samples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            endedAt: try container.decode(Date.self, forKey: .endedAt),
            durationSeconds: try container.decode(TimeInterval.self, forKey: .durationSeconds),
            distanceKm: try container.decode(Double.self, forKey: .distanceKm),
            averageSpeedKmh: try container.decode(Double.self, forKey: .averageSpeedKmh),
            startRemainingAh: try container.decodeIfPresent(Double.self, forKey: .startRemainingAh),
            endRemainingAh: try container.decodeIfPresent(Double.self, forKey: .endRemainingAh),
            consumedAh: try container.decodeIfPresent(Double.self, forKey: .consumedAh) ?? 0,
            energyAhPer100Km: try container.decodeIfPresent(Double.self, forKey: .energyAhPer100Km) ?? 0,
            samples: try container.decodeIfPresent([TripLocationSample].self, forKey: .samples) ?? [])
    }
}

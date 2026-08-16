import Foundation

enum SoftwareLogLevel: Int, Codable, CaseIterable, Comparable, Hashable {
    case debug
    case info
    case warning
    case error

    static func < (lhs: SoftwareLogLevel, rhs: SoftwareLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayText: String {
        switch self {
        case .debug: return "调试"
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }
}

struct SoftwareLogEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let level: SoftwareLogLevel
    let source: String
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: SoftwareLogLevel,
        source: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.source = source
        self.message = message
    }
}

import Foundation

/// BLE 轮询间隔规则（对齐 Android `BmsBluetoothManager.setPollingInterval` 的
/// `coerceIn(200L, 60_000L)`：默认 1000 ms，钳制范围 200 ms 至 60000 ms）。
enum PollInterval {
    static let defaultMilliseconds = 1_000
    static let minimumMilliseconds = 200
    static let maximumMilliseconds = 60_000

    /// 将毫秒数钳制到 [200, 60000]。
    static func clamped(_ milliseconds: Int) -> Int {
        min(max(milliseconds, minimumMilliseconds), maximumMilliseconds)
    }
}

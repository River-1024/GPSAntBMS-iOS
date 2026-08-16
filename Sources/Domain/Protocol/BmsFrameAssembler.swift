import Foundation

/// 帧组装错误。
enum FrameAssemblerError: Error, Equatable {
    /// 缓冲区超过 512 字节。
    /// Android 端视为数据异常，清空缓冲区后静默丢弃；这里用类型化错误表达该丢弃事件。
    case bufferOverflow(limit: Int)
}

/// ANT BMS 响应帧组装器（移植自 Android `BmsBluetoothManager.handleIncomingData`）。
///
/// BLE Notify 分片按序喂入，规则与 Android 完全一致：
/// 1. 分片以帧头 `7E A1` 开头 → 清空旧缓存，开始新帧；
/// 2. 分片追加到缓存；
/// 3. 缓存超过 512 字节 → 清空缓存并抛 `bufferOverflow`（Android 为清空后静默丢弃）；
/// 4. 缓存末尾为 `AA 55` → 视为完整帧返回，并清空缓存。
///
/// 已知限制（与 Android 一致，非缺陷）：协议无转义机制，若帧内恰好出现 `AA 55`
/// 且落在分片末尾，会被提前当作帧尾；解析器因此对可选尾部字段用长度保护跳过。
struct BmsFrameAssembler {
    /// 缓冲区上限（Android 硬编码 512 字节，BMS 响应帧最大约 200 字节）
    static let maxBufferSize = 512

    private(set) var buffer: [UInt8] = []

    /// 当前缓存字节数。
    var pendingCount: Int { buffer.count }

    /// 缓存是否为空（无进行中的帧）。
    var isEmpty: Bool { buffer.isEmpty }

    /// 追加一个 BLE 通知分片。
    /// - Parameter chunk: 单次 Notify 收到的字节。
    /// - Returns: 完整帧字节（以 `AA 55` 结尾）并清空缓存；帧未完成时返回 nil。
    /// - Throws: `FrameAssemblerError.bufferOverflow`。抛出前缓存已清空，可继续使用本组装器。
    @discardableResult
    mutating func append(_ chunk: [UInt8]) throws -> [UInt8]? {
        guard !chunk.isEmpty else { return nil }

        // 帧头 7E A1：丢弃旧缓存，开始新帧
        if chunk.count >= 2, chunk[0] == 0x7E, chunk[1] == 0xA1 {
            buffer.removeAll()
        }

        buffer.append(contentsOf: chunk)

        // 溢出保护：超过 512 字节说明数据异常，清空缓冲区（与 Android 顺序一致）
        if buffer.count > Self.maxBufferSize {
            buffer.removeAll()
            throw FrameAssemblerError.bufferOverflow(limit: Self.maxBufferSize)
        }

        // 帧尾 AA 55：完整帧到达
        if buffer.count >= 2,
            buffer[buffer.count - 2] == 0xAA,
            buffer[buffer.count - 1] == 0x55 {
            defer { buffer.removeAll() }
            return buffer
        }

        return nil
    }

    /// 手动清空缓存。
    mutating func reset() {
        buffer.removeAll()
    }
}

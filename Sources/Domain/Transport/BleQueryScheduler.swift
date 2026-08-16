import Foundation

/// 查询命令串行化调度器：任意时刻最多一个在途（in-flight）写入，
/// 轮询节拍撞上在途写入时只合并一个挂起（pending）查询，写入完成回调后立即补发。
///
/// 这是「串行化 `.withResponse` 查询轮询」的纯逻辑核心（不持有定时器，定时由服务层驱动）：
/// - `pollTick()`：定时器节拍。在途 → 置 `hasPending` 并返回 false（本轮不写）；空闲 → 标记在途并返回 true（立即写）。
/// - `writeCompleted()`：`didWriteValueFor` 回调。清在途；若之前合并了挂起查询 → 立即补发（返回 true）并重新标记在途。
/// - `reset()`：停止/断开时清空在途与挂起，保证前台会话重启后不残留半途状态。
struct BleQueryScheduler: Equatable {
    /// 是否有写入在途（等待 `didWriteValueFor`）。
    private(set) var isInFlight = false
    /// 是否合并了一个待补发的查询（多个节拍只保留一个）。
    private(set) var hasPending = false

    /// 轮询节拍。返回 true 表示本轮应写入一条查询命令。
    mutating func pollTick() -> Bool {
        if isInFlight {
            hasPending = true
            return false
        }
        isInFlight = true
        return true
    }

    /// 在途写入完成（`didWriteValueFor`）。返回 true 表示应立刻补发合并的挂起查询。
    mutating func writeCompleted() -> Bool {
        isInFlight = false
        if hasPending {
            hasPending = false
            isInFlight = true
            return true
        }
        return false
    }

    /// 清空在途与挂起（停止轮询 / 断开 / 前台会话停止时调用）。
    mutating func reset() {
        isInFlight = false
        hasPending = false
    }
}

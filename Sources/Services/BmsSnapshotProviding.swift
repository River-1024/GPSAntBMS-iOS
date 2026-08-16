import Combine
import Foundation

/// 仪表盘快照提供者契约。
///
/// `DashboardViewModel` 只依赖该协议（而非具体服务类），
/// 便于单元测试注入 Mock 提供者；`BmsBluetoothService` 是生产实现。
protocol BmsSnapshotProviding {
    /// 当前快照（服务发布的最新解析结果）。
    var snapshot: BmsSnapshot { get }

    /// 快照更新流（服务层在每次解析/连接状态变化后发布）。
    var snapshotPublisher: AnyPublisher<BmsSnapshot, Never> { get }
}

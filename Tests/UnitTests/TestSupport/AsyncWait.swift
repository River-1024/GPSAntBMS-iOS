import Foundation
import XCTest

/// 推进主 run loop 直到条件满足或超时，否则断言失败。
///
/// 背景：`DashboardViewModel` 经 `receive(on: DispatchQueue.main)` 投递的 Combine 值，
/// 在 iOS 模拟器 XCTest 中**不会**被 `XCTNSPredicateExpectation` 的
/// `wait(for:timeout:)` 驱动——谓词等待不 drain 主队列，sink 永不执行，
/// 任何依赖该投递路径的期望都会 1 秒超时（CI 第 7 轮 5 个测试实测失败）。
/// 本函数用 `RunLoop.main.run(until:)` 显式推进主队列，逐帧轮询条件。
///
/// - Parameters:
///   - timeout: 最长等待秒数（默认 5 秒，覆盖 CI 慢机）。
///   - condition: 轮询条件；每次迭代重新求值。
func waitUntil(timeout: TimeInterval = 5.0,
               file: StaticString = #filePath,
               line: UInt = #line,
               _ condition: @autoclosure () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), "条件在 \(timeout) 秒内未满足", file: file, line: line)
}

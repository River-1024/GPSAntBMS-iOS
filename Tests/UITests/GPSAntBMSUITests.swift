import XCTest

/// UI 测试：启动冒烟 + 五个一级 Tab 切换。
///
/// 策略：
/// - **不依赖真实 BLE 硬件**：不点击扫描/连接，仅断言 App 启动、五个 Tab 均可选中、
///   各屏幕可达性标识存在；
/// - **权限弹窗兜底**：首次启动可能出现定位/蓝牙系统授权弹窗，通过最小化策略
///   （SpringBoard / App 弹窗查询 + 点击任一可用按钮）关闭后继续断言——
///   App 在未授权/未决定状态下也能正常渲染，因此允许/拒绝任一选择均可继续。
final class GPSAntBMSUITests: XCTestCase {

    /// (Tab 标识, Tab 中文名, 屏幕标识)
    private static let tabs: [(tabID: String, tabLabel: String, screenID: String)] = [
        ("tab.dashboard", "仪表盘", "dashboard.screen"),
        ("tab.devices", "设备", "devices.screen"),
        ("tab.dashcam", "录像", "dashcam.screen"),
        ("tab.trips", "行程", "trips.screen"),
        ("tab.settings", "设置", "settings.screen"),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 启动冒烟：App 能正常启动并进入前台（首次启动的系统权限弹窗不影响该断言）。
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        dismissPermissionAlertsIfPresent(in: app)

        XCTAssertEqual(app.state, .runningForeground)
    }

    /// 五个一级 Tab 均可选中，且各自屏幕在选中后可见。
    func testSelectingAllTabs() throws {
        let app = XCUIApplication()
        app.launch()
        dismissPermissionAlertsIfPresent(in: app)

        for tab in Self.tabs {
            tabBarButton(app, id: tab.tabID, label: tab.tabLabel).tap()

            let screen = app.descendants(matching: .any)[tab.screenID].firstMatch
            XCTAssertTrue(screen.waitForExistence(timeout: 5),
                          "选中「\(tab.tabLabel)」后应可见 \(tab.screenID)")
        }
    }

    func testDashcamPanelLivesOnRecordingTabInsteadOfDashboard() throws {
        let app = XCUIApplication()
        app.launch()
        dismissPermissionAlertsIfPresent(in: app)

        tabBarButton(app, id: "tab.dashboard", label: "仪表盘").tap()
        XCTAssertFalse(app.buttons["dashcam.open"].exists)

        tabBarButton(app, id: "tab.dashcam", label: "录像").tap()
        XCTAssertTrue(app.buttons["dashcam.open"].waitForExistence(timeout: 5))
    }

    // MARK: - 私有辅助

    /// 查找 Tab 栏按钮：优先按稳定标识，回退到中文标签（适配两种 SwiftUI 标识传播行为）。
    private func tabBarButton(_ app: XCUIApplication, id: String, label: String) -> XCUIElement {
        let byID = app.tabBars.buttons[id]
        if byID.exists {
            return byID
        }
        return app.tabBars.buttons[label]
    }

    /// 最小化权限弹窗处理：最多两轮（定位/蓝牙各可能弹一次），
    /// 优先在 App 弹窗查询中查找，其次 SpringBoard；任意可用按钮即可关闭。
    private func dismissPermissionAlertsIfPresent(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alertSources = [app.alerts, springboard.alerts]

        for _ in 0..<2 {
            var dismissed = false
            for query in alertSources {
                let alert = query.firstMatch
                if alert.waitForExistence(timeout: 2) {
                    Self.dismissButton(in: alert).tap()
                    dismissed = true
                    break
                }
            }
            if !dismissed {
                break
            }
        }
    }

    private static func dismissButton(in alert: XCUIElement) -> XCUIElement {
        for label in ["允许", "Allow", "好", "OK", "不允许", "Don't Allow"] {
            let button = alert.buttons[label]
            if button.exists {
                return button
            }
        }
        return alert.buttons.element(boundBy: 0)
    }
}

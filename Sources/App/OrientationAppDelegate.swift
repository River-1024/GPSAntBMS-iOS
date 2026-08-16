import UIKit

/// 为 SwiftUI WindowGroup 提供可动态更新的方向策略。
final class OrientationAppDelegate: NSObject, UIApplicationDelegate {
    static var supportedMask: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedMask
    }

    static func apply(_ preference: ScreenOrientationPreference) {
        switch preference {
        case .system:
            supportedMask = [.portrait, .landscapeLeft, .landscapeRight]
        case .portrait:
            supportedMask = .portrait
        case .landscape:
            supportedMask = [.landscapeLeft, .landscapeRight]
        }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if #available(iOS 16.0, *) {
                scene.requestGeometryUpdate(
                    UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: supportedMask),
                    errorHandler: nil
                )
            }
        }
    }
}

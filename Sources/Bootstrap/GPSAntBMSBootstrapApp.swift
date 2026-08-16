// 首次里程碑引导入口（Bootstrap）。
// 本文件是 App 目标唯一编译的源码（见 project.yml 中 GPSAntBMS.sources）。
// 仅静态状态页：无交互、无权限、无 BLE/GPS 依赖，验证未签名 IPA 可运行。

import SwiftUI

@main
struct GPSAntBMSBootstrapApp: App {
    var body: some Scene {
        WindowGroup {
            BootstrapStatusView()
        }
    }
}

/// 静态状态页：应用名、首次构建版本标记，以及后续功能说明。
struct BootstrapStatusView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "battery.100")
                .font(.system(size: 56))
                .foregroundStyle(.white)
                .frame(width: 112, height: 112)
                .background(Circle().fill(.tint))

            Text("GPS ANT BMS")
                .font(.largeTitle)
                .bold()

            Text("首次构建版本")
                .font(.title3)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 120)

            Text("BLE 蓝牙连接与 GPS 速度显示功能将在后续版本提供。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            Text("v0.1.0 · 未签名构建")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

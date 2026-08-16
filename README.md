# GPS ANT BMS (iOS)

GPS ANT BMS 是一个原生 SwiftUI iOS 应用，用于通过 BLE 连接 ANT BMS，显示电池状态与 GPS 速度，并在本机提供行程、续航估算和行车记录功能。

## 功能

- 扫描并连接名称以 `ANT` 开头的 BLE 设备。
- 通过 FFE0/FFE1 服务与特征读取并解析 ANT BMS 状态帧。
- 显示电压、电流、功率、剩余容量、SOC、温度、单体电压和 GPS 速度。
- 在本机记录行程轨迹、距离、时长、平均速度和关联的 BMS 样本。
- 维护本地续航计算池，支持自动估算和手动 km/Ah 回退值。
- 使用后置摄像头和麦克风录制分段行车视频，支持锁定、循环容量、播放、分享与导出。
- 提供仪表盘、设备、行程、录像和设置界面。

## 平台边界

| 项目 | 说明 |
| --- | --- |
| 最低系统 | iOS 16.0 |
| UI | SwiftUI，`@main` App 生命周期 |
| 系统框架 | CoreBluetooth、CoreLocation、AVFoundation、SwiftUI、Combine |
| 第三方运行时依赖 | 无 |
| 工程生成 | XcodeGen，以 `project.yml` 为唯一工程定义 |
| CI 产物 | 未签名 IPA，仅供自签或构建校验 |

应用不包含账号、云同步、分析 SDK、广告 SDK、HTTP API 或 WebSocket 上报。位置、BMS、行程、录像和软件日志都在设备本机处理；只有用户主动分享、导出或复制时才会离开应用。完整说明见 [PRIVACY.md](PRIVACY.md)。

## 目录

| 路径 | 作用 |
| --- | --- |
| `Sources/App/` | App 组合根、生命周期和顶层导航 |
| `Sources/Domain/` | 协议、模型、行程、续航、录像和设置规则 |
| `Sources/Services/` | BLE、定位、录像、行程和日志服务 |
| `Sources/Features/` | 仪表盘、设备、行程、录像和设置界面 |
| `Sources/DesignSystem/` | 主题与公共视觉样式 |
| `Resources/` | Info.plist、Privacy Manifest、entitlements 和图标 |
| `Tests/` | SwiftPM/Xcode 单元测试和 UI 冒烟测试 |
| `scripts/` | 工程生成、测试、校验和未签名 IPA 打包脚本 |

## 构建

需要 macOS、包含 iOS 27 SDK 的 Xcode，以及 XcodeGen。

```bash
brew install xcodegen
./scripts/generate_project.sh
open GPSAntBMS.xcodeproj
```

运行测试：

```bash
swift test
./scripts/test.sh
```

生成未签名 IPA：

```bash
./scripts/package_unsigned_ipa.sh
```

产物位于 `dist/GPSAntBMS-unsigned.ipa`。该文件不包含签名材料，不能直接通过 Apple 官方渠道安装或发布。

Windows 没有 Xcode 工具链，不能直接构建 iOS App。本仓库的 GitHub Actions 会在 macOS runner 上完成工程生成、SwiftPM 测试、模拟器测试、未签名 IPA 打包和结构校验。

## 权限与本地数据

- 蓝牙：连接 ANT BMS 并读取状态。
- 使用 App 时定位：显示 GPS 速度并记录行程。
- 始终定位：仅在用户开启后台保活并正在记录行程时请求。
- 摄像头与麦克风：录制用户主动开始的行车视频。
- 添加到照片：仅在用户主动导出录像时使用。
- 后台模式：定位、BLE central 和音频，仅用于用户启用的行程/录像相关流程。

用户可以在 App 内删除行程、录像和软件日志。录像分享前应自行检查画面与声音中是否包含位置、车牌、人脸或其他敏感信息。

## 当前状态

核心功能和自动化测试已经实现；公开整理前的功能源码基线为 `4afe021fbd25344fc7553e720e55d9d291507fa9`。公开仓库 CI 已完整通过工程生成、SwiftPM 测试、模拟器测试、未签名 IPA 打包、结构校验和 Artifact 上传；ANT BMS、GPS、后台切换和连续录像仍需在真机上完成验证。

详细状态与已知限制见 [docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md)，行车记录真机测试见 [docs/DASHCAM_DEVICE_VERIFICATION.md](docs/DASHCAM_DEVICE_VERIFICATION.md)。

## 安全与贡献

- 安全问题请按 [SECURITY.md](SECURITY.md) 私下报告，不要在公开 Issue 中披露凭据或漏洞细节。
- 提交代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
- 不要提交证书、描述文件、私钥、Token、真实设备数据、本机路径或包含隐私信息的日志与媒体。

## 许可证

本项目使用 [MIT License](LICENSE)。

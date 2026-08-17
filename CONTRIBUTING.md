# 贡献指南

## 开发环境

需要 macOS、包含 iOS 27 SDK 的 Xcode 和 XcodeGen。工程文件由 `project.yml` 生成，不提交 `GPSAntBMS.xcodeproj`。

```bash
brew install xcodegen
./scripts/generate_project.sh
swift test
./scripts/test.sh
```

涉及设备、定位、后台行为或录像的改动，还应在真机上验证。行车记录测试清单见 `docs/DASHCAM_DEVICE_VERIFICATION.md`。

修改用户可见版本或应用内更新记录时，遵循 [版本管理说明](docs/VERSIONING.md)。

## 提交要求

- 保持改动聚焦，并为行为变化补充测试。
- 不要提交生成工程、构建产物、未签名 IPA 或工具会话目录。
- 不要提交 Token、证书、描述文件、私钥、`.env`、本机绝对路径或私有远端地址。
- 不要提交真实 GPS 轨迹、设备标识、录像、声音或未脱敏日志。
- 修改权限、后台模式或数据处理方式时，同步更新 `README.md`、`PRIVACY.md`、`Resources/Info.plist` 和 `Resources/PrivacyInfo.xcprivacy`。

## Pull Request

Pull Request 应说明用户可见变化、验证方式、已知限制以及是否涉及蓝牙、定位、录像、后台模式或本地数据格式。CI 必须通过后再合并。

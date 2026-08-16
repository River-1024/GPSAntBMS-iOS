# scripts/ 说明

| 脚本 | 平台 | 作用 |
| --- | --- | --- |
| `generate_project.sh` | macOS | 用 XcodeGen 生成确定性工程 `GPSAntBMS.xcodeproj`（构建前必须执行） |
| `test.sh` | macOS | 模拟器构建 + 单元/UI 测试（`CODE_SIGNING_ALLOWED=NO`）；**CI 强制门禁**，失败即阻断打包 |
| `package_unsigned_ipa.sh` | macOS | Release 设备包构建 + 未签名 IPA 打包（`dist/GPSAntBMS-unsigned.ipa`） |
| `generate_project.ps1` | Windows | 明确失败的占位脚本：Windows 无法生成/构建 iOS 工程，只能做静态检查，指引使用 CI |

所有脚本都遵循「快速失败」约定：

- 非 macOS 平台立即 `exit 1` 并说明原因。
- 缺少 xcodegen、缺少工程、缺少模拟器、构建产物缺失等前置条件不满足时立即失败。
- CI 中的任何步骤失败都会导致整个 workflow 失败，不会静默跳过。

CI 强制顺序（测试在打包之前，均为门禁，见 `.github/workflows/ci.yml`）：

```bash
./scripts/generate_project.sh      # 1. 生成工程
swift test                         # 2. SPM 纯域层测试（强制，失败即阻断）
./scripts/test.sh                  # 3. 模拟器单元 + UI 测试（强制，失败即阻断）
./scripts/package_unsigned_ipa.sh  # 4. Release 设备构建并打包未签名 IPA
# 5. CI 校验 IPA 结构：必须含 Payload/GPSAntBMS.app/ 与可执行文件
#    Payload/GPSAntBMS.app/GPSAntBMS，且不得包含 embedded.mobileprovision
# 6. 上传 GPSAntBMS-unsigned-ipa artifact
```

该 workflow 尚未在 macOS/GitHub Actions 上运行过：不得声称测试通过、IPA 已产出或真机验证完成。Windows 本机只能做静态检查（无 Swift/Xcode 工具链），`generate_project.ps1` 会明确失败并说明原因。

本机 macOS 调试：

```bash
brew install xcodegen
./scripts/generate_project.sh
open GPSAntBMS.xcodeproj
```

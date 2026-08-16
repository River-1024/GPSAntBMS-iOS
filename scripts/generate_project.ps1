# ============================================================
# generate_project.ps1 - Windows 占位脚本
#
# iOS 工程生成/构建需要 macOS（Xcode 与 XcodeGen 仅存在于 macOS）。
# 本脚本在 Windows 上明确失败并给出指引，避免产生无效路径或半成品。
# ============================================================

Write-Error "iOS 工程生成需要 macOS：本机（运行 ./scripts/generate_project.sh）或 GitHub Actions macos runner。Windows 不支持 Xcode/XcodeGen。请推送代码后使用 iOS 仓库的 CI workflow。"

exit 1

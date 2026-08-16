#!/usr/bin/env bash
# 生成确定性 Xcode 工程（GPSAntBMS.xcodeproj）。
# 仅支持 macOS（Xcode/XcodeGen 仅存在于 macOS）。
set -euo pipefail

if [[ "$OSTYPE" != "darwin"* ]]; then
  echo "错误：Xcode 工程生成只支持 macOS（macOS 本机或 GitHub Actions macos runner）。" >&2
  echo "Windows 用户请推送后使用 GitHub Actions，或运行 scripts/generate_project.ps1 查看说明。" >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "错误：缺少 xcodegen。请先执行：brew install xcodegen" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

xcodegen generate

if [[ ! -d "GPSAntBMS.xcodeproj" ]]; then
  echo "错误：xcodegen 执行完成但未生成 GPSAntBMS.xcodeproj。" >&2
  exit 1
fi

echo "生成完成：$(pwd)/GPSAntBMS.xcodeproj"

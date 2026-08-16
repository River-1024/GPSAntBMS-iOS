#!/usr/bin/env bash
# 构建未签名 Release 设备包，并打包为未签名 IPA（dist/GPSAntBMS-unsigned.ipa）。
# 仅支持 macOS，且需要先生成工程（./scripts/generate_project.sh）。
#
# 未签名 IPA 的用途与限制：
# - 不能通过 Apple 官方通道安装或上架（App Store/TestFlight 均不接受）。
# - 仅可用于自签工具（AltStore、Sideloadly 等）重新签名后侧载，
#   或作为 CI 构建产物完整性冒烟验证。
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$OSTYPE" != "darwin"* ]]; then
  echo "错误：IPA 打包必须在 macOS 上运行（macOS 本机或 GitHub Actions macos runner）。" >&2
  exit 1
fi

if [[ ! -d "GPSAntBMS.xcodeproj" ]]; then
  echo "错误：未找到 GPSAntBMS.xcodeproj，请先运行 ./scripts/generate_project.sh" >&2
  exit 1
fi

APP_PATH="build/DerivedData/Build/Products/Release-iphoneos/GPSAntBMS.app"
IPA_PATH="dist/GPSAntBMS-unsigned.ipa"

# 未签名构建：不指定 CODE_SIGN_IDENTITY，禁止签名。
xcodebuild build \
  -project GPSAntBMS.xcodeproj \
  -scheme GPSAntBMS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

if [[ ! -d "${APP_PATH}" ]]; then
  echo "错误：构建产物缺失：${APP_PATH}" >&2
  exit 1
fi

rm -rf build/IPA dist
mkdir -p build/IPA/Payload dist

cp -R "${APP_PATH}" build/IPA/Payload/

(
  cd build/IPA
  zip -qry "../../${IPA_PATH}" Payload
)

if [[ ! -f "${IPA_PATH}" ]]; then
  echo "错误：IPA 打包失败：${IPA_PATH}" >&2
  exit 1
fi

echo "未签名 IPA 已生成：$(pwd)/${IPA_PATH}"
echo "注意：该 IPA 未签名，仅适用于自签工具重新签名后侧载，不可直接安装或上架。"

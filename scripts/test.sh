#!/usr/bin/env bash
# 在模拟器上构建并运行单元测试与 UI 测试（scheme: GPSAntBMS）。
# 仅支持 macOS，且需要先生成工程（./scripts/generate_project.sh）。
# 模拟器选择：
# - 显式设置 SIMULATOR_NAME 时，指定的设备必须可用，否则立即失败；
# - 未设置时自动检测可用的 iPhone 模拟器（优先 iPhone 15，其次任选可用设备），
#   不盲目假设某个型号必然存在。
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$OSTYPE" != "darwin"* ]]; then
  echo "错误：测试必须在 macOS 上运行（macOS 本机或 GitHub Actions macos runner）。" >&2
  exit 1
fi

if [[ ! -d "GPSAntBMS.xcodeproj" ]]; then
  echo "错误：未找到 GPSAntBMS.xcodeproj，请先运行 ./scripts/generate_project.sh" >&2
  exit 1
fi

# 自动选择模拟器：优先 iPhone 15，否则返回第一个可用的 iPhone 模拟器。
# 使用 simctl 的 JSON 输出解析，避免依赖文本格式中的设备名/状态列。
pick_available_simulator() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
names = []
for _runtime, devices in data.get("devices", {}).items():
    for d in devices:
        name = d.get("name", "")
        if name.startswith("iPhone") and name not in names:
            names.append(name)
if "iPhone 15" in names:
    print("iPhone 15")
elif names:
    print(names[0])
'
}

if [[ -n "${SIMULATOR_NAME:-}" ]]; then
  SIM_NAME="$SIMULATOR_NAME"
  if ! xcrun simctl list devices available | grep -qF "${SIM_NAME}"; then
    echo "错误：找不到名为 '${SIM_NAME}' 的模拟器。可用设备列表：" >&2
    xcrun simctl list devices available >&2
    echo "可通过 SIMULATOR_NAME 环境变量指定其他设备，例如：SIMULATOR_NAME='iPhone 16' ./scripts/test.sh" >&2
    exit 1
  fi
else
  SIM_NAME="$(pick_available_simulator)" || true
  if [[ -z "${SIM_NAME}" ]]; then
    echo "错误：没有可用的 iPhone 模拟器。请先在 Xcode 中创建模拟器。" >&2
    exit 1
  fi
  echo "未指定 SIMULATOR_NAME，自动选择模拟器：${SIM_NAME}"
fi

# CODE_SIGNING_ALLOWED=NO：模拟器构建无需签名。
xcodebuild test \
  -project GPSAntBMS.xcodeproj \
  -scheme GPSAntBMS \
  -destination "platform=iOS Simulator,name=${SIM_NAME}" \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO

echo "测试完成。"

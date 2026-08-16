#!/usr/bin/env bash
set -euo pipefail

require_text() {
  local file="$1"
  local text="$2"
  if ! grep -Fq -- "$text" "$file"; then
    echo "错误：${file} 缺少 Liquid Glass 契约：${text}" >&2
    exit 1
  fi
}

require_absent() {
  local path="$1"
  local text="$2"
  if grep -R -Fq --include='*.swift' -- "$text" "$path"; then
    echo "错误：${path} 仍包含旧的不透明表面：${text}" >&2
    exit 1
  fi
}

require_text "Sources/DesignSystem/Theme.swift" "glassEffect(.regular"
require_text "Sources/DesignSystem/Theme.swift" "GlassEffectContainer(spacing: spacing)"
require_text "Sources/DesignSystem/Theme.swift" "buttonStyle(.glassProminent)"
require_text "Sources/DesignSystem/Theme.swift" "legacyGlassSurface"
require_text "Sources/Features/Dashboard/DashboardView.swift" ".appFlatCard()"
require_text "Sources/Features/Dashboard/DashboardView.swift" ".appFlatCapsule()"
require_text "Sources/Features/Dashboard/DashboardView.swift" ".appFlatButtonStyle()"
require_text "Sources/Features/Settings/SettingsView.swift" ".settingsFlatControlSurface()"
if grep -Fq -- ".appGlass" "Sources/Features/Dashboard/DashboardView.swift"; then
  echo "错误：首页仍调用 Liquid Glass 内容修饰器" >&2
  exit 1
fi
if grep -Fq -- "AdaptiveGlassEffectContainer" "Sources/Features/Settings/SettingsView.swift"; then
  echo "错误：设置页仍使用 Liquid Glass 容器" >&2
  exit 1
fi
require_text ".github/workflows/ci.yml" "runs-on: xcode-27"
require_absent "Sources/Features" ".background(Theme.Colors.surface"
require_absent "Sources/Features" ".background(Theme.Colors.background)"

echo "Liquid Glass 静态契约检查通过"

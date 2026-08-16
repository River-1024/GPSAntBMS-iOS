# iOS 前端标准检查

检查日期：2026-08-07

## 本次已修复

| 项目 | 现状 | 处理 |
| --- | --- | --- |
| 设置选择器 | 使用 `.navigationLink`，每次选择都推入二级页面 | 改为 `.menu`，当前值留在设置行内，点按后直接弹出选择菜单 |
| 设置数值控件触控区 | 加减按钮高度约 36pt | 输入框和加减按钮提升到至少 44pt，适配手指操作与辅助触控 |
| 设置数值字体 | 使用固定 16pt 自定义字号 | 改为系统 `body` + 等宽数字，并允许 Dynamic Type 放大 |
| 设置页信息架构 | 已使用 `Form` + grouped，但选择行为不统一 | 保留系统分组列表，统一为“分组标题 + 行内当前值 + 菜单选择” |

## 仍需后续处理

### P0：屏幕方向设置未生效

`AppSettings.screenOrientation` 可以保存和读取，但当前代码没有把它转换为
`UIWindowScene` 的 `UIInterfaceOrientationMask`。因此用户改变“屏幕方向偏好”后，
应用实际方向策略不变。应在窗口/Scene 层实现统一的方向策略，并在设置变更后刷新当前场景。

### P1：主仪表盘与行程页仍有固定字号

`Theme.Fonts.metric`、`Theme.Fonts.telemetry` 使用固定 point size。设置页已改为系统正文样式，
但仪表盘大数字和行程摘要仍需要一次 Dynamic Type 审核：优先使用 text style 或按可用宽度缩放，
同时保留等宽数字对齐。

### P1：自定义控件需要逐项做可访问性审计

当前设置数值加减按钮已有中文 accessibility label；仪表盘图表、状态指示点和部分图标按钮仍应补充
可读的 `accessibilityLabel` / `accessibilityValue`，并检查 VoiceOver 下的焦点顺序。

### P2：颜色与对比度复核

主题已使用 UIKit 语义色（`label`、`secondaryLabel`、`separator`、系统警告色），方向正确。
仍应在浅色、深色和“增加对比度”环境下做截图复核，特别是图表辅助线、低电量状态和禁用按钮。

### P2：系统容器行为

顶层使用 `TabView` + 每个 Tab 独立 `NavigationStack`，设置页使用 grouped `Form`，符合当前 SwiftUI
导航与设置页面的原生结构。后续只需在 iOS 26 SDK 真机/模拟器上复核系统 Liquid Glass 的默认采样，
不建议再叠加自定义不透明卡片背景。

## 验证边界

- Windows 工作区无法运行 Xcode、Simulator 或 VoiceOver。
- 本次已完成静态 diff 检查；完整 UI 编译、动态字体、方向掩码和无障碍验证应由 macOS CI/真机完成。

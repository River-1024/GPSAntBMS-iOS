import SwiftUI
import UIKit

/// 设计系统：使用系统语义色同时适配浅色、深色与高对比环境。
enum Theme {
    enum Colors {
        static let background = Color(uiColor: .systemGroupedBackground)
        static let surface = Color(uiColor: .secondarySystemGroupedBackground)
        static let textPrimary = Color(uiColor: .label)
        static let textSecondary = Color(uiColor: .secondaryLabel)
        static let accent = Color(uiColor: .systemGreen)
        static let warning = Color(uiColor: .systemOrange)
        static let danger = Color(uiColor: .systemRed)
        static let divider = Color(uiColor: .separator)
    }

    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let page: CGFloat = 20
    }

    enum Radius {
        static let card: CGFloat = 16
    }

    enum Fonts {
        /// 大数字指标（仪表盘主数值；等宽数字避免跳动）
        static func metric(_ size: CGFloat) -> Font {
            .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
        }

        /// 遥测数值正文（等宽数字，用于表格/卡片数值对齐）
        static func telemetry(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .rounded).monospacedDigit()
        }

        /// 页面标题/强调文字
        static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
        /// 分区标题/次要说明
        static let section = Font.system(size: 13, weight: .semibold, design: .rounded)
        /// 辅助说明文字
        static let caption = Font.system(size: 12, weight: .medium)
    }
}

extension View {
    /// 首页内容卡片使用不透明系统表面，保留边界但移除模糊、折射与阴影。
    func appFlatCard() -> some View {
        background(
            Theme.Colors.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.Colors.divider, lineWidth: 0.5)
        }
    }

    /// 首页状态胶囊使用实体表面，避免与系统 Tab 栏的玻璃材质叠加。
    func appFlatCapsule() -> some View {
        background(Theme.Colors.surface, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Theme.Colors.divider, lineWidth: 0.5)
            }
    }

    /// 首页内容区按钮使用原生 bordered 样式，不启用 Liquid Glass ButtonStyle。
    @ViewBuilder
    func appFlatButtonStyle(prominent: Bool = false) -> some View {
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// 设置页数值控件使用不透明浅色表面，保留 44pt 触控尺寸。
    func settingsFlatControlSurface() -> some View {
        background(
            Theme.Colors.surface,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.Colors.divider, lineWidth: 0.5)
        }
    }

    /// 页面级背景保持系统语义色，并覆盖安全区供导航栏与 Tab 栏采样。
    func appPageBackground() -> some View {
        background {
            Theme.Colors.background
                .ignoresSafeArea()
        }
    }

    /// 自定义卡片在 iOS 26+ 使用 Liquid Glass；旧系统使用原生材质回退。
    func appGlassCard(interactive: Bool = false) -> some View {
        appGlassSurface(
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
            interactive: interactive
        )
    }

    /// 紧凑状态与操作控件使用胶囊形 Liquid Glass。
    func appGlassCapsule(interactive: Bool = false) -> some View {
        appGlassSurface(in: Capsule(), interactive: interactive)
    }

    /// 设置页紧凑数值控件使用小圆角 Liquid Glass。
    @ViewBuilder
    func settingsControlSurface() -> some View {
        appGlassSurface(
            in: RoundedRectangle(cornerRadius: 8, style: .continuous),
            interactive: true
        )
    }

    /// iOS 26+ 使用系统 Glass ButtonStyle；旧系统回退到 bordered 系列。
    @ViewBuilder
    func appGlassButtonStyle(prominent: Bool = false) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
#else
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
#endif
    }

    @ViewBuilder
    private func appGlassSurface<S: Shape>(in shape: S, interactive: Bool) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if interactive {
                glassEffect(.regular.interactive(), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
        } else {
            legacyGlassSurface(in: shape)
        }
#else
        legacyGlassSurface(in: shape)
#endif
    }

    private func legacyGlassSurface<S: Shape>(in shape: S) -> some View {
        background(.thinMaterial, in: shape)
            .overlay {
                shape
                    .stroke(Theme.Colors.divider, lineWidth: 0.5)
            }
    }
}

/// 让相邻 Glass 元素共享采样与形变环境；旧系统保持原布局不变。
struct AdaptiveGlassEffectContainer<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = Theme.Spacing.small,
         @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
#else
        content
#endif
    }
}

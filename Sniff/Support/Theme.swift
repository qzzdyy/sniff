import SwiftUI

/// 全局视觉规范：全部使用系统语义色与系统字号，不做任何自绘风格的“设计感”。
/// 原版小工具集是纯 UIKit + 系统控件的工具类 App，界面靠系统默认外观撑起来，
/// 这里保持同样的克制：不加卡片阴影、不加渐变、不用自定义色值。
enum Theme {
    static let groupedBG = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let label = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let tertiary = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: .separator)
    static let tint = Color(uiColor: .systemBlue)
    static let icon = Color(uiColor: .label)

    /// 分组标题：系统 grouped 风格的小号灰字
    static let sectionTitle = Font.footnote.weight(.regular)
    /// 工具格子的文字
    static let tileTitle = Font.caption
    /// 工具格子的图标
    static let tileIcon = Font.system(size: 26, weight: .light)
}

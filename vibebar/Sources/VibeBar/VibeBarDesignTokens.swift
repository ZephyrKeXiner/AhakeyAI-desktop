import SwiftUI

enum VibeBarDesignTokens {
    enum Color {
        static let textPrimary = SwiftUI.Color.white
        static let textSecondary = SwiftUI.Color.white.opacity(0.64)
        static let fillSoft = SwiftUI.Color.white.opacity(0.08)
        static let accentCyan = SwiftUI.Color.cyan
        static let accentIslandBlue = SwiftUI.Color(red: 0.337, green: 0.761, blue: 1.0)
        static let accentVoice = SwiftUI.Color(red: 0.749, green: 0.353, blue: 0.949)
        static let accentSuccess = SwiftUI.Color(red: 0.188, green: 0.820, blue: 0.345)
        static let accentWarning = SwiftUI.Color(red: 1.0, green: 0.839, blue: 0.039)
        static let accentError = SwiftUI.Color(red: 1.0, green: 0.271, blue: 0.227)
    }

    enum Typography {
        static let compact = Font.system(size: 11, weight: .semibold)
        static let compactMic = Font.system(size: 11, weight: .semibold)
        static let title = Font.system(size: 16, weight: .semibold)
        static let subtitle = Font.system(size: 11, weight: .medium)
        static let tileTitle = Font.system(size: 11, weight: .semibold)
        static let tileBadge = Font.system(size: 10, weight: .medium)
        static let footnote = Font.system(size: 11)
    }

    enum Layout {
        /// 展开岛与静息刘海总宽（一致，避免收窄动画）；可在设置中调节。
        static var islandWidth: CGFloat { VibeBarIslandAppearanceSettings.islandWidth }
        static var expandedWidth: CGFloat { islandWidth }
        static let tileWidth: CGFloat = 90
        static let tileHeight: CGFloat = 64
        static let tileCornerRadius: CGFloat = 8
        static let compactHorizontalPadding: CGFloat = 0
        static let compactVerticalPadding: CGFloat = 0
        static let compactSpacing: CGFloat = 6
        static let compactAppIconSize: CGFloat = 12
        /// 顶部热区宽 = 展开岛宽；高覆盖菜单栏刘海区。
        static let topHotZoneWidth: CGFloat = islandWidth
        static let topHotZoneHeight: CGFloat = 58
        static let compactActivationWidth: CGFloat = topHotZoneWidth
    }
}

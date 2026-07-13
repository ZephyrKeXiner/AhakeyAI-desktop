import AppKit

/// 刘海与展开岛布局计算（与 DynamicNotchKit 物理刘海槽对齐）。
@MainActor
enum VibeBarNotchLayout {
    static func physicalNotchWidth(for screen: NSScreen) -> CGFloat {
        if let topLeft = screen.auxiliaryTopLeftArea?.width,
           let topRight = screen.auxiliaryTopRightArea?.width {
            return screen.frame.width - topLeft - topRight
        }
        return 300
    }

    /// 左右槽各占宽度，使 leading + 物理刘海 + trailing ≈ islandWidth。
    static func compactSideWidth(for screen: NSScreen) -> CGFloat {
        let notchWidth = physicalNotchWidth(for: screen)
        let islandWidth = VibeBarDesignTokens.Layout.islandWidth
        return max(72, (islandWidth - notchWidth) / 2)
    }

    static func refreshCompactSideWidth(on state: VibeBarState, screen: NSScreen) {
        state.compactSideWidth = compactSideWidth(for: screen)
    }
}

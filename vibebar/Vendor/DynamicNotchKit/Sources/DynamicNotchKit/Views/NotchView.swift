//
//  NotchView.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2023-08-24.
//

import SwiftUI

struct NotchView<Expanded, CompactLeading, CompactTrailing>: View where Expanded: View, CompactLeading: View, CompactTrailing: View {
    @ObservedObject private var dynamicNotch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>
    @State private var compactLeadingWidth: CGFloat = 0
    @State private var compactTrailingWidth: CGFloat = 0
    private let safeAreaInset: CGFloat = 15

    init(dynamicNotch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>) {
        self.dynamicNotch = dynamicNotch
    }

    private var expandedNotchCornerRadii: (top: CGFloat, bottom: CGFloat) {
        if case let .notch(topCornerRadius, bottomCornerRadius) = dynamicNotch.style {
            (top: topCornerRadius, bottom: bottomCornerRadius)
        } else {
            (top: 15, bottom: 20)
        }
    }

    private var compactNotchCornerRadii: (top: CGFloat, bottom: CGFloat) {
        (top: 6, bottom: 14)
    }

    private var islandShellWidth: CGFloat? {
        dynamicNotch.islandShellWidth
    }

    private var usesFixedShell: Bool {
        islandShellWidth != nil
    }

    private var shellExpansionAnimation: Animation {
        .bouncy(duration: 0.38)
    }

    private var fixedShellExpandedTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.9, anchor: .top).combined(with: .opacity),
            removal: .scale(scale: 0.94, anchor: .top).combined(with: .opacity)
        )
    }

    private var fixedShellCompactTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }

    private var minWidth: CGFloat {
        if let islandShellWidth {
            return islandShellWidth
        }
        return dynamicNotch.notchSize.width + (topCornerRadius * 2)
    }

    private var topCornerRadius: CGFloat {
        if usesFixedShell {
            return compactShellHeight / 2
        }
        return dynamicNotch.state == .expanded ? expandedNotchCornerRadii.top : compactNotchCornerRadii.top
    }

    private var bottomCornerRadius: CGFloat {
        if usesFixedShell {
            return compactShellHeight / 2
        }
        return dynamicNotch.state == .expanded ? expandedNotchCornerRadii.bottom : compactNotchCornerRadii.bottom
    }

    /// Fixed-shell compact is taller than the physical notch so status + LED strip fit.
    private var compactShellHeight: CGFloat {
        if usesFixedShell {
            return dynamicNotch.notchSize.height + 18
        }
        return dynamicNotch.notchSize.height
    }

    private var xOffset: CGFloat {
        if usesFixedShell || dynamicNotch.state != .compact {
            0
        } else {
            compactXOffset
        }
    }

    private var compactXOffset: CGFloat {
        (compactTrailingWidth - compactLeadingWidth) / 2
    }

    var body: some View {
        notchContent()
            .background {
                Rectangle()
                    .foregroundStyle(.black)
                    .padding(-50) // The opening/closing animation can overshoot, so this makes sure that it's still black
            }
            .mask {
                NotchShape(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
                .padding(.horizontal, 0.5)
                .frame(
                    width: dynamicNotch.state != .hidden ? nil : minWidth,
                    height: dynamicNotch.state != .hidden ? nil : dynamicNotch.notchSize.height
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .offset(x: xOffset)
            .animation(usesFixedShell ? shellExpansionAnimation : .smooth, value: dynamicNotch.state)
            .animation(.smooth, value: [compactLeadingWidth, compactTrailingWidth, islandShellWidth ?? 0])
    }

    private func notchContent() -> some View {
        ZStack {
            compactContent()
                .fixedSize()
                .offset(x: dynamicNotch.state == .compact ? 0 : compactXOffset)
                .frame(
                    width: dynamicNotch.state == .compact ? nil : dynamicNotch.notchSize.width,
                    height: (dynamicNotch.state == .compact && dynamicNotch.isHovering && !usesFixedShell)
                        ? dynamicNotch.menubarHeight
                        : compactShellHeight
                )

            expandedContent()
                .fixedSize()
                .frame(
                    maxWidth: dynamicNotch.state == .expanded ? nil : 0,
                    maxHeight: dynamicNotch.state == .expanded ? nil : 0
                )
                .offset(x: dynamicNotch.state == .compact ? -compactXOffset : 0)
        }
        .padding(.horizontal, topCornerRadius)
        .fixedSize()
        .frame(minWidth: minWidth, minHeight: compactShellHeight)
        .onHover { hovering in
            if !usesFixedShell {
                dynamicNotch.updateHoverState(hovering)
            }
        }
    }

    func compactContent() -> some View {
        Group {
            if usesFixedShell, dynamicNotch.state == .compact, !dynamicNotch.disableCompactLeading {
                dynamicNotch.compactLeadingContent
                    .environment(\.notchSection, .compactLeading)
                    .frame(width: islandShellWidth)
                    .transition(fixedShellCompactTransition)
            } else {
                legacyCompactContent()
            }
        }
        .frame(height: compactShellHeight)
        .onChange(of: dynamicNotch.disableCompactLeading) { _ in
            if dynamicNotch.disableCompactLeading {
                compactLeadingWidth = 0
            }
        }
        .onChange(of: dynamicNotch.disableCompactTrailing) { _ in
            if dynamicNotch.disableCompactTrailing {
                compactTrailingWidth = 0
            }
        }
    }

    private func legacyCompactContent() -> some View {
        HStack(spacing: 0) {
            if dynamicNotch.state == .compact, !dynamicNotch.disableCompactLeading {
                dynamicNotch.compactLeadingContent
                    .environment(\.notchSection, .compactLeading)
                    .safeAreaInset(edge: .leading, spacing: 0) { Color.clear.frame(width: 8) }
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 4) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { compactLeadingWidth = $0 }
                    .transition(.blur(intensity: 10).combined(with: .scale(x: 0, anchor: .trailing)).combined(with: .opacity))
            }

            Spacer()
                .frame(width: dynamicNotch.notchSize.width)

            if dynamicNotch.state == .compact, !dynamicNotch.disableCompactTrailing {
                dynamicNotch.compactTrailingContent
                    .environment(\.notchSection, .compactTrailing)
                    .safeAreaInset(edge: .trailing, spacing: 0) { Color.clear.frame(width: 8) }
                    .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 4) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { compactTrailingWidth = $0 }
                    .transition(.blur(intensity: 10).combined(with: .scale(x: 0, anchor: .leading)).combined(with: .opacity))
            }
        }
    }

    func expandedContent() -> some View {
        HStack(spacing: 0) {
            if dynamicNotch.state == .expanded {
                dynamicNotch.expandedContent
                    .transition(usesFixedShell ? fixedShellExpandedTransition : .blur(intensity: 10).combined(with: .scale(y: 0.6, anchor: .top)).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: usesFixedShell ? max(8, dynamicNotch.notchSize.height * 0.35) : dynamicNotch.notchSize.height)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: usesFixedShell ? 6 : safeAreaInset)
        }
        .safeAreaInset(edge: .leading, spacing: 0) {
            Color.clear.frame(width: usesFixedShell ? 4 : safeAreaInset)
        }
        .safeAreaInset(edge: .trailing, spacing: 0) {
            Color.clear.frame(width: usesFixedShell ? 4 : safeAreaInset)
        }
        .frame(minWidth: islandShellWidth ?? dynamicNotch.notchSize.width)
    }
}

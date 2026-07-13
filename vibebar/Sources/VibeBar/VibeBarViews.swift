import SwiftUI

/// 实岛静息态：与设置预览一致的统一胶囊布局。
struct VibeBarCompactIslandCapsule: View {
    @ObservedObject var state: VibeBarState
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        VibeBarCompactNotchPreviewCapsule(
            model: VibeBarCompactNotchModel(state: state),
            width: state.islandWidth,
            agentStatus: state.agentStatus,
            showsOuterCapsule: false
        )
        .contentShape(Capsule(style: .continuous))
        .onHover(perform: onHoverChanged)
    }
}

struct VibeBarCompactStatusItem: View {
    @ObservedObject var state: VibeBarState
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        VibeBarCompactIslandCapsule(state: state, onHoverChanged: onHoverChanged)
    }
}

struct VibeBarCompactVoiceItem: View {
    @ObservedObject var state: VibeBarState
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        EmptyView()
    }
}

struct VibeBarExpandedMenu: View {
    @ObservedObject var state: VibeBarState
    let onAppear: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onCompact: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(VibeBarDesignTokens.Color.accentCyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VibeBar")
                        .font(VibeBarDesignTokens.Typography.title)
                    Text(subtitle)
                        .font(VibeBarDesignTokens.Typography.subtitle)
                        .foregroundStyle(VibeBarDesignTokens.Color.textSecondary)
                }
                Spacer()
                Button(action: onCompact) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                capabilityTile(
                    title: "VoiceAgent",
                    systemName: "waveform",
                    badge: "Ready",
                    tint: VibeBarDesignTokens.Color.accentVoice,
                    action: { state.onOpenVoiceAgent?() }
                )
                capabilityTile(
                    title: "Device",
                    systemName: state.keyboardConnected ? "battery.75percent" : "keyboard",
                    badge: deviceBadge,
                    tint: state.keyboardConnected ? VibeBarDesignTokens.Color.accentCyan : .secondary,
                    action: { state.onOpenDevice?() }
                )
                capabilityTile(
                    title: "Approve",
                    systemName: approveIcon,
                    badge: approveBadge,
                    tint: approveTint,
                    action: { state.onOpenApprove?() }
                )
                capabilityTile(
                    title: "OLED",
                    systemName: "rectangle.inset.filled",
                    badge: "Ready",
                    tint: .indigo,
                    action: { state.onOpenOLED?() }
                )
            }

            HStack(spacing: 8) {
                Spacer()
                Text("Move cursor away to collapse")
                    .font(VibeBarDesignTokens.Typography.footnote)
                    .foregroundStyle(VibeBarDesignTokens.Color.textSecondary)
            }
        }
        .frame(width: state.islandWidth)
        .foregroundStyle(VibeBarDesignTokens.Color.textPrimary)
        .contentShape(Rectangle())
        .onAppear(perform: onAppear)
        .onHover(perform: onHoverChanged)
    }

    private var subtitle: String {
        if let name = state.deviceName, state.keyboardConnected {
            return name
        }
        return state.keyboardConnected ? "Connected" : "Disconnected"
    }

    private var deviceBadge: String {
        state.keyboardConnected ? "\(state.batteryLevel)%" : "Off"
    }

    private var approveIcon: String {
        guard state.leverKnown else { return "questionmark.circle" }
        return state.leverIsAuto ? "checkmark.circle" : "hand.raised"
    }

    private var approveBadge: String {
        guard state.leverKnown else { return "Unknown" }
        return state.leverIsAuto ? "Auto" : "Ask"
    }

    private var approveTint: Color {
        guard state.leverKnown else { return .secondary }
        return state.leverIsAuto ? VibeBarDesignTokens.Color.accentSuccess : VibeBarDesignTokens.Color.accentWarning
    }

    private func capabilityTile(
        title: String,
        systemName: String,
        badge: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(VibeBarDesignTokens.Typography.tileTitle)
                    .foregroundStyle(VibeBarDesignTokens.Color.textPrimary)
                Text(badge)
                    .font(VibeBarDesignTokens.Typography.tileBadge)
                    .foregroundStyle(VibeBarDesignTokens.Color.textSecondary)
            }
            .frame(width: VibeBarDesignTokens.Layout.tileWidth, height: VibeBarDesignTokens.Layout.tileHeight)
        }
        .buttonStyle(.borderless)
        .background(
            VibeBarDesignTokens.Color.fillSoft,
            in: RoundedRectangle(cornerRadius: VibeBarDesignTokens.Layout.tileCornerRadius, style: .continuous)
        )
    }
}

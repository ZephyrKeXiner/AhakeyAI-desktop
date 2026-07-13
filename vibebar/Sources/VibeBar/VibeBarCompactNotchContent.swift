import SwiftUI

/// 预览与实际灵动岛共用的常驻岛紧凑内容模型。
public struct VibeBarCompactNotchModel: Equatable {
    public var restingStateKind: VibeBarRestingStateKind
    public var rightSlot: VibeBarRightSlotDisplay
    public var leftSlot: VibeBarLeftSlotDisplay
    public var sessionCount: Int
    public var statusPrimary: String
    public var statusSecondary: String
    public var showsPauseIndicator: Bool
    public var voiceRecording: Bool
    public var voiceListening: Bool
    public var keyboardConnected: Bool
    public var batteryLevel: Int
    public var leverKnown: Bool
    public var leverIsAuto: Bool
    public var agentStatus: VibeBarAgentStatus
    public var lightStripEnabled: Bool
    public var deviceName: String?

    public init(
        restingStateKind: VibeBarRestingStateKind,
        rightSlot: VibeBarRightSlotDisplay,
        leftSlot: VibeBarLeftSlotDisplay = .statusLine,
        sessionCount: Int,
        statusPrimary: String,
        statusSecondary: String,
        showsPauseIndicator: Bool,
        voiceRecording: Bool,
        voiceListening: Bool,
        keyboardConnected: Bool,
        batteryLevel: Int = 0,
        leverKnown: Bool = false,
        leverIsAuto: Bool = false,
        agentStatus: VibeBarAgentStatus = .idle,
        lightStripEnabled: Bool = true,
        deviceName: String? = nil
    ) {
        self.restingStateKind = restingStateKind
        self.rightSlot = rightSlot
        self.leftSlot = leftSlot
        self.sessionCount = sessionCount
        self.statusPrimary = statusPrimary
        self.statusSecondary = statusSecondary
        self.showsPauseIndicator = showsPauseIndicator
        self.voiceRecording = voiceRecording
        self.voiceListening = voiceListening
        self.keyboardConnected = keyboardConnected
        self.batteryLevel = batteryLevel
        self.leverKnown = leverKnown
        self.leverIsAuto = leverIsAuto
        self.agentStatus = agentStatus
        self.lightStripEnabled = lightStripEnabled
        self.deviceName = deviceName
    }

    @MainActor
    public init(state: VibeBarState) {
        self.init(
            restingStateKind: state.compactRestingStateKind,
            rightSlot: state.compactRightSlot,
            leftSlot: state.compactLeftSlot,
            sessionCount: state.compactSessionCount,
            statusPrimary: state.compactStatusPrimary,
            statusSecondary: state.compactStatusSecondary,
            showsPauseIndicator: state.compactShowsPauseIndicator,
            voiceRecording: state.voiceRecording,
            voiceListening: state.voiceListening,
            keyboardConnected: state.keyboardConnected,
            batteryLevel: state.batteryLevel,
            leverKnown: state.leverKnown,
            leverIsAuto: state.leverIsAuto,
            agentStatus: state.agentStatus,
            lightStripEnabled: state.compactLightStripEnabled,
            deviceName: state.deviceName
        )
    }

    public var statusLine: String {
        "\(statusPrimary) · \(statusSecondary)"
    }
}

/// 常驻岛左侧：图标簇 + 可配置左槽内容。
public struct VibeBarCompactLeadingNotchContent: View {
    let model: VibeBarCompactNotchModel
    @ObservedObject private var focusTimer = VibeBarFocusTimerStore.shared

    public init(model: VibeBarCompactNotchModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: VibeBarDesignTokens.Layout.compactSpacing) {
            leadingCluster
            leftSlotContent
        }
    }

    @ViewBuilder
    private var leftSlotContent: some View {
        switch model.leftSlot {
        case .statusLine:
            statusLine
        case .deviceName:
            Text(model.deviceName ?? (model.keyboardConnected ? "AhaKey" : "Offline"))
                .font(VibeBarDesignTokens.Typography.compact)
                .fontWeight(.semibold)
                .foregroundStyle(VibeBarDesignTokens.Color.textPrimary)
                .lineLimit(1)
        case .battery:
            HStack(spacing: 3) {
                Image(systemName: model.keyboardConnected ? "battery.75percent" : "battery.0percent")
                    .font(.system(size: 10, weight: .semibold))
                Text(model.keyboardConnected ? "\(model.batteryLevel)%" : "—")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .foregroundStyle(VibeBarDesignTokens.Color.textPrimary.opacity(0.9))
        case .agentStatus:
            Text(model.agentStatus.compactLabel)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(model.agentStatus.lightPrimary.opacity(0.95))
        case .clock:
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(Self.clockFormatter.string(from: context.date))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(VibeBarDesignTokens.Color.textPrimary.opacity(0.9))
                    .monospacedDigit()
            }
        case .focusTimer:
            Text(focusTimer.displayText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(
                    focusTimer.isRunning
                        ? Color(red: 1.0, green: 0.72, blue: 0.28)
                        : VibeBarDesignTokens.Color.textPrimary.opacity(0.9)
                )
                .monospacedDigit()
        case .hidden:
            EmptyView()
        }
    }

    private var statusLine: some View {
        HStack(spacing: 0) {
            Text(model.statusPrimary)
                .fontWeight(.semibold)
            Text(" · \(model.statusSecondary)")
                .fontWeight(.medium)
                .foregroundStyle(VibeBarDesignTokens.Color.textPrimary.opacity(0.92))
        }
        .font(VibeBarDesignTokens.Typography.compact)
        .foregroundStyle(VibeBarDesignTokens.Color.textPrimary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var leadingCluster: some View {
        switch model.restingStateKind {
        case .auto:
            HStack(spacing: 5) {
                appIconSquare
                if model.showsPauseIndicator {
                    pauseIcon
                }
            }
        case .space:
            Image(systemName: "square.dashed")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VibeBarDesignTokens.Color.textPrimary.opacity(0.55))
        case .running:
            HStack(spacing: 5) {
                appIconSquare
                pauseIcon
            }
        case .waiting:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.65)
        }
    }

    private var appIconSquare: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(VibeBarDesignTokens.Color.accentIslandBlue)
            .frame(
                width: VibeBarDesignTokens.Layout.compactAppIconSize,
                height: VibeBarDesignTokens.Layout.compactAppIconSize
            )
    }

    private var pauseIcon: some View {
        Image(systemName: "pause.fill")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(VibeBarDesignTokens.Color.textPrimary.opacity(0.95))
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// 常驻岛右侧：右槽内容 + 话筒（话筒始终保留）。
public struct VibeBarCompactTrailingNotchContent: View {
    let model: VibeBarCompactNotchModel
    @ObservedObject private var focusTimer = VibeBarFocusTimerStore.shared

    public init(model: VibeBarCompactNotchModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 6) {
            rightSlotContent
            micIcon
        }
    }

    @ViewBuilder
    private var rightSlotContent: some View {
        switch model.rightSlot {
        case .sessionCount:
            Text("x\(model.sessionCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(VibeBarDesignTokens.Color.textPrimary.opacity(0.9))
        case .agent:
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color(red: 1.0, green: 0.55, blue: 0.18))
                        .frame(width: 7, height: 7)
                }
            }
        case .focusTimer:
            Text(focusTimer.displayText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(
                    focusTimer.isRunning
                        ? Color(red: 1.0, green: 0.72, blue: 0.28)
                        : VibeBarDesignTokens.Color.textPrimary.opacity(0.9)
                )
                .monospacedDigit()
        case .battery:
            HStack(spacing: 3) {
                Image(systemName: model.keyboardConnected ? "battery.75percent" : "battery.0percent")
                    .font(.system(size: 10, weight: .semibold))
                Text(model.keyboardConnected ? "\(model.batteryLevel)%" : "—")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .foregroundStyle(VibeBarDesignTokens.Color.textPrimary.opacity(0.9))
        case .lever:
            Text(model.leverKnown ? (model.leverIsAuto ? "Auto" : "Ask") : "—")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(VibeBarDesignTokens.Color.textPrimary.opacity(0.9))
        case .clock:
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(Self.clockFormatter.string(from: context.date))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(VibeBarDesignTokens.Color.textPrimary.opacity(0.9))
                    .monospacedDigit()
            }
        case .agentStatus:
            Text(model.agentStatus.compactLabel)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(model.agentStatus.lightPrimary.opacity(0.95))
        case .hidden:
            EmptyView()
        }
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var micIcon: some View {
        Image(systemName: micSymbolName)
            .font(VibeBarDesignTokens.Typography.compactMic)
            .foregroundStyle(micColor)
            .frame(width: 14, height: 14)
    }

    private var micSymbolName: String {
        if model.voiceRecording || model.voiceListening { return "mic.fill" }
        return "mic"
    }

    private var micColor: Color {
        if model.voiceRecording { return VibeBarDesignTokens.Color.accentError }
        if model.voiceListening { return VibeBarDesignTokens.Color.accentSuccess }
        return VibeBarDesignTokens.Color.textPrimary.opacity(0.88)
    }
}

/// 设置页「常驻岛预览」胶囊（与实际灵动岛同一套渲染）。
public struct VibeBarCompactNotchPreviewCapsule: View {
    let model: VibeBarCompactNotchModel
    var width: CGFloat = VibeBarIslandAppearanceSettings.islandWidth
    var agentStatus: VibeBarAgentStatus = .idle
    /// 实岛由 NotchShape 提供黑壳；设置预览需要自绘胶囊。
    var showsOuterCapsule: Bool = true

    public init(
        model: VibeBarCompactNotchModel,
        width: CGFloat = VibeBarIslandAppearanceSettings.islandWidth,
        agentStatus: VibeBarAgentStatus = .idle,
        showsOuterCapsule: Bool = true
    ) {
        self.model = model
        self.width = width
        self.agentStatus = agentStatus
        self.showsOuterCapsule = showsOuterCapsule
    }

    public var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                VibeBarCompactLeadingNotchContent(model: model)
                Spacer(minLength: 8)
                VibeBarCompactTrailingNotchContent(model: model)
            }

            if model.lightStripEnabled {
                VibeBarAgentLightStrip(
                    status: agentStatus,
                    ledCount: 32,
                    height: 7,
                    showsRecess: false
                )
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 5)
        .padding(.bottom, 6)
        .frame(width: width)
        .background {
            if showsOuterCapsule {
                Capsule(style: .continuous)
                    .fill(Color.black)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(agentStatus.lightPrimary.opacity(0.28), lineWidth: 1)
                    )
            }
        }
    }
}

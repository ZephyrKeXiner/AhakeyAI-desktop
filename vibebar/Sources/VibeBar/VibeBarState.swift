import Foundation
import SwiftUI

@MainActor
public final class VibeBarState: ObservableObject {
    @Published public var keyboardConnected: Bool = false
    @Published public var batteryLevel: Int = 0
    @Published public var deviceName: String? = nil

    /// `true` 表示拨杆在 auto 位（switchState == 0），AI 工具调用自动放行
    @Published public var leverIsAuto: Bool = false
    /// 是否已经读取到拨杆状态。读不到时默认 ask（fail-safe）
    @Published public var leverKnown: Bool = false

    @Published public var voiceListening: Bool = false
    @Published public var voiceRecording: Bool = false

    /// 静息态左侧状态文案（如 Claude · editing）。
    @Published public var compactStatusPrimary: String = "Claude"
    @Published public var compactStatusSecondary: String = "editing"
    @Published public var compactShowsPauseIndicator: Bool = true
    @Published public var compactRestingStateKind: VibeBarRestingStateKind = .auto
    @Published public var compactRightSlot: VibeBarRightSlotDisplay = .hidden
    @Published public var compactLeftSlot: VibeBarLeftSlotDisplay = .statusLine
    @Published public var compactLightStripEnabled: Bool = true
    @Published public var compactSessionCount: Int = 3
    /// Compact 左右槽宽度（与展开岛总宽对齐）。
    @Published public var compactSideWidth: CGFloat = 135
    /// 灵动岛壳层宽度（与设置同步）。
    @Published public var islandWidth: CGFloat = VibeBarIslandAppearanceSettings.islandWidth
    /// 展开岛已启用模块（有序）。
    @Published public var enabledExpandedModules: [VibeBarExpandedModule] = VibeBarExpandedModule.defaultEnabledOrder

    /// Agent Command Center 运行态。
    @Published public var agentStatus: VibeBarAgentStatus = .idle
    @Published public var agentTaskTitle: String = ""
    @Published public var agentProgress: Double = 0
    @Published public var agentRunning: Bool = false
    /// 来自 IDE hook 的原始态（0–8），nil 表示无有效实时态。
    @Published public var liveIDEStateValue: Int? = nil

    /// 主 app 注入的回调：用户在灵动岛展开菜单里点 "打开主窗口" 时调用
    public var onOpenMainWindow: (() -> Void)?
    public var onOpenVoiceAgent: (() -> Void)?
    public var onOpenDevice: (() -> Void)?
    public var onOpenApprove: (() -> Void)?
    public var onOpenOLED: (() -> Void)?
    public var onOpenVoice: (() -> Void)?
    public var onKeyRecord: (() -> Void)?
    public var onKeyApprove: (() -> Void)?
    public var onKeyReject: (() -> Void)?
    public var onKeySwitch: (() -> Void)?

    /// 由 VibeBarController 注入：展开面板 hover / 收起。
    public var onIslandHoverChanged: ((Bool) -> Void)?
    public var onIslandCompact: (() -> Void)?
    public var onIslandAppear: (() -> Void)?
    /// 主 app 注入：灵动岛展开/收起时播放提示音（由 app 层判断是否静音）。
    public var onIslandInteractionSound: (() -> Void)?

    public init() {}
}

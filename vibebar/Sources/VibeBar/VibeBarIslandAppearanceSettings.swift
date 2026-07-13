import Foundation

/// 灵动岛收起态右槽显示内容。
public enum VibeBarRightSlotDisplay: String, CaseIterable, Identifiable, Codable, Sendable {
    case sessionCount
    case agent
    case focusTimer
    case battery
    case lever
    case clock
    case agentStatus
    case hidden

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sessionCount: "会话数"
        case .agent: "代理"
        case .focusTimer: "专注"
        case .battery: "电量"
        case .lever: "拨杆"
        case .clock: "时钟"
        case .agentStatus: "状态"
        case .hidden: "不显示"
        }
    }
}

/// 刘海 / 静息态配置种类。
public enum VibeBarRestingStateKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case space
    case running
    case waiting

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "自动"
        case .space: "空间"
        case .running: "运行"
        case .waiting: "等待"
        }
    }

    public var configPageTitle: String {
        "常驻岛配置"
    }
}

/// 灵动岛刘海外观持久化与运行时同步。
public enum VibeBarIslandAppearanceSettings {
    public static let previewSessionCountKey = "vibebar.island.previewSessionCount"
    public static let hoverExpandKey = "vibebar.island.hoverExpandEnabled"
    public static let hoverExpandDelayMsKey = "vibebar.island.hoverExpandDelayMs"
    public static let islandWidthKey = "vibebar.island.islandWidth"
    public static let autoCollapseOnLeaveKey = "vibebar.island.autoCollapseOnLeave"
    public static let hapticFeedbackKey = "vibebar.island.hapticFeedbackEnabled"
    public static let preferredDisplayKey = "vibebar.island.preferredDisplay"
    public static let languageModeKey = "vibebar.island.languageMode"
    public static let suppressForegroundNotificationsKey = "vibebar.island.suppressForegroundNotifications"
    public static let replyInCompletionCardKey = "vibebar.island.replyInCompletionCard"
    public static let enabledRightSlotComponentsKey = "vibebar.island.enabledRightSlotComponents"
    public static let compactLightStripEnabledKey = "vibebar.island.compactLightStripEnabled"
    public static let enabledExpandedModulesKey = "vibebar.island.enabledExpandedModules"
    private static let leftSlotKeyPrefix = "vibebar.island.leftSlot."

    public enum PreferredDisplay: String, CaseIterable, Identifiable, Sendable {
        case auto
        case main
        case mouse

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .auto: "自动"
            case .main: "主显示器"
            case .mouse: "鼠标所在屏"
            }
        }
    }

    public enum LanguageMode: String, CaseIterable, Identifiable, Sendable {
        case system
        case simplifiedChinese
        case english

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .system: "跟随系统"
            case .simplifiedChinese: "简体中文"
            case .english: "English"
            }
        }
    }

    /// 灵动岛静息/展开统一宽度（pt），可调范围 200…450。
    public static let islandWidthMin: CGFloat = 200
    public static let islandWidthMax: CGFloat = 450
    public static let islandWidthDefault: CGFloat = 450

    public static var islandWidth: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: islandWidthKey)
            if stored <= 0 { return islandWidthDefault }
            return min(islandWidthMax, max(islandWidthMin, CGFloat(stored)))
        }
        set {
            let clamped = min(islandWidthMax, max(islandWidthMin, newValue))
            UserDefaults.standard.set(Double(clamped), forKey: islandWidthKey)
            notifyAppearanceDidChange()
        }
    }

    public static var hoverExpandEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: hoverExpandKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: hoverExpandKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hoverExpandKey)
            notifyAppearanceDidChange()
        }
    }

    /// 悬停多久后展开（毫秒），默认 100（0.1s）。
    public static var hoverExpandDelayMs: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: hoverExpandDelayMsKey)
            if stored <= 0 { return 100 }
            // 旧默认 1000 → 迁移到 0.1s
            if stored == 1000 { return 100 }
            return stored
        }
        set {
            UserDefaults.standard.set(max(100, newValue), forKey: hoverExpandDelayMsKey)
            notifyAppearanceDidChange()
        }
    }

    /// 鼠标离开展开岛后自动收起，默认开启。
    public static var autoCollapseOnLeave: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoCollapseOnLeaveKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: autoCollapseOnLeaveKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoCollapseOnLeaveKey)
            notifyAppearanceDidChange()
        }
    }

    /// 悬停展开时震动反馈，默认开启。
    public static var hapticFeedbackEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: hapticFeedbackKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: hapticFeedbackKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hapticFeedbackKey)
            notifyAppearanceDidChange()
        }
    }

    public static var preferredDisplay: PreferredDisplay {
        get {
            guard let raw = UserDefaults.standard.string(forKey: preferredDisplayKey),
                  let value = PreferredDisplay(rawValue: raw) else {
                return .auto
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: preferredDisplayKey)
            notifyAppearanceDidChange()
        }
    }

    public static var languageMode: LanguageMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: languageModeKey),
                  let value = LanguageMode(rawValue: raw) else {
                return .system
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: languageModeKey)
            notifyAppearanceDidChange()
        }
    }

    public static var suppressForegroundNotifications: Bool {
        get {
            if UserDefaults.standard.object(forKey: suppressForegroundNotificationsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: suppressForegroundNotificationsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: suppressForegroundNotificationsKey)
            notifyAppearanceDidChange()
        }
    }

    public static var replyInCompletionCard: Bool {
        get {
            if UserDefaults.standard.object(forKey: replyInCompletionCardKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: replyInCompletionCardKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: replyInCompletionCardKey)
            notifyAppearanceDidChange()
        }
    }
    public static let editingStateKindKey = "vibebar.island.editingStateKind"
    private static let rightSlotKeyPrefix = "vibebar.island.rightSlot."

    public static var editingStateKind: VibeBarRestingStateKind {
        get {
            guard let raw = UserDefaults.standard.string(forKey: editingStateKindKey),
                  let kind = VibeBarRestingStateKind(rawValue: raw) else {
                return .auto
            }
            return kind
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: editingStateKindKey)
            notifyAppearanceDidChange()
        }
    }

    public static func rightSlot(for state: VibeBarRestingStateKind) -> VibeBarRightSlotDisplay {
        let key = rightSlotKeyPrefix + state.rawValue
        guard let raw = UserDefaults.standard.string(forKey: key),
              let value = VibeBarRightSlotDisplay(rawValue: raw) else {
            return state == .running ? .sessionCount : .hidden
        }
        return value
    }

    public static func setRightSlot(_ display: VibeBarRightSlotDisplay, for state: VibeBarRestingStateKind) {
        UserDefaults.standard.set(display.rawValue, forKey: rightSlotKeyPrefix + state.rawValue)
        notifyAppearanceDidChange()
    }

    public static func leftSlot(for state: VibeBarRestingStateKind) -> VibeBarLeftSlotDisplay {
        let key = leftSlotKeyPrefix + state.rawValue
        guard let raw = UserDefaults.standard.string(forKey: key),
              let value = VibeBarLeftSlotDisplay(rawValue: raw) else {
            return .statusLine
        }
        return value
    }

    public static func setLeftSlot(_ display: VibeBarLeftSlotDisplay, for state: VibeBarRestingStateKind) {
        UserDefaults.standard.set(display.rawValue, forKey: leftSlotKeyPrefix + state.rawValue)
        notifyAppearanceDidChange()
    }

    /// 常驻岛底部 Agent 灯条是否显示。
    public static var compactLightStripEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: compactLightStripEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: compactLightStripEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: compactLightStripEnabledKey)
            notifyAppearanceDidChange()
        }
    }

    // MARK: - Expanded island module inventory（组件库）

    /// 有序已启用展开岛模块；至少保留 OLED。
    public static var enabledExpandedModules: [VibeBarExpandedModule] {
        get {
            guard let raw = UserDefaults.standard.array(forKey: enabledExpandedModulesKey) as? [String] else {
                return VibeBarExpandedModule.defaultEnabledOrder
            }
            let parsed = raw.compactMap(VibeBarExpandedModule.init(rawValue:))
            if parsed.isEmpty { return VibeBarExpandedModule.defaultEnabledOrder }
            var seen = Set<VibeBarExpandedModule>()
            var result = parsed.filter { seen.insert($0).inserted }
            if !result.contains(.oledPet) {
                result.insert(.oledPet, at: min(result.count, 2))
            }
            return result
        }
        set {
            var seen = Set<VibeBarExpandedModule>()
            var finalList = newValue.filter { seen.insert($0).inserted }
            if !finalList.contains(.oledPet) {
                finalList.insert(.oledPet, at: min(finalList.count, 2))
            }
            if finalList.isEmpty {
                finalList = [.oledPet]
            }
            UserDefaults.standard.set(finalList.map(\.rawValue), forKey: enabledExpandedModulesKey)
            notifyAppearanceDidChange()
        }
    }

    public static var disabledExpandedModules: [VibeBarExpandedModule] {
        VibeBarExpandedModule.allCases.filter { !enabledExpandedModules.contains($0) }
    }

    public static func isExpandedModuleEnabled(_ module: VibeBarExpandedModule) -> Bool {
        enabledExpandedModules.contains(module)
    }

    @discardableResult
    public static func setExpandedModuleEnabled(_ module: VibeBarExpandedModule, enabled: Bool) -> String? {
        var list = enabledExpandedModules
        if enabled {
            if !list.contains(module) {
                // 按默认机身顺序插入
                let order = VibeBarExpandedModule.defaultEnabledOrder
                if let ideal = order.firstIndex(of: module) {
                    let insertAt = list.firstIndex { order.firstIndex(of: $0).map { $0 > ideal } ?? true } ?? list.count
                    list.insert(module, at: insertAt)
                } else {
                    list.append(module)
                }
            }
            enabledExpandedModules = list
            return nil
        }
        if module == .oledPet {
            return "OLED Pet 为展开岛核心，不可关闭"
        }
        guard list.count > 1 else {
            return "至少保留一个展开岛模块"
        }
        list.removeAll { $0 == module }
        enabledExpandedModules = list
        return nil
    }

    public static func moveEnabledExpandedModules(from offsets: IndexSet, to offset: Int) {
        var list = enabledExpandedModules
        list.move(fromOffsets: offsets, toOffset: offset)
        enabledExpandedModules = list
    }

    public static var previewSessionCount: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: previewSessionCountKey)
            return value > 0 ? value : 3
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: previewSessionCountKey)
            notifyAppearanceDidChange()
        }
    }

    /// 根据运行时信号决定当前应使用哪套刘海配置。
    public static func liveRestingStateKind(agentRunning: Bool, voiceRecording: Bool) -> VibeBarRestingStateKind {
        if voiceRecording { return .running }
        if agentRunning { return .running }
        return .auto
    }

    @MainActor
    public static func sync(
        to state: VibeBarState,
        agentRunning: Bool,
        modePrimary: String,
        connected: Bool
    ) {
        let liveKind = liveRestingStateKind(agentRunning: agentRunning, voiceRecording: state.voiceRecording)
        let rightSlot = rightSlot(for: liveKind)
        let leftSlot = leftSlot(for: liveKind)
        let sessionCount = previewSessionCount

        state.compactRestingStateKind = liveKind
        state.compactRightSlot = rightSlot
        state.compactLeftSlot = leftSlot
        state.compactLightStripEnabled = compactLightStripEnabled
        state.compactSessionCount = sessionCount
        state.islandWidth = islandWidth
        state.enabledExpandedModules = enabledExpandedModules

        switch liveKind {
        case .auto:
            if agentRunning {
                state.compactStatusPrimary = modePrimary
                state.compactStatusSecondary = "editing"
                state.compactShowsPauseIndicator = true
            } else if connected {
                state.compactStatusPrimary = "VibeBar"
                state.compactStatusSecondary = modePrimary.lowercased()
                state.compactShowsPauseIndicator = false
            } else {
                state.compactStatusPrimary = "VibeBar"
                state.compactStatusSecondary = "idle"
                state.compactShowsPauseIndicator = false
            }
        case .space:
            state.compactStatusPrimary = "Space"
            state.compactStatusSecondary = "idle"
            state.compactShowsPauseIndicator = false
        case .running:
            state.compactStatusPrimary = modePrimary
            state.compactStatusSecondary = "editing"
            state.compactShowsPauseIndicator = true
        case .waiting:
            state.compactStatusPrimary = "VibeBar"
            state.compactStatusSecondary = "waiting"
            state.compactShowsPauseIndicator = false
        }
    }

    @MainActor
    public static func previewModel(
        for kind: VibeBarRestingStateKind,
        rightSlot: VibeBarRightSlotDisplay,
        leftSlot: VibeBarLeftSlotDisplay? = nil,
        sessionCount: Int,
        deviceState: VibeBarState,
        lightStripEnabled: Bool? = nil
    ) -> VibeBarCompactNotchModel {
        let (primary, secondary, pause): (String, String, Bool) = {
            switch kind {
            case .auto:
                if deviceState.compactRestingStateKind == .auto || deviceState.compactRestingStateKind == .running {
                    return (deviceState.compactStatusPrimary, deviceState.compactStatusSecondary, deviceState.compactShowsPauseIndicator)
                }
                return ("VibeBar", deviceState.keyboardConnected ? "idle" : "idle", false)
            case .space:
                return ("Space", "idle", false)
            case .running:
                return (deviceState.compactStatusPrimary.isEmpty ? "Claude" : deviceState.compactStatusPrimary, "editing", true)
            case .waiting:
                return ("VibeBar", "waiting", false)
            }
        }()

        return VibeBarCompactNotchModel(
            restingStateKind: kind,
            rightSlot: rightSlot,
            leftSlot: leftSlot ?? Self.leftSlot(for: kind),
            sessionCount: sessionCount,
            statusPrimary: primary,
            statusSecondary: secondary,
            showsPauseIndicator: pause,
            voiceRecording: deviceState.voiceRecording,
            voiceListening: deviceState.voiceListening,
            keyboardConnected: deviceState.keyboardConnected,
            batteryLevel: deviceState.batteryLevel,
            leverKnown: deviceState.leverKnown,
            leverIsAuto: deviceState.leverIsAuto,
            agentStatus: deviceState.agentStatus,
            lightStripEnabled: lightStripEnabled ?? compactLightStripEnabled,
            deviceName: deviceState.deviceName
        )
    }

    public static let appearanceDidChangeNotification = Notification.Name("vibebar.island.appearanceDidChange")

    private static func notifyAppearanceDidChange() {
        NotificationCenter.default.post(name: appearanceDidChangeNotification, object: nil)
    }
}

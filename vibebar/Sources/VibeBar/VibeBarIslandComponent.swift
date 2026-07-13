import Foundation

/// 常驻岛（静息态）左槽显示内容。
public enum VibeBarLeftSlotDisplay: String, CaseIterable, Identifiable, Codable, Sendable {
    case statusLine
    case deviceName
    case battery
    case agentStatus
    case clock
    case focusTimer
    case hidden

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .statusLine: "状态文案"
        case .deviceName: "设备名"
        case .battery: "电量"
        case .agentStatus: "Agent"
        case .clock: "时钟"
        case .focusTimer: "专注"
        case .hidden: "仅图标"
        }
    }
}

/// 展开岛可配置模块（组件库对象）。
public enum VibeBarExpandedModule: String, CaseIterable, Identifiable, Codable, Sendable {
    case lightStrip
    case focusChip
    case oledPet
    case keyPad
    case magneticBase

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lightStrip: "Agent 灯带"
        case .focusChip: "专注计时"
        case .oledPet: "OLED Pet"
        case .keyPad: "四键键帽"
        case .magneticBase: "磁吸底座"
        }
    }

    public var detail: String {
        switch self {
        case .lightStrip: "展开岛顶部状态灯效"
        case .focusChip: "顶栏番茄钟启停芯片"
        case .oledPet: "中央屏幕槽与任务文案"
        case .keyPad: "Voice / Approve / Reject / Submit"
        case .magneticBase: "连接、电量与拨杆状态条"
        }
    }

    public var systemImage: String {
        switch self {
        case .lightStrip: "light.max"
        case .focusChip: "timer"
        case .oledPet: "rectangle.inset.filled"
        case .keyPad: "keyboard"
        case .magneticBase: "dock.rectangle"
        }
    }

    /// 默认全部启用、按机身自上而下顺序。
    public static var defaultEnabledOrder: [VibeBarExpandedModule] {
        [.lightStrip, .focusChip, .oledPet, .keyPad, .magneticBase]
    }
}

/// 兼容旧名：组件库现指向展开岛模块。
public typealias VibeBarIslandComponent = VibeBarExpandedModule

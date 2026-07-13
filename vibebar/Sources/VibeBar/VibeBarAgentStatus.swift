import SwiftUI

/// VibeBar Agent Command Center 运行态（硬件灯带 / OLED Pet 共用）。
public enum VibeBarAgentStatus: String, CaseIterable, Identifiable, Sendable {
    case idle
    case listening
    case thinking
    case searching
    case coding
    case approval
    case completed
    case error

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .idle: "Waiting"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .searching: "Searching"
        case .coding: "Coding"
        case .approval: "Need approval"
        case .completed: "Completed"
        case .error: "Error"
        }
    }

    /// 刘海右槽短标签。
    public var compactLabel: String {
        switch self {
        case .idle: "Idle"
        case .listening: "Listen"
        case .thinking: "Think"
        case .searching: "Search"
        case .coding: "Code"
        case .approval: "Approve"
        case .completed: "Done"
        case .error: "Error"
        }
    }

    public var petEmoji: String {
        switch self {
        case .idle: "🐱"
        case .listening: "🐱👂"
        case .thinking: "🐱💭"
        case .searching: "🐱🔍"
        case .coding: "🐱⌨️"
        case .approval: "🐱❗"
        case .completed: "🐱✨"
        case .error: "🐱⚠️"
        }
    }

    /// 灯带主色（用于渐变与呼吸）。
    public var lightPrimary: Color {
        switch self {
        case .idle: Color(red: 0.25, green: 0.62, blue: 1.0)
        case .listening: Color(red: 0.20, green: 0.85, blue: 0.95)
        case .thinking: Color(red: 0.62, green: 0.35, blue: 0.98)
        case .searching: Color(red: 0.45, green: 0.55, blue: 1.0)
        case .coding: Color(red: 0.20, green: 0.88, blue: 0.45)
        case .approval: Color(red: 1.0, green: 0.78, blue: 0.15)
        case .completed: Color.white
        case .error: Color(red: 1.0, green: 0.32, blue: 0.28)
        }
    }

    public var lightSecondary: Color {
        switch self {
        case .idle: Color(red: 0.15, green: 0.35, blue: 0.85)
        case .listening: Color(red: 0.10, green: 0.55, blue: 0.90)
        case .thinking: Color(red: 0.35, green: 0.20, blue: 0.75)
        case .searching: Color(red: 0.25, green: 0.35, blue: 0.90)
        case .coding: Color(red: 0.10, green: 0.55, blue: 0.35)
        case .approval: Color(red: 0.95, green: 0.45, blue: 0.10)
        case .completed: Color(red: 0.75, green: 0.85, blue: 1.0)
        case .error: Color(red: 0.65, green: 0.10, blue: 0.15)
        }
    }

    public var animationKind: VibeBarLightAnimationKind {
        switch self {
        case .idle: .breathe
        case .listening: .scan
        case .thinking: .flow
        case .searching: .fastFlow
        case .coding: .stream
        case .approval: .blink
        case .completed: .flash
        case .error: .alert
        }
    }
}

public enum VibeBarLightAnimationKind: String, Sendable {
    case breathe
    case scan
    case flow
    case fastFlow
    case stream
    case blink
    case flash
    case alert
}

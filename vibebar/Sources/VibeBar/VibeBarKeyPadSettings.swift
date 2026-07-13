import Foundation
import SwiftUI

/// 展开岛四键角色（岛内动作映射）。
public enum VibeBarKeyPadRole: String, CaseIterable, Identifiable, Codable, Sendable {
    case voice
    case approve
    case reject
    case submit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .voice: "Voice"
        case .approve: "Approve"
        case .reject: "Reject"
        case .submit: "Submit"
        }
    }

    public var defaultSystemImage: String {
        switch self {
        case .voice: "mic"
        case .approve: "checkmark.circle.fill"
        case .reject: "xmark.circle.fill"
        case .submit: "return"
        }
    }

    public var defaultTintHex: String {
        switch self {
        case .voice: "#BF59F2"
        case .approve: "#42E86B"
        case .reject: "#FF7359"
        case .submit: "#56C2FF"
        }
    }
}

/// 单键外观与角色配置。
public struct VibeBarKeyPadSlot: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var role: VibeBarKeyPadRole
    public var title: String
    public var systemImage: String
    public var tintHex: String
    public var isEnabled: Bool

    public init(
        id: String,
        role: VibeBarKeyPadRole,
        title: String,
        systemImage: String,
        tintHex: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.systemImage = systemImage
        self.tintHex = tintHex
        self.isEnabled = isEnabled
    }

    public var tintColor: Color {
        Color(hex: tintHex) ?? Color(hex: role.defaultTintHex) ?? .accentColor
    }

    public static func `default`(slotIndex: Int, role: VibeBarKeyPadRole) -> VibeBarKeyPadSlot {
        VibeBarKeyPadSlot(
            id: "key\(slotIndex + 1)",
            role: role,
            title: role.title,
            systemImage: role.defaultSystemImage,
            tintHex: role.defaultTintHex,
            isEnabled: true
        )
    }
}

/// 展开岛四键键帽持久化配置。
public enum VibeBarKeyPadSettings {
    public static let storageKey = "vibebar.island.keyPadSettings"
    public static let didChangeNotification = Notification.Name("vibebar.island.keyPadSettingsDidChange")

    public static var defaultSlots: [VibeBarKeyPadSlot] {
        [
            .default(slotIndex: 0, role: .voice),
            .default(slotIndex: 1, role: .approve),
            .default(slotIndex: 2, role: .reject),
            .default(slotIndex: 3, role: .submit),
        ]
    }

    public static var slots: [VibeBarKeyPadSlot] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode([VibeBarKeyPadSlot].self, from: data),
                  decoded.count == 4 else {
                return defaultSlots
            }
            return sanitize(decoded)
        }
        set {
            let sanitized = sanitize(newValue)
            if let data = try? JSONEncoder().encode(sanitized) {
                UserDefaults.standard.set(data, forKey: storageKey)
            }
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
            NotificationCenter.default.post(
                name: VibeBarIslandAppearanceSettings.appearanceDidChangeNotification,
                object: nil
            )
        }
    }

    public static var visibleSlots: [VibeBarKeyPadSlot] {
        let visible = slots.filter(\.isEnabled)
        return visible.isEmpty ? [slots[0]] : visible
    }

    public static func resetToDefaults() {
        slots = defaultSlots
    }

    public static func updateSlot(_ slot: VibeBarKeyPadSlot) {
        var list = slots
        guard let index = list.firstIndex(where: { $0.id == slot.id }) else { return }
        list[index] = slot
        // voice 唯一：若新槽位是 voice，其它 voice 改回原默认角色
        if slot.role == .voice {
            for i in list.indices where list[i].id != slot.id && list[i].role == .voice {
                let fallback = defaultSlots[i].role
                list[i].role = fallback == .voice ? .submit : fallback
                if list[i].title == VibeBarKeyPadRole.voice.title {
                    list[i].title = list[i].role.title
                }
            }
        }
        // 至少保留一个可见键
        if list.filter(\.isEnabled).isEmpty {
            list[index].isEnabled = true
        }
        slots = list
    }

    private static func sanitize(_ input: [VibeBarKeyPadSlot]) -> [VibeBarKeyPadSlot] {
        var list = input
        if list.count != 4 {
            return defaultSlots
        }
        var seenVoice = false
        for i in list.indices {
            if list[i].role == .voice {
                if seenVoice {
                    list[i].role = defaultSlots[i].role == .voice ? .submit : defaultSlots[i].role
                } else {
                    seenVoice = true
                }
            }
            if list[i].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                list[i].title = list[i].role.title
            }
            if list[i].systemImage.isEmpty {
                list[i].systemImage = list[i].role.defaultSystemImage
            }
        }
        if list.filter(\.isEnabled).isEmpty {
            list[0].isEnabled = true
        }
        return list
    }
}

public extension Color {
    init?(hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt64(raw, radix: 16) else { return nil }
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

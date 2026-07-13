import SwiftUI

/// Agent 状态 LED 灯带（展开岛与静息刘海共用）。
public struct VibeBarAgentLightStrip: View {
    public var status: VibeBarAgentStatus
    public var ledCount: Int
    public var height: CGFloat
    /// 是否绘制独立凹槽底；刘海内嵌时用 false，直接画在黑底上。
    public var showsRecess: Bool

    public init(
        status: VibeBarAgentStatus,
        ledCount: Int = 36,
        height: CGFloat = 22,
        showsRecess: Bool = true
    ) {
        self.status = status
        self.ledCount = ledCount
        self.height = height
        self.showsRecess = showsRecess
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                let width = proxy.size.width
                let spacing = width / CGFloat(max(ledCount - 1, 1))
                let dot = min(spacing * 0.42, height * 0.42)

                ZStack {
                    if showsRecess {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                    }

                    Canvas { context, size in
                        for i in 0..<ledCount {
                            let intensity = ledIntensity(index: i, time: t, count: ledCount, kind: status.animationKind)
                            let color = (i % 2 == 0 ? status.lightPrimary : status.lightSecondary)
                                .opacity(0.14 + 0.86 * intensity)
                            let x = CGFloat(i) * spacing
                            let y = size.height / 2
                            let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
                            context.fill(Path(ellipseIn: rect), with: .color(color))
                            if intensity > 0.5 {
                                context.fill(
                                    Path(ellipseIn: rect.insetBy(dx: -1.4, dy: -1.4)),
                                    with: .color(color.opacity(0.28))
                                )
                            }
                        }
                    }
                    .padding(.horizontal, showsRecess ? 6 : 2)
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Agent 灯带：\(status.title)")
    }

    private func ledIntensity(index: Int, time: TimeInterval, count: Int, kind: VibeBarLightAnimationKind) -> Double {
        let x = Double(index) / Double(max(count - 1, 1))
        switch kind {
        case .breathe:
            return 0.35 + 0.65 * (0.5 + 0.5 * sin(time * 2.2))
        case .scan:
            let wave = abs(sin(time * 3.2 - x * .pi * 2))
            return 0.15 + 0.85 * pow(wave, 2.2)
        case .flow:
            return 0.2 + 0.8 * (0.5 + 0.5 * sin(time * 2.6 + x * .pi * 3))
        case .fastFlow:
            return 0.15 + 0.85 * (0.5 + 0.5 * sin(time * 5.5 + x * .pi * 4))
        case .stream:
            let head = (time * 1.8).truncatingRemainder(dividingBy: 1.0)
            let dist = abs(x - head)
            return 0.18 + 0.82 * max(0, 1 - dist * 3.2)
        case .blink:
            return (sin(time * 8) > 0) ? 1.0 : 0.18
        case .flash:
            return 0.4 + 0.6 * abs(sin(time * 10))
        case .alert:
            return (Int(time * 4) % 2 == 0) ? 1.0 : 0.12
        }
    }
}

import Foundation

/// 番茄钟式专注计时（默认 25 分钟），刘海右槽与展开岛共用。
@MainActor
public final class VibeBarFocusTimerStore: ObservableObject {
    public static let shared = VibeBarFocusTimerStore()

    public static let defaultDurationSeconds = 25 * 60

    private static let remainingKey = "vibebar.focus.remainingSeconds"
    private static let runningKey = "vibebar.focus.isRunning"
    private static let endDateKey = "vibebar.focus.endDate"

    @Published public private(set) var remainingSeconds: Int
    @Published public private(set) var isRunning: Bool

    private var tickTimer: Timer?

    public var displayText: String {
        let clamped = max(0, remainingSeconds)
        let minutes = clamped / 60
        let seconds = clamped % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    public var progress: Double {
        let total = Double(Self.defaultDurationSeconds)
        guard total > 0 else { return 0 }
        return 1 - (Double(max(0, remainingSeconds)) / total)
    }

    private init() {
        let defaults = UserDefaults.standard
        let storedRemaining = defaults.integer(forKey: Self.remainingKey)
        remainingSeconds = storedRemaining > 0 ? storedRemaining : Self.defaultDurationSeconds
        isRunning = defaults.bool(forKey: Self.runningKey)

        if isRunning, let end = defaults.object(forKey: Self.endDateKey) as? Date {
            remainingSeconds = max(0, Int(end.timeIntervalSinceNow.rounded()))
            if remainingSeconds <= 0 {
                finish()
            } else {
                startTicking()
            }
        } else {
            isRunning = false
            persist()
        }
    }

    public func toggle() {
        if isRunning {
            pause()
        } else {
            start()
        }
    }

    public func start() {
        if remainingSeconds <= 0 {
            remainingSeconds = Self.defaultDurationSeconds
        }
        isRunning = true
        UserDefaults.standard.set(Date().addingTimeInterval(TimeInterval(remainingSeconds)), forKey: Self.endDateKey)
        persist()
        startTicking()
    }

    public func pause() {
        isRunning = false
        stopTicking()
        UserDefaults.standard.removeObject(forKey: Self.endDateKey)
        persist()
    }

    public func reset() {
        pause()
        remainingSeconds = Self.defaultDurationSeconds
        persist()
    }

    private func finish() {
        isRunning = false
        remainingSeconds = 0
        stopTicking()
        UserDefaults.standard.removeObject(forKey: Self.endDateKey)
        persist()
        // 结束后自动复位，方便下一轮
        remainingSeconds = Self.defaultDurationSeconds
        persist()
    }

    private func startTicking() {
        stopTicking()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard isRunning else { return }
        if let end = UserDefaults.standard.object(forKey: Self.endDateKey) as? Date {
            remainingSeconds = max(0, Int(end.timeIntervalSinceNow.rounded()))
        } else {
            remainingSeconds = max(0, remainingSeconds - 1)
        }
        persist()
        if remainingSeconds <= 0 {
            finish()
        }
    }

    private func persist() {
        UserDefaults.standard.set(remainingSeconds, forKey: Self.remainingKey)
        UserDefaults.standard.set(isRunning, forKey: Self.runningKey)
        objectWillChange.send()
    }
}

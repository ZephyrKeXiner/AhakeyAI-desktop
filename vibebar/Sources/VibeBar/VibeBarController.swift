import AppKit
import DynamicNotchKit
import SwiftUI

@MainActor
private protocol VibeBarDynamicNotchShell: AnyObject {
    var islandShellWidth: CGFloat? { get set }
    var disableCompactTrailing: Bool { get set }
}

extension DynamicNotch: VibeBarDynamicNotchShell {}

@MainActor
public final class VibeBarController {
    public static let shared = VibeBarController()

    private var notch: (any DynamicNotchControllable)?
    private var dynamicNotch: AnyObject?
    private var pendingCompactTask: Task<Void, Never>?
    private var pendingExpandTask: Task<Void, Never>?
    private var pointerTimer: Timer?
    private var appearanceObserver: NSObjectProtocol?

    private var isHoveringExpanded = false
    private var isExpanded = false
    private var isExpandHoverActive = false
    private weak var state: VibeBarState?
    private var expandedContent: (() -> AnyView)?

    /// 鼠标离开展开岛后延迟收起。
    private let leaveCompactDelayMs: UInt64 = 400
    private var expandGraceUntil: Date?
    private var lastInteractionSoundAt: Date?

    private init() {}

    public func start(state: VibeBarState) {
        start(state: state, expandedContent: nil)
    }

    public func start(state: VibeBarState, expandedContent: @escaping () -> AnyView) {
        start(state: state, expandedContent: Optional.some(expandedContent))
    }

    private func start(state: VibeBarState, expandedContent: (() -> AnyView)?) {
        guard notch == nil else { return }
        self.state = state
        self.expandedContent = expandedContent
        state.onIslandHoverChanged = { [weak self] in self?.expandedHoverChanged($0) }
        state.onIslandCompact = { [weak self] in self?.compactNow() }
        state.onIslandAppear = { [weak self] in self?.expandedMenuAppeared() }

        let screen = targetScreen(for: NSEvent.mouseLocation)
        VibeBarNotchLayout.refreshCompactSideWidth(on: state, screen: screen)

        let notch = DynamicNotch(
            hoverBehavior: [.keepVisible],
            style: .notch
        ) { [weak self] in
            if let expanded = self?.expandedContent {
                expanded()
            } else {
                AnyView(
                    VibeBarExpandedMenu(
                        state: state,
                        onAppear: { self?.expandedMenuAppeared() },
                        onHoverChanged: { self?.expandedHoverChanged($0) },
                        onCompact: { self?.compactNow() }
                    )
                )
            }
        } compactLeading: {
            VibeBarCompactStatusItem(state: state) { _ in }
        } compactTrailing: {
            EmptyView()
        }

        notch.disableCompactTrailing = true
        applyShellAppearance(to: notch)
        self.notch = notch
        self.dynamicNotch = notch
        observeAppearanceChanges()
        refreshPointerTracking()
        compactNow(playSound: false)
    }

    public func stop() {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }
        pointerTimer?.invalidate()
        pointerTimer = nil
        pendingCompactTask?.cancel()
        pendingCompactTask = nil
        cancelPendingExpand()
        notch = nil
        dynamicNotch = nil
        state = nil
        isExpanded = false
        isHoveringExpanded = false
        isExpandHoverActive = false
        expandGraceUntil = nil
    }

    // MARK: - Notch state machine

    private func compactNow(playSound: Bool = true) {
        pendingCompactTask?.cancel()
        cancelPendingExpand()
        let wasExpanded = isExpanded
        isExpanded = false
        isHoveringExpanded = false
        expandGraceUntil = nil
        if playSound, wasExpanded {
            playInteractionSound()
        }
        Task { await notch?.compactInPlace(on: targetScreen(for: NSEvent.mouseLocation)) }
    }

    private func expandNow() {
        guard !isExpanded, VibeBarIslandAppearanceSettings.hoverExpandEnabled else { return }
        pendingCompactTask?.cancel()
        cancelPendingExpand()
        let screen = targetScreen(for: NSEvent.mouseLocation)
        if let state {
            VibeBarNotchLayout.refreshCompactSideWidth(on: state, screen: screen)
        }
        isExpanded = true
        isHoveringExpanded = true
        expandGraceUntil = Date().addingTimeInterval(0.35)
        playHapticIfEnabled()
        playInteractionSound()
        Task { await notch?.expandInPlace(on: screen) }
    }

    private func expandedMenuAppeared() {
        pendingCompactTask?.cancel()
        isExpanded = true
        isHoveringExpanded = true
        expandGraceUntil = Date().addingTimeInterval(0.35)
    }

    private func expandedHoverChanged(_ hovering: Bool) {
        isHoveringExpanded = hovering
        if hovering {
            pendingCompactTask?.cancel()
        } else {
            scheduleCompactIfIdle()
        }
    }

    private func scheduleCompactIfIdle() {
        guard VibeBarIslandAppearanceSettings.autoCollapseOnLeave else { return }
        pendingCompactTask?.cancel()
        pendingCompactTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(self?.leaveCompactDelayMs ?? 400))
            await MainActor.run {
                self?.compactIfIdle()
            }
        }
    }

    private func compactIfIdle() {
        guard isExpanded else { return }
        guard VibeBarIslandAppearanceSettings.autoCollapseOnLeave else { return }
        if isHoveringExpanded || isPointerInExpandedRetentionZone() {
            return
        }
        if let grace = expandGraceUntil, Date() < grace {
            let remaining = grace.timeIntervalSince(Date())
            pendingCompactTask?.cancel()
            pendingCompactTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0.05, remaining)))
                await MainActor.run {
                    self?.compactIfIdle()
                }
            }
            return
        }
        compactNow()
    }

    // MARK: - Pointer tracking (single source of truth)

    private func notePointerEnteredHotZone() {
        guard VibeBarIslandAppearanceSettings.hoverExpandEnabled, !isExpanded else { return }
        guard !isExpandHoverActive else { return }
        isExpandHoverActive = true
        scheduleExpandAfterHover()
    }

    private func notePointerLeftHotZone() {
        isExpandHoverActive = false
        cancelPendingExpand()
    }

    private func scheduleExpandAfterHover() {
        pendingExpandTask?.cancel()
        let delayMs = UInt64(VibeBarIslandAppearanceSettings.hoverExpandDelayMs)
        pendingExpandTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            await MainActor.run {
                self?.expandIfPointerStillInHotZone()
            }
        }
    }

    private func cancelPendingExpand() {
        pendingExpandTask?.cancel()
        pendingExpandTask = nil
    }

    private func expandIfPointerStillInHotZone() {
        pendingExpandTask = nil
        guard isExpandHoverActive, !isExpanded else { return }
        guard isPointerInTopHotZone() else {
            isExpandHoverActive = false
            return
        }
        expandNow()
    }

    private func isPointerInTopHotZone() -> Bool {
        let mouse = NSEvent.mouseLocation
        let screen = targetScreen(for: mouse)
        return topHotZone(on: screen).contains(mouse)
    }

    private func isPointerInExpandedRetentionZone() -> Bool {
        let mouse = NSEvent.mouseLocation
        let screen = targetScreen(for: mouse)
        return expandedRetentionRect(on: screen).contains(mouse)
    }

    private func evaluatePointerInteraction() {
        let mouse = NSEvent.mouseLocation
        let screen = targetScreen(for: mouse)

        if isExpanded {
            let inRetention = expandedRetentionRect(on: screen).contains(mouse)
            if inRetention {
                isHoveringExpanded = true
                pendingCompactTask?.cancel()
            } else if isHoveringExpanded {
                isHoveringExpanded = false
                scheduleCompactIfIdle()
            }
            return
        }

        if topHotZone(on: screen).contains(mouse) {
            notePointerEnteredHotZone()
        } else {
            notePointerLeftHotZone()
        }
    }

    private func refreshPointerTracking() {
        pointerTimer?.invalidate()
        pointerTimer = nil

        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluatePointerInteraction()
            }
        }
        if let pointerTimer {
            RunLoop.main.add(pointerTimer, forMode: .common)
        }
    }

    private func observeAppearanceChanges() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: VibeBarIslandAppearanceSettings.appearanceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyShellAppearanceToLiveNotch()
                if !VibeBarIslandAppearanceSettings.hoverExpandEnabled {
                    self.cancelPendingExpand()
                    self.isExpandHoverActive = false
                }
            }
        }
    }

    private func applyShellAppearance(to notch: VibeBarDynamicNotchShell) {
        let width = VibeBarIslandAppearanceSettings.islandWidth
        notch.islandShellWidth = width
        notch.disableCompactTrailing = true
        state?.islandWidth = width
    }

    private func applyShellAppearanceToLiveNotch() {
        guard let notch = dynamicNotch as? VibeBarDynamicNotchShell else { return }
        applyShellAppearance(to: notch)
        if let state {
            let screen = targetScreen(for: NSEvent.mouseLocation)
            VibeBarNotchLayout.refreshCompactSideWidth(on: state, screen: screen)
        }
    }

    private func playInteractionSound() {
        let now = Date()
        if let lastInteractionSoundAt, now.timeIntervalSince(lastInteractionSoundAt) < 0.35 {
            return
        }
        lastInteractionSoundAt = now
        state?.onIslandInteractionSound?()
    }

    private func playHapticIfEnabled() {
        guard VibeBarIslandAppearanceSettings.hapticFeedbackEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    // MARK: - Hit zones (screen coordinates, bottom-left origin)

    private func topHotZone(on screen: NSScreen) -> CGRect {
        let width = VibeBarIslandAppearanceSettings.islandWidth
        let height = max(
            VibeBarDesignTokens.Layout.topHotZoneHeight,
            screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top + 12 : VibeBarDesignTokens.Layout.topHotZoneHeight
        )
        return CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// 展开岛保留区：与壳层同宽，覆盖键盘画布 + 四格。
    private func expandedRetentionRect(on screen: NSScreen) -> CGRect {
        let width = VibeBarIslandAppearanceSettings.islandWidth + 32
        let height: CGFloat = 430
        return CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func targetScreen(for point: NSPoint) -> NSScreen {
        switch VibeBarIslandAppearanceSettings.preferredDisplay {
        case .main:
            return NSScreen.main ?? NSScreen.screens.first!
        case .mouse, .auto:
            return NSScreen.screens.first { $0.frame.contains(point) }
                ?? NSScreen.main
                ?? NSScreen.screens.first!
        }
    }
}

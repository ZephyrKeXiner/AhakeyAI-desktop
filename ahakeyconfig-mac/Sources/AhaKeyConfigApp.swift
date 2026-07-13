import AppKit
import SwiftUI
import AVFoundation
import Speech
import UserNotifications
import VibeBar
import Combine
import AhaKeyPluginKit

@main
struct AhaKeyConfigApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var bleManager = AhaKeyBLEManager()
    @State private var vibeBarBridge = VibeBarBridge()

    var body: some Scene {
        WindowGroup("AhaKey Studio", id: "main") {
            ContentView(bleManager: bleManager, islandState: vibeBarBridge.state)
                .frame(minWidth: 1180, minHeight: 680)
                .background(MainWindowReopenHelper())
                .onAppear {
                    // 用 AppDelegate.shared，避免 weak 捕获 App 属性包装器导致回调失效。
                    let reopenMain: () -> Void = {
                        AppDelegate.shared?.reopenMainWindow()
                    }
                    vibeBarBridge.attach(bleManager: bleManager, onOpenMainWindow: reopenMain)
                    wireVibeBarNavigation(state: vibeBarBridge.state, reopenMain: reopenMain)
                    let islandState = vibeBarBridge.state
                    VibeBarController.shared.start(state: islandState) {
                        AnyView(
                            VibeBarIslandExpandedView(
                                bleManager: bleManager,
                                state: islandState
                            )
                        )
                    }
                }
        }
        .windowStyle(.titleBar)

        if #available(macOS 13.0, *) {
            MenuBarExtra("AhaKey", systemImage: "keyboard") {
                Button("打开主窗口") {
                    AppDelegate.shared?.reopenMainWindow()
                }

                Divider()

                Button("退出 AhaKey Studio") {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private(set) static weak var shared: AppDelegate?

    /// 由 SwiftUI `openWindow` 注册；主窗口关闭后仍可用于重建 WindowGroup。
    private static var openMainWindowHandler: (@MainActor () -> Void)?

    static func registerOpenMainWindow(_ handler: @escaping @MainActor () -> Void) {
        openMainWindowHandler = handler
    }

    private var voiceHUDPanel: NSPanel?
    private var voiceHUDHostingView: NSHostingView<VoiceInputFloatingHUD>?
    private var voiceHUDCancellables = Set<AnyCancellable>()
    private var lastHUDCommittedText = ""
    private var voiceHUDUserFrameOrigin: NSPoint?
    private var voiceHUDWasVisible = false
    private var pluginShutdownStarted = false
    private var pluginShutdownFinished = false
    private var mainWindowReopenPending = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // 单实例：检查是否已有实例在运行
        let bundleID = Bundle.main.bundleIdentifier ?? "lab.jawa.ahakeyconfig"
        let currentBundlePath = Bundle.main.bundlePath
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            let otherInstances = running.filter { $0 != NSRunningApplication.current }
            let sameBundleInstance = otherInstances.first { app in
                app.bundleURL?.path == currentBundlePath
            }

            if let existing = sameBundleInstance {
                existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                NSApp.terminate(nil)
                return
            }

            for stale in otherInstances {
                stale.terminate()
            }
        }

        // 检查签名是否变化，如果变化则自动重置麦克风权限
        PermissionSignatureChecker.checkAndResetOnSignatureChange { success in
            DispatchQueue.main.async {
                if success {
                    let alert = NSAlert()
                    alert.messageText = "检测到应用签名变化"
                    alert.informativeText = "麦克风权限已自动重置，下次点击「申请」按钮时会弹出系统授权对话框。"
                    alert.addButton(withTitle: "确定")
                    alert.runModal()
                }
            }
        }

        UNUserNotificationCenter.current().delegate = self

        VoiceRelayService.shared.start()
        NativeSpeechTranscriptionService.shared.start()
        AhaKeyIslandAppSettings.applyStoredPreferences()
        installVoiceHUDPanel()
        observeVoiceHUDVisibility()
        VoiceStatusHUDController.shared.suppressRecordingStates = true

        Task {
            let count = await PluginRuntime.shared.start()
            if count > 0 {
                FileHandle.standardError.write(
                    Data("[plugins] loaded \(count) plugin(s)\n".utf8)
                )
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if pluginShutdownFinished { return .terminateNow }
        guard !pluginShutdownStarted else { return .terminateLater }
        pluginShutdownStarted = true
        Task {
            await PluginRuntime.shared.stop()
            pluginShutdownFinished = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        VoiceRelayService.shared.refreshPermissions()
        NativeSpeechTranscriptionService.shared.refreshPermissions()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // `flag` 会把 VibeBar、语音 HUD 等浮动面板也算作可见窗口，不能据此判断
        // Studio 主窗口是否仍在；统一交给主窗口筛选逻辑处理。
        reopenMainWindow()
        return true
    }

    func reopenMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = Self.findStudioMainWindow() {
            mainWindowReopenPending = false
            Self.showStudioMainWindow(window)
            return
        }

        // SwiftUI 的 openWindow 是异步的。重建完成前合并 Dock、菜单栏和灵动岛
        // 连续发来的打开请求，否则每次调用都会创建一个新的 WindowGroup 实例。
        guard !mainWindowReopenPending else { return }
        mainWindowReopenPending = true

        guard let handler = Self.openMainWindowHandler else {
            mainWindowReopenPending = false
            return
        }
        handler()
        bringReopenedMainWindowToFront(attempt: 0)
    }

    private func bringReopenedMainWindowToFront(attempt: Int) {
        if let window = Self.findStudioMainWindow() {
            mainWindowReopenPending = false
            Self.showStudioMainWindow(window)
            return
        }

        // 给 SwiftUI 最多约 1 秒完成 WindowGroup 的异步创建；超时后允许用户重试。
        guard attempt < 20 else {
            mainWindowReopenPending = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.bringReopenedMainWindowToFront(attempt: attempt + 1)
        }
    }

    private static func showStudioMainWindow(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func findStudioMainWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter { window in
            guard !(window is NSPanel) else { return false }
            guard window.styleMask.contains(.titled) else { return false }
            // 灵动岛 / HUD 等小窗排除；主 Studio 窗口通常 ≥ 800×500。
            let size = window.frame.size
            return size.width >= 700 && size.height >= 450
        }
        if let visible = candidates.first(where: { $0.isVisible && !$0.isMiniaturized }) {
            return visible
        }
        if let miniaturized = candidates.first(where: \.isMiniaturized) {
            return miniaturized
        }
        // close() 后的 SwiftUI NSWindow 可能短暂残留在 NSApp.windows，但已无法
        // makeKeyAndOrderFront。不要把这种不可见的旧窗口当成可复用主窗口。
        return nil
    }

    private func installVoiceHUDPanel() {
        guard voiceHUDPanel == nil else { return }

        let nativeSpeech = NativeSpeechTranscriptionService.shared
        let view = VoiceInputFloatingHUD(
            nativeSpeech: nativeSpeech,
            onCancel: {
                if nativeSpeech.isRecording {
                    nativeSpeech.stopRecording()
                }
            },
            onConfirm: {
                if nativeSpeech.isRecording {
                    nativeSpeech.stopRecording()
                }
            },
            onDragChanged: { [weak self] delta in
                self?.moveVoiceHUDPanel(by: delta)
            },
            onDragEnded: { [weak self] in
                self?.rememberVoiceHUDPanelPosition()
            }
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 180, height: 58)

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        voiceHUDPanel = panel
        voiceHUDHostingView = hostingView
    }

    private func observeVoiceHUDVisibility() {
        let service = NativeSpeechTranscriptionService.shared
        Publishers.Merge3(
            service.$isRecording.map { _ in () }.eraseToAnyPublisher(),
            service.$statusMessage.map { _ in () }.eraseToAnyPublisher(),
            service.$lastCommittedText.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            self?.updateVoiceHUDPanelVisibility()
        }
        .store(in: &voiceHUDCancellables)
    }

    private func updateVoiceHUDPanelVisibility() {
        guard let panel = voiceHUDPanel else { return }
        let service = NativeSpeechTranscriptionService.shared
        let isBusy = service.statusMessage.contains("整理")
        let hasNewCommittedText = !service.lastCommittedText.isEmpty && service.lastCommittedText != lastHUDCommittedText
        let visible = service.isRecording || isBusy || hasNewCommittedText

        if visible {
            if !voiceHUDWasVisible {
                positionVoiceHUDPanel(panel)
            }
            panel.orderFrontRegardless()
            voiceHUDWasVisible = true
            if hasNewCommittedText {
                lastHUDCommittedText = service.lastCommittedText
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) { [weak self] in
                    guard let self, !NativeSpeechTranscriptionService.shared.isRecording else { return }
                    if !NativeSpeechTranscriptionService.shared.statusMessage.contains("整理") {
                        self.voiceHUDPanel?.orderOut(nil)
                        self.voiceHUDWasVisible = false
                    }
                }
            }
        } else {
            panel.orderOut(nil)
            voiceHUDWasVisible = false
        }
    }

    private func positionVoiceHUDPanel(_ panel: NSPanel) {
        let size = NSSize(width: 180, height: 58)
        if let savedOrigin = voiceHUDUserFrameOrigin {
            panel.setFrame(NSRect(origin: clampedVoiceHUDOrigin(savedOrigin, size: size), size: size), display: true)
            return
        }
        if let mainWindow = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isMiniaturized }) {
            let frame = mainWindow.frame
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: max(frame.minY + 18, (mainWindow.screen?.visibleFrame.minY ?? 0) + 18)
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 18
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func moveVoiceHUDPanel(by delta: CGSize) {
        guard let panel = voiceHUDPanel else { return }
        let current = panel.frame
        let nextOrigin = NSPoint(
            x: current.origin.x + delta.width,
            y: current.origin.y + delta.height
        )
        panel.setFrame(NSRect(origin: clampedVoiceHUDOrigin(nextOrigin, size: current.size), size: current.size), display: true)
    }

    private func rememberVoiceHUDPanelPosition() {
        guard let panel = voiceHUDPanel else { return }
        voiceHUDUserFrameOrigin = panel.frame.origin
    }

    private func clampedVoiceHUDOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let screenFrame = (NSScreen.screens.first { $0.visibleFrame.intersects(NSRect(origin: origin, size: size)) } ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(
            x: min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8),
            y: min(max(origin.y, screenFrame.minY + 8), screenFrame.maxY - size.height - 8)
        )
    }
}

@MainActor
private func wireVibeBarNavigation(state: VibeBarState, reopenMain: @escaping () -> Void) {
    state.onOpenMainWindow = reopenMain
    state.onIslandInteractionSound = {
        VibeBarIslandSoundSettings.playInteractionIfEnabled()
    }
    state.onOpenVoiceAgent = {
        reopenMain()
        StudioNavigationRouter.shared.navigate(to: .voiceAgent)
    }
    state.onOpenDevice = {
        reopenMain()
        StudioNavigationRouter.shared.navigate(to: .device)
    }
    state.onOpenApprove = {
        reopenMain()
        StudioNavigationRouter.shared.navigate(to: .approve)
    }
    state.onOpenOLED = {
        reopenMain()
        StudioNavigationRouter.shared.navigate(to: .oled)
    }
    state.onOpenVoice = {
        reopenMain()
        StudioNavigationRouter.shared.navigate(to: .voice)
    }
    state.onKeyRecord = {
        NativeSpeechTranscriptionService.shared.toggleRecordingFromVoiceKey()
    }
    state.onKeyApprove = {
        reopenMain()
        StudioNavigationRouter.shared.navigate(to: .approve)
    }
    state.onKeyReject = {
        reopenMain()
        StudioNavigationRouter.shared.navigate(to: .approve)
    }
    state.onKeySwitch = nil
}

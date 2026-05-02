import Foundation
import VoiceAgent

@MainActor
func makeDefaultVoiceAssistantModel() -> VoiceAssistantModel {
    VoiceAssistantModel.voiceAssistant(subAgents: defaultVoiceSubAgents())
}

private func defaultVoiceSubAgents() -> [VoiceSubAgent] {
    [VoiceSubAgent.feishuMessenger()].compactMap { $0 }
}

@MainActor
final class VoiceAgentSessionStore: ObservableObject {
    static let shared = VoiceAgentSessionStore()

    @Published private(set) var runSnapshots: [VoiceAgentRunSnapshot] = []
    @Published var selectedRunID: UUID?

    let assistantModel: VoiceAssistantModel

    private var activeKeyboardMode: AhaKeyModeSlot = .mode0
    private var hasStarted = false
    private var runEventsTask: Task<Void, Never>?
    private var keyboardModeObserver: NSObjectProtocol?

    private init() {
        self.assistantModel = makeDefaultVoiceAssistantModel()
    }

    func start(keyboardMode: AhaKeyModeSlot = .mode0) {
        activeKeyboardMode = keyboardMode
        installKeyboardModeObserverIfNeeded()
        installVoicePromptConsumer()

        guard !hasStarted else { return }
        hasStarted = true

        runEventsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.assistantModel.registerInitialSubAgents()
            await self.refreshRunSnapshots(selectLatestIfNeeded: false)

            for await _ in self.assistantModel.runEvents {
                await self.refreshRunSnapshots(selectLatestIfNeeded: true)
            }
        }
    }

    func updateKeyboardMode(_ mode: AhaKeyModeSlot) {
        activeKeyboardMode = mode
    }

    func sendPrompt(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await assistantModel.send(trimmed)
        await refreshRunSnapshots(selectLatestIfNeeded: true)
        selectedRunID = runSnapshots.last?.runID
    }

    func reset() async {
        await assistantModel.reset()
        runSnapshots = []
        selectedRunID = nil
    }

    private func refreshRunSnapshots(selectLatestIfNeeded: Bool) async {
        runSnapshots = await assistantModel.runSnapshots()

        if let selectedRunID, runSnapshots.contains(where: { $0.runID == selectedRunID }) {
            return
        }

        if selectLatestIfNeeded || selectedRunID == nil {
            selectedRunID = runSnapshots.last?.runID
        }
    }

    private func installVoicePromptConsumer() {
        NativeSpeechTranscriptionService.shared.setFinalTranscriptConsumer { [weak self] text in
            guard let self, self.activeKeyboardMode == .mode2 else { return false }
            Task { @MainActor in
                await self.sendPrompt(text)
            }
            return true
        }
    }

    private func installKeyboardModeObserverIfNeeded() {
        guard keyboardModeObserver == nil else { return }
        keyboardModeObserver = NotificationCenter.default.addObserver(
            forName: .ahaKeyKeyboardWorkModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?["workMode"] as? Int,
                  let mode = AhaKeyModeSlot(rawValue: raw)
            else { return }
            Task { @MainActor in
                self?.updateKeyboardMode(mode)
            }
        }
    }
}

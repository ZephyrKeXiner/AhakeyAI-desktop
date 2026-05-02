import Combine
import Foundation
import VoiceAgent

/// SwiftUI 主 View 直接复用的 agent 包装。
///
/// 设计意图：把 `VoiceAgentRunner` 的 actor API 转换成 `ObservableObject`，
/// 暴露三件 UI 关心的事情——
/// - `messages`：可直接 `ForEach` 的对话条目；
/// - `isThinking`：调用中状态；
/// - `lastError`：上次失败描述。
///
/// runner 内部的工具事件以 `AsyncStream<String>` 形式暴露给 `events`，便于在
/// 调试面板做实时回显，但不阻塞 UI 主流程。
@MainActor
public final class Agent: ObservableObject {
    public struct ChatMessage: Identifiable, Equatable {
        public enum Role: String, Sendable, Equatable {
            case user
            case assistant
            case system
        }

        public let id: UUID
        public let role: Role
        public var content: String
        public let createdAt: Date

        public init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = Date()) {
            self.id = id
            self.role = role
            self.content = content
            self.createdAt = createdAt
        }
    }

    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isThinking: Bool = false
    @Published public var lastError: String?

    public let systemPrompt: String
    /// runner 内部的工具/子 agent 事件流。可在调试视图里 `for await event in agent.events` 读取。
    public let events: AsyncStream<String>

    private let runner: VoiceAgentRunner
    private nonisolated let eventContinuation: AsyncStream<String>.Continuation

    public init(
        systemPrompt: String,
        model: String = VoiceAgentRuntimeConfig.openAIModel,
        options: VoiceAgentOptions = VoiceAgentOptions(temperature: 0.3, maxTokens: 2048),
        tools: [OpenAIToolDefinition] = [],
        toolHandlers: [String: VoiceAgentToolHandler] = [:],
        client: any VoiceAgentLLMClient = OpenAICompatibleChatClient.configuredOpenAI()
    ) {
        self.systemPrompt = systemPrompt
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.events = stream
        self.eventContinuation = continuation
        // 闭包只捕获 Sendable 的 continuation，避免 self 跨 actor 引用。
        let onEvent: VoiceAgentEventCallback = { [continuation] event in
            continuation.yield(event)
        }
        self.runner = VoiceAgentRunner(
            model: model,
            systemPrompt: systemPrompt,
            client: client,
            tools: tools,
            toolHandlers: toolHandlers,
            options: options,
            onEvent: onEvent
        )
    }

    deinit {
        eventContinuation.finish()
    }

    /// 发送一轮用户输入；UI 状态在调用前后自动维护，失败写入 `lastError` 而非抛出。
    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        appendUser(trimmed)
        isThinking = true
        lastError = nil
        defer { isThinking = false }

        do {
            let reply = try await runner.send(trimmed)
            appendAssistant(reply)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 仅写入用户气泡而不调用 LLM，便于上层做可逆 UI 编辑。
    public func appendUser(_ content: String) {
        messages.append(ChatMessage(role: .user, content: content))
    }

    /// 在 UI 端预占一个 assistant 气泡（流式或异步追加场景使用）。
    public func appendAssistant(_ content: String) {
        messages.append(ChatMessage(role: .assistant, content: content))
    }

    /// 清空 UI 与 runner 历史，保留 system prompt。
    public func reset() async {
        await runner.reset()
        messages.removeAll()
        lastError = nil
    }

    /// 直接读取 runner 的完整历史（含 system / tool 消息），用于调试或导出。
    public func transcript() async -> [VoiceAgentMessage] {
        await runner.history()
    }
}

// MARK: - Convenience

public extension Agent {
    /// 与 `VoiceAgentLiveSession` 默认 prompt 对齐的语音助手实例。
    static func voiceAssistant(
        tools: [OpenAIToolDefinition] = [],
        toolHandlers: [String: VoiceAgentToolHandler] = [:],
        options: VoiceAgentOptions = VoiceAgentOptions(temperature: 0.3, maxTokens: 2048)
    ) -> Agent {
        Agent(
            systemPrompt: """
            你是 AhaKey Mode 2 的智能语音助手。
            你可以直接回答简单问题。
            只有当子任务彼此独立，且并行处理明显优于你自己串行完成时，才使用 subagent。
            一次用户请求最多拆成 3-4 个子 agent；不要让子 agent 再委派 subagent。
            对于简单查询、总结、格式整理、依赖前序结果的任务，请直接完成。
            回答简洁、直接、有条理。
            """,
            options: options,
            tools: tools,
            toolHandlers: toolHandlers
        )
    }
}

import Foundation

public typealias VoiceAgentToolHandler = @Sendable (String) async throws -> String
public typealias VoiceAgentEventCallback = @Sendable (String) async -> Void

private struct SubAgentArgs: Sendable {
    var systemPrompt: String
    var prompt: String

    static func parse(_ arguments: String) throws -> SubAgentArgs {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SubAgentArgumentError.missingPrompt(arguments)
        }

        let data = Data(trimmed.utf8)
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            if trimmed.looksLikeJSON {
                throw SubAgentArgumentError.invalidJSON(trimmed, error.localizedDescription)
            }
            // Some OpenAI-compatible providers may return bare text instead of
            // a JSON-encoded function argument. Treat it as the delegated prompt.
            return SubAgentArgs(systemPrompt: defaultSystemPrompt, prompt: trimmed)
        }

        if let prompt = value as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SubAgentArgs(systemPrompt: defaultSystemPrompt, prompt: prompt)
        }

        guard let object = value as? [String: Any] else {
            throw SubAgentArgumentError.unsupportedShape(trimmed)
        }

        let systemPrompt = firstString(
            in: object,
            keys: ["system_prompt", "systemPrompt", "systemprompt", "system", "instructions"]
        ) ?? defaultSystemPrompt

        if let prompt = firstString(
            in: object,
            keys: ["prompt", "task", "input", "query", "question", "request", "user_prompt", "userPrompt"]
        ) {
            return SubAgentArgs(systemPrompt: systemPrompt, prompt: prompt)
        }

        if let onlyString = object.values.compactMap({ $0 as? String }).first(where: { !$0.isBlank }) {
            return SubAgentArgs(systemPrompt: systemPrompt, prompt: onlyString)
        }

        throw SubAgentArgumentError.missingPrompt(trimmed)
    }

    private static let defaultSystemPrompt = """
    You are an independent sub-agent. Complete the delegated task, keep your reasoning focused on the task, and return a concise result to the parent agent.
    """

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isBlank {
                return value
            }
        }
        return nil
    }
}

private enum SubAgentArgumentError: LocalizedError {
    case invalidJSON(String, String)
    case unsupportedShape(String)
    case missingPrompt(String)

    var errorDescription: String? {
        switch self {
        case let .invalidJSON(arguments, underlying):
            "Invalid subagent arguments: malformed JSON \(preview(arguments)) (\(underlying))."
        case let .unsupportedShape(arguments):
            "Invalid subagent arguments: expected a JSON object or string, got \(preview(arguments))."
        case let .missingPrompt(arguments):
            "Invalid subagent arguments: missing non-empty prompt/task field in \(preview(arguments))."
        }
    }

    private func preview(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 160 { return "'\(trimmed)'" }
        return "'\(String(trimmed.prefix(160)))...'"
    }
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var looksLikeJSON: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        return first == "{" || first == "[" || first == "\""
    }
}

/// Coda-style agentic runner: 由 LLM 自行决定何时调用工具（包括派生子 agent）。
/// subagent 只允许由 root agent 派生，用于真正可并行的独立子任务。
public actor VoiceAgentRunner {
    public static let maxDepth = 1
    public static let maxConcurrentCalls = 3
    public static let maxSubagentCallsPerRun = 4

    private let client: any VoiceAgentLLMClient
    private let model: String
    private let options: VoiceAgentOptions
    private let tools: [OpenAIToolDefinition]
    private let toolHandlers: [String: VoiceAgentToolHandler]
    private let onEvent: VoiceAgentEventCallback?
    private let limiter: ConcurrencyLimiter
    private var messages: [VoiceAgentMessage]

    public init(
        model: String,
        systemPrompt: String,
        client: any VoiceAgentLLMClient,
        tools: [OpenAIToolDefinition] = [],
        toolHandlers: [String: VoiceAgentToolHandler] = [:],
        options: VoiceAgentOptions = VoiceAgentOptions(),
        onEvent: VoiceAgentEventCallback? = nil
    ) {
        self.client = client
        self.model = model
        self.options = options
        self.tools = tools
        self.toolHandlers = toolHandlers
        self.onEvent = onEvent
        self.limiter = ConcurrencyLimiter(limit: Self.maxConcurrentCalls)
        self.messages = [.system(systemPrompt)]
    }

    /// Send user text and run the full agentic loop (tool calls + sub-agents).
    @discardableResult
    public func send(_ userText: String) async throws -> String {
        var working = messages
        working.append(.user(userText))
        var remainingSubagentCalls = Self.maxSubagentCallsPerRun
        let result = try await Self.runAgent(
            messages: &working,
            model: model,
            client: client,
            tools: tools,
            toolHandlers: toolHandlers,
            options: options,
            depth: 0,
            remainingSubagentCalls: &remainingSubagentCalls,
            limiter: limiter,
            onEvent: onEvent
        )
        messages = working
        return result
    }

    public func history() -> [VoiceAgentMessage] { messages }

    public func reset() {
        let sys = messages.first
        messages = sys.map { [$0] } ?? []
    }

    // MARK: - Recursive agent loop

    private static func runAgent(
        messages: inout [VoiceAgentMessage],
        model: String,
        client: any VoiceAgentLLMClient,
        tools: [OpenAIToolDefinition],
        toolHandlers: [String: VoiceAgentToolHandler],
        options: VoiceAgentOptions,
        depth: Int,
        remainingSubagentCalls: inout Int,
        limiter: ConcurrencyLimiter,
        onEvent: VoiceAgentEventCallback?
    ) async throws -> String {
        while true {
            let allTools = depth == 0 && remainingSubagentCalls > 0
                ? tools + [subagentToolDefinition]
                : tools

            let request = OpenAIChatCompletionRequest(
                model: model,
                messages: messages,
                temperature: options.temperature,
                maxTokens: options.maxTokens,
                tools: allTools.isEmpty ? nil : allTools
            )

            // Acquire before API call, release after.
            await limiter.acquire()
            let response: VoiceAgentMessage
            do {
                response = try await client.complete(request)
            } catch {
                await limiter.release()
                throw error
            }
            await limiter.release()

            messages.append(response)

            guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                return response.content
            }

            let allowedSubagentToolCallIDs = reserveSubagentToolCalls(
                toolCalls,
                remainingSubagentCalls: &remainingSubagentCalls
            )
            let requestedSubagentCount = toolCalls.filter { $0.function.name == "subagent" }.count
            if requestedSubagentCount > allowedSubagentToolCallIDs.count {
                await onEvent?("[subagent] skipped \(requestedSubagentCount - allowedSubagentToolCallIDs.count) call(s): budget exhausted")
            }

            // Execute all tool calls in parallel (bounded by limiter);
            // individual failures return error text instead of crashing the group.
            let toolResults: [(id: String, output: String)] = await withTaskGroup(
                of: (String, String).self
            ) { group in
                for toolCall in toolCalls {
                    let name = toolCall.function.name
                    let args = toolCall.function.arguments
                    let id = toolCall.id

                    group.addTask {
                        do {
                            let output: String
                            if name == "subagent" {
                                if depth != 0 {
                                    output = "Error: subagent delegation is only available to the root agent. Complete this task directly instead of delegating again."
                                } else if !allowedSubagentToolCallIDs.contains(id) {
                                    output = "Error: subagent budget exceeded. Use the existing context and completed subagent results to synthesize the answer."
                                } else {
                                    output = try await handleSubagent(
                                        args,
                                        model: model,
                                        client: client,
                                        tools: tools,
                                        toolHandlers: toolHandlers,
                                        options: options,
                                        depth: depth,
                                        limiter: limiter,
                                        onEvent: onEvent
                                    )
                                }
                            } else if let handler = toolHandlers[name] {
                                await onEvent?("[tool] \(name)")
                                output = try await handler(args)
                            } else {
                                output = "Error: unknown tool '\(name)'"
                            }
                            return (id, output)
                        } catch {
                            await onEvent?("[error] tool \(name) failed: \(error.localizedDescription)")
                            return (id, "Error: \(error.localizedDescription)")
                        }
                    }
                }
                var results: [(String, String)] = []
                for await r in group { results.append(r) }
                return results
            }

            // Append results in original tool_calls order
            for toolCall in toolCalls {
                if let r = toolResults.first(where: { $0.id == toolCall.id }) {
                    messages.append(.tool(r.output, toolCallID: r.id))
                }
            }
        }
    }

    private static func reserveSubagentToolCalls(
        _ toolCalls: [OpenAIToolCall],
        remainingSubagentCalls: inout Int
    ) -> Set<String> {
        guard remainingSubagentCalls > 0 else { return [] }

        let requested = toolCalls.filter { $0.function.name == "subagent" }
        let allowed = requested.prefix(remainingSubagentCalls).map(\.id)
        remainingSubagentCalls -= allowed.count
        return Set(allowed)
    }

    private static func handleSubagent(
        _ arguments: String,
        model: String,
        client: any VoiceAgentLLMClient,
        tools: [OpenAIToolDefinition],
        toolHandlers: [String: VoiceAgentToolHandler],
        options: VoiceAgentOptions,
        depth: Int,
        limiter: ConcurrencyLimiter,
        onEvent: VoiceAgentEventCallback?
    ) async throws -> String {
        guard depth + 1 <= maxDepth else {
            return "Error: max sub-agent depth (\(maxDepth)) exceeded"
        }

        let parsed = try SubAgentArgs.parse(arguments)
        await onEvent?("[subagent depth=\(depth + 1)] \(String(parsed.prompt.prefix(80)))...")

        var subMessages: [VoiceAgentMessage] = [
            .system(parsed.systemPrompt),
            .user(parsed.prompt),
        ]
        var childSubagentBudget = 0
        return try await runAgent(
            messages: &subMessages,
            model: model,
            client: client,
            tools: tools,
            toolHandlers: toolHandlers,
            options: options,
            depth: depth + 1,
            remainingSubagentCalls: &childSubagentBudget,
            limiter: limiter,
            onEvent: onEvent
        )
    }

    private static let subagentToolDefinition = OpenAIToolDefinition(
        function: .init(
            name: "subagent",
            description: "Launch an independent sub-agent for a self-contained subtask only when parallel delegation is materially better than doing the work serially in the current agent. Do not use this for trivial lookups, follow-up synthesis, formatting, or tasks whose output depends on another subtask. For complex requests, split into at most 3-4 independent subagents total. Subagents cannot delegate again; they must complete their assigned task directly.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "system_prompt": .object([
                        "type": .string("string"),
                        "description": .string("Optional system prompt for the sub-agent to follow. If omitted, the runner uses a safe default."),
                    ]),
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("The independent task for the sub-agent to complete directly. Make it self-contained and include the needed context; do not ask it to create more subagents."),
                    ]),
                ]),
                "required": .array([.string("prompt")]),
            ])
        )
    )
}

public extension VoiceAgentRunner {
    static func configuredOpenAI(
        systemPrompt: String,
        tools: [OpenAIToolDefinition] = [],
        toolHandlers: [String: VoiceAgentToolHandler] = [:],
        options: VoiceAgentOptions = VoiceAgentOptions(),
        onEvent: VoiceAgentEventCallback? = nil
    ) -> VoiceAgentRunner {
        VoiceAgentRunner(
            model: VoiceAgentRuntimeConfig.openAIModel,
            systemPrompt: systemPrompt,
            client: OpenAICompatibleChatClient.configuredOpenAI(),
            tools: tools,
            toolHandlers: toolHandlers,
            options: options,
            onEvent: onEvent
        )
    }
}

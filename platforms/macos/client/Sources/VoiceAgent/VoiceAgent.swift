import Foundation
#if canImport(Security)
import Security
#endif

public enum VoiceAgentRuntimeConfig {
    public static let apiKeyEnvironmentVariables = [
        "AHAKEY_OPENAI_API_KEY",
        "OPENAI_API_KEY",
    ]
    public static let baseURLEnvironmentVariable = "AHAKEY_OPENAI_BASE_URL"
    public static let modelEnvironmentVariable = "AHAKEY_OPENAI_MODEL"
    public static let keychainService = "com.ahakey.voiceagent"
    public static let keychainAPIKeyAccount = "openai-compatible-api-key"

    public static let defaultOpenAIBaseURL = URL(string: "https://api.openai-next.com/v1")!
    public static let defaultModel = "gpt-5.5"

    public static var openAIBaseURL: URL {
        openAIBaseURL(environment: ProcessInfo.processInfo.environment)
    }

    public static var openAIAPIKey: String? {
        openAIAPIKey(environment: ProcessInfo.processInfo.environment)
    }

    public static var openAIModel: String {
        openAIModel(environment: ProcessInfo.processInfo.environment)
    }

    public static func openAIBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard
            let rawValue = nonEmpty(environment[baseURLEnvironmentVariable]),
            let url = URL(string: rawValue),
            url.scheme != nil,
            url.host != nil
        else {
            return defaultOpenAIBaseURL
        }
        return url
    }

    public static func openAIAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeKeychain: Bool = true
    ) -> String? {
        for variable in apiKeyEnvironmentVariables {
            if let apiKey = nonEmpty(environment[variable]) {
                return apiKey
            }
        }

        guard includeKeychain else { return nil }
        return VoiceAgentKeychain.openAIAPIKey(
            service: keychainService,
            account: keychainAPIKeyAccount
        )
    }

    public static func openAIModel(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        nonEmpty(environment[modelEnvironmentVariable]) ?? defaultModel
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum VoiceAgentKeychain {
    public static func openAIAPIKey(service: String, account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
        #else
        return nil
        #endif
    }
}

// MARK: - JSON Value (for tool parameter schemas)

public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(b): try container.encode(b)
        case let .int(i): try container.encode(i)
        case let .double(d): try container.encode(d)
        case let .string(s): try container.encode(s)
        case let .array(a): try container.encode(a)
        case let .object(o): try container.encode(o)
        }
    }
}

// MARK: - OpenAI Function Calling Types

public struct OpenAIFunctionCall: Codable, Sendable, Equatable {
    public var name: String
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

public struct OpenAIToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var type: String
    public var function: OpenAIFunctionCall

    public init(id: String, type: String = "function", function: OpenAIFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct OpenAIToolDefinition: Codable, Sendable {
    public var type: String
    public var function: FunctionSpec

    public struct FunctionSpec: Codable, Sendable {
        public var name: String
        public var description: String
        public var parameters: JSONValue

        public init(name: String, description: String, parameters: JSONValue) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    public init(type: String = "function", function: FunctionSpec) {
        self.type = type
        self.function = function
    }
}

// MARK: - Core Types

public enum VoiceAgentRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct VoiceAgentMessage: Codable, Equatable, Sendable {
    public var role: VoiceAgentRole
    public var content: String
    public var name: String?
    public var toolCallID: String?
    public var toolCalls: [OpenAIToolCall]?

    public init(
        role: VoiceAgentRole,
        content: String,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [OpenAIToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    public static func system(_ content: String) -> VoiceAgentMessage {
        VoiceAgentMessage(role: .system, content: content)
    }

    public static func user(_ content: String) -> VoiceAgentMessage {
        VoiceAgentMessage(role: .user, content: content)
    }

    public static func assistant(_ content: String) -> VoiceAgentMessage {
        VoiceAgentMessage(role: .assistant, content: content)
    }

    public static func tool(_ content: String, toolCallID: String) -> VoiceAgentMessage {
        VoiceAgentMessage(role: .tool, content: content, toolCallID: toolCallID)
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case name
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }

    // Custom decoder: OpenAI returns content=null when tool_calls is present
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(VoiceAgentRole.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolCalls = try container.decodeIfPresent([OpenAIToolCall].self, forKey: .toolCalls)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
    }
}

public struct OpenAIChatCompletionRequest: Codable, Sendable {
    public var model: String
    public var messages: [VoiceAgentMessage]
    public var temperature: Double?
    public var maxTokens: Int?
    public var stream: Bool?
    public var tools: [OpenAIToolDefinition]?

    public init(
        model: String,
        messages: [VoiceAgentMessage],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        stream: Bool? = nil,
        tools: [OpenAIToolDefinition]? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.tools = tools
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
        case tools
    }
}

public struct OpenAIChatCompletionResponse: Codable, Sendable {
    public struct Choice: Codable, Sendable {
        public var index: Int
        public var message: VoiceAgentMessage
        public var finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }
    }

    public struct Usage: Codable, Sendable {
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var totalTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    public var id: String?
    public var object: String?
    public var created: Int?
    public var model: String?
    public var choices: [Choice]
    public var usage: Usage?

    /// API error envelope – some providers return `{"error": {...}}` with HTTP 200.
    public var error: APIError?

    public struct APIError: Codable, Sendable {
        public var message: String?
        public var type: String?
        public var code: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        object = try container.decodeIfPresent(String.self, forKey: .object)
        created = try container.decodeIfPresent(Int.self, forKey: .created)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
        usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
        error = try container.decodeIfPresent(APIError.self, forKey: .error)
    }
}

public struct VoiceAgentTurn: Equatable, Sendable {
    public var sessionID: UUID
    public var index: Int
    public var userMessage: VoiceAgentMessage
    public var assistantMessage: VoiceAgentMessage
}

public struct VoiceAgentSessionSnapshot: Equatable, Sendable {
    public var sessionID: UUID
    public var model: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [VoiceAgentMessage]

    public var turnCount: Int {
        messages.filter { $0.role == .user }.count
    }
}

public struct VoiceAgentMemorySnapshot: Equatable, Sendable {
    public var facts: [String: String]
    public var notes: [String]

    public var rendered: String {
        var lines: [String] = []
        if !facts.isEmpty {
            lines.append("Facts:")
            for key in facts.keys.sorted() {
                lines.append("- \(key): \(facts[key] ?? "")")
            }
        }
        if !notes.isEmpty {
            lines.append("Notes:")
            for note in notes {
                lines.append("- \(note)")
            }
        }
        return lines.isEmpty ? "No memory yet." : lines.joined(separator: "\n")
    }
}

public actor VoiceAgentMemory {
    private var facts: [String: String]
    private var notes: [String]

    public init(facts: [String: String] = [:], notes: [String] = []) {
        self.facts = facts
        self.notes = notes
    }

    public func setFact(_ key: String, value: String) {
        facts[key] = value
    }

    public func fact(_ key: String) -> String? {
        facts[key]
    }

    public func remember(_ note: String) {
        notes.append(note)
    }

    public func snapshot() -> VoiceAgentMemorySnapshot {
        VoiceAgentMemorySnapshot(facts: facts, notes: notes)
    }

    public func reset() {
        facts = [:]
        notes = []
    }
}

public struct VoiceAgentToolContext: Sendable {
    public var sessionID: UUID
    public var agentName: String
    public var memory: VoiceAgentMemorySnapshot

    public init(sessionID: UUID, agentName: String, memory: VoiceAgentMemorySnapshot) {
        self.sessionID = sessionID
        self.agentName = agentName
        self.memory = memory
    }
}

public struct VoiceAgentToolInvocation: Equatable, Sendable {
    public var name: String
    public var input: String

    public init(name: String, input: String) {
        self.name = name
        self.input = input
    }
}

public struct VoiceAgentToolResult: Equatable, Sendable {
    public var name: String
    public var input: String
    public var output: String

    public init(name: String, input: String, output: String) {
        self.name = name
        self.input = input
        self.output = output
    }
}

public protocol VoiceAgentTool: Sendable {
    var name: String { get }
    var description: String { get }

    func call(input: String, context: VoiceAgentToolContext) async throws -> String
}

public struct VoiceSubAgentAssignment: Equatable, Sendable {
    public var agentName: String
    public var task: String
    public var context: String?
    public var toolInvocations: [VoiceAgentToolInvocation]

    public init(
        agentName: String,
        task: String,
        context: String? = nil,
        toolInvocations: [VoiceAgentToolInvocation] = []
    ) {
        self.agentName = agentName
        self.task = task
        self.context = context
        self.toolInvocations = toolInvocations
    }
}

public enum VoiceSubAgentEventPhase: String, Equatable, Sendable {
    case started
    case toolStarted
    case toolFinished
    case completed
    case failed
}

public struct VoiceSubAgentEvent: Equatable, Sendable {
    public var runID: UUID
    public var agentName: String
    public var task: String
    public var phase: VoiceSubAgentEventPhase
    public var toolName: String?
    public var message: String?
    public var timestamp: Date

    public init(
        runID: UUID,
        agentName: String,
        task: String,
        phase: VoiceSubAgentEventPhase,
        toolName: String? = nil,
        message: String? = nil,
        timestamp: Date = Date()
    ) {
        self.runID = runID
        self.agentName = agentName
        self.task = task
        self.phase = phase
        self.toolName = toolName
        self.message = message
        self.timestamp = timestamp
    }
}

public typealias VoiceSubAgentEventHandler = @Sendable (VoiceSubAgentEvent) async -> Void

public struct VoiceSubAgentResult: Equatable, Sendable {
    public var runID: UUID
    public var agentName: String
    public var task: String
    public var output: String
    public var toolResults: [VoiceAgentToolResult]
    public var memory: VoiceAgentMemorySnapshot
    public var session: VoiceAgentSessionSnapshot
    public var startedAt: Date
    public var completedAt: Date
}

public struct VoiceAgentOrchestrationResult: Equatable, Sendable {
    public var input: String
    public var finalOutput: String
    public var subAgentResults: [VoiceSubAgentResult]
    public var supervisorSession: VoiceAgentSessionSnapshot
}

public enum VoiceSubAgentRunStatus: Equatable, Sendable {
    case running
    case completed(VoiceSubAgentResult)
    case failed(String)
    case cancelled
}

public struct VoiceSubAgentLiveSnapshot: Sendable {
    public var runID: UUID
    public var agentName: String
    public var task: String
    public var spawnedAt: Date
    public var status: VoiceSubAgentRunStatus
    public var session: VoiceAgentSessionSnapshot
    public var memory: VoiceAgentMemorySnapshot
}

/// `VoiceSubAgentHandle` is the Swift counterpart to a `tokio::JoinHandle`:
/// the underlying `Task` is already executing concurrently when the handle is
/// returned; the orchestrator retains the handle for the supervisor's full
/// lifetime so its session and memory remain inspectable even after the task
/// has resolved.
public actor VoiceSubAgentHandle {
    public nonisolated let runID: UUID
    public nonisolated let agentName: String
    public nonisolated let task: String
    public nonisolated let spawnedAt: Date

    private let subAgent: VoiceSubAgent
    private let runTask: Task<VoiceSubAgentResult, Error>
    private var resolved: VoiceSubAgentRunStatus = .running

    init(
        runID: UUID,
        agentName: String,
        task: String,
        spawnedAt: Date,
        subAgent: VoiceSubAgent,
        runTask: Task<VoiceSubAgentResult, Error>
    ) {
        self.runID = runID
        self.agentName = agentName
        self.task = task
        self.spawnedAt = spawnedAt
        self.subAgent = subAgent
        self.runTask = runTask
    }

    @discardableResult
    public func value() async throws -> VoiceSubAgentResult {
        do {
            let result = try await runTask.value
            resolved = .completed(result)
            return result
        } catch is CancellationError {
            resolved = .cancelled
            throw CancellationError()
        } catch {
            resolved = .failed(error.localizedDescription)
            throw error
        }
    }

    public func cancel() {
        runTask.cancel()
    }

    public func status() -> VoiceSubAgentRunStatus { resolved }

    public func sessionSnapshot() async -> VoiceAgentSessionSnapshot {
        await subAgent.sessionSnapshot()
    }

    public func memorySnapshot() async -> VoiceAgentMemorySnapshot {
        await subAgent.memorySnapshot()
    }

    public func liveSnapshot() async -> VoiceSubAgentLiveSnapshot {
        VoiceSubAgentLiveSnapshot(
            runID: runID,
            agentName: agentName,
            task: task,
            spawnedAt: spawnedAt,
            status: resolved,
            session: await subAgent.sessionSnapshot(),
            memory: await subAgent.memorySnapshot()
        )
    }
}

public enum VoiceAgentError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidEndpoint(URL)
    case emptyResponse
    case badStatusCode(Int, String)
    case unknownSubAgent(String)
    case unknownTool(agentName: String, toolName: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Missing OpenAI-compatible API key."
        case let .invalidEndpoint(url):
            "Invalid OpenAI-compatible endpoint: \(url.absoluteString)"
        case .emptyResponse:
            "The model returned no assistant message."
        case let .badStatusCode(code, body):
            "OpenAI-compatible endpoint returned HTTP \(code): \(body)"
        case let .unknownSubAgent(name):
            "Unknown subagent: \(name)"
        case let .unknownTool(agentName, toolName):
            "Unknown tool '\(toolName)' for subagent '\(agentName)'."
        }
    }
}

public protocol VoiceAgentLLMClient: Sendable {
    func complete(_ request: OpenAIChatCompletionRequest) async throws -> VoiceAgentMessage
}

public final class OpenAICompatibleChatClient: VoiceAgentLLMClient, @unchecked Sendable {
    private let endpoint: URL
    private let apiKeyProvider: @Sendable () -> String?
    private let additionalHeaders: [String: String]
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        baseURL: URL = URL(string: "https://api.openai-next.com/v1")!,
        apiKeyProvider: @escaping @Sendable () -> String?,
        additionalHeaders: [String: String] = [:],
        session: URLSession? = nil
    ) {
        self.endpoint = baseURL.appendingPathComponent("chat/completions")
        self.apiKeyProvider = apiKeyProvider
        self.additionalHeaders = additionalHeaders
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func complete(_ request: OpenAIChatCompletionRequest) async throws -> VoiceAgentMessage {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw VoiceAgentError.missingAPIKey
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in additionalHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceAgentError.invalidEndpoint(endpoint)
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoiceAgentError.badStatusCode(httpResponse.statusCode, body)
        }

        let completion = try decoder.decode(OpenAIChatCompletionResponse.self, from: data)
        if let apiError = completion.error {
            let msg = apiError.message ?? "Unknown API error"
            throw VoiceAgentError.badStatusCode(httpResponse.statusCode, msg)
        }
        guard let message = completion.choices.first?.message else {
            throw VoiceAgentError.emptyResponse
        }
        return message
    }
}

public extension OpenAICompatibleChatClient {
    static func configuredOpenAI() -> OpenAICompatibleChatClient {
        OpenAICompatibleChatClient(
            baseURL: VoiceAgentRuntimeConfig.openAIBaseURL,
            apiKeyProvider: { VoiceAgentRuntimeConfig.openAIAPIKey }
        )
    }
}

public struct VoiceAgentOptions: Equatable, Sendable {
    public var temperature: Double?
    public var maxTokens: Int?

    public init(temperature: Double? = nil, maxTokens: Int? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

public actor VoiceAgent {
    private let sessionID: UUID
    private let model: String
    private let options: VoiceAgentOptions
    private let client: any VoiceAgentLLMClient
    private let initialSystemPrompt: String?
    private let createdAt: Date
    private var updatedAt: Date
    private var messages: [VoiceAgentMessage]

    public init(
        sessionID: UUID = UUID(),
        model: String,
        systemPrompt: String? = nil,
        options: VoiceAgentOptions = VoiceAgentOptions(),
        client: any VoiceAgentLLMClient
    ) {
        self.sessionID = sessionID
        self.model = model
        self.options = options
        self.client = client
        self.initialSystemPrompt = systemPrompt
        self.createdAt = Date()
        self.updatedAt = createdAt
        self.messages = systemPrompt.map { [.system($0)] } ?? []
    }

    @discardableResult
    public func send(_ userText: String) async throws -> String {
        let turn = try await sendTurn(userText)
        return turn.assistantMessage.content
    }

    @discardableResult
    public func sendTurn(_ userText: String) async throws -> VoiceAgentTurn {
        let userMessage = VoiceAgentMessage.user(userText)
        messages.append(userMessage)

        let request = OpenAIChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: options.temperature,
            maxTokens: options.maxTokens,
            stream: false
        )

        do {
            let assistantMessage = try await client.complete(request)
            messages.append(assistantMessage)
            updatedAt = Date()
            return VoiceAgentTurn(
                sessionID: sessionID,
                index: messages.filter { $0.role == .user }.count,
                userMessage: userMessage,
                assistantMessage: assistantMessage
            )
        } catch {
            if messages.last == userMessage {
                messages.removeLast()
            }
            throw error
        }
    }

    public func history() -> [VoiceAgentMessage] {
        messages
    }

    public func snapshot() -> VoiceAgentSessionSnapshot {
        VoiceAgentSessionSnapshot(
            sessionID: sessionID,
            model: model,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages
        )
    }

    public func reset(keepingSystemPrompt: Bool = true) {
        if keepingSystemPrompt, let initialSystemPrompt {
            messages = [.system(initialSystemPrompt)]
        } else {
            messages = []
        }
        updatedAt = Date()
    }
}

public extension VoiceAgent {
    static func configuredOpenAI(
        model: String = VoiceAgentRuntimeConfig.openAIModel,
        systemPrompt: String? = nil,
        options: VoiceAgentOptions = VoiceAgentOptions()
    ) -> VoiceAgent {
        VoiceAgent(
            model: model,
            systemPrompt: systemPrompt,
            options: options,
            client: OpenAICompatibleChatClient.configuredOpenAI()
        )
    }
}

public actor VoiceSubAgent {
    public let name: String
    public let purpose: String

    private let agent: VoiceAgent
    private let memory: VoiceAgentMemory
    private let tools: [String: any VoiceAgentTool]
    private let eventHandler: VoiceSubAgentEventHandler?

    public init(
        name: String,
        purpose: String,
        model: String,
        systemPrompt: String,
        options: VoiceAgentOptions = VoiceAgentOptions(),
        client: any VoiceAgentLLMClient,
        memory: VoiceAgentMemory = VoiceAgentMemory(),
        tools: [any VoiceAgentTool] = [],
        eventHandler: VoiceSubAgentEventHandler? = nil
    ) {
        self.name = name
        self.purpose = purpose
        self.agent = VoiceAgent(
            model: model,
            systemPrompt: systemPrompt,
            options: options,
            client: client
        )
        self.memory = memory
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.eventHandler = eventHandler
    }

    public func run(_ assignment: VoiceSubAgentAssignment) async throws -> VoiceSubAgentResult {
        let runID = UUID()
        let startedAt = Date()
        await emit(
            runID: runID,
            task: assignment.task,
            phase: .started,
            message: "Subagent \(name) started."
        )

        do {
            let toolResults = try await executeTools(
                assignment.toolInvocations,
                runID: runID,
                task: assignment.task
            )
            for result in toolResults {
                await memory.remember("Tool \(result.name) returned: \(result.output)")
            }

            let memorySnapshot = await memory.snapshot()
            let prompt = Self.buildPrompt(
                agentName: name,
                purpose: purpose,
                task: assignment.task,
                context: assignment.context,
                memory: memorySnapshot,
                tools: availableToolDescriptions(),
                toolResults: toolResults
            )

            let output = try await agent.send(prompt)
            await memory.remember("Task: \(assignment.task)\nAnswer: \(output)")

            let completedAt = Date()
            await emit(
                runID: runID,
                task: assignment.task,
                phase: .completed,
                message: "Subagent \(name) completed."
            )

            return VoiceSubAgentResult(
                runID: runID,
                agentName: name,
                task: assignment.task,
                output: output,
                toolResults: toolResults,
                memory: await memory.snapshot(),
                session: await agent.snapshot(),
                startedAt: startedAt,
                completedAt: completedAt
            )
        } catch {
            await emit(
                runID: runID,
                task: assignment.task,
                phase: .failed,
                message: error.localizedDescription
            )
            throw error
        }
    }

    public func executeTool(_ invocation: VoiceAgentToolInvocation) async throws -> VoiceAgentToolResult {
        let runID = UUID()
        return try await executeTools([invocation], runID: runID, task: "manual tool execution").first!
    }

    public func memorySnapshot() async -> VoiceAgentMemorySnapshot {
        await memory.snapshot()
    }

    public func sessionSnapshot() async -> VoiceAgentSessionSnapshot {
        await agent.snapshot()
    }

    public func reset(keepingSystemPrompt: Bool = true, clearingMemory: Bool = false) async {
        await agent.reset(keepingSystemPrompt: keepingSystemPrompt)
        if clearingMemory {
            await memory.reset()
        }
    }

    public func availableTools() -> [String] {
        tools.keys.sorted()
    }

    private func executeTools(
        _ invocations: [VoiceAgentToolInvocation],
        runID: UUID,
        task: String
    ) async throws -> [VoiceAgentToolResult] {
        guard !invocations.isEmpty else { return [] }

        let memorySnapshot = await memory.snapshot()
        let session = await agent.snapshot()
        let context = VoiceAgentToolContext(
            sessionID: session.sessionID,
            agentName: name,
            memory: memorySnapshot
        )

        var results: [VoiceAgentToolResult] = []
        results.reserveCapacity(invocations.count)
        for invocation in invocations {
            guard let tool = tools[invocation.name] else {
                throw VoiceAgentError.unknownTool(agentName: name, toolName: invocation.name)
            }
            await emit(
                runID: runID,
                task: task,
                phase: .toolStarted,
                toolName: invocation.name,
                message: "Tool \(invocation.name) started."
            )
            let output = try await tool.call(input: invocation.input, context: context)
            results.append(
                VoiceAgentToolResult(
                    name: invocation.name,
                    input: invocation.input,
                    output: output
                )
            )
            await emit(
                runID: runID,
                task: task,
                phase: .toolFinished,
                toolName: invocation.name,
                message: "Tool \(invocation.name) finished."
            )
        }
        return results
    }

    private func emit(
        runID: UUID,
        task: String,
        phase: VoiceSubAgentEventPhase,
        toolName: String? = nil,
        message: String? = nil
    ) async {
        guard let eventHandler else { return }
        await eventHandler(
            VoiceSubAgentEvent(
                runID: runID,
                agentName: name,
                task: task,
                phase: phase,
                toolName: toolName,
                message: message
            )
        )
    }

    private func availableToolDescriptions() -> [String] {
        tools.values
            .sorted { $0.name < $1.name }
            .map { "\($0.name): \($0.description)" }
    }

    private static func buildPrompt(
        agentName: String,
        purpose: String,
        task: String,
        context: String?,
        memory: VoiceAgentMemorySnapshot,
        tools: [String],
        toolResults: [VoiceAgentToolResult]
    ) -> String {
        var sections: [String] = [
            "Subagent: \(agentName)",
            "Purpose: \(purpose)",
            "Task:\n\(task)",
        ]

        if let context, !context.isEmpty {
            sections.append("Shared context:\n\(context)")
        }

        sections.append("Memory:\n\(memory.rendered)")

        if !tools.isEmpty {
            sections.append("Available tools:\n" + tools.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !toolResults.isEmpty {
            let renderedResults = toolResults
                .map { "- \($0.name)(\($0.input)) -> \($0.output)" }
                .joined(separator: "\n")
            sections.append("Tool results:\n\(renderedResults)")
        }

        sections.append("Return your result for the supervisor. Be concise and include relevant evidence from memory or tools.")
        return sections.joined(separator: "\n\n")
    }
}

public actor VoiceAgentOrchestrator {
    private let supervisor: VoiceAgent
    private var subAgents: [String: VoiceSubAgent]
    private var handles: [UUID: VoiceSubAgentHandle] = [:]

    public init(supervisor: VoiceAgent, subAgents: [VoiceSubAgent]) {
        self.supervisor = supervisor
        self.subAgents = Dictionary(uniqueKeysWithValues: subAgents.map { ($0.name, $0) })
    }

    public func addSubAgent(_ subAgent: VoiceSubAgent) {
        subAgents[subAgent.name] = subAgent
    }

    public func availableSubAgents() -> [String] {
        subAgents.keys.sorted()
    }

    /// `tokio::spawn` 等价：立即派生一个并发 `Task` 跑这次 assignment，
    /// 返回 handle 给 supervisor 持有。Task 在派生瞬间已开始执行，handle
    /// 会被 orchestrator 缓存到 `handles[runID]` 直到 orchestrator 释放，
    /// 以便 supervisor 在整个生命周期内随时读取该 run 的会话/记忆。
    @discardableResult
    public func spawn(_ assignment: VoiceSubAgentAssignment) throws -> VoiceSubAgentHandle {
        guard let subAgent = subAgents[assignment.agentName] else {
            throw VoiceAgentError.unknownSubAgent(assignment.agentName)
        }
        let runID = UUID()
        let runTask = Task<VoiceSubAgentResult, Error> {
            try await subAgent.run(assignment)
        }
        let handle = VoiceSubAgentHandle(
            runID: runID,
            agentName: assignment.agentName,
            task: assignment.task,
            spawnedAt: Date(),
            subAgent: subAgent,
            runTask: runTask
        )
        handles[runID] = handle
        return handle
    }

    public func spawnAll(_ assignments: [VoiceSubAgentAssignment]) throws -> [VoiceSubAgentHandle] {
        try assignments.map { try spawn($0) }
    }

    public func handle(runID: UUID) -> VoiceSubAgentHandle? {
        handles[runID]
    }

    public func handles(forName name: String) -> [VoiceSubAgentHandle] {
        handles.values.filter { $0.agentName == name }
    }

    public func liveHandles() -> [VoiceSubAgentHandle] {
        Array(handles.values)
    }

    public func liveSnapshots() async -> [VoiceSubAgentLiveSnapshot] {
        var out: [VoiceSubAgentLiveSnapshot] = []
        out.reserveCapacity(handles.count)
        for handle in handles.values {
            out.append(await handle.liveSnapshot())
        }
        return out
    }

    public func subAgentSessionSnapshot(name: String) async throws -> VoiceAgentSessionSnapshot {
        guard let subAgent = subAgents[name] else {
            throw VoiceAgentError.unknownSubAgent(name)
        }
        return await subAgent.sessionSnapshot()
    }

    public func subAgentMemorySnapshot(name: String) async throws -> VoiceAgentMemorySnapshot {
        guard let subAgent = subAgents[name] else {
            throw VoiceAgentError.unknownSubAgent(name)
        }
        return await subAgent.memorySnapshot()
    }

    public func cancelAll() async {
        for handle in handles.values {
            await handle.cancel()
        }
    }

    public func run(_ input: String) async throws -> VoiceAgentOrchestrationResult {
        let assignments = subAgents.keys.sorted().map {
            VoiceSubAgentAssignment(agentName: $0, task: input)
        }
        return try await run(input, assignments: assignments)
    }

    public func run(
        _ input: String,
        assignments: [VoiceSubAgentAssignment]
    ) async throws -> VoiceAgentOrchestrationResult {
        let spawned = try spawnAll(assignments)
        let results: [VoiceSubAgentResult]
        do {
            results = try await joinAll(spawned)
        } catch {
            for handle in spawned {
                await handle.cancel()
            }
            throw error
        }
        let sorted = results.sorted { $0.agentName < $1.agentName }

        let finalPrompt = Self.buildSupervisorPrompt(input: input, results: sorted)
        let finalOutput = try await supervisor.send(finalPrompt)
        return VoiceAgentOrchestrationResult(
            input: input,
            finalOutput: finalOutput,
            subAgentResults: sorted,
            supervisorSession: await supervisor.snapshot()
        )
    }

    /// Sequentially `await` each handle. Tasks run concurrently regardless,
    /// so wall time is `max(durations)` — equivalent to tokio's `join_all`.
    private func joinAll(_ spawned: [VoiceSubAgentHandle]) async throws -> [VoiceSubAgentResult] {
        var results: [VoiceSubAgentResult] = []
        results.reserveCapacity(spawned.count)
        for handle in spawned {
            results.append(try await handle.value())
        }
        return results
    }

    private static func buildSupervisorPrompt(
        input: String,
        results: [VoiceSubAgentResult]
    ) -> String {
        let rendered = results.map { result in
            """
            [\(result.agentName)]
            Task: \(result.task)
            Output:
            \(result.output)
            """
        }.joined(separator: "\n\n")

        return """
        User request:
        \(input)

        Subagent results:
        \(rendered)

        Produce the final answer for the user. Resolve disagreements, keep it concise, and preserve useful details.
        """
    }
}

// MARK: - Concurrency limiter

/// Actor-based semaphore that limits concurrent async work.
private actor ConcurrencyLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            running -= 1
        }
    }
}

// MARK: - Agentic Runner (Coda-style recursive tool loop)

private struct SubAgentArgs: Codable {
    var systemprompt: String
    var prompt: String
}

public typealias VoiceAgentToolHandler = @Sendable (String) async throws -> String
public typealias VoiceAgentEventCallback = @Sendable (String) async -> Void

/// Coda-style agentic runner: the LLM decides when to call tools (including
/// spawning sub-agents). Each sub-agent runs the same recursive loop with
/// its own conversation context and full tool access.
public actor VoiceAgentRunner {
    public static let maxDepth = 3
    public static let maxConcurrentCalls = 3

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
        messages.append(.user(userText))
        var working = messages
        let result = try await Self.runAgent(
            messages: &working,
            model: model,
            client: client,
            tools: tools,
            toolHandlers: toolHandlers,
            options: options,
            depth: 0,
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
        limiter: ConcurrencyLimiter,
        onEvent: VoiceAgentEventCallback?
    ) async throws -> String {
        let allTools = depth < maxDepth
            ? tools + [subagentToolDefinition]
            : tools

        while true {
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

        let parsed = try JSONDecoder().decode(SubAgentArgs.self, from: Data(arguments.utf8))
        await onEvent?("[subagent depth=\(depth + 1)] \(String(parsed.prompt.prefix(80)))...")

        var subMessages: [VoiceAgentMessage] = [
            .system(parsed.systemprompt),
            .user(parsed.prompt),
        ]
        return try await runAgent(
            messages: &subMessages,
            model: model,
            client: client,
            tools: tools,
            toolHandlers: toolHandlers,
            options: options,
            depth: depth + 1,
            limiter: limiter,
            onEvent: onEvent
        )
    }

    private static let subagentToolDefinition = OpenAIToolDefinition(
        function: .init(
            name: "subagent",
            description: "Launch an independent sub-agent to handle a subtask. The sub-agent has its own conversation context and access to all tools. Use this when you need to delegate a self-contained task (e.g. research, analysis, or a focused subtask) without polluting the main conversation.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "systemprompt": .object([
                        "type": .string("string"),
                        "description": .string("The system prompt for the sub-agent to follow"),
                    ]),
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("The task description for the sub-agent to complete"),
                    ]),
                ]),
                "required": .array([.string("systemprompt"), .string("prompt")]),
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

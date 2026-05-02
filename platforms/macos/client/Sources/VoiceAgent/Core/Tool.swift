import Foundation

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

/// 子 agent 在结构化任务流（`VoiceSubAgent`/`VoiceAgentOrchestrator`）中调用的工具协议。
/// 与 `VoiceAgentRunner` 中的 OpenAI function-calling 工具是两条不同的链路。
public protocol VoiceAgentTool: Sendable {
    var name: String { get }
    var description: String { get }

    func call(input: String, context: VoiceAgentToolContext) async throws -> String
}

#if DEBUG
import Foundation

private struct MockVoiceAgentClient: VoiceAgentLLMClient {
    var handler: @Sendable (OpenAIChatCompletionRequest) async throws -> VoiceAgentMessage

    func complete(_ request: OpenAIChatCompletionRequest) async throws -> VoiceAgentMessage {
        try await handler(request)
    }
}

enum VoiceAgentSelfTests {
    static func runAll() async throws {
        try testOpenAIRequestEncoding()
        try await testConversationHistory()
        try await testResetKeepsSystemPrompt()
        try await testEmptyResponseError()
    }

    private static func testOpenAIRequestEncoding() throws {
        let request = OpenAIChatCompletionRequest(
            model: "gpt-test",
            messages: [
                .system("You are concise."),
                .user("hello"),
                .tool("lookup result", toolCallID: "call_123"),
            ],
            temperature: 0.2,
            maxTokens: 128,
            stream: false
        )

        let data = try JSONEncoder().encode(request)
        let object = try requireDictionary(from: data)

        try expect(object["model"] as? String == "gpt-test", "model should encode")
        try expect(object["temperature"] as? Double == 0.2, "temperature should encode")
        try expect(object["max_tokens"] as? Int == 128, "max_tokens should encode")
        try expect(object["stream"] as? Bool == false, "stream should encode")

        let messages = try requireArray(object["messages"], "messages should encode")
        let toolMessage = try requireDictionary(messages[2], "tool message should encode")
        try expect(toolMessage["tool_call_id"] as? String == "call_123", "tool_call_id should encode")
    }

    private static func testConversationHistory() async throws {
        let client = MockVoiceAgentClient { request in
            try expect(request.messages.map(\.role) == [.system, .user], "request should include system + user")
            try expect(request.messages.last?.content == "请总结今天的工作", "user text should be forwarded")
            return .assistant("已总结")
        }

        let agent = VoiceAgent(
            model: "gpt-test",
            systemPrompt: "你是语音助手。",
            client: client
        )

        let output = try await agent.send("请总结今天的工作")
        try expect(output == "已总结", "assistant output should return")

        let history = await agent.history()
        try expect(history.map(\.role) == [.system, .user, .assistant], "history should append assistant")
        try expect(history.last?.content == "已总结", "history should store assistant content")
    }

    private static func testResetKeepsSystemPrompt() async throws {
        let client = MockVoiceAgentClient { _ in .assistant("ok") }
        let agent = VoiceAgent(
            model: "gpt-test",
            systemPrompt: "system",
            client: client
        )

        try await agent.send("hello")
        await agent.reset()

        let history = await agent.history()
        try expect(history == [.system("system")], "reset should keep system prompt by default")
    }

    private static func testEmptyResponseError() async throws {
        let data = Data("""
        {
          "id": "chatcmpl-test",
          "object": "chat.completion",
          "created": 0,
          "model": "gpt-test",
          "choices": []
        }
        """.utf8)

        let response = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        try expect(response.choices.isEmpty, "empty choices response should decode")
    }

    private static func requireDictionary(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try requireDictionary(object, "root object should be dictionary")
    }

    private static func requireDictionary(_ value: Any, _ message: String) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else {
            throw SelfTestFailure(message)
        }
        return dictionary
    }

    private static func requireArray(_ value: Any?, _ message: String) throws -> [Any] {
        guard let array = value as? [Any] else {
            throw SelfTestFailure(message)
        }
        return array
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw SelfTestFailure(message)
        }
    }
}

private struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

#if VOICE_AGENT_RUN_TESTS
@main
private enum VoiceAgentTestRunner {
    static func main() async {
        do {
            try await VoiceAgentSelfTests.runAll()
            print("VoiceAgent self-tests passed.")
        } catch {
            fputs("VoiceAgent self-tests failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}
#endif
#endif

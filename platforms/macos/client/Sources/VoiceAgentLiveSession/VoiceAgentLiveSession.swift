import Foundation
import VoiceAgent

@main
enum VoiceAgentLiveSessionRunner {
    static func main() async {
        let runner = VoiceAgentRunner.configuredOpenAI(
            systemPrompt: """
            你是 AhaKey Mode 2 的智能语音助手。
            你可以直接回答简单问题。
            对于复杂任务，你可以使用 subagent 工具派生子 agent 来并行处理子任务。
            子 agent 拥有独立的上下文和完整的工具访问权限。
            回答简洁、直接、有条理。
            """,
            options: VoiceAgentOptions(temperature: 0.3, maxTokens: 2048),
            onEvent: { event in
                print("  \(event)")
            }
        )

        let turns = Array(CommandLine.arguments.dropFirst())
        if !turns.isEmpty {
            for text in turns {
                await send(text, to: runner)
            }
            return
        }

        await runInteractiveSession(runner: runner)
    }

    private static func runInteractiveSession(runner: VoiceAgentRunner) async {
        print("VoiceAgent started (with subagent tool). Type a message, .exit to quit.")
        print("")

        while true {
            print("> ", terminator: "")
            guard let line = readLine(strippingNewline: true) else {
                print("")
                break
            }

            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            switch text {
            case ".exit", ":q", "quit":
                print("Session ended.")
                return
            case ".reset":
                await runner.reset()
                print("Session reset.")
            default:
                await send(text, to: runner)
            }
        }
    }

    private static func send(_ text: String, to runner: VoiceAgentRunner) async {
        do {
            let response = try await runner.send(text)
            print("\n\(response)\n")
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
        }
    }
}

# Voice Agent — 模块深入与扩展指南

> 目标：让你能在 Voice Agent 里**加一个新工具**或**加一个新的 sub-agent**，而不必读完整个模块。

模块位置：`platforms/macos/client/Sources/VoiceAgent/`，对应 SPM target `VoiceAgent`（library）。

## 1. 设计目标

- 一个 **supervisor + 多 sub-agent** 的编排模型，类似 OpenAI Assistants / Anthropic sub-agents。
- 每个 sub-agent 是「角色 + system prompt + 一组工具 + 自己的记忆」。
- 工具用 OpenAI function calling 协议，supervisor 与 sub-agent 共用一套工具协议。
- 会话 / 记忆可序列化，跨次启动恢复。
- 全部跑在本地 Swift 进程，对外只走一个 OpenAI 兼容 endpoint。

## 2. 角色和职责

| 类型 | 文件 | 是什么 |
|------|------|--------|
| `VoiceAgent` | `Agents/VoiceAgent.swift` | Supervisor，`actor`，持有一个 `VoiceAgentRunner` |
| `VoiceSubAgent` | `Agents/VoiceSubAgent.swift` | 子代理，有自己的 system prompt / tools / memory |
| `VoiceAgentOrchestrator` | `Agents/VoiceAgentOrchestrator.swift` | 把 supervisor 的「派发任务」翻译成「派生 sub-agent run」 |
| `VoiceAgentRunner` | `Runner/VoiceAgentRunner.swift` | 执行一次"输入 → LLM → tool → LLM …"循环 |
| `VoiceAgentRunState` | `Runner/VoiceAgentRunState.swift` | 单次 run 的状态机 |
| `ConcurrencyLimiter` | `Runner/ConcurrencyLimiter.swift` | 全局并发限流 |
| `OpenAICompatibleChatClient` | `Networking/LLMClient.swift` | OpenAI 协议 LLM 客户端，默认实现 |

## 3. 工具协议

工具协议在 `Core/Tool.swift`：

```swift
public protocol VoiceAgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema describing the tool's input parameters (OpenAI function calling format).
    var parameters: JSONValue { get }

    func call(input: String, context: VoiceAgentToolContext) async throws -> String
}
```

- `name` / `description` / `parameters` 直接喂给 LLM 做 function calling，runner 调 `openAIDefinition()` 自动转。
- `call(input:context:)` 拿到 LLM 给的 JSON 字符串，**自己负责解析**，返回的字符串再被回灌给 LLM。
- `context` 里能拿到当前 `sessionID` / `agentName` / `memory` 快照，用于工具读上下文。

### 加一个新工具

最小例子：

```swift
import Foundation
import VoiceAgent

public struct EchoTool: VoiceAgentTool {
    public let name = "echo"
    public let description = "Echo back the input text. Useful for sanity checks."
    public let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "text": .object([
                "type": .string("string"),
                "description": .string("Text to echo."),
            ]),
        ]),
        "required": .array([.string("text")]),
    ])

    public init() {}

    public func call(input: String, context: VoiceAgentToolContext) async throws -> String {
        // input 是 LLM 生成的 JSON 字符串，照 parameters schema 解
        let data = Data(input.utf8)
        let parsed = try JSONDecoder().decode([String: String].self, from: data)
        return parsed["text"] ?? ""
    }
}
```

> 不想写自己的类型？直接用 `ClosureVoiceAgentTool(name:description:parameters:handler:)`，单文件搞定原型。

把工具挂到 sub-agent 上（见下一节）。

## 4. 加一个新 sub-agent

参考已有的 `Integrations/FeishuSubAgentFactory.swift`，照同样的「extension VoiceSubAgent + static factory」模式来。

骨架：

```swift
import Foundation

public extension VoiceSubAgent {
    static func mySubAgent(
        llmClient: (any VoiceAgentLLMClient)? = nil,
        model: String = VoiceAgentRuntimeConfig.openAIModel,
        eventHandler: VoiceSubAgentEventHandler? = nil
    ) -> VoiceSubAgent {
        let systemPrompt = """
        # 身份
        你是 …
        # 能力
        - …
        # 执行原则
        - …
        """

        let tools: [any VoiceAgentTool] = [
            EchoTool(),
            // 你的工具
        ]

        return VoiceSubAgent(
            name: "my-agent",
            purpose: "What this sub-agent is for (one sentence; supervisor sees this).",
            model: model,
            systemPrompt: systemPrompt,
            client: llmClient ?? OpenAICompatibleChatClient.configuredOpenAI(),
            tools: tools,
            eventHandler: eventHandler
        )
    }
}
```

然后在 supervisor 那边把它加进 orchestrator：

```swift
let orchestrator = VoiceAgentOrchestrator(
    supervisor: supervisor,
    subAgents: [
        .feishuMessenger(contacts: feishuContacts),
        .mySubAgent(),
    ]
)
```

或者动态加：

```swift
await orchestrator.addSubAgent(.mySubAgent())
```

### Sub-agent 命名约定

- `name`：snake-case 的稳定标识，supervisor 用它来分发任务（如 `"feishu"`、`"my-agent"`）。
- `purpose`：一句话告诉 supervisor 这个 sub-agent 适合干什么 —— supervisor 是靠这句话来决定派发的。**写不清楚 = supervisor 就不会调你**。

### System prompt 模板

看 `FeishuSubAgentFactory.feishuMessenger` 的 prompt 结构：

```
# 身份
# 能力
# 预配置 / 上下文（动态注入）
# 执行原则
  ## 意图判断
  ## 发送流程 / 操作流程
```

这套结构是验证过的，新 sub-agent 直接套用。重点是**意图判断**：必须显式告诉 LLM「只有用户明确要做 X 时才调用工具，否则先确认」，否则模型会瞎调。

## 5. 记忆 (`VoiceAgentMemory`)

`Core/Memory.swift`，actor 包装的 key-value + 自由笔记池：

```swift
await memory.setFact("user_name", value: "Alice")
let name = await memory.fact("user_name")
await memory.remember("用户说他喜欢简短回答")
let snapshot = await memory.snapshot()  // 序列化 / 跨 sub-agent 传递
```

工具 `call` 拿到的是 `VoiceAgentToolContext.memory` 的**快照**，read-only。要写回需要从 sub-agent 自己的 runner 拿真 memory。

## 6. 会话持久化

`Utilities/VoiceAgentSessionStore.swift`（注意：这个在 macOS App target 里，不在 VoiceAgent target —— 因为持久化方式跟平台绑定）：

- 跨次启动恢复 supervisor 会话与 sub-agent 历史。
- 序列化的核心结构是 `VoiceAgentSessionSnapshot` (`Core/Message.swift` 附近)。

加新 sub-agent 一般不用动这一块，session store 是按 sub-agent name 自动归档的。

## 7. 并发与生命周期

- `VoiceAgentOrchestrator.spawn(_:)` 立即起一个 `Task`，返回 `VoiceSubAgentHandle`，handle 缓存在 orchestrator 直到 run 结束。
- `ConcurrencyLimiter` 给全局并发设上限（`Runner/ConcurrencyLimiter.swift`），避免一次性炸出 50 个 sub-agent 同时打 LLM。
- 事件回调通过 `VoiceSubAgentEventHandler`，phase 包括 `started / toolStarted / toolFinished / completed / failed`。UI 想画 timeline 直接订阅。

## 8. 调试

不想跑整个 GUI 验证 voice agent 改动？用 `VoiceAgentLiveSession` 这个独立 executable target：

```bash
swift run VoiceAgentLiveSession
```

它在 `Sources/VoiceAgentLiveSession/`，是个纯 CLI 入口，方便单测 supervisor / sub-agent / 工具，不依赖 SwiftUI。

## 9. 常见陷阱

- **不要在 SwiftUI View 的 `init` 里调 `VoiceRelayService.updateRoutes`** —— `@Published` 一变 view 重建，按住说话状态会被重置。这是已经踩过的坑，注释写在 `AhaKeyStudioView.init`。
- **工具 `parameters` 必须是合法 JSON Schema**，runner 把它原样塞进 OpenAI request；schema 写错 LLM 调用会直接报错。
- **sub-agent 的 `name` 是 supervisor 派发用的 key**，重名后注册会覆盖。
- **lark-cli 是 per-user 状态**，CI / 别人机器上跑测试时不会自动有飞书登录态。

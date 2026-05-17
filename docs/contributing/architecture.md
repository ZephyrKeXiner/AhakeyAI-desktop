# Architecture — 仓库与 macOS 客户端架构

> 目标：在改任何东西之前，先看懂模块边界和数据流。

## 1. 仓库整体

- **双平台并存，目录隔离。** Windows 与 macOS 各自走完全不同的运行时栈，统一仓库但绝不混目录。
  - `platforms/windows/` — Python (PySide6) + .NET BLE bridge + 本地语音组件
  - `platforms/macos/client/` — Swift + SwiftUI + CoreBluetooth，单仓承载
- **源码 only。** 安装包 / DLL / `.dmg` / `.app` 都不进仓库，靠 GitHub Releases 分发。
- **平台级 vs 客户端级 docs**：仓库根 `docs/` 是平台公共文档；`platforms/macos/client/docs/` 放只对 macOS 客户端有意义的（如 BLE 协议）。

## 2. macOS 客户端：双进程结构

```
┌──────────────────────────────┐         ┌───────────────────────────────┐
│  AhaKeyConfig (主进程)        │         │  ahakeyconfig-agent (守护)    │
│  - SwiftUI 全部界面           │         │  - 无 UI                       │
│  - 设备配置 / OLED / 语音助手  │ ──────► │  - LaunchAgent 常驻            │
│  - 通过 CoreBluetooth 直连键盘 │  Unix   │  - 维持 BLE 连接               │
│                              │ socket  │  - 接收 LED 状态命令并写 BLE   │
└──────────────────────────────┘         └───────────────────────────────┘
            │                                          ▲
            │ CoreBluetooth (BLE)                      │
            ▼                                          │
       ┌──────────────┐                                │
       │  AhaKey-X1   │ ◄──── 0x90 命令 LED 状态同步 ──┘
       └──────────────┘
```

守护进程的存在是为了 **GUI 关掉之后，Claude Code / Cursor 的 hook 还能推送 LED 状态**。状态流：

```
Claude Code hook → scripts/ahakey-state.sh → Unix socket
                                          → ahakeyconfig-agent
                                          → BLE 0x90 → 键盘灯条变色
```

## 3. macOS 客户端：Swift Package 结构

`platforms/macos/client/Package.swift` 拆出 5 个 target：

| Target | 类型 | 干嘛的 |
|--------|------|--------|
| `AhaKeyConfig` | executable | App 主体，UI + 业务粘合 |
| `AhaKeyConfigUI` | library | 设计系统 (`AhaKeyDesignSystem`) + Onboarding 资源 |
| `VoiceAgent` | library | Voice Agent 全部逻辑（platform-agnostic Swift） |
| `VoiceAgentLiveSession` | executable | 不带 UI 的 voice agent 调试入口 |
| `AhaKeyConfigAgent` | executable | 后台守护进程二进制 |

按 target 思考依赖很清楚：UI 依赖 `AhaKeyConfigUI` + `VoiceAgent`，守护进程完全独立。

## 4. macOS 客户端：源码分层

```
Sources/
├── AhaKeyConfigApp.swift            App 入口、单实例控制
├── AhaKeyConfigUI/                  设计系统 + Onboarding (library target)
├── Agent/                           守护进程源码 (独立 target)
├── BLE/
│   ├── AhaKeyProtocol.swift         帧编解码 / DeviceCmd / HID 键码表
│   └── AhaKeyBLEManager.swift       CoreBluetooth 通信、自动重连、写队列
├── Models/                          数据模型 (AhaKeyStudioModels 等)
├── Utilities/
│   ├── AgentManager.swift           LaunchAgent 注册 + Claude/Cursor hooks 安装
│   ├── NativeSpeechTranscriptionService.swift  Apple Speech 包装
│   ├── VoiceAssistantModel.swift    UI 侧 voice 模型
│   └── VoiceAgentSessionStore.swift 会话跨次启动持久化
├── Views/                           SwiftUI 视图（见下表）
├── VoiceAgent/                      Voice Agent 核心逻辑 (独立 target)
└── VoiceAgentLiveSession/           Voice Agent 命令行调试入口
```

**关键 View 一览：**

| View | 作用 |
|------|------|
| `AhaKeyRootWorkspaceView` | 顶层路由：`IDE 工作台` ↔ `Agent 工作台` |
| `AhaKeyStudioView` | 主壳子，承载配置台 / 设备信息 / AI 引擎 / 使用数据 / 账号 |
| `AhaKeyWorkbenchView` | Agent 工作台 |
| `AhaKeyKeyConfigPageView` | 键位配置页 |
| `VoiceAgentWorkspaceView` | 语音助手工作区 |
| `VoiceInputFloatingHUD` | 浮动按住说话面板 |
| `LLMConfigView` | LLM endpoint / model / key 配置 |
| `FeishuSetupView` / `FeishuContactsConfigView` | 飞书登录 + 联系人别名管理 |
| `UnifiedTypelessOnboardingView` | 首启 onboarding |

## 5. Voice Agent 模块分层

`Sources/VoiceAgent/` 内部按职责再分层：

```
VoiceAgent/
├── Core/             基础类型：Message / Memory / Tool / JSONValue / Errors / Configuration
├── Agents/           Agent 实体：VoiceAgent (supervisor) / VoiceSubAgent / VoiceAgentOrchestrator
├── Networking/       LLMClient (OpenAI 协议) + OpenAIProtocol
├── Runner/           执行机：VoiceAgentRunner / VoiceAgentRunState / ConcurrencyLimiter
└── Integrations/     具体集成：FeishuClient / FeishuTools / FeishuSubAgentFactory
```

各层依赖向下，**Integrations 可以用 Core / Agents，但 Core 永远不知道飞书的存在**。要加新集成（钉钉、Slack、企微……）就照 `Integrations/Feishu*` 的模式增加文件，不动 Core/Agents。

## 6. 一次语音助手交互的数据流

```
用户按住说话
    │
    ▼
VoiceInputFloatingHUD (UI)
    │  音频帧
    ▼
NativeSpeechTranscriptionService (Apple Speech)
    │  转写文本
    ▼
VoiceAssistantModel
    │
    ▼
VoiceAgent (supervisor, actor)
    │  分发任务
    ▼
VoiceAgentOrchestrator.spawn(assignment)
    │  并发派生 sub-agent run
    ▼
VoiceSubAgent.run(assignment)
    │  LLM function calling
    ▼
LLMClient (OpenAICompatibleChatClient)
    │  tool_call
    ▼
VoiceAgentTool.call(input, context)
    │  例：FeishuSendMessageTool → lark-cli → 飞书 API
    ▼
返回 tool result → 继续 LLM 推理 → 最终回答
    │
    ▼
VoiceAgentSessionStore (持久化会话快照)
```

并发控制由 `ConcurrencyLimiter` 管，sub-agent 跑在独立 `Task` 里，handle 由 orchestrator 缓存到 run 结束。

## 7. Windows 模块关系（保留）

| 模块 | 职责 |
|------|------|
| `desktop-main` | 用户侧主桌面程序，设备配置、订阅交互、调起本地语音 |
| `ble-bridge` | BLE ↔ TCP 桥接，给主客户端用 TCP 接键盘 |
| `hook-installer` | Claude / Cursor hooks 安装、分发、状态桥接脚本 |
| `speech` | 本地语音输入、转写客户端 / 服务端 |

Windows 走的是 Python ↔ .NET ↔ Swift Helper 三层链路；macOS 把这三层全压成一个 Swift 进程。这就是为什么两边目录不能合并。

## 8. 当前边界

- 后端服务 (`wxcloudrun-flask-main/`) 不在本仓库。
- 跨平台 `shared/` 暂未抽出，第一轮只做了占位 README。
- macOS 客户端进入活跃功能开发期；Windows 客户端维持迁入 baseline。

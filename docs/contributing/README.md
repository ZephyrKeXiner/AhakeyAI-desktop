# Contributing — 新贡献者技术文档

这里是给**第一次参与 AhakeyAI/desktop 开发**的同学准备的入口。看完这一组文档，你应该能：

1. 在本机把 macOS 客户端跑起来（或在 Windows 上拉起对应模块）。
2. 看懂仓库当前的整体架构 —— 尤其是这一轮新增的 Voice Agent / 飞书集成。
3. 知道往哪里加代码、怎么提 PR。

## 路径图

| 文档 | 你会读到什么 | 什么时候读 |
|------|--------------|------------|
| [`dev-setup.md`](./dev-setup.md) | 环境要求、构建、签名、调试 | 第一次拉代码 |
| [`architecture.md`](./architecture.md) | 仓库整体架构 + macOS / Windows 模块分层 | 想加新功能前 |
| [`voice-agent.md`](./voice-agent.md) | Voice Agent 模块深入、如何加新工具 / sub-agent | 改 voice agent 相关功能时 |
| [`workflow.md`](./workflow.md) | 分支策略、commit message、PR 流程 | 准备提交代码前 |

## 五分钟上手清单（macOS）

```bash
git clone https://github.com/AhakeyAI/desktop.git
cd desktop/platforms/macos/client

# 1. 构建 + 打包 .app（含图标和签名）
make build

# 2. 安装到 /Applications 并启动
INSTALL_TO_APPLICATIONS=1 LAUNCH_AFTER_INSTALL=1 bash scripts/build.sh
```

第一次构建如果碰到签名 / Bluetooth 权限问题，直接翻 [`dev-setup.md`](./dev-setup.md) 的「常见问题」一节。

## 你应该先认识的几个文件

- [`platforms/macos/client/Package.swift`](../../platforms/macos/client/Package.swift) — Swift 包定义，看清楚有几个 target（`AhaKeyConfig` / `AhaKeyConfigUI` / `VoiceAgent` / `VoiceAgentLiveSession` / `AhaKeyConfigAgent`）。
- [`platforms/macos/client/Sources/VoiceAgent/`](../../platforms/macos/client/Sources/VoiceAgent/) — Voice Agent 模块根目录，按 `Core / Agents / Networking / Runner / Integrations` 分层。
- [`platforms/macos/client/Sources/Views/AhaKeyRootWorkspaceView.swift`](../../platforms/macos/client/Sources/Views/AhaKeyRootWorkspaceView.swift) — UI 根入口，理解从 SwiftUI 一路下钻到哪里。
- [`platforms/macos/client/docs/ble-protocol.md`](../../platforms/macos/client/docs/ble-protocol.md) — BLE 协议完整文档。

## 仓库级文档（旧）

`docs/` 目录还有一组仓库迁入时期的文档（`architecture.md` / `installation.md` / `repo-layout.md` / `roadmap.md` / `status.md` / `supported-platforms.md` / `releases.md`）。这些主要描述「为什么这么拆仓库」「初始状态是什么」，做考古时可以看，但 voice agent 之后的新架构以本目录文档为准。

## 提问 / 反馈

- 有 bug 或 feature request：提 [GitHub Issue](https://github.com/AhakeyAI/desktop/issues)。
- 想讨论架构方向：先在 PR 描述里写清楚，或在 issue 里开讨论。
- 文档有错 / 想补：直接改这一组 markdown，连同代码一起 PR 进来即可。

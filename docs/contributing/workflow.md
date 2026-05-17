# Workflow — 分支、提交、PR

> 目标：让你的代码顺利合进来，不被打回来挑格式。

## 1. 分支模型

```
main      ← 稳定分支，发版来源
 ▲
 │  PR
 │
dev       ← 集成分支，所有 feature 先进这里
 ▲
 │  PR
 │
feat/xxx  ← feature 分支
fix/xxx   ← bug fix 分支
```

- 不要直接往 `main` 推。
- 不要在 `dev` 上直接 commit；从 `dev` 切 `feat/*` 或 `fix/*`，再 PR 回 `dev`。
- 发版时 `dev` → `main`（由 maintainer 操作）。

## 2. Commit message

参考最近的提交：

```
Feat: add VoiceAgent View
Update: enhance the function of subagent
Fix: fix the error of Feishu login
feat: complete basic agent function
```

约定：

- 前缀用 `Feat:` / `Fix:` / `Update:` / `Refactor:` / `Docs:` / `Chore:`（首字母可大可小，目前两种风格都有，**新代码统一小写更友好**）。
- 一句话写「干了什么」，能用英文写英文，中文也接受。
- 多 commit 的工作分多次 commit，不要一个 commit 塞 30 个文件。

不接受：

- `update`、`fix bug`、`改了点东西` 这种没信息量的 message。
- 一个 commit 里既改代码又改无关 lint。

## 3. PR

### 标题

跟 commit 同风格，简洁能看懂：

```
Feat: add Dingtalk sub-agent
Fix: restore push-to-talk state when SwiftUI rebuilds AhaKeyStudioView
```

### 描述（建议结构）

```markdown
## 这次干了什么
- 一句话总结
- 主要改了哪些模块

## 为什么这么改
- 背景 / 触发的问题
- 为什么不选另一种方案（如果有权衡）

## 怎么验证
- 本地跑了什么
- 截图 / 录屏（UI 改动必带）

## 影响范围
- 涉及哪些 target / 哪些 View / 哪些已有功能
- 是否需要重新登录 / 重新签名 / 清缓存
```

### Reviewer 怎么挑

- macOS 改动：找熟 Swift / SwiftUI 的 maintainer
- VoiceAgent 改动：CC 写 voice agent 那批人
- 飞书 / lark-cli 改动：必须实际测发消息，截图发到 PR
- 文档改动：可以 self-merge 但建议至少一个 LGTM

## 4. 代码风格

### Swift / SwiftUI

- 走默认 Swift API 风格，不引外部 linter。
- View 内部 `@State` / `@Binding` / `@StateObject` 用法看现有 `AhaKeyStudioView`。
- 注释鼓励写**为什么**而不是**是什么**。看 `AhaKeyStudioView.init` 那段防"按住说话状态被重置"的注释 —— 这种就是好注释。
- `actor` 用于跨 task 共享可变状态（参考 `VoiceAgent` / `VoiceAgentMemory` / `VoiceAgentOrchestrator`）。
- 公开 API 一律加 `public` 显式标注。

### Python (Windows)

- 跟随原 baseline 风格，不主动重排。
- 新加文件用 PEP 8。

### 不要做的事

- 不要顺手重命名一堆和你的改动无关的符号。
- 不要在功能 PR 里夹杂 import 重排 / 空行整理。
- 不要把构建产物 / 本地配置 / 签名证书加进 commit。看 `.gitignore`，不确定先问。

## 5. CHANGELOG

发版前 maintainer 会在根 `CHANGELOG.md` 新建一节并归档当版改动。日常开发不需要每个 PR 都改 changelog，**但**：

- 大功能 PR 在描述里写一句「适合放进 changelog 的描述」，maintainer 能直接抄。
- 改了对外行为（hotkey、UI 流程、配置 schema 等）尤其要在 PR 描述里点出来。

## 6. 跑得起来 = 才提 PR

提 PR 前最低限度：

- macOS：`make build` 能过；如果改了 voice agent，`swift run VoiceAgentLiveSession` 能跑通你改的路径。
- Windows：对应模块 `python main.py` / 对应 spec 能跑起来。
- 改了 UI：附截图或录屏，不要让 reviewer 自己脑补。

`.github/workflows/release.yml` 是发版工作流，PR 上不强制跑（但发版前会跑）。

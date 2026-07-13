# 飞书快捷操作

AhaKey Studio 的飞书/Lark 后台快捷操作插件。默认不需要开放平台密钥，安装后即可用全局快捷键打开飞书、云文档并粘贴日报或会议纪要模板。

## 默认快捷键

| 快捷键 | 动作 |
| --- | --- |
| `Control+Option+F` | 打开本机 Lark/飞书；未安装时打开网页版 |
| `Control+Option+D` | 打开飞书云文档 |
| `Control+Option+R` | 在当前应用粘贴日报模板 |
| `Control+Option+M` | 在当前应用粘贴会议纪要模板 |
| `Control+Option+,` | 打开插件私密配置文件 |

粘贴动作会更新系统剪贴板并模拟 `Command+V`，因此需要为 AhaKey Studio 开启辅助功能权限。全局快捷键通常还需要输入监控权限。

## 本机配置

首次运行后插件会创建：

```text
~/Library/Application Support/AhaKeyConfig/plugin-data/dev.ahakey.feishu-quick-actions/config.json
```

配置文件权限会收紧为 `0600`。你可以修改快捷键、飞书入口和文本模板，然后调用 `feishu/reloadConfig` 或在插件管理页重启插件。

### 可选群机器人 webhook

在目标飞书群中添加“自定义机器人”，把它的 v2 webhook 填入配置文件的 `webhookUrl`。插件不会把 webhook 写进安装包、日志或仓库。

```json
{
  "webhookUrl": "https://open.feishu.cn/open-apis/bot/v2/hook/你的私密标识"
}
```

自定义机器人只能向其所在群单向推送消息。需要收消息、单聊、管理群或访问云文档时，应改用经过管理员授权的飞书应用机器人。

官方文档：

- <https://open.feishu.cn/document/ukTMukTMukTM/ucTM5YjL3ETO24yNxkjN>
- <https://open.feishu.cn/document/client-docs/bot-v3/bot-overview?lang=zh-CN>

## 插件 RPC

| 方法 | 说明 |
| --- | --- |
| `feishu/listActions` | 列出可用动作 |
| `feishu/getStatus` | 返回 App、配置、webhook 与快捷键状态 |
| `feishu/openApp` | 打开本机飞书/Lark，失败时回退网页版 |
| `feishu/openWeb` | 打开飞书网页版 |
| `feishu/openDocs` | 打开飞书云文档 |
| `feishu/pasteTemplate` | 粘贴 `dailyReport` 或 `meetingNotes` 模板 |
| `feishu/sendWebhook` | 向已配置群机器人发送 `{ text }` |
| `feishu/openConfig` | 用默认编辑器打开配置文件 |
| `feishu/reloadConfig` | 重读配置并重新注册快捷键 |

## 构建和打包

```bash
cd plugins/feishu-quick-actions
npm install
npm run package:plugin
```

安装包输出到 `release/feishu-quick-actions-<version>.ahakeyplugin`。它只包含 manifest、说明和已经打包依赖的单文件 JavaScript，不需要在用户机器上执行 `npm install`，但需要 Node.js 18 或更高版本。

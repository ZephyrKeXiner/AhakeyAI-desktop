# Dev Setup — 开发环境搭建

> 目标：把代码克隆下来到本机能跑起来。

## macOS 客户端（主力开发方向）

### 环境要求

| 项 | 版本 |
|----|------|
| macOS | 14.0+（推荐 15.0+） |
| Xcode | 15+（或等价 Swift toolchain） |
| Swift | 5.9+ |
| 架构 | Apple Silicon（arm64） |
| Bluetooth | 真机调试需开启系统蓝牙 |
| lark-cli | 飞书功能需要（详见下） |

### 克隆 + 构建

```bash
git clone https://github.com/AhakeyAI/desktop.git
cd desktop/platforms/macos/client
```

三种构建方式，按需要选：

```bash
# 仅编译，不打包 .app
swift build -c release --arch arm64 --product AhaKeyConfig

# 编译 + 打包 .app bundle（图标 + 代码签名 + entitlements）
make build           # 等同于 bash scripts/build.sh

# 编译 + 安装到 /Applications + 启动
make install         # 等同于 INSTALL_TO_APPLICATIONS=1 LAUNCH_AFTER_INSTALL=1 bash scripts/build.sh
```

### Debug 构建

`scripts/build-debug.sh` 用单独的 Info.plist，系统「隐私与安全性」里显示为 **AhaKey Studio（调试）**，跟正式包并列存在，TCC 权限互不污染。

```bash
bash scripts/build-debug.sh
```

调试常用：

```bash
# 把当前 dist/ 下的 debug .app 打开到 Xcode 做断点调试
bash scripts/open-xcode-preview.sh
```

### 签名

`scripts/build.sh` 会自动找本机的 Developer ID Application 或 Apple Development 证书。手动指定：

```bash
SIGNING_IDENTITY="你的签名身份" bash scripts/build.sh
```

如果根本没有 Apple 开发者证书，先跑：

```bash
bash scripts/ensure-dev-signing.sh
```

### 本地配置

`scripts/build.local.env.example` 是本地构建变量模板。复制成 `build.local.env` 后可放 `SIGNING_IDENTITY`、`APP_IDENTIFIER` 等覆盖项，不会进 git。

### 飞书功能需要 lark-cli

Voice Agent 的飞书集成通过 `lark-cli` 以**用户自己的身份**发消息。App bundle 内已经内置了 `lark-cli`，但首次使用需要登录：在 App 内进入 *AI 引擎 → 飞书设置 → 登录*。

App 自身不存任何飞书凭证，凭证在 `lark-cli` 本地态里。

### 常见问题

**Bluetooth 权限弹不出来 / CoreBluetooth 报 unauthorized。**
确认 entitlements 里有 `com.apple.security.device.bluetooth`，`scripts/build.sh` 会自动加。如果用 Xcode 直开项目，需要在 Signing & Capabilities 手动加 Bluetooth。

**找不到签名证书。**
`security find-identity -p codesigning -v` 看看本机有什么。要么装个 Apple Development 证书，要么用 ad-hoc 签名（在 `build.local.env` 里 `SIGNING_IDENTITY="-"`）。

**Voice Agent 启动后 LLM 一直转圈。**
进 App 的 *AI 引擎 → LLM 配置*，确认 endpoint / API key 都填了。客户端走 OpenAI 协议，任意兼容后端都行。

**飞书发消息报 lark-cli not logged in。**
进 *AI 引擎 → 飞书设置*，点登录。`lark-cli` 是逐机器 / 逐用户登录的。

---

## Windows 客户端

Windows 端这一轮没大改，按现有 baseline 开发即可。

### 各模块入口

| 模块 | 路径 | 起动方式 |
|------|------|----------|
| desktop-main | `platforms/windows/desktop-main/vibe_code_config_tool/` | `pip install -r requirements.txt` → `python main.py` |
| ble-bridge | `platforms/windows/ble-bridge/BLE_tcp_bridge_for_vibe_code/` | 用 Visual Studio 打开 `BLE_tcp_driver.sln`（.NET Framework 4.7.2） |
| hook-installer | `platforms/windows/hook-installer/vibe_code_hook/` | `python hook_install.py` |
| speech | `platforms/windows/speech/Capswriter/` | `pip install -r requirements.txt` → `python start_server.py` / `python start_client.py` |

### 打包入口

- `KeyboardConfig_onedir.spec` / `KeyboardConfig.spec`（desktop-main，PyInstaller）
- `hook_install.spec`（hook-installer）
- `build.spec`（speech）

历史 Inno Setup 脚本在 `platforms/windows/scripts/inno-setup/`，目前作为留档，不当成正式入口。

### 不进仓库的内容

- 预编译 DLL（Capswriter 用到的本地模型 / 推理运行时）
- 安装器装配目录
- 发布后的 `exe` / `msi` / `dmg` / `.app`
- 签名证书、私钥、token

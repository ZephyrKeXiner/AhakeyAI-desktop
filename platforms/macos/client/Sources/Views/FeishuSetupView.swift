import SwiftUI
import VoiceAgent

/// 飞书集成配置面板：App 凭证 + lark-cli 用户登录 + 联系人管理。
struct FeishuSetupView: View {
    @State private var appID: String = ""
    @State private var appSecret: String = ""
    @State private var larkCLIStatus: LarkCLIStatus = .checking
    @State private var loginURL: String?
    @State private var deviceCode: String?
    @State private var statusMessage: String?
    @State private var statusIsError: Bool = false

    private let keychainService = VoiceAgentRuntimeConfig.keychainService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            credentialsSection
            Divider()
            larkCLISection
            Divider()
            FeishuContactsConfigView()
        }
        .onAppear { loadCredentials(); checkLarkCLI() }
    }

    // MARK: - App 凭证

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("应用凭证")
                .font(.callout.weight(.semibold))

            HStack(spacing: 8) {
                Text("App ID")
                    .frame(width: 80, alignment: .leading)
                TextField("cli_xxxxxxxxx", text: $appID)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }

            HStack(spacing: 8) {
                Text("App Secret")
                    .frame(width: 80, alignment: .leading)
                SecureField("填入 App Secret", text: $appSecret)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }

            HStack {
                Spacer()
                Button("保存凭证") { saveCredentials() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(appID.trimmingCharacters(in: .whitespaces).isEmpty
                        || appSecret.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .secondary)
            }
        }
    }

    // MARK: - lark-cli 用户登录

    private var larkCLISection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("用户登录 (lark-cli)")
                    .font(.callout.weight(.semibold))
                Spacer()
                statusBadge
            }

            switch larkCLIStatus {
            case .checking:
                ProgressView("检查中…")
                    .controlSize(.small)

            case .notInstalled:
                VStack(alignment: .leading, spacing: 6) {
                    Text("未安装 lark-cli，请先在终端执行：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("npm install -g @larksuite/cli")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
                }

            case .notConfigured:
                Text("请先保存 App 凭证，然后点击「配置并登录」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("配置并登录") { configureLarkCLI() }
                    .controlSize(.small)

            case .notLoggedIn:
                if let loginURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("请在浏览器中打开以下链接完成授权：")
                            .font(.caption)
                        Text(loginURL)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
                            .lineLimit(3)

                        HStack {
                            Button("复制链接") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(loginURL, forType: .string)
                            }
                            .controlSize(.small)

                            Button("在浏览器打开") {
                                if let url = URL(string: loginURL) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)

                            Button("授权完成，确认") { completeLogin() }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    Button("开始登录") { startLogin() }
                        .controlSize(.small)
                }

            case .loggedIn(let user):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("已登录: \(user)")
                        .font(.caption)
                }
                Button("重新登录") { startLogin() }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch larkCLIStatus {
        case .loggedIn:
            Text("已登录")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.15)))
                .foregroundStyle(.green)
        case .notLoggedIn, .notConfigured:
            Text("未登录")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
                .foregroundStyle(.orange)
        case .notInstalled:
            Text("未安装")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red.opacity(0.15)))
                .foregroundStyle(.red)
        case .checking:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func loadCredentials() {
        appID = VoiceAgentKeychain.openAIAPIKey(
            service: keychainService,
            account: VoiceAgentRuntimeConfig.keychainFeishuAppIDAccount
        ) ?? ""
        appSecret = VoiceAgentKeychain.openAIAPIKey(
            service: keychainService,
            account: VoiceAgentRuntimeConfig.keychainFeishuAppSecretAccount
        ) ?? ""
    }

    private func saveCredentials() {
        let trimmedID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        let ok1 = VoiceAgentKeychain.saveToKeychain(
            service: keychainService,
            account: VoiceAgentRuntimeConfig.keychainFeishuAppIDAccount,
            value: trimmedID
        )
        let ok2 = VoiceAgentKeychain.saveToKeychain(
            service: keychainService,
            account: VoiceAgentRuntimeConfig.keychainFeishuAppSecretAccount,
            value: trimmedSecret
        )

        if ok1 && ok2 {
            statusMessage = "凭证已保存到 Keychain"
            statusIsError = false
            // 动态加载飞书 subagent
            Task {
                await VoiceAgentSessionStore.shared.reloadFeishuSubAgent()
            }
        } else {
            statusMessage = "保存失败"
            statusIsError = true
        }
    }

    private func checkLarkCLI() {
        Task.detached {
            let path = Self.findLarkCLI()
            guard let path else {
                await MainActor.run { larkCLIStatus = .notInstalled }
                return
            }

            // Check if configured
            let configOutput = Self.runProcess(path, args: ["config", "show"])
            if configOutput.contains("not configured") || configOutput.contains("error") {
                await MainActor.run { larkCLIStatus = .notConfigured }
                return
            }

            // Check auth status
            let authOutput = Self.runProcess(path, args: ["auth", "status"])
            if authOutput.contains("logged_in") || authOutput.contains("user") {
                let user = Self.extractUser(from: authOutput)
                await MainActor.run { larkCLIStatus = .loggedIn(user: user) }
            } else {
                await MainActor.run { larkCLIStatus = .notLoggedIn }
            }
        }
    }

    private func configureLarkCLI() {
        Task.detached {
            guard let path = Self.findLarkCLI() else { return }
            let trimmedID = await appID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSecret = await appSecret.trimmingCharacters(in: .whitespacesAndNewlines)

            // Configure app
            let process = Process()
            let pipe = Pipe()
            let inputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["config", "init", "--app-id", trimmedID, "--app-secret-stdin", "--brand", "feishu"]
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = inputPipe
            try? process.run()
            inputPipe.fileHandleForWriting.write(Data((trimmedSecret + "\n").utf8))
            inputPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()

            await MainActor.run { startLogin() }
        }
    }

    private func startLogin() {
        Task.detached {
            guard let path = Self.findLarkCLI() else { return }

            let output = Self.runProcess(path, args: ["auth", "login", "--domain", "im", "--json", "--no-wait"])

            // Parse device_code and verification_url
            if let data = output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["device_code"] as? String,
               let url = json["verification_url"] as? String {
                await MainActor.run {
                    deviceCode = code
                    loginURL = url
                    larkCLIStatus = .notLoggedIn
                }
            } else {
                await MainActor.run {
                    statusMessage = "启动登录失败: \(output)"
                    statusIsError = true
                }
            }
        }
    }

    private func completeLogin() {
        guard let code = deviceCode else { return }
        Task.detached {
            guard let path = Self.findLarkCLI() else { return }
            let output = Self.runProcess(path, args: ["auth", "login", "--device-code", code])

            if output.contains("授权成功") || output.contains("OK") {
                let user = Self.extractUser(from: output)
                await MainActor.run {
                    larkCLIStatus = .loggedIn(user: user)
                    loginURL = nil
                    deviceCode = nil
                }
                // 登录成功后动态加载飞书 subagent
                await VoiceAgentSessionStore.shared.reloadFeishuSubAgent()
            } else {
                await MainActor.run {
                    statusMessage = "登录失败，请确认已在浏览器完成授权后重试"
                    statusIsError = true
                }
            }
        }
    }

    // MARK: - Helpers

    nonisolated private static func findLarkCLI() -> String? {
        let paths = [
            "/usr/local/bin/lark-cli",
            "/opt/homebrew/bin/lark-cli",
            ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.npm-global/bin/lark-cli" },
        ].compactMap { $0 }
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    nonisolated private static func runProcess(_ execPath: String, args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func extractUser(from output: String) -> String {
        // 尝试从 "用户: xxx (ou_xxx)" 格式提取
        if let range = output.range(of: "用户: ") ?? output.range(of: "user: ") {
            let after = output[range.upperBound...]
            let name = after.prefix(while: { $0 != " " && $0 != "(" && $0 != "\n" })
            if !name.isEmpty { return String(name) }
        }
        return "已授权"
    }
}

// MARK: - Status enum

private enum LarkCLIStatus {
    case checking
    case notInstalled
    case notConfigured
    case notLoggedIn
    case loggedIn(user: String)
}

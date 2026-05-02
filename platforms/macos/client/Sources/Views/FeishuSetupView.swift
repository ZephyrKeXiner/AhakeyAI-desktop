import SwiftUI
import VoiceAgent

/// 飞书集成配置面板：lark-cli 用户登录 + 联系人管理。
/// lark-cli 二进制和 app 凭证均内置于 app bundle，用户只需扫码登录。
struct FeishuSetupView: View {
    @State private var larkCLIStatus: LarkCLIStatus = .checking
    @State private var loginURL: String?
    @State private var deviceCode: String?
    @State private var statusMessage: String?
    @State private var statusIsError: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            larkCLISection
            Divider()
            FeishuContactsConfigView()
        }
        .onAppear { checkLarkCLI() }
    }

    // MARK: - lark-cli 登录状态

    private var larkCLISection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("飞书账号")
                    .font(.callout.weight(.semibold))
                Spacer()
                statusBadge
            }

            switch larkCLIStatus {
            case .checking:
                ProgressView("检查中…")
                    .controlSize(.small)

            case .notInstalled:
                Text("lark-cli 未找到，请联系开发者。")
                    .font(.caption)
                    .foregroundStyle(.red)

            case .notLoggedIn:
                if let loginURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("请在浏览器中打开以下链接，用飞书扫码完成授权：")
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

                            Button("已完成授权") { completeLogin() }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("登录飞书后即可使用语音发消息功能。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("登录飞书") { startLogin() }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    }
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

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .secondary)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch larkCLIStatus {
        case .loggedIn:
            Text("已连接")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.15)))
                .foregroundStyle(.green)
        case .notLoggedIn:
            Text("未登录")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
                .foregroundStyle(.orange)
        case .notInstalled:
            Text("异常")
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

    private func checkLarkCLI() {
        Task.detached {
            guard let path = Self.findLarkCLI() else {
                await MainActor.run { larkCLIStatus = .notInstalled }
                return
            }

            // 确保 lark-cli 已用内置凭证配置
            Self.ensureConfigured(path: path)

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

    private func startLogin() {
        Task.detached {
            guard let path = Self.findLarkCLI() else { return }

            // 确保已配置
            Self.ensureConfigured(path: path)

            // 启动登录，请求 im + contact 权限
            let output = Self.runProcess(path, args: [
                "auth", "login",
                "--scope", "im,contact:user:search",
                "--json", "--no-wait",
            ])

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
                    statusMessage = "启动登录失败: \(output.prefix(200))"
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

            if output.contains("OK") || output.contains("logged_in") || output.contains("success") {
                let user = Self.extractUser(from: output)
                await MainActor.run {
                    larkCLIStatus = .loggedIn(user: user)
                    loginURL = nil
                    deviceCode = nil
                    statusMessage = nil
                    statusIsError = false
                }
            } else {
                await MainActor.run {
                    statusMessage = "登录失败，请确认已在浏览器完成授权后重试"
                    statusIsError = true
                }
            }
        }
    }

    // MARK: - Helpers

    /// 内置的飞书应用凭证。用户无需自行创建应用。
    private static let embeddedAppID = "cli_a97f07e4fd39dcc4"
    private static let embeddedAppSecret = "CX2LgH3QQk5csXWmjAJ6Hgd0MybuZaEz"

    /// 确保 lark-cli 已用内置凭证初始化。
    nonisolated private static func ensureConfigured(path: String) {
        // 检查是否已配置
        let configOutput = runProcess(path, args: ["config", "show"])
        if configOutput.contains(embeddedAppID) {
            return // 已正确配置
        }

        // 用内置凭证初始化
        let process = Process()
        let pipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["config", "init", "--app-id", embeddedAppID, "--app-secret-stdin", "--brand", "feishu"]
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = inputPipe
        do { try process.run() } catch { return }
        inputPipe.fileHandleForWriting.write(Data((embeddedAppSecret + "\n").utf8))
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    }

    nonisolated private static func findLarkCLI() -> String? {
        var paths: [String] = []

        // 优先 app bundle 内置
        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("lark-cli").path,
           FileManager.default.fileExists(atPath: bundlePath) {
            paths.append(bundlePath)
        }

        paths += [
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
        if let range = output.range(of: "user: ") ?? output.range(of: "name: ") {
            let after = output[range.upperBound...]
            let name = after.prefix(while: { $0 != " " && $0 != "(" && $0 != "\n" && $0 != "," })
            if !name.isEmpty { return String(name) }
        }
        return "已授权"
    }
}

// MARK: - Status enum

private enum LarkCLIStatus {
    case checking
    case notInstalled
    case notLoggedIn
    case loggedIn(user: String)
}

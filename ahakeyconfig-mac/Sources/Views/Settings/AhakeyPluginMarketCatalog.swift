import Foundation
import AhaKeyPluginKit

/// 插件市场顶部分段。
enum AhakeyPluginMarketSection: String, CaseIterable, Identifiable, Hashable {
    case mine
    case store

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mine: "我的插件"
        case .store: "开源市场"
        }
    }

    var subtitle: String {
        switch self {
        case .mine: "已装与教程"
        case .store: "发现与贡献"
        }
    }
}

/// 插件市场货架条目（本轮静态目录；后续可接远程商店）。
struct AhakeyPluginMarketItem: Identifiable, Equatable, Hashable {
    enum Status: String, Equatable {
        case inDevelopment
        case example

        var title: String {
            switch self {
            case .inDevelopment: "开发中"
            case .example: "示例"
            }
        }
    }

    let id: String
    let name: String
    let version: String
    let summary: String
    let repoPath: String
    let permissions: [String]
    let status: Status
    let systemImage: String
}

enum AhakeyPluginMarketCatalog {
    /// 本机插件安装目录（与 PluginManifest 约定一致）。
    static let localInstallPathHint = "~/Library/Application Support/AhaKeyConfig/plugins/"

    static let items: [AhakeyPluginMarketItem] = [
        AhakeyPluginMarketItem(
            id: "dev.ahakey.keysilk-keypad",
            name: "KeySilk Portable Keypad",
            version: "0.1.0",
            summary: "便携键区适配器：布局/绑定查询、companion 热键安装，以及 openUrl / pasteText 等宿主动作分发。",
            repoPath: "plugins/keysilk-keypad",
            permissions: [
                "host/getInfo",
                "host/log",
                "host/getSwitchState",
                "host/openUrl",
                "host/openPath",
                "host/pasteText",
                "host/registerGlobalHotkey",
            ],
            status: .inDevelopment,
            systemImage: "keyboard"
        ),
        AhakeyPluginMarketItem(
            id: "dev.ahakey.example.typescript",
            name: "TypeScript Showcase",
            version: "0.1.0",
            summary: "TypeScript SDK 示例：握手宿主、读取设备信息与拨杆状态，适合上手插件开发。",
            repoPath: "sdks/typescript/examples/hello-plugin",
            permissions: [
                "host/getInfo",
                "host/log",
                "host/getSwitchState",
            ],
            status: .example,
            systemImage: "curlybraces"
        ),
        AhakeyPluginMarketItem(
            id: "dev.ahakey.example.lever-counter",
            name: "Lever Counter",
            version: "0.1.0",
            summary: "拨杆翻档计数示例：统计自动/手动档切换次数与停留时长，演示后台轮询与本地快照。",
            repoPath: "sdks/typescript/examples/lever-counter",
            permissions: [
                "host/getInfo",
                "host/log",
                "host/getSwitchState",
            ],
            status: .example,
            systemImage: "switch.2"
        ),
    ]
}

/// 本机插件与正式运行时状态的 UI 投影。
enum AhakeyInstalledPluginsStore {
    struct Discovery {
        let plugins: [InstalledPlugin]
        let errors: [String]
    }

    struct InstalledPlugin: Identifiable, Equatable, Hashable {
        let id: String
        let name: String
        let version: String
        let permissions: [String]
        let directoryPath: String
        let enabled: Bool
        let loaded: Bool
        let methods: [String]
        let error: String?
    }

    static func discover() async -> Discovery {
        let snapshot = await PluginRuntime.shared.snapshot()
        let plugins = snapshot.plugins.map { plugin in
            InstalledPlugin(
                id: plugin.id,
                name: plugin.name,
                version: plugin.version,
                permissions: plugin.permissions,
                directoryPath: plugin.directory.path,
                enabled: plugin.enabled,
                loaded: plugin.loaded,
                methods: plugin.methods,
                error: plugin.error
            )
        }
        return Discovery(plugins: plugins, errors: snapshot.discoveryErrors)
    }
}

// swift-tools-version: 5.9

import PackageDescription
let package = Package(
    name: "AhaKeyConfig",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .executable(name: "AhaKeyConfig", targets: ["AhaKeyConfig"]),
        .executable(name: "AhaKeyNotchSmoke", targets: ["AhaKeyNotchSmoke"]),
        .library(name: "AhaKeyConfigUI", targets: ["AhaKeyConfigUI"]),
        .executable(name: "ahakeyconfig-agent", targets: ["AhaKeyConfigAgent"]),
        .library(name: "VoiceAgent", targets: ["VoiceAgent"]),
        .library(name: "FeishuKit", targets: ["FeishuKit"]),
        .executable(name: "VoiceAgentLiveSession", targets: ["VoiceAgentLiveSession"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.0.0"),
    ],

    targets: [
        .target(
            name: "AhaKeyConfigUI",
            dependencies: [],
            path: "Sources/AhaKeyConfigUI",
            resources: [
                .process("Resources/Onboarding"),
            ]
        ),
        .target(
            name: "VoiceAgent",
            path: "Sources/VoiceAgent"
        ),
        .target(
            name: "FeishuKit",
            dependencies: ["VoiceAgent"],
            path: "Sources/FeishuKit"
        ),
        .executableTarget(
            name: "VoiceAgentLiveSession",
            dependencies: ["VoiceAgent"],
            path: "Sources/VoiceAgentLiveSession"
        ),
        .executableTarget(
            name: "Plugin",
            path: "Sources/AhaKeyPlugin"
        ),
        .executableTarget(
            name: "AhaKeyConfig",
            dependencies: [
                "AhaKeyConfigUI",
                // 启用 VoiceAgent / Feishu 模块时取消下面两行注释，并把下方 exclude 里的 "VoiceAgentUI"、"FeishuKit" 删掉。
                // "VoiceAgent",
                // "FeishuKit",
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
            ],
            path: "Sources",
            exclude: [
                "Agent", "AhaKeyConfigUI", "VoiceAgent", "VoiceAgentLiveSession", "AhaKeyNotchSmoke", "AhaKeyPlugin",
                // VoiceAgent + Feishu 默认不编入主软件：
                "VoiceAgentUI",
                "FeishuKit",
            ],
            // 与 scripts/build.sh 中 Info.plist 一致。嵌入 __info_plist 段后 TCC 可识别。
            // Debug 使用单独 plist：系统在「隐私与安全性」列表中显示为「AhaKey Studio（调试）」，与正式包区分。
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Packaging/AhaKeyConfig-EmbeddedInfo-Debug.plist",
                ], .when(platforms: [.macOS], configuration: .debug)),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Packaging/AhaKeyConfig-EmbeddedInfo.plist",
                ], .when(platforms: [.macOS], configuration: .release)),
            ]
        ),
        .executableTarget(
            name: "AhaKeyConfigAgent",
            path: "Sources/Agent"
        ),
        .executableTarget(
            name: "AhaKeyNotchSmoke",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
            ],
            path: "Sources/AhaKeyNotchSmoke"
        ),
        .testTarget(
            name: "AhaKeyConfigTests",
            dependencies: ["AhaKeyConfig"],
            path: "Tests/AhaKeyConfigTests"
        ),
    ]
)

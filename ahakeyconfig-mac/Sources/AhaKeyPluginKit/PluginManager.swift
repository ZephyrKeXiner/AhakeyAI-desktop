import Foundation

// 扫描插件目录、加载 manifest、拉起所有插件，并管它们的生命周期。
//
// 默认插件目录：
//   ~/Library/Application Support/AhaKeyConfig/plugins/<id>/plugin.json
//
// 可通过环境变量 `AHAKEY_PLUGINS_DIR` 临时覆写（调试用）。
//
// 单个插件加载失败不会影响其他插件 —— 错误写到 stderr，把这个 id 标记为 failed。

public actor PluginManager {
    public struct LoadedPlugin: Sendable {
        public let manifest: PluginManifest
        public let host: PluginHost
        public let initialize: PluginInitializeResult?
    }

    public struct LoadFailure: Sendable {
        public let pluginID: String?
        public let manifestDirectory: URL
        public let error: String
    }

    private let pluginsRoot: URL
    private let appInfo: HostAppInfo
    private var loaded: [String: LoadedPlugin] = [:]
    private(set) public var failures: [LoadFailure] = []

    public init(
        pluginsRoot: URL = PluginManager.defaultPluginsRoot,
        appInfo: HostAppInfo = .current()
    ) {
        self.pluginsRoot = pluginsRoot
        self.appInfo = appInfo
    }

    public static var defaultPluginsRoot: URL {
        if let override = ProcessInfo.processInfo.environment["AHAKEY_PLUGINS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/AhaKeyConfig/plugins",
                isDirectory: true
            )
    }

    // MARK: - Discover

    /// 扫描 `pluginsRoot` 下所有一级子目录，挑出有 `plugin.json` 的。
    /// 不抛错（根目录不存在 → 空数组）。
    public func discover() -> [PluginManifest] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: pluginsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var out: [PluginManifest] = []
        var seenIDs = Set<String>()
        for dir in entries {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            do {
                let manifest = try PluginManifest.load(from: dir)
                guard seenIDs.insert(manifest.id).inserted else {
                    recordFailure(.init(
                        pluginID: manifest.id,
                        manifestDirectory: dir,
                        error: "Duplicate plugin id: \(manifest.id)"
                    ))
                    continue
                }
                out.append(manifest)
            } catch {
                recordFailure(.init(
                    pluginID: nil,
                    manifestDirectory: dir,
                    error: error.localizedDescription
                ))
                FileHandle.standardError.write(
                    Data("[PluginManager] skip \(dir.lastPathComponent): \(error)\n".utf8)
                )
            }
        }
        return out
    }

    // MARK: - Load / Unload

    /// 把发现到的插件全部加载。返回成功数；失败的写到 `failures` 与 stderr。
    @discardableResult
    public func loadAll(excluding disabledPluginIDs: Set<String> = []) async -> Int {
        failures.removeAll()
        let manifests = discover()
        let before = loaded.count
        for m in manifests {
            guard !disabledPluginIDs.contains(m.id) else { continue }
            do {
                try await load(manifest: m)
            } catch {
                recordFailure(.init(
                    pluginID: m.id,
                    manifestDirectory: m.directory,
                    error: error.localizedDescription
                ))
                FileHandle.standardError.write(
                    Data("[PluginManager] load \(m.id) failed: \(error)\n".utf8)
                )
            }
        }
        return loaded.count - before
    }

    public func load(manifest: PluginManifest) async throws {
        if loaded[manifest.id] != nil { return } // 幂等

        try manifest.validateRuntime()
        let unknownPermissions = Set(manifest.permissions)
            .subtracting(Set(PluginHost.availableHostMethods))
        guard unknownPermissions.isEmpty else {
            throw PluginManifestError.invalid(
                "unsupported permissions: \(unknownPermissions.sorted().joined(separator: ", "))"
            )
        }

        let ep = manifest.resolvedEntrypoint
        let client = PluginClient(
            executable: ep.executable,
            arguments: ep.arguments,
            environment: ep.environment,
            workingDirectory: ep.workingDirectory
        )
        let host = PluginHost(
            client: client,
            appInfo: appInfo,
            permissions: Set(manifest.permissions)
        )
        do {
            await host.registerDefaultHandlers()
            await client.setTerminationHandler { [weak self] status in
                Task { await self?.pluginDidTerminate(id: manifest.id, status: status) }
            }
            try await client.start()

            // 握手
            let info = try await client.initialize(
                host: appInfo,
                hostMethods: PluginHost.availableHostMethods
            )
            try await client.sendInitialized()

            loaded[manifest.id] = LoadedPlugin(manifest: manifest, host: host, initialize: info)
        } catch {
            host.cleanup()
            await client.stop(gracePeriod: 0.5)
            throw error
        }
    }

    public func unloadAll() async {
        for id in Array(loaded.keys) {
            await unload(id: id)
        }
    }

    public func unload(id: String) async {
        guard let plugin = loaded.removeValue(forKey: id) else { return }
        await plugin.host.client.shutdown()
        plugin.host.cleanup()
        await plugin.host.client.stop()
    }

    public func reload(id: String) async throws {
        await unload(id: id)
        guard let manifest = discover().first(where: { $0.id == id }) else {
            throw PluginManifestError.invalid("plugin is not installed: \(id)")
        }
        try await load(manifest: manifest)
    }

    // MARK: - 查询

    public func allLoaded() -> [LoadedPlugin] {
        Array(loaded.values)
    }

    public func plugin(id: String) -> LoadedPlugin? {
        loaded[id]
    }

    public func failure(id: String) -> LoadFailure? {
        failures.last { $0.pluginID == id }
    }

    private func pluginDidTerminate(id: String, status: Int32?) {
        guard let plugin = loaded.removeValue(forKey: id) else { return }
        plugin.host.cleanup()
        let detail = status.map { "Plugin process exited with status \($0)" }
            ?? "Plugin process closed its output"
        recordFailure(.init(
            pluginID: id,
            manifestDirectory: plugin.manifest.directory,
            error: detail
        ))
        NotificationCenter.default.post(name: .ahaKeyPluginRuntimeDidChange, object: nil)
    }

    private func recordFailure(_ failure: LoadFailure) {
        guard !failures.contains(where: {
            $0.pluginID == failure.pluginID
                && $0.manifestDirectory == failure.manifestDirectory
                && $0.error == failure.error
        }) else { return }
        failures.append(failure)
    }
}

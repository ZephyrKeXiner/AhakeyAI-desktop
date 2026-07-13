import Foundation

public extension Notification.Name {
    static let ahaKeyPluginRuntimeDidChange = Notification.Name("dev.ahakey.pluginRuntimeDidChange")
}

public enum PluginPreferences {
    private static let disabledIDsKey = "ahakey.plugins.disabledIDs"

    public static var disabledPluginIDs: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: disabledIDsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(newValue.sorted(), forKey: disabledIDsKey)
        }
    }

    public static func isEnabled(id: String) -> Bool {
        !disabledPluginIDs.contains(id)
    }

    public static func setEnabled(_ enabled: Bool, id: String) {
        var ids = disabledPluginIDs
        if enabled {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        disabledPluginIDs = ids
    }

    static func remove(id: String) {
        var ids = disabledPluginIDs
        ids.remove(id)
        disabledPluginIDs = ids
    }
}

public struct PluginRuntimeSnapshot: Sendable {
    public struct Plugin: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let version: String
        public let directory: URL
        public let permissions: [String]
        public let enabled: Bool
        public let loaded: Bool
        public let methods: [String]
        public let error: String?
    }

    public let plugins: [Plugin]
    public let discoveryErrors: [String]
}

/// 正式 App 与插件管理 UI 共享的唯一插件运行时。
public actor PluginRuntime {
    public static let shared = PluginRuntime()

    private let manager: PluginManager
    private var started = false

    public init(manager: PluginManager = PluginManager()) {
        self.manager = manager
    }

    @discardableResult
    public func start() async -> Int {
        guard !started else { return (await manager.allLoaded()).count }
        started = true
        let count = await manager.loadAll(excluding: PluginPreferences.disabledPluginIDs)
        notifyChange()
        return count
    }

    public func stop() async {
        guard started else { return }
        started = false
        await manager.unloadAll()
        notifyChange()
    }

    @discardableResult
    public func reloadAll() async -> Int {
        await manager.unloadAll()
        started = true
        let count = await manager.loadAll(excluding: PluginPreferences.disabledPluginIDs)
        notifyChange()
        return count
    }

    public func setEnabled(_ enabled: Bool, id: String) async {
        PluginPreferences.setEnabled(enabled, id: id)
        if enabled {
            _ = await reloadAll()
        } else {
            await manager.unload(id: id)
            notifyChange()
        }
    }

    public func reload(id: String) async throws {
        try await manager.reload(id: id)
        notifyChange()
    }

    public func install(from sourceURL: URL) async throws {
        let source = sourceURL.standardizedFileURL
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw PluginPackageError.fileNotFound(source)
        }

        if isDirectory.boolValue {
            try await installPluginDirectory(source)
            return
        }
        let supportedExtensions = ["zip", "ahakeyplugin"]
        guard supportedExtensions.contains(source.pathExtension.lowercased()) else {
            throw PluginPackageError.unsupportedFile(source.lastPathComponent)
        }

        let temporaryRoot = fm.temporaryDirectory
            .appendingPathComponent("AhaKeyPluginInstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temporaryRoot) }
        let pluginDirectory = try PluginPackageArchive.extractPluginDirectory(
            from: source,
            to: temporaryRoot
        )
        try await installPluginDirectory(pluginDirectory)
    }

    private func installPluginDirectory(_ sourceDirectory: URL) async throws {
        let source = sourceDirectory.standardizedFileURL
        let manifest = try PluginManifest.load(from: source)
        try manifest.validateRuntime()

        let managerRoot = await manager.installationRoot()
        let root = managerRoot.standardizedFileURL
        let target = root.appendingPathComponent(manifest.id, isDirectory: true)
        let staging = root.appendingPathComponent(
            ".installing-\(manifest.id)-\(UUID().uuidString)",
            isDirectory: true
        )
        let fm = FileManager.default
        guard source != target else {
            throw PluginManifestError.invalid("plugin is already in the install directory")
        }
        guard !fm.fileExists(atPath: target.path) else {
            throw PluginManifestError.invalid("plugin is already installed: \(manifest.id)")
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.copyItem(at: source, to: staging)
            let stagedManifest = try PluginManifest.load(from: staging)
            try stagedManifest.validateRuntime()
            try fm.moveItem(at: staging, to: target)
        } catch {
            throw error
        }

        let installedManifest = try PluginManifest.load(from: target)
        PluginPreferences.setEnabled(true, id: manifest.id)
        do {
            try await manager.load(manifest: installedManifest)
            started = true
            notifyChange()
        } catch {
            PluginPreferences.remove(id: manifest.id)
            try? fm.removeItem(at: target)
            notifyChange()
            throw error
        }
    }

    public func uninstall(id: String) async throws {
        guard let manifest = await manager.discover().first(where: { $0.id == id }) else {
            throw PluginManifestError.invalid("plugin is not installed: \(id)")
        }

        let managerRoot = await manager.installationRoot()
        let root = managerRoot.standardizedFileURL
        let directory = manifest.directory.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard directory.path.hasPrefix(rootPrefix), directory.path != root.path else {
            throw PluginManifestError.invalid("refusing to remove a plugin outside the plugin root")
        }

        await manager.unload(id: id)
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: directory, resultingItemURL: &trashedURL)
        } catch {
            if PluginPreferences.isEnabled(id: id) {
                try? await manager.load(manifest: manifest)
            }
            notifyChange()
            throw error
        }
        PluginPreferences.remove(id: id)
        notifyChange()
    }

    public func call(
        pluginID: String,
        method: String,
        params: JSONValue? = nil,
        timeout: TimeInterval = 10
    ) async throws -> JSONValue {
        guard let plugin = await manager.plugin(id: pluginID) else {
            throw PluginClientError.notRunning
        }
        guard plugin.initialize?.methods?.contains(method) == true else {
            throw JSONRPCError(
                code: JSONRPCError.methodNotFound,
                message: "Plugin \(pluginID) does not expose \(method)"
            )
        }
        return try await plugin.host.client.call(method, params: params, timeout: timeout)
    }

    public func snapshot() async -> PluginRuntimeSnapshot {
        let manifests = await manager.discover()
        let loaded = Dictionary(
            uniqueKeysWithValues: await manager.allLoaded().map { ($0.manifest.id, $0) }
        )
        let failures = await manager.failures

        let plugins: [PluginRuntimeSnapshot.Plugin] = manifests.map { manifest in
            let running = loaded[manifest.id]
            return PluginRuntimeSnapshot.Plugin(
                id: manifest.id,
                name: manifest.name,
                version: manifest.version,
                directory: manifest.directory,
                permissions: manifest.permissions,
                enabled: PluginPreferences.isEnabled(id: manifest.id),
                loaded: running != nil,
                methods: running?.initialize?.methods ?? [],
                error: failures.last(where: { $0.pluginID == manifest.id })?.error
            )
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return PluginRuntimeSnapshot(
            plugins: plugins,
            discoveryErrors: failures
                .filter { $0.pluginID == nil }
                .map { "\($0.manifestDirectory.lastPathComponent): \($0.error)" }
        )
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .ahaKeyPluginRuntimeDidChange, object: nil)
    }
}

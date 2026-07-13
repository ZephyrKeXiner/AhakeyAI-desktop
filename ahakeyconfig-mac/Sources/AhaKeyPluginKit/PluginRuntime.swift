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

public struct PluginInstallPreview: Identifiable, Sendable, Equatable {
    public enum SourceKind: String, Sendable {
        case archive
        case developmentFolder
    }

    public let sourceURL: URL
    public let sourceKind: SourceKind
    public let pluginID: String
    public let name: String
    public let version: String
    public let apiVersion: Int
    public let permissions: [String]
    public let packageSHA256: String?
    public let installedVersion: String?
    public let installedEnabled: Bool?

    public var isUpdate: Bool { installedVersion != nil }

    public var id: String {
        [sourceURL.path, pluginID, version, packageSHA256 ?? "folder"].joined(separator: "|")
    }

    fileprivate func matches(_ manifest: PluginManifest, packageSHA256: String?) -> Bool {
        pluginID == manifest.id
            && name == manifest.name
            && version == manifest.version
            && apiVersion == manifest.apiVersion
            && permissions == manifest.permissions
            && self.packageSHA256 == packageSHA256
    }
}

private struct PluginSemanticVersion: Comparable {
    private enum Identifier: Equatable {
        case numeric(Int)
        case text(String)
    }

    private let core: [Int]
    private let prerelease: [Identifier]?

    init?(_ rawValue: String) {
        let withoutBuild = rawValue.split(separator: "+", maxSplits: 1).first.map(String.init) ?? rawValue
        let versionParts = withoutBuild.split(separator: "-", maxSplits: 1).map(String.init)
        let core = versionParts[0].split(separator: ".").compactMap { Int($0) }
        guard core.count == 3 else { return nil }
        self.core = core
        if versionParts.count == 2 {
            prerelease = versionParts[1].split(separator: ".").map { part in
                Int(part).map(Identifier.numeric) ?? .text(String(part))
            }
        } else {
            prerelease = nil
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0 ..< 3 where lhs.core[index] != rhs.core[index] {
            return lhs.core[index] < rhs.core[index]
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case let (.some(lhsParts), .some(rhsParts)):
            for (lhsPart, rhsPart) in zip(lhsParts, rhsParts) where lhsPart != rhsPart {
                switch (lhsPart, rhsPart) {
                case let (.numeric(lhsValue), .numeric(rhsValue)):
                    return lhsValue < rhsValue
                case (.numeric, .text):
                    return true
                case (.text, .numeric):
                    return false
                case let (.text(lhsValue), .text(rhsValue)):
                    return lhsValue < rhsValue
                }
            }
            return lhsParts.count < rhsParts.count
        }
    }
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

    public func previewInstallation(from sourceURL: URL) async throws -> PluginInstallPreview {
        let source = sourceURL.standardizedFileURL
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw PluginPackageError.fileNotFound(source)
        }

        if isDirectory.boolValue {
            let manifest = try PluginManifest.load(from: source)
            try manifest.validateRuntime()
            try PluginManager.validateHostPermissions(manifest)
            return try await makeInstallPreview(
                sourceURL: source,
                sourceKind: .developmentFolder,
                manifest: manifest,
                packageSHA256: nil
            )
        }
        let supportedExtensions = ["zip", "ahakeyplugin"]
        guard supportedExtensions.contains(source.pathExtension.lowercased()) else {
            throw PluginPackageError.unsupportedFile(source.lastPathComponent)
        }

        let temporaryRoot = fm.temporaryDirectory
            .appendingPathComponent("AhaKeyPluginPreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temporaryRoot) }
        let extracted = try PluginPackageArchive.extractPluginDirectory(
            from: source,
            to: temporaryRoot
        )
        let manifest = try PluginManifest.load(from: extracted.directory)
        try manifest.validateRuntime()
        try PluginManager.validateHostPermissions(manifest)
        return try await makeInstallPreview(
            sourceURL: source,
            sourceKind: .archive,
            manifest: manifest,
            packageSHA256: extracted.sha256
        )
    }

    private func makeInstallPreview(
        sourceURL: URL,
        sourceKind: PluginInstallPreview.SourceKind,
        manifest: PluginManifest,
        packageSHA256: String?
    ) async throws -> PluginInstallPreview {
        let installed = await manager.discover().first(where: { $0.id == manifest.id })
        if let installed {
            guard let currentVersion = PluginSemanticVersion(installed.version),
                  let candidateVersion = PluginSemanticVersion(manifest.version),
                  candidateVersion > currentVersion else {
                throw PluginPackageError.versionNotNewer(
                    installed: installed.version,
                    candidate: manifest.version
                )
            }
        }
        return PluginInstallPreview(
            sourceURL: sourceURL,
            sourceKind: sourceKind,
            pluginID: manifest.id,
            name: manifest.name,
            version: manifest.version,
            apiVersion: manifest.apiVersion,
            permissions: manifest.permissions,
            packageSHA256: packageSHA256,
            installedVersion: installed?.version,
            installedEnabled: installed.map { PluginPreferences.isEnabled(id: $0.id) }
        )
    }

    public func install(from sourceURL: URL, approved preview: PluginInstallPreview) async throws {
        let source = sourceURL.standardizedFileURL
        guard source == preview.sourceURL.standardizedFileURL else {
            throw PluginPackageError.packageChanged
        }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw PluginPackageError.fileNotFound(source)
        }
        if isDirectory.boolValue {
            guard preview.sourceKind == .developmentFolder else {
                throw PluginPackageError.packageChanged
            }
            try await installPluginDirectory(
                source,
                approved: preview,
                packageSHA256: nil
            )
            return
        }

        guard preview.sourceKind == .archive, let expectedSHA256 = preview.packageSHA256 else {
            throw PluginPackageError.packageChanged
        }
        let supportedExtensions = ["zip", "ahakeyplugin"]
        guard supportedExtensions.contains(source.pathExtension.lowercased()) else {
            throw PluginPackageError.unsupportedFile(source.lastPathComponent)
        }
        let temporaryRoot = fm.temporaryDirectory
            .appendingPathComponent("AhaKeyPluginInstall-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temporaryRoot) }
        let extracted = try PluginPackageArchive.extractPluginDirectory(
            from: source,
            to: temporaryRoot,
            expectedSHA256: expectedSHA256
        )
        try await installPluginDirectory(
            extracted.directory,
            approved: preview,
            packageSHA256: extracted.sha256
        )
    }

    private func installPluginDirectory(
        _ sourceDirectory: URL,
        approved preview: PluginInstallPreview,
        packageSHA256: String?
    ) async throws {
        let source = sourceDirectory.standardizedFileURL
        let manifest = try PluginManifest.load(from: source)
        try manifest.validateRuntime()
        try PluginManager.validateHostPermissions(manifest)
        guard preview.matches(manifest, packageSHA256: packageSHA256) else {
            throw PluginPackageError.packageChanged
        }

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

        let existingManifest = fm.fileExists(atPath: target.path)
            ? try PluginManifest.load(from: target)
            : nil
        let existingEnabled = existingManifest.map { PluginPreferences.isEnabled(id: $0.id) }
        guard preview.installedVersion == existingManifest?.version,
              preview.installedEnabled == existingEnabled else {
            throw PluginPackageError.packageChanged
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        let stagedManifest = try PluginManifest.load(from: staging)
        try stagedManifest.validateRuntime()
        try PluginManager.validateHostPermissions(stagedManifest)
        guard preview.matches(stagedManifest, packageSHA256: packageSHA256) else {
            throw PluginPackageError.packageChanged
        }

        if let existingEnabled {
            try await updatePlugin(
                id: manifest.id,
                stagedAt: staging,
                target: target,
                wasEnabled: existingEnabled
            )
        } else {
            try await activateNewPlugin(id: manifest.id, stagedAt: staging, target: target)
        }
    }

    private func activateNewPlugin(id: String, stagedAt staging: URL, target: URL) async throws {
        let fm = FileManager.default
        var movedToTarget = false
        do {
            try fm.moveItem(at: staging, to: target)
            movedToTarget = true
            let installedManifest = try PluginManifest.load(from: target)
            PluginPreferences.setEnabled(true, id: id)
            try await manager.load(manifest: installedManifest)
            started = true
            notifyChange()
        } catch {
            PluginPreferences.remove(id: id)
            if movedToTarget { try? fm.removeItem(at: target) }
            notifyChange()
            throw error
        }
    }

    private func updatePlugin(
        id: String,
        stagedAt staging: URL,
        target: URL,
        wasEnabled: Bool
    ) async throws {
        let fm = FileManager.default
        let backup = target.deletingLastPathComponent().appendingPathComponent(
            ".backup-\(id)-\(UUID().uuidString)",
            isDirectory: true
        )
        var oldMoved = false
        var newMoved = false

        await manager.unload(id: id)
        do {
            try fm.moveItem(at: target, to: backup)
            oldMoved = true
            try fm.moveItem(at: staging, to: target)
            newMoved = true

            let installedManifest = try PluginManifest.load(from: target)
            PluginPreferences.setEnabled(wasEnabled, id: id)
            if wasEnabled {
                try await manager.load(manifest: installedManifest)
                started = true
            }
            try? fm.removeItem(at: backup)
            notifyChange()
        } catch {
            let updateError = error
            await manager.unload(id: id)
            var rollbackErrors: [String] = []

            if newMoved {
                do {
                    try fm.removeItem(at: target)
                } catch {
                    rollbackErrors.append("remove failed version: \(error.localizedDescription)")
                }
            }
            if oldMoved {
                do {
                    try fm.moveItem(at: backup, to: target)
                } catch {
                    rollbackErrors.append("restore old files: \(error.localizedDescription)")
                }
            }

            PluginPreferences.setEnabled(wasEnabled, id: id)
            if wasEnabled, fm.fileExists(atPath: target.path) {
                do {
                    let restoredManifest = try PluginManifest.load(from: target)
                    try await manager.load(manifest: restoredManifest)
                    started = true
                } catch {
                    rollbackErrors.append("restart old version: \(error.localizedDescription)")
                }
            }
            notifyChange()

            if rollbackErrors.isEmpty {
                throw updateError
            }
            throw PluginPackageError.rollbackFailed(
                updateError: updateError.localizedDescription,
                rollbackError: rollbackErrors.joined(separator: "; ")
            )
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

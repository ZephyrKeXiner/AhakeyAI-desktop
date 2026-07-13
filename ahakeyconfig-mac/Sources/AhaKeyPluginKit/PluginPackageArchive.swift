import Foundation

public enum PluginPackageError: Error, Sendable {
    case fileNotFound(URL)
    case unsupportedFile(String)
    case archiveTooLarge(actual: Int, max: Int)
    case tooManyEntries(actual: Int, max: Int)
    case unsafeEntry(String)
    case extractionFailed(String)
    case expandedPackageTooLarge(actual: Int64, max: Int64)
    case symbolicLinkNotAllowed(String)
    case manifestNotFound
    case multipleManifests(Int)
}

extension PluginPackageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "插件包不存在：\(url.path)"
        case .unsupportedFile(let name):
            return "不支持的插件文件：\(name)。请选择 .zip 或 .ahakeyplugin。"
        case .archiveTooLarge(let actual, let max):
            return "插件包过大（\(Self.byteCount(actual))），上限为 \(Self.byteCount(max))。"
        case .tooManyEntries(let actual, let max):
            return "插件包包含 \(actual) 个文件，超过上限 \(max)。"
        case .unsafeEntry(let entry):
            return "插件包包含不安全路径：\(entry)"
        case .extractionFailed(let detail):
            return "无法解压插件包：\(detail)"
        case .expandedPackageTooLarge(let actual, let max):
            return "插件解压后过大（\(Self.byteCount(actual))），上限为 \(Self.byteCount(max))。"
        case .symbolicLinkNotAllowed(let path):
            return "插件包不允许包含符号链接：\(path)"
        case .manifestNotFound:
            return "插件包中没有找到 plugin.json。"
        case .multipleManifests(let count):
            return "插件包中找到 \(count) 个 plugin.json；一个安装包只能包含一个插件。"
        }
    }

    private static func byteCount<T: BinaryInteger>(_ value: T) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}

/// `.zip` / `.ahakeyplugin` 安装包的最小安全解包器。
///
/// 解包前检查路径穿越，解包后限制文件数量、总大小和符号链接，并要求唯一的 plugin.json。
enum PluginPackageArchive {
    static let maxArchiveBytes = 100 * 1024 * 1024
    static let maxEntryCount = 10_000
    static let maxExpandedBytes: Int64 = 500 * 1024 * 1024

    static func extractPluginDirectory(from archive: URL, to destination: URL) throws -> URL {
        let fm = FileManager.default
        let source = archive.standardizedFileURL
        guard fm.fileExists(atPath: source.path) else {
            throw PluginPackageError.fileNotFound(source)
        }

        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw PluginPackageError.unsupportedFile(source.lastPathComponent)
        }
        if let size = values.fileSize, size > maxArchiveBytes {
            throw PluginPackageError.archiveTooLarge(actual: size, max: maxArchiveBytes)
        }

        let listingData = try runTool(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", source.path]
        )
        guard let listing = String(data: listingData, encoding: .utf8) else {
            throw PluginPackageError.extractionFailed("文件列表不是有效的 UTF-8。")
        }
        let entries = listing.split(whereSeparator: \.isNewline).map(String.init)
        guard entries.count <= maxEntryCount else {
            throw PluginPackageError.tooManyEntries(actual: entries.count, max: maxEntryCount)
        }
        for entry in entries {
            try validateEntryPath(entry)
        }

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try runTool(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", source.path, destination.path]
        )

        return try inspectExtractedPackage(at: destination)
    }

    static func validateEntryPath(_ entry: String) throws {
        let normalized = entry.replacingOccurrences(of: "\\", with: "/")
        let withoutTrailingSlash = normalized.hasSuffix("/")
            ? String(normalized.dropLast())
            : normalized
        guard !withoutTrailingSlash.isEmpty,
              withoutTrailingSlash.utf8.count <= 1_024,
              !withoutTrailingSlash.hasPrefix("/"),
              !withoutTrailingSlash.contains("\0") else {
            throw PluginPackageError.unsafeEntry(entry)
        }

        let components = withoutTrailingSlash.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw PluginPackageError.unsafeEntry(entry)
        }
        if let first = components.first,
           String(first).range(of: #"^[A-Za-z]:$"#, options: .regularExpression) != nil {
            throw PluginPackageError.unsafeEntry(entry)
        }
    }

    private static func inspectExtractedPackage(at root: URL) throws -> URL {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw PluginPackageError.extractionFailed("无法遍历解压目录。")
        }

        var count = 0
        var expandedBytes: Int64 = 0
        var manifests: [URL] = []
        for case let url as URL in enumerator {
            count += 1
            guard count <= maxEntryCount else {
                throw PluginPackageError.tooManyEntries(actual: count, max: maxEntryCount)
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw PluginPackageError.symbolicLinkNotAllowed(url.path)
            }
            if values.isRegularFile == true {
                expandedBytes += Int64(values.fileSize ?? 0)
                guard expandedBytes <= maxExpandedBytes else {
                    throw PluginPackageError.expandedPackageTooLarge(
                        actual: expandedBytes,
                        max: maxExpandedBytes
                    )
                }
                if url.lastPathComponent == "plugin.json" {
                    manifests.append(url)
                }
            }
        }

        guard !manifests.isEmpty else {
            throw PluginPackageError.manifestNotFound
        }
        guard manifests.count == 1 else {
            throw PluginPackageError.multipleManifests(manifests.count)
        }
        return manifests[0].deletingLastPathComponent()
    }

    private static func runTool(executable: URL, arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw PluginPackageError.extractionFailed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.flatMap { $0.isEmpty ? nil : $0 }
                ?? "工具退出码 \(process.terminationStatus)"
            throw PluginPackageError.extractionFailed(message)
        }
        return data
    }
}

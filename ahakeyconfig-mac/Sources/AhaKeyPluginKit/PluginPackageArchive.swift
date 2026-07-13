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

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)

        // 后续检查与解压只使用私有快照，避免源文件在预检和解压之间被替换。
        let snapshot = destination.appendingPathComponent("package.zip")
        try fm.copyItem(at: source, to: snapshot)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: snapshot.path)
        let snapshotSize = try snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard snapshotSize <= maxArchiveBytes else {
            throw PluginPackageError.archiveTooLarge(actual: snapshotSize, max: maxArchiveBytes)
        }

        try preflightArchive(at: snapshot)

        let payload = destination.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: false)
        _ = try runTool(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", snapshot.path, payload.path]
        )

        return try inspectExtractedPackage(at: payload)
    }

    private static func preflightArchive(at archive: URL) throws {
        let namesData = try runTool(
            executable: URL(fileURLWithPath: "/usr/bin/zipinfo"),
            arguments: ["-1", archive.path]
        )
        let metadataData = try runTool(
            executable: URL(fileURLWithPath: "/usr/bin/zipinfo"),
            arguments: ["-lT", archive.path]
        )
        guard let namesOutput = String(data: namesData, encoding: .utf8),
              let metadataOutput = String(data: metadataData, encoding: .utf8) else {
            throw PluginPackageError.extractionFailed("文件列表不是有效的 UTF-8。")
        }

        let entries = namesOutput.split(whereSeparator: \.isNewline).map(String.init)
        let metadataLines = metadataOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                line.range(
                    of: #"^[bcdlps-][rwxStTs-]{9}\s"#,
                    options: .regularExpression
                ) != nil
            }
        guard entries.count == metadataLines.count else {
            throw PluginPackageError.extractionFailed("无法可靠读取插件包条目元数据。")
        }
        guard entries.count <= maxEntryCount else {
            throw PluginPackageError.tooManyEntries(actual: entries.count, max: maxEntryCount)
        }

        var expandedBytes: Int64 = 0
        var canonicalPaths = Set<String>()
        for (entry, metadataLine) in zip(entries, metadataLines) {
            try validateEntryPath(entry)

            let canonicalPath = entry
                .replacingOccurrences(of: "\\", with: "/")
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard canonicalPaths.insert(canonicalPath).inserted else {
                throw PluginPackageError.unsafeEntry("重复或大小写冲突：\(entry)")
            }

            let columns = metadataLine.split(
                separator: " ",
                maxSplits: 8,
                omittingEmptySubsequences: true
            )
            guard columns.count == 9, let size = Int64(columns[3]) else {
                throw PluginPackageError.extractionFailed("无法解析条目元数据：\(entry)")
            }
            let mode = columns[0]
            if mode.first == "l" {
                throw PluginPackageError.symbolicLinkNotAllowed(entry)
            }
            guard mode.first == "-" || mode.first == "d" else {
                throw PluginPackageError.unsafeEntry("不支持的文件类型：\(entry)")
            }

            let (nextSize, overflow) = expandedBytes.addingReportingOverflow(size)
            guard !overflow, nextSize <= maxExpandedBytes else {
                throw PluginPackageError.expandedPackageTooLarge(
                    actual: overflow ? Int64.max : nextSize,
                    max: maxExpandedBytes
                )
            }
            expandedBytes = nextSize
        }
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

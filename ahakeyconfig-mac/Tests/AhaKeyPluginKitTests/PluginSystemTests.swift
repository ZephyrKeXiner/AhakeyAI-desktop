import Foundation
import XCTest
@testable import AhaKeyPluginKit

final class PluginSystemTests: XCTestCase {
    func testManifestDefaultsAPIVersionAndMergesExecutablePath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeManifest(
            to: root,
            id: "dev.ahakey.tests.valid",
            command: "/bin/sh",
            permissions: ["host/log"]
        )

        let manifest = try PluginManifest.load(from: root)
        XCTAssertEqual(manifest.apiVersion, PluginManifest.supportedAPIVersion)
        XCTAssertTrue(manifest.resolvedEntrypoint.environment?["PATH"]?.contains("/usr/bin") == true)
        XCTAssertNoThrow(try manifest.validateRuntime())
    }

    func testManifestRejectsUnsafeIDAndUnsupportedAPIVersion() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeManifest(to: root, id: "../escape", command: "/bin/sh")
        XCTAssertThrowsError(try PluginManifest.load(from: root))

        try writeManifest(
            to: root,
            id: "dev.ahakey.tests.future",
            command: "/bin/sh",
            apiVersion: PluginManifest.supportedAPIVersion + 1
        )
        XCTAssertThrowsError(try PluginManifest.load(from: root))
    }

    func testArchiveEntryValidationRejectsPathTraversal() {
        XCTAssertNoThrow(try PluginPackageArchive.validateEntryPath("hello-plugin/dist/main.js"))
        for entry in ["../escape", "plugin/../escape", "/tmp/escape", "C:/escape", "plugin//main.js"] {
            XCTAssertThrowsError(try PluginPackageArchive.validateEntryPath(entry), entry)
        }
    }

    func testArchiveRejectsSymbolicLinksBeforeExtraction() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("symlink-package", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try writeManifest(to: package, id: "dev.ahakey.tests.symlink", command: "/bin/sh")
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("outside"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )

        let archive = root.appendingPathComponent("symlink.ahakeyplugin")
        let extractionRoot = root.appendingPathComponent("extracted", isDirectory: true)
        try createArchive(of: package, at: archive)

        XCTAssertThrowsError(
            try PluginPackageArchive.extractPluginDirectory(from: archive, to: extractionRoot)
        ) { error in
            XCTAssertTrue(error is PluginPackageError)
            XCTAssertTrue(error.localizedDescription.contains("符号链接"))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: extractionRoot.appendingPathComponent("payload").path
            )
        )
    }

    func testRuntimeInstallsNestedPluginArchive() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = root.appendingPathComponent("fixture-package", isDirectory: true)
        let installRoot = root.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let script = package.appendingPathComponent("plugin.sh")
        let scriptBody = #"""
        while IFS= read -r line; do
          case "$line" in
            *plugin*initialize*)
              printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"name":"Archive Fixture","version":"0.1.0","methods":[]}}'
              ;;
            *plugin*shutdown*)
              printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":null}'
              ;;
            *plugin*exit*) exit 0 ;;
          esac
        done
        """#
        try Data(scriptBody.utf8).write(to: script)
        try writeManifest(
            to: package,
            id: "dev.ahakey.tests.archive",
            command: "/bin/sh",
            args: ["${pluginDir}/plugin.sh"]
        )

        let archive = root.appendingPathComponent("fixture.ahakeyplugin")
        try createArchive(of: package, at: archive)

        let runtime = PluginRuntime(manager: PluginManager(pluginsRoot: installRoot))
        do {
            let preview = try await runtime.previewInstallation(from: archive)
            XCTAssertEqual(preview.pluginID, "dev.ahakey.tests.archive")
            XCTAssertEqual(preview.packageSHA256?.count, 64)
            try await runtime.install(from: archive, approved: preview)
            let snapshot = await runtime.snapshot()
            XCTAssertEqual(snapshot.plugins.map(\.id), ["dev.ahakey.tests.archive"])
            XCTAssertEqual(snapshot.plugins.first?.loaded, true)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: installRoot
                        .appendingPathComponent("dev.ahakey.tests.archive/plugin.json")
                        .path
                )
            )
        } catch {
            await runtime.stop()
            throw error
        }
        await runtime.stop()
    }

    func testRuntimeRejectsDirectManifestFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package", isDirectory: true)
        let installRoot = root.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try writeManifest(to: package, id: "dev.ahakey.tests.direct", command: "/bin/sh")
        try Data("must not be copied".utf8).write(to: package.appendingPathComponent("secret.txt"))

        let runtime = PluginRuntime(manager: PluginManager(pluginsRoot: installRoot))
        do {
            _ = try await runtime.previewInstallation(
                from: package.appendingPathComponent("plugin.json")
            )
            XCTFail("direct plugin.json installation should be rejected")
        } catch is PluginPackageError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot.path))
    }

    func testRuntimeRejectsArchiveChangedAfterApproval() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package", isDirectory: true)
        let installRoot = root.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try writeManifest(to: package, id: "dev.ahakey.tests.changed", command: "/bin/sh")
        let archive = root.appendingPathComponent("changed.ahakeyplugin")
        try createArchive(of: package, at: archive)

        let runtime = PluginRuntime(manager: PluginManager(pluginsRoot: installRoot))
        let preview = try await runtime.previewInstallation(from: archive)
        let handle = try FileHandle(forWritingTo: archive)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("changed".utf8))
        try handle.close()

        do {
            try await runtime.install(from: archive, approved: preview)
            XCTFail("changed archive should require a new approval")
        } catch let error as PluginPackageError {
            XCTAssertEqual(error.localizedDescription, PluginPackageError.packageChanged.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot.path))
    }

    func testRuntimeRollsBackWhenPluginCannotLoad() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package", isDirectory: true)
        let installRoot = root.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try writeManifest(
            to: package,
            id: "dev.ahakey.tests.load-failure",
            command: "/bin/false"
        )

        let runtime = PluginRuntime(manager: PluginManager(pluginsRoot: installRoot))
        do {
            let preview = try await runtime.previewInstallation(from: package)
            try await runtime.install(from: package, approved: preview)
            XCTFail("a plugin that exits during startup should fail installation")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installRoot.appendingPathComponent("dev.ahakey.tests.load-failure").path
            )
        )
        if FileManager.default.fileExists(atPath: installRoot.path) {
            let installEntries = try FileManager.default.contentsOfDirectory(atPath: installRoot.path)
            XCTAssertTrue(installEntries.isEmpty, "failed install must not leave a staging directory")
        }
        let snapshot = await runtime.snapshot()
        XCTAssertTrue(snapshot.plugins.isEmpty)
    }

    func testManagerLoadsAndUnloadsAStdioPlugin() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)

        let script = plugin.appendingPathComponent("plugin.sh")
        let scriptBody = #"""
        while IFS= read -r line; do
          case "$line" in
            *plugin*initialize*)
              printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"name":"Fixture","version":"0.1.0","methods":["fixture/ping"]}}'
              ;;
            *plugin*shutdown*)
              printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":null}'
              ;;
            *plugin*exit*) exit 0 ;;
          esac
        done
        """#
        try Data(scriptBody.utf8).write(to: script)

        try writeManifest(
            to: plugin,
            id: "dev.ahakey.tests.fixture",
            command: "/bin/sh",
            args: ["${pluginDir}/plugin.sh"]
        )

        let manager = PluginManager(pluginsRoot: root)
        let count = await manager.loadAll()
        XCTAssertEqual(count, 1)
        let loaded = await manager.plugin(id: "dev.ahakey.tests.fixture")
        XCTAssertEqual(loaded?.initialize?.methods, ["fixture/ping"])

        await manager.unloadAll()
        let remaining = await manager.allLoaded()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testManagerRejectsUnknownHostPermission() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try writeManifest(
            to: plugin,
            id: "dev.ahakey.tests.permission",
            command: "/bin/sh",
            permissions: ["host/notReal"]
        )

        let manager = PluginManager(pluginsRoot: root)
        let count = await manager.loadAll()
        XCTAssertEqual(count, 0)
        let failure = await manager.failure(id: "dev.ahakey.tests.permission")
        XCTAssertTrue(failure?.error.contains("unsupported permissions") == true)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AhaKeyPluginTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeManifest(
        to directory: URL,
        id: String,
        command: String,
        args: [String] = [],
        permissions: [String] = [],
        apiVersion: Int? = nil
    ) throws {
        var manifest: [String: Any] = [
            "id": id,
            "name": "Fixture Plugin",
            "version": "0.1.0",
            "entrypoint": ["command": command, "args": args],
            "permissions": permissions,
        ]
        if let apiVersion { manifest["apiVersion"] = apiVersion }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try data.write(to: directory.appendingPathComponent("plugin.json"))
    }

    private func createArchive(of directory: URL, at archive: URL) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", directory.path, archive.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PluginSystemTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "ditto failed",
                ]
            )
        }
    }
}

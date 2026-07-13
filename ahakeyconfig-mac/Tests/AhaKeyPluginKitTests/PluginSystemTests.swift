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
            try await runtime.install(from: archive)
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

import Foundation
import Testing

@testable import AppBoxKit

/// Builds a throwaway filesystem: a fake app bundle containing the CLI, plus
/// PATH directories we control.
private struct Sandbox {
    let root: URL
    let appBundle: URL
    var pathDirectories: [URL] = []

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cliinstaller-" + UUID().uuidString)
        appBundle = root.appendingPathComponent("AppBox.app")

        let helpers = appBundle.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)

        let cli = helpers.appendingPathComponent("appbox")
        try "#!/bin/sh\necho bundled\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: cli.path)
    }

    mutating func addPathDirectory(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pathDirectories.append(directory)
        return directory
    }

    /// Put a plain (non-symlink) executable named appbox in a directory —
    /// stands in for the original bash script.
    func addScript(in directory: URL) throws {
        let script = directory.appendingPathComponent("appbox")
        try "#!/bin/sh\necho legacy script\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    var environment: [String: String] {
        ["PATH": pathDirectories.map(\.path).joined(separator: ":"), "HOME": root.path]
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("CLI installation")
struct CLIInstallerTests {

    @Test("reports not installed when PATH has no appbox")
    func notInstalled() throws {
        var sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        _ = try sandbox.addPathDirectory("bin")

        #expect(
            CLIInstaller.status(
                appBundle: sandbox.appBundle, environment: sandbox.environment) == .notInstalled)
    }

    @Test("installing creates a symlink into the bundle")
    func installCreatesSymlink() throws {
        var sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let bin = try sandbox.addPathDirectory("bin")

        let result = try CLIInstaller.install(
            appBundle: sandbox.appBundle, into: bin, environment: sandbox.environment)

        #expect(result.linkPath == bin.appendingPathComponent("appbox"))
        #expect(result.backedUpTo == nil)
        #expect(result.shadowedBy.isEmpty)
        #expect(!result.directoryNotOnPath)
        #expect(
            CLIInstaller.status(appBundle: sandbox.appBundle, environment: sandbox.environment)
                == .installed(at: result.linkPath))
    }

    /// The original bash script must not be silently destroyed — the user may
    /// want it back.
    @Test("an existing script is moved aside, not deleted")
    func existingScriptIsBackedUp() throws {
        var sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let bin = try sandbox.addPathDirectory("bin")
        try sandbox.addScript(in: bin)

        let result = try CLIInstaller.install(
            appBundle: sandbox.appBundle, into: bin, environment: sandbox.environment)

        let backup = try #require(result.backedUpTo)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let contents = try String(contentsOf: backup, encoding: .utf8)
        #expect(contents.contains("legacy script"))
    }

    /// The bug this whole type exists to prevent: installing into a directory
    /// that loses to an earlier PATH entry.
    @Test("installing behind an existing copy reports the shadowing")
    func shadowingIsReported() throws {
        var sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let first = try sandbox.addPathDirectory("home-bin")   // wins
        let second = try sandbox.addPathDirectory("usr-local") // loses
        try sandbox.addScript(in: first)

        let result = try CLIInstaller.install(
            appBundle: sandbox.appBundle, into: second, environment: sandbox.environment)

        #expect(result.shadowedBy == [first.appendingPathComponent("appbox")])

        // And the status must admit that ours is not the one that runs.
        let status = CLIInstaller.status(
            appBundle: sandbox.appBundle, environment: sandbox.environment)
        #expect(
            status
                == .shadowed(
                    ours: second.appendingPathComponent("appbox"),
                    winner: first.appendingPathComponent("appbox")))
    }

    @Test("an unmanaged appbox is reported as foreign")
    func foreignInstallation() throws {
        var sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let bin = try sandbox.addPathDirectory("bin")
        try sandbox.addScript(in: bin)

        #expect(
            CLIInstaller.status(appBundle: sandbox.appBundle, environment: sandbox.environment)
                == .foreign(at: bin.appendingPathComponent("appbox")))
    }

    /// Installing should replace the copy that currently wins rather than
    /// adding a second one further down PATH that never runs.
    @Test("recommends the directory already holding the winning copy")
    func recommendsWinningDirectory() throws {
        var sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let home = try sandbox.addPathDirectory("bin")
        _ = try sandbox.addPathDirectory("usr-local")
        try sandbox.addScript(in: home)

        // candidateDirectories derives ~/bin from HOME, which the sandbox
        // points at its own root. Compare by normalized path: a URL for an
        // existing directory carries a trailing slash and won't compare equal.
        #expect(
            CLIInstaller.normalized(
                CLIInstaller.recommendedDirectory(environment: sandbox.environment))
                == CLIInstaller.normalized(home))
    }

    @Test("uninstall removes only our symlink")
    func uninstallLeavesForeignCopies() throws {
        var sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let ours = try sandbox.addPathDirectory("bin")
        let theirs = try sandbox.addPathDirectory("other")
        try sandbox.addScript(in: theirs)

        try CLIInstaller.install(
            appBundle: sandbox.appBundle, into: ours, environment: sandbox.environment)
        try CLIInstaller.uninstall(
            appBundle: sandbox.appBundle, environment: sandbox.environment)

        #expect(!FileManager.default.fileExists(atPath: ours.appendingPathComponent("appbox").path))
        #expect(FileManager.default.fileExists(atPath: theirs.appendingPathComponent("appbox").path))
    }

    @Test("installing outside PATH is flagged")
    func offPathInstall() throws {
        var sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        _ = try sandbox.addPathDirectory("bin")
        let elsewhere = sandbox.root.appendingPathComponent("not-on-path")

        let result = try CLIInstaller.install(
            appBundle: sandbox.appBundle, into: elsewhere, environment: sandbox.environment)
        #expect(result.directoryNotOnPath)
    }
}

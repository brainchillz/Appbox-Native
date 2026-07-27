import AppBoxKit
import AppKit
import Foundation

/// Opens a real terminal window attached to a box.
///
/// This deliberately writes a small script and hands it to Terminal via `open`
/// rather than driving Terminal with AppleScript: `open` needs no Automation
/// permission, so there is no TCC prompt and nothing to fail silently if the
/// user declines it. The tradeoff is that we cannot target an existing window.
enum TerminalLauncher {

    /// Open an interactive shell in the box, starting it first if needed.
    static func openShell(box: Box, containerBinary: URL) throws {
        let script = """
            #!/bin/sh
            # Opened by AppBox. Closing this window leaves the box running.
            printf '\\033]0;appbox: %s\\007' '\(box.name)'
            if ! '\(containerBinary.path)' list --quiet | grep -qx '\(box.name)'; then
              echo "Starting '\(box.name)'…"
              '\(containerBinary.path)' start '\(box.name)' >/dev/null || exit 1
              sleep 1
            fi
            if '\(containerBinary.path)' exec '\(box.name)' test -x /bin/bash 2>/dev/null; then
              exec '\(containerBinary.path)' exec -it '\(box.name)' /bin/bash
            else
              exec '\(containerBinary.path)' exec -it '\(box.name)' /bin/sh
            fi
            """
        try launch(script: script, named: "appbox-shell-\(box.name)")
    }

    /// Open a terminal tailing the box's logs.
    static func openLogs(box: Box, containerBinary: URL) throws {
        let script = """
            #!/bin/sh
            printf '\\033]0;appbox logs: %s\\007' '\(box.name)'
            exec '\(containerBinary.path)' logs --follow '\(box.name)'
            """
        try launch(script: script, named: "appbox-logs-\(box.name)")
    }

    private static func launch(script: String, named name: String) throws {
        // A per-launch directory keeps concurrent windows from overwriting one
        // another's script before Terminal has read it.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("\(name).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        guard let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal")
        else {
            // Fall back to whatever is registered for .command files.
            NSWorkspace.shared.open(url)
            return
        }

        NSWorkspace.shared.open(
            [url], withApplicationAt: terminal, configuration: configuration)
    }
}

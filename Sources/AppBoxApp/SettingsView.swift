import AppBoxKit
import AppKit
import SwiftUI

/// Settings: the command line tool and launch-at-login.
struct SettingsView: View {
    @State private var loginItem = LoginItem()
    @State private var cliStatus: CLIInstaller.Status = .notInstalled
    @State private var installations: [CLIInstaller.Installation] = []
    @State private var lastResult: CLIInstaller.InstallResult?
    @State private var errorText: String?

    /// The running app bundle, which is where the CLI we install points.
    private var appBundle: URL { Bundle.main.bundleURL }

    private var appIsInApplications: Bool {
        appBundle.path.hasPrefix("/Applications/")
    }

    var body: some View {
        Form {
            commandLineSection
            loginSection
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
        .onAppear(perform: refresh)
    }

    // MARK: - CLI

    private var commandLineSection: some View {
        Section("Command Line Tool") {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                    Text(statusText)
                }
            }

            Text(statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if installations.count > 1 || !installations.filter({ !$0.isManaged }).isEmpty {
                pathListing
            }

            // The symlink points at wherever the app is right now, so
            // installing before moving the app into place would break it.
            if !appIsInApplications {
                Label(
                    "AppBox is running from \(appBundle.deletingLastPathComponent().path). "
                        + "Move it to /Applications first — the installed command links to "
                        + "the app's current location and will break if the app moves.",
                    systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(isInstalled ? "Reinstall" : "Install…") { install() }
                if isInstalled {
                    Button("Remove") { uninstall() }
                }
                Spacer()
            }

            if let result = lastResult {
                resultNotes(result)
            }

            if let errorText {
                Label(errorText, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// Shows every appbox on PATH, in the order the shell would find them —
    /// this is what makes a shadowing problem obvious rather than mysterious.
    private var pathListing: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Found on your PATH, in order:")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(installations.enumerated()), id: \.offset) { index, installation in
                HStack(spacing: 6) {
                    Text(index == 0 ? "▶︎" : " ")
                        .font(.caption.monospaced())
                        .foregroundStyle(index == 0 ? .green : .secondary)
                    Text(installation.path.path)
                        .font(.caption.monospaced())
                    if installation.isManaged {
                        Text("(this app)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("▶︎ marks the one your shell actually runs.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultNotes(_ result: CLIInstaller.InstallResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Linked \(result.linkPath.path)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)

            if let backup = result.backedUpTo {
                Label(
                    "Your previous appbox was kept at \(backup.lastPathComponent)",
                    systemImage: "archivebox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !result.shadowedBy.isEmpty {
                Label(
                    "Still shadowed by \(result.shadowedBy.map(\.path).joined(separator: ", ")) "
                        + "— that copy comes first on PATH and will run instead.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if result.directoryNotOnPath {
                Label(
                    "That directory isn’t on your PATH, so the command won’t be found.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var isInstalled: Bool {
        if case .installed = cliStatus { return true }
        if case .shadowed = cliStatus { return true }
        return false
    }

    private var statusSymbol: String {
        switch cliStatus {
        case .installed: "checkmark.circle.fill"
        case .shadowed, .foreign: "exclamationmark.triangle.fill"
        case .notInstalled: "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch cliStatus {
        case .installed: .green
        case .shadowed, .foreign: .orange
        case .notInstalled: .secondary
        }
    }

    private var statusText: String {
        switch cliStatus {
        case .installed: "Installed"
        case .shadowed: "Installed but shadowed"
        case .foreign: "A different appbox is installed"
        case .notInstalled: "Not installed"
        }
    }

    private var statusDetail: String {
        switch cliStatus {
        case .installed(let path):
            "`appbox` runs from \(path.path) and points into this app, so the "
                + "command line and the app always agree."
        case .shadowed(_, let winner):
            "Another copy at \(winner.path) comes first on your PATH and will run "
                + "instead. Install into that directory to replace it."
        case .foreign(let path):
            "\(path.path) was not installed by this app — it may be the original "
                + "shell script. Installing will move it aside, not delete it."
        case .notInstalled:
            "Install the `appbox` command so you can manage boxes from the terminal. "
                + "It is a symlink into this app, so it updates whenever the app does."
        }
    }

    private func install() {
        errorText = nil
        let directory = CLIInstaller.recommendedDirectory()
        do {
            lastResult = try CLIInstaller.install(appBundle: appBundle, into: directory)
        } catch {
            errorText = error.localizedDescription
        }
        refresh()
    }

    private func uninstall() {
        errorText = nil
        do {
            try CLIInstaller.uninstall(appBundle: appBundle)
            lastResult = nil
        } catch {
            errorText = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        cliStatus = CLIInstaller.status(appBundle: appBundle)
        installations = CLIInstaller.discover(appBundle: appBundle)
        loginItem.refresh()
    }

    // MARK: - Login

    private var loginSection: some View {
        Section("General") {
            Toggle(
                "Launch AppBox at login",
                isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }))

            Text(loginItem.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if loginItem.needsApproval {
                Button("Open Login Items in System Settings") {
                    loginItem.openLoginItemsSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            if let error = loginItem.lastError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

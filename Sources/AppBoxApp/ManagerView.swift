import AppBoxKit
import AppKit
import SwiftUI

/// The full management window: boxes on the left, detail and actions on the
/// right. The menu bar dropdown is for quick on/off; this is where you create,
/// inspect and destroy.
struct ManagerView: View {
    @Bindable var store: BoxStore
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String?

    private var selectedBox: Box? {
        store.managedBoxes.first { $0.name == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(store.managedBoxes, id: \.name, selection: $selection) { box in
                HStack(spacing: 8) {
                    StateDot(state: box.state, busy: store.busy.contains(box.name))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(box.name)
                        Text(box.distro ?? "unknown")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.busy.contains(box.name) {
                        ProgressView().controlSize(.small)
                    }
                }
                .tag(box.name)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        openWindow(id: "create")
                    } label: {
                        Label("New Box", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(8)
                .background(.bar)
            }
        } detail: {
            if let box = selectedBox {
                BoxDetailView(box: box, store: store)
            } else {
                ContentUnavailableView(
                    store.managedBoxes.isEmpty ? "No boxes yet" : "Select a box",
                    systemImage: "shippingbox",
                    description: Text(
                        store.managedBoxes.isEmpty
                            ? "Create one to get started."
                            : "Pick a box from the list to see its details."))
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            store.menuIsOpen = true
            if selection == nil { selection = store.managedBoxes.first?.name }
        }
        .onDisappear { store.menuIsOpen = false }
    }
}

struct BoxDetailView: View {
    let box: Box
    @Bindable var store: BoxStore
    @State private var logText = ""
    @State private var loadingLogs = false

    private var isBusy: Bool { store.busy.contains(box.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                Divider()
                details
                Divider()
                logs
            }
            .padding(20)
        }
        .navigationTitle(box.name)
    }

    private var header: some View {
        HStack(spacing: 10) {
            StateDot(state: box.state, busy: isBusy)
            Text(box.name).font(.title2).bold()
            Text(box.state.rawValue)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                store.toggle(box)
            } label: {
                Label(
                    box.isRunning ? "Stop" : "Start",
                    systemImage: box.isRunning ? "stop.fill" : "play.fill")
            }

            Button {
                guard let binary = store.containerBinary else { return }
                try? TerminalLauncher.openShell(box: box, containerBinary: binary)
            } label: {
                Label("Open Shell", systemImage: "terminal")
            }

            Button {
                store.restart(box)
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }

            Button {
                store.provision(box)
            } label: {
                Label("Install Toolset", systemImage: "shippingbox.and.arrow.backward")
            }

            Spacer()

            Button(role: .destructive) {
                confirmDestroy()
            } label: {
                Label("Destroy", systemImage: "trash")
            }
        }
        .disabled(isBusy)
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            row("Distribution", box.distro ?? "unknown")
            row("Image", box.image, monospaced: true)
            row("IP address", box.ipv4 ?? "— (only assigned while running)")
            row("Resources", "\(box.cpus) CPU · \(box.memory)")

            if let user = box.user {
                row("User", "\(user) — with sudo, matching your Mac account")
            } else {
                row("User", "root only (bare box)")
            }

            if let home = box.homeDirectory {
                row("Home", home.path, monospaced: true, reveal: home)
            }
            row("Host data", box.dataDirectory.path, monospaced: true, reveal: box.dataDirectory)

            if box.managed == .inferred {
                row("Managed", "Yes — detected by shape (created before appbox used labels)")
            }
            if let created = box.createdAt {
                row("Created", created)
            }
        }
    }

    @ViewBuilder
    private func row(
        _ label: String, _ value: String, monospaced: Bool = false, reveal: URL? = nil
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            HStack(spacing: 6) {
                Text(value)
                    .font(monospaced ? .body.monospaced() : .body)
                    .textSelection(.enabled)
                if let reveal {
                    Button {
                        NSWorkspace.shared.selectFile(
                            nil, inFileViewerRootedAtPath: reveal.path)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                    .disabled(!FileManager.default.fileExists(atPath: reveal.path))
                }
            }
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Console").font(.headline)
                Spacer()
                Button {
                    guard let binary = store.containerBinary else { return }
                    try? TerminalLauncher.openLogs(box: box, containerBinary: binary)
                } label: {
                    Label("Follow in Terminal", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                Button {
                    Task { await loadLogs() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            ScrollView {
                Text(logText.isEmpty ? "…" : logText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 160)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if loadingLogs { ProgressView().controlSize(.small) }
            }
        }
        .task(id: box.name) { await loadLogs() }
    }

    private func loadLogs() async {
        loadingLogs = true
        logText = await store.logs(for: box)
        loadingLogs = false
    }

    private func confirmDestroy() {
        let alert = NSAlert()
        alert.messageText = "Destroy “\(box.name)”?"
        alert.informativeText =
            "The container is deleted. Host data in \(box.dataDirectory.path) is kept "
            + "unless you also choose to delete it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Destroy")
        alert.addButton(withTitle: "Cancel")

        let purge = NSButton(checkboxWithTitle: "Also delete host data", target: nil, action: nil)
        alert.accessoryView = purge

        if alert.runModal() == .alertFirstButtonReturn {
            store.destroy(box, purge: purge.state == .on)
        }
    }
}

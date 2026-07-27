import AppBoxKit
import SwiftUI

/// Carries the natural height of the box rows up to the ScrollView that
/// contains them.
struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MenuBarContentView: View {
    @Bindable var store: BoxStore
    @Environment(\.openWindow) private var openWindow

    /// Natural height of the rows, once measured.
    @State private var measuredListHeight: CGFloat?

    /// About six rows. Past this the list scrolls rather than growing toward
    /// the bottom of the screen.
    static let maxListHeight: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if store.health != .ok {
                HealthBanner(store: store)
                Divider()
            }

            if let activity = store.activity {
                ActivityRow(text: activity)
                Divider()
            }

            if let error = store.lastError {
                ErrorRow(text: error) { store.lastError = nil }
                Divider()
            }

            boxList

            Divider()
            footer
        }
        .onAppear { store.menuIsOpen = true }
        .onDisappear { store.menuIsOpen = false }
    }

    private var header: some View {
        HStack {
            Text("AppBox").font(.headline)
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let boxes = store.managedBoxes
        guard !boxes.isEmpty else { return "no boxes" }
        return "\(store.runningCount) of \(boxes.count) running"
    }

    @ViewBuilder
    private var boxList: some View {
        if store.managedBoxes.isEmpty {
            VStack(spacing: 6) {
                Text(store.health == .ok ? "No boxes yet" : "Boxes unavailable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if store.health == .ok {
                    Button("Create your first box…") {
                        activateApp()
                        openWindow(id: "create")
                    }
                    .buttonStyle(.link)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.managedBoxes, id: \.name) { box in
                        BoxRow(box: box, store: store)
                        if box.name != store.managedBoxes.last?.name {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                // Report the natural height of the rows so the ScrollView can
                // be sized to fit them.
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ListHeightKey.self, value: proxy.size.height)
                    })
            }
            // A ScrollView has no intrinsic height, so `.frame(maxHeight:)`
            // alone collapses it to roughly one row. Measure the content and
            // ask for exactly that, capped so a long list scrolls instead of
            // running off the screen. `nil` on the first pass lets it lay out
            // naturally before the measurement arrives.
            .frame(height: measuredListHeight.map { min($0, Self.maxListHeight) })
            .onPreferenceChange(ListHeightKey.self) { height in
                guard height > 0 else { return }
                measuredListHeight = height
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                activateApp()
                openWindow(id: "create")
            } label: {
                Label("New Box", systemImage: "plus")
            }
            .disabled(store.health == .cliMissing)

            Button {
                activateApp()
                openWindow(id: "manager")
            } label: {
                Label("Manage", systemImage: "square.grid.2x2")
            }

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit AppBox")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One box in the dropdown: state dot, name, details, and an on/off toggle.
struct BoxRow: View {
    let box: Box
    @Bindable var store: BoxStore
    @State private var isHovering = false

    private var isBusy: Bool { store.busy.contains(box.name) }

    var body: some View {
        HStack(spacing: 10) {
            StateDot(state: box.state, busy: isBusy)

            VStack(alignment: .leading, spacing: 1) {
                Text(box.name).font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                if isHovering {
                    Menu {
                        Button("Open Shell") { openShell() }
                        Button("Follow Logs") { openLogs() }
                        Divider()
                        Button("Restart") { store.restart(box) }
                        Button("Install Standard Toolset") { store.provision(box) }
                        Divider()
                        Button("Destroy…", role: .destructive) { confirmDestroy() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Toggle("", isOn: Binding(
                    get: { box.isRunning },
                    set: { _ in store.toggle(box) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(box.isRunning ? "Stop \(box.name)" : "Start \(box.name)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        .onHover { isHovering = $0 }
        .onTapGesture { openShell() }
        .help("Click to open a shell")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let distro = box.distro { parts.append(distro) }
        if let ip = box.ipv4 { parts.append(ip) }
        else if !box.isRunning { parts.append("stopped") }
        parts.append("\(box.cpus) CPU · \(box.memory)")
        return parts.joined(separator: " · ")
    }

    private func openShell() {
        guard let binary = store.containerBinary else { return }
        try? TerminalLauncher.openShell(box: box, containerBinary: binary)
    }

    private func openLogs() {
        guard let binary = store.containerBinary else { return }
        try? TerminalLauncher.openLogs(box: box, containerBinary: binary)
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
        purge.state = .off
        alert.accessoryView = purge

        activateApp()
        if alert.runModal() == .alertFirstButtonReturn {
            store.destroy(box, purge: purge.state == .on)
        }
    }
}

struct StateDot: View {
    let state: BoxState
    var busy = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            .opacity(busy ? 0.4 : 1)
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .stopped: .secondary.opacity(0.5)
        case .unknown: .orange
        }
    }
}

/// Surfaces the two failure modes that otherwise look like "the app is broken",
/// each with the action that actually fixes it.
struct HealthBanner: View {
    @Bindable var store: BoxStore

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)

                if let action {
                    Button(action.label) { action.perform() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    private var title: String {
        switch store.health {
        case .cliMissing: "Apple’s container CLI isn’t installed"
        case .serviceStopped: "The container service isn’t running"
        case .versionSkew: "container CLI and daemon versions differ"
        case .ok: ""
        }
    }

    private var detail: String {
        switch store.health {
        case .cliMissing:
            "AppBox drives Apple’s container tool. Install it, then reopen this menu."
        case .serviceStopped:
            "Boxes can’t be listed or started until the service is up."
        case .versionSkew(let cli, let daemon):
            "CLI \(cli), daemon \(daemon). A skew commonly breaks container networking."
        case .ok:
            ""
        }
    }

    private struct Action {
        let label: String
        let perform: () -> Void
    }

    private var action: Action? {
        switch store.health {
        case .cliMissing:
            Action(label: "Open the installer page") {
                if let url = URL(string: "https://github.com/apple/container/releases") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .serviceStopped:
            Action(label: "Start the service") { store.startService() }
        case .versionSkew:
            Action(label: "Restart the service") { store.restartService() }
        case .ok:
            nil
        }
    }
}

struct ActivityRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ErrorRow: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(text).font(.caption).lineLimit(4)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.red.opacity(0.08))
    }
}

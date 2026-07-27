import AppBoxKit
import Foundation
import Observation

/// Health of the underlying `container` install, which the UI has to surface
/// rather than fail silently — a stopped service or a version skew is by far
/// the most common reason nothing works.
enum ServiceHealth: Equatable {
    case ok
    case cliMissing
    case serviceStopped
    case versionSkew(cli: String, daemon: String)
}

/// Observable state behind the menu bar and manager window.
///
/// All container work happens off the main actor — `BoxManager` is synchronous
/// and some operations (image pulls, provisioning) take minutes.
@MainActor
@Observable
final class BoxStore {
    private(set) var boxes: [Box] = []
    private(set) var health: ServiceHealth = .ok
    private(set) var isLoading = false
    /// Names of boxes with an operation in flight, so rows can show a spinner
    /// and avoid double-clicks.
    private(set) var busy: Set<String> = []
    var lastError: String?

    /// Long-running jobs (create, provision) surfaced as progress text.
    private(set) var activity: String?

    /// Poll fast while the user is looking, slowly otherwise. Apple's CLI has
    /// no event stream, so polling is the only way to notice external changes.
    var menuIsOpen = false {
        didSet { if menuIsOpen { Task { await refresh() } } }
    }

    /// Path to Apple's `container` binary, needed when handing a command to
    /// Terminal (which does not inherit this app's discovery).
    private(set) var containerBinary: URL?

    private var manager: BoxManager?
    private var pollTask: Task<Void, Never>?

    var managedBoxes: [Box] { boxes.filter { $0.managed != .foreign } }
    var runningCount: Int { managedBoxes.filter(\.isRunning).count }

    init() {
        connect()
        startPolling()
    }

    // MARK: - Connection

    private func connect() {
        do {
            let client = try ContainerClient.discover()
            manager = BoxManager(client: client, config: .fromEnvironment())
            containerBinary = client.binary
        } catch {
            manager = nil
            containerBinary = nil
            health = .cliMissing
        }
    }

    private func startPolling() {
        // Inherits main-actor isolation from the enclosing type.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                try? await Task.sleep(for: menuIsOpen ? .seconds(2) : .seconds(30))
            }
        }
    }

    // MARK: - Refresh

    func refresh() async {
        if manager == nil { connect() }
        guard let manager else { return }

        isLoading = true
        defer { isLoading = false }

        let result = await Task.detached(priority: .userInitiated) { () -> Result<([Box], ServiceHealth), Error> in
            guard manager.client.isServiceRunning() else {
                return .success(([], .serviceStopped))
            }
            do {
                let boxes = try manager.list(includeForeign: false)
                let skew = manager.client.versionSkew()
                let health: ServiceHealth = skew.map {
                    .versionSkew(cli: $0.cli, daemon: $0.daemon)
                } ?? .ok
                return .success((boxes, health))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let (boxes, health)):
            self.boxes = boxes
            self.health = health
            if case .ok = health { lastError = nil }
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    // MARK: - Service control

    func startService() {
        run(activity: "Starting the container service…") { manager in
            try manager.client.startService()
        }
    }

    /// A CLI/daemon skew breaks networking; restarting the daemon is the fix.
    func restartService() {
        run(activity: "Restarting the container service…") { manager in
            _ = try? manager.client.run(["system", "stop"])
            try manager.client.startService()
        }
    }

    // MARK: - Box actions

    func start(_ box: Box) {
        run(box: box.name) { try $0.start(box.name) }
    }

    func stop(_ box: Box) {
        run(box: box.name) { try $0.stop(box.name) }
    }

    func toggle(_ box: Box) {
        box.isRunning ? stop(box) : start(box)
    }

    func restart(_ box: Box) {
        run(box: box.name) { try $0.restart(box.name) }
    }

    func provision(_ box: Box) {
        run(box: box.name, activity: "Installing the standard toolset in \(box.name)…") {
            try $0.provision(box.name)
        }
    }

    func destroy(_ box: Box, purge: Bool) {
        run(box: box.name, activity: "Destroying \(box.name)…") {
            try $0.destroy(box.name, purge: purge)
        }
    }

    func create(name: String, token: String, full: Bool, cpus: Int?, memory: String?) {
        let label = full
            ? "Creating \(name) and installing the toolset — this can take a few minutes…"
            : "Creating \(name)…"
        run(box: name, activity: label) { manager in
            _ = try manager.create(
                BoxManager.CreateRequest(
                    name: name, token: token, full: full, cpus: cpus, memory: memory))
        }
    }

    /// Fetch recent log output for a box.
    func logs(for box: Box) async -> String {
        guard let manager else { return "" }
        return await Task.detached(priority: .userInitiated) { () -> String in
            let result = try? manager.client.run(["logs", box.name])
            guard let result else { return "" }
            let combined = result.stdout + result.stderr
            return combined.isEmpty
                ? "No log output.\n\nBoxes run `sleep infinity` as their init process, "
                    + "so there is usually nothing here — open a shell instead."
                : combined
        }.value
    }

    // MARK: - Plumbing

    /// Run a container operation off the main actor, tracking busy state and
    /// refreshing when it finishes.
    private func run(
        box: String? = nil,
        activity: String? = nil,
        operation: @escaping @Sendable (BoxManager) throws -> Void
    ) {
        guard let manager else { return }

        if let box { busy.insert(box) }
        if let activity { self.activity = activity }

        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try operation(manager)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            if let box { busy.remove(box) }
            if activity != nil { self.activity = nil }
            if let error { lastError = error }
            await refresh()
        }
    }
}

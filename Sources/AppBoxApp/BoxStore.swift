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
/// All container work happens off the main actor — `BoxService` is synchronous
/// and some operations (image pulls, provisioning) take minutes.
@MainActor
@Observable
final class BoxStore {
    private(set) var boxes: [Box] = []
    private(set) var health: ServiceHealth = .ok
    private(set) var isLoading = false
    /// Names of boxes with an operation in flight, so rows can show a spinner
    /// and avoid double-clicks. Keyed by kind as well as name, since a machine
    /// and a container may share one.
    private(set) var busy: Set<String> = []
    var lastError: String?

    /// Long-running jobs (create, provision) surfaced as progress text.
    private(set) var activity: String?

    /// Whether the installed `container` can do machines at all. Drives whether
    /// the New Box window offers the choice.
    private(set) var machinesAvailable = false

    /// Poll fast while the user is looking, slowly otherwise. Apple's CLI has
    /// no event stream, so polling is the only way to notice external changes.
    var menuIsOpen = false {
        didSet { if menuIsOpen { Task { await refresh() } } }
    }

    /// Path to Apple's `container` binary, needed when handing a command to
    /// Terminal (which does not inherit this app's discovery).
    private(set) var containerBinary: URL?

    private var service: BoxService?
    private var pollTask: Task<Void, Never>?

    var managedBoxes: [Box] { boxes.filter { $0.managed != .foreign } }
    var runningCount: Int { managedBoxes.filter(\.isRunning).count }

    func isBusy(_ box: Box) -> Bool { busy.contains(box.id) }

    init() {
        connect()
        startPolling()
    }

    // MARK: - Connection

    private func connect() {
        do {
            let service = try BoxService.discover()
            self.service = service
            containerBinary = service.client.binary
            machinesAvailable = service.machinesAvailable
        } catch {
            service = nil
            containerBinary = nil
            machinesAvailable = false
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
        if service == nil { connect() }
        guard let service else { return }

        isLoading = true
        defer { isLoading = false }

        let result = await Task.detached(priority: .userInitiated) {
            () -> Result<([Box], ServiceHealth), Error> in
            guard service.isServiceRunning() else {
                return .success(([], .serviceStopped))
            }
            do {
                let boxes = try service.list(includeForeign: false)
                let skew = service.client.versionSkew()
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
        run(activity: "Starting the container service…") { service in
            try service.client.startService()
        }
    }

    /// A CLI/daemon skew breaks networking; restarting the daemon is the fix.
    func restartService() {
        run(activity: "Restarting the container service…") { service in
            _ = try? service.client.run(["system", "stop"])
            try service.client.startService()
        }
    }

    // MARK: - Box actions

    func start(_ box: Box) {
        run(box: box) { try $0.start(box) }
    }

    func stop(_ box: Box) {
        run(box: box) { try $0.stop(box) }
    }

    func toggle(_ box: Box) {
        box.isRunning ? stop(box) : start(box)
    }

    func restart(_ box: Box) {
        run(box: box) { try $0.restart(box) }
    }

    func provision(_ box: Box) {
        let what = box.kind == .machine
            ? "Installing the toolset and finishing setup in \(box.name)…"
            : "Installing the standard toolset in \(box.name)…"
        run(box: box, activity: what) { try $0.provision(box) }
    }

    func destroy(_ box: Box, purge: Bool) {
        run(box: box, activity: "Destroying \(box.name)…") {
            try $0.destroy(box, purge: purge)
        }
    }

    /// Machines only: make this the one bare `container machine` commands use.
    func makeDefault(_ box: Box) {
        guard box.kind == .machine else { return }
        run(box: box) { try $0.machines.setDefault(box.name) }
    }

    func create(
        kind: BoxKind,
        name: String,
        token: String,
        bare: Bool,
        cpus: Int?,
        memory: String?,
        homeMount: HomeMount?
    ) {
        let label = bare
            ? "Creating a bare \(kind.rawValue) \(name)…"
            : "Creating \(name)… (the first \(kind.rawValue) of a distro builds an image)"

        run(key: "\(kind.rawValue):\(name)", activity: label) { service in
            _ = try service.create(
                kind: kind, name: name, token: token, bare: bare,
                cpus: cpus, memory: memory, homeMount: homeMount)
        }
    }

    /// Fetch recent log output for a box.
    func logs(for box: Box) async -> String {
        guard let service else { return "" }
        return await Task.detached(priority: .userInitiated) { () -> String in
            let text = service.logs(box)
            guard text.isEmpty else { return text }

            return box.kind == .machine
                ? "No log output yet. A machine's console is quiet unless "
                    + "something it runs writes to it."
                : "No log output.\n\nContainers run `sleep infinity` as their init process, "
                    + "so there is usually nothing here — open a shell instead."
        }.value
    }

    // MARK: - Plumbing

    /// Run an operation off the main actor, tracking busy state and refreshing
    /// when it finishes.
    private func run(
        box: Box,
        activity: String? = nil,
        operation: @escaping @Sendable (BoxService) throws -> Void
    ) {
        run(key: box.id, activity: activity, operation: operation)
    }

    private func run(
        key: String? = nil,
        activity: String? = nil,
        operation: @escaping @Sendable (BoxService) throws -> Void
    ) {
        guard let service else { return }

        if let key { busy.insert(key) }
        if let activity { self.activity = activity }

        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try operation(service)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            if let key { busy.remove(key) }
            if activity != nil { self.activity = nil }
            if let error { lastError = error }
            await refresh()
        }
    }
}

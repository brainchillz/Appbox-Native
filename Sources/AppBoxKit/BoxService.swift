import Foundation

/// One door to both kinds of box.
///
/// Machines and containers live in separate namespaces in Apple's CLI, and are
/// driven by different commands, but the CLI and the menu bar app should not
/// have to care: you start a box, you shell into a box, you destroy a box.
/// Every method here takes a `Box` rather than a name, because a machine and a
/// container are allowed to share one — the box itself says which it is.
public struct BoxService: Sendable {
    public let boxes: BoxManager
    public let machines: MachineManager
    /// Whether the installed `container` has machine support at all. False on
    /// anything older than 1.1.0, where appbox falls back to containers only.
    public let machinesAvailable: Bool

    public init(boxes: BoxManager, machines: MachineManager, machinesAvailable: Bool) {
        self.boxes = boxes
        self.machines = machines
        self.machinesAvailable = machinesAvailable
    }

    /// Build a service from the environment, probing once for machine support.
    public static func discover(
        config: Configuration = .fromEnvironment(),
        user: HostUser = .current()
    ) throws -> BoxService {
        let container = try ContainerClient.discover()
        let machineClient = MachineClient(container: container)
        return BoxService(
            boxes: BoxManager(client: container, config: config, user: user),
            machines: MachineManager(client: machineClient, config: config, user: user),
            machinesAvailable: machineClient.isSupported())
    }

    public var client: ContainerClient { boxes.client }
    public var config: Configuration { boxes.config }

    /// The kind `create` uses when the caller doesn't say.
    ///
    /// Machines wherever they exist: they are what appbox's containers were
    /// imitating, and they do it better. Containers remain a deliberate choice
    /// for the two things machines can't do — a private home, and `/data`.
    public var defaultKind: BoxKind { machinesAvailable ? .machine : .container }

    // MARK: - Queries

    /// Every box, machines first.
    ///
    /// A failure listing one kind must not hide the other, so machine trouble
    /// is swallowed here: an old `container`, or a machine daemon that hasn't
    /// started, should cost you the machines — not the whole list.
    public func list(includeForeign: Bool = false) throws -> [Box] {
        let machineBoxes = machinesAvailable ? ((try? machines.list()) ?? []) : []
        let containerBoxes = try boxes.list(includeForeign: includeForeign)
        return machineBoxes + containerBoxes
    }

    /// Find a box by name, preferring a machine when both kinds share one.
    public func find(_ name: String) throws -> Box? {
        if machinesAvailable, let machine = try? machines.find(name) {
            return machine
        }
        return try boxes.find(name)
    }

    public func requireBox(_ name: String) throws -> Box {
        guard let box = try find(name) else { throw AppBoxError.boxNotFound(name: name) }
        return box
    }

    // MARK: - Lifecycle, dispatched by kind

    public func start(_ box: Box) throws {
        switch box.kind {
        case .machine: try machines.start(box.name)
        case .container: try boxes.start(box.name)
        }
    }

    public func stop(_ box: Box) throws {
        switch box.kind {
        case .machine: try machines.stop(box.name)
        case .container: try boxes.stop(box.name)
        }
    }

    public func restart(_ box: Box) throws {
        switch box.kind {
        case .machine: try machines.restart(box.name)
        case .container: try boxes.restart(box.name)
        }
    }

    public func ensureRunning(_ box: Box) throws {
        switch box.kind {
        case .machine: try machines.ensureRunning(box.name)
        case .container: try boxes.ensureRunning(box.name)
        }
    }

    /// Install the standard toolset, and for a machine also finish the account
    /// setup `container` leaves half-done.
    public func provision(_ box: Box, reporter: ProgressReporter = SilentReporter()) throws {
        switch box.kind {
        case .machine:
            try machines.provision(box.name, reporter: reporter)
            try machines.polish(box.name, reporter: reporter)
        case .container:
            try boxes.provision(box.name, reporter: reporter)
        }
    }

    /// Destroy a box. `purge` only means anything for a container — a machine's
    /// disk always goes with it.
    public func destroy(
        _ box: Box, purge: Bool, reporter: ProgressReporter = SilentReporter()
    ) throws {
        switch box.kind {
        case .machine: try machines.destroy(box.name, reporter: reporter)
        case .container: try boxes.destroy(box.name, purge: purge, reporter: reporter)
        }
    }

    // MARK: - Create

    /// Create a box of the given kind, from one request shape.
    @discardableResult
    public func create(
        kind: BoxKind? = nil,
        name: String,
        token: String? = nil,
        bare: Bool = false,
        cpus: Int? = nil,
        memory: String? = nil,
        homeMount: HomeMount? = nil,
        setDefault: Bool = false,
        reporter: ProgressReporter = SilentReporter()
    ) throws -> Box {
        switch kind ?? defaultKind {
        case .machine:
            return try machines.create(
                MachineManager.CreateRequest(
                    name: name, token: token, bare: bare, cpus: cpus, memory: memory,
                    homeMount: homeMount, setDefault: setDefault),
                reporter: reporter)
        case .container:
            return try boxes.create(
                BoxManager.CreateRequest(
                    name: name, token: token, bare: bare, cpus: cpus, memory: memory),
                reporter: reporter)
        }
    }

    /// Resolve the image a create would use, without creating anything. Both
    /// kinds resolve tokens identically, so the caller's kind doesn't matter.
    public func resolveImage(token: String?, name: String) throws -> ResolvedImage {
        try ImageResolver.resolve(token: token, config: config, name: name)
    }

    // MARK: - Health

    public func isServiceRunning() -> Bool { client.isServiceRunning() }

    /// Recent log output for a box, as one blob for the detail pane.
    ///
    /// Stripped of ANSI escapes: a machine's console is a systemd boot log
    /// written in colour, and a plain text view would show the codes rather
    /// than obey them.
    public func logs(_ box: Box) -> String {
        switch box.kind {
        case .machine:
            return LogText.plain(machines.client.logText(box.name, lines: 200))
        case .container:
            guard let result = try? client.run(["logs", box.name]) else { return "" }
            return LogText.plain(result.stdout + result.stderr)
        }
    }
}

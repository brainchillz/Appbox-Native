import Foundation

/// Receives human-facing progress from long operations. The CLI prints these
/// to stderr in the script's `==>` idiom; the menu bar app will route them to
/// a progress sheet and notifications.
public protocol ProgressReporter: Sendable {
    func info(_ message: String)
    func warn(_ message: String)
    /// Raw line of subprocess output (image pull progress, package manager
    /// chatter). Usually shown verbatim.
    func detail(_ line: String)
}

/// A reporter that discards everything — useful for tests and for GUI paths
/// that read results rather than watch progress.
public struct SilentReporter: ProgressReporter {
    public init() {}
    public func info(_ message: String) {}
    public func warn(_ message: String) {}
    public func detail(_ line: String) {}
}

/// How confident we are that a container is an appbox-managed box.
public enum Managed: String, Sendable {
    /// Created by a labelled appbox — definitive.
    case labelled
    /// Created by an older appbox: no label, but it has the appbox shape
    /// (init process holding it open plus a /data bind mount).
    case inferred
    /// Not an appbox box — some other container on the same machine.
    case foreign
}

/// The appbox-level view of a container.
public struct Box: Sendable {
    public var name: String
    public var state: BoxState
    public var image: String
    public var ipv4: String?
    public var dataDirectory: URL
    public var managed: Managed
    public var distro: String?
    public var cpus: Int
    public var memory: String
    public var createdAt: String?

    public var isRunning: Bool { state == .running }
    /// Does the host data directory actually exist on disk?
    public var hasHostData: Bool {
        FileManager.default.fileExists(atPath: dataDirectory.path)
    }
}

/// appbox's policy layer: what a "box" is, how one is created, provisioned and
/// destroyed. `ContainerClient` knows how to talk to Apple's CLI; this type
/// knows what appbox means by a box.
public struct BoxManager: Sendable {
    public let client: ContainerClient
    public let config: Configuration

    public init(client: ContainerClient, config: Configuration) {
        self.client = client
        self.config = config
    }

    // MARK: - Labels

    /// Marks a container as appbox-managed. Added at create time so the menu
    /// bar app can tell our boxes apart from any other container on the machine
    /// without guessing. Older boxes predate this and are matched by shape —
    /// see `classify`.
    public enum Label {
        public static let managed = "appbox.managed"
        public static let distro = "appbox.distro"
        public static let version = "appbox.version"
        /// Bumped if the meaning of appbox's labels ever changes.
        public static let schema = "appbox.schema"

        public static let currentSchema = "1"
    }

    /// The mount point every box gets its host data at.
    public static let dataMountPoint = "/data"

    /// Decide whether a container is one of ours.
    ///
    /// The label is definitive. Failing that we look for the shape appbox has
    /// always created: an init process parked on `sleep infinity` plus a bind
    /// mount at /data. That correctly claims boxes made by the bash script and
    /// correctly ignores unrelated containers.
    public static func classify(_ record: ContainerRecord) -> Managed {
        if record.labels[Label.managed] == "1" { return .labelled }

        let parkedOnSleep = record.configuration.initProcess.executable == "sleep"
            && record.configuration.initProcess.arguments == ["infinity"]
        let hasDataMount = record.configuration.mounts
            .contains { $0.destination == dataMountPoint }

        return (parkedOnSleep && hasDataMount) ? .inferred : .foreign
    }

    private func box(from record: ContainerRecord) -> Box {
        Box(
            name: record.id,
            state: record.state,
            image: record.image,
            ipv4: record.ipv4,
            dataDirectory: config.dataDirectory(for: record.id),
            managed: Self.classify(record),
            // Labels are authoritative; fall back to reading the image
            // reference so pre-label boxes still report a distro.
            distro: record.labels[Label.distro]
                ?? Distro.infer(fromImage: record.image)?.distro.rawValue,
            cpus: record.configuration.resources.cpus,
            memory: record.configuration.resources.memoryDescription,
            createdAt: record.configuration.creationDate
        )
    }

    // MARK: - Queries

    /// List boxes. By default this includes foreign containers so that `appbox
    /// list` keeps showing everything the bash script showed; the menu bar app
    /// filters to managed boxes.
    public func list(includeForeign: Bool = true) throws -> [Box] {
        try client.list(all: true)
            .map(box(from:))
            .filter { includeForeign || $0.managed != .foreign }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func find(_ name: String) throws -> Box? {
        guard let record = try client.inspect(name) else { return nil }
        return box(from: record)
    }

    public func requireBox(_ name: String) throws -> Box {
        guard let box = try find(name) else {
            throw AppBoxError.boxNotFound(name: name)
        }
        return box
    }

    // MARK: - Create

    public struct CreateRequest: Sendable {
        public var name: String
        /// Distro token or raw image reference. Nil means "use the default".
        public var token: String?
        public var full: Bool
        public var cpus: Int?
        public var memory: String?

        public init(
            name: String, token: String? = nil, full: Bool = false,
            cpus: Int? = nil, memory: String? = nil
        ) {
            self.name = name
            self.token = token
            self.full = full
            self.cpus = cpus
            self.memory = memory
        }
    }

    /// Resolve which image to create from.
    ///
    /// Order: explicit token, then `APPBOX_IMAGE`, then the saved default
    /// distro. With none of those we refuse rather than silently picking
    /// Ubuntu — the caller shows the distro menu.
    public func resolveImage(for request: CreateRequest) throws
        -> (image: String, distro: String?, viaDefault: String?)
    {
        if let token = request.token, !token.isEmpty {
            let distro = Distro.parse(token: token)?.distro.rawValue
            return (Distro.resolveImage(token: token), distro, nil)
        }
        if let forced = config.forcedImage {
            return (forced, Distro.parse(token: forced)?.distro.rawValue, nil)
        }
        if let saved = config.defaultDistro() {
            let distro = Distro.parse(token: saved)?.distro.rawValue
            return (Distro.resolveImage(token: saved), distro, saved)
        }
        throw AppBoxError.noDistroSpecified(name: request.name)
    }

    @discardableResult
    public func create(
        _ request: CreateRequest,
        reporter: ProgressReporter = SilentReporter()
    ) throws -> Box {
        let resolved = try resolveImage(for: request)

        if try client.exists(request.name) {
            throw AppBoxError.boxAlreadyExists(name: request.name)
        }

        if let viaDefault = resolved.viaDefault {
            reporter.info("using default distro '\(viaDefault)' -> \(resolved.image)")
        }

        let dataDirectory = config.dataDirectory(for: request.name)
        try FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true)

        let cpus = request.cpus ?? config.cpus
        let memory = request.memory ?? config.memory

        reporter.info(
            "creating box '\(request.name)' from \(resolved.image) "
                + "(cpus=\(cpus) mem=\(memory))")
        reporter.info(
            "host data dir: \(dataDirectory.path)  ->  \(Self.dataMountPoint) inside the box")

        var labels = [
            Label.managed: "1",
            Label.schema: Label.currentSchema,
        ]
        if let distro = resolved.distro { labels[Label.distro] = distro }
        if let token = request.token,
           let parsed = Distro.parse(token: token), let version = parsed.version {
            labels[Label.version] = version
        }

        let spec = ContainerClient.RunSpec(
            name: request.name,
            image: resolved.image,
            cpus: cpus,
            memory: memory,
            volumes: [(host: dataDirectory.path, guest: Self.dataMountPoint)],
            labels: labels
        )

        try client.create(spec) { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { reporter.detail(trimmed) }
        }

        // Brief settle so the box reports an IP.
        Thread.sleep(forTimeInterval: 1.0)
        reporter.info("box '\(request.name)' is up.")

        if request.full {
            try provision(request.name, reporter: reporter)
        }

        return try requireBox(request.name)
    }

    // MARK: - Provision

    /// Detect the package manager inside a box.
    public func detectPackageManager(_ name: String) -> PackageManager? {
        for manager in PackageManager.allCases
        where client.probe(name, shellCommand: manager.detectCommand) {
            return manager
        }
        return nil
    }

    /// Install the standard CLI toolset. Idempotent — safe to re-run.
    public func provision(
        _ name: String,
        reporter: ProgressReporter = SilentReporter()
    ) throws {
        guard try client.exists(name) else { throw AppBoxError.boxNotFound(name: name) }
        try ensureRunning(name)

        guard let manager = detectPackageManager(name) else {
            throw AppBoxError.noPackageManager(box: name)
        }

        reporter.info("installing standard CLI toolset via \(manager.rawValue)…")

        let result = try client.exec(
            name, ["sh", "-c", PackageSets.installCommand(for: manager)],
            onOutputLine: { reporter.detail($0) },
            onErrorLine: { reporter.detail($0) }
        )

        guard result.succeeded else {
            throw AppBoxError.commandFailed(
                command: "\(manager.rawValue) install",
                exitCode: result.exitCode,
                stderr: result.stderr)
        }

        reporter.info(
            "provisioning complete — 'ip', 'curl', 'dig', 'vim', 'sudo', etc. are now available.")
    }

    // MARK: - Lifecycle

    /// Start the box if it is not already running, and give it a moment to
    /// settle. Used by every command that needs to run something inside.
    public func ensureRunning(_ name: String) throws {
        guard try !client.isRunning(name) else { return }
        try client.start(name)
        Thread.sleep(forTimeInterval: 1.0)
    }

    public func start(_ name: String) throws {
        guard try client.exists(name) else { throw AppBoxError.boxNotFound(name: name) }
        try client.start(name)
    }

    public func stop(_ name: String) throws {
        guard try client.exists(name) else { throw AppBoxError.boxNotFound(name: name) }
        try client.stop(name)
    }

    public func restart(_ name: String) throws {
        guard try client.exists(name) else { throw AppBoxError.boxNotFound(name: name) }
        try? client.stop(name)
        Thread.sleep(forTimeInterval: 1.0)
        try client.start(name)
    }

    /// Pick an interactive shell that exists in the box.
    public func preferredShell(_ name: String) -> String {
        client.probe(name, shellCommand: "test -x /bin/bash") ? "/bin/bash" : "/bin/sh"
    }

    public func destroy(
        _ name: String,
        purge: Bool,
        reporter: ProgressReporter = SilentReporter()
    ) throws {
        guard try client.exists(name) else { throw AppBoxError.boxNotFound(name: name) }

        try? client.stop(name)
        try client.delete(name)
        reporter.info("destroyed container '\(name)'")

        let boxDirectory = config.boxDirectory(for: name)
        if purge {
            // Report what actually happened. Claiming a purge for a directory
            // that was never there hides an APPBOX_HOME mismatch, which is
            // exactly when you most want to notice.
            if FileManager.default.fileExists(atPath: boxDirectory.path) {
                try FileManager.default.removeItem(at: boxDirectory)
                reporter.info("purged host data at \(boxDirectory.path)")
            } else {
                reporter.info("no host data to purge at \(boxDirectory.path)")
            }
        } else {
            reporter.info(
                "host data kept at \(config.dataDirectory(for: name).path) "
                    + "(use --purge to delete it too)")
        }
    }
}

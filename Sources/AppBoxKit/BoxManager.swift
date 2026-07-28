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
    /// Host directory backing the box user's home, when the box has one.
    /// Read from the container's actual mounts rather than assumed from
    /// configuration, so it reflects how the box was really created.
    public var homeDirectory: URL?
    public var managed: Managed
    public var distro: String?
    /// The Linux account created to mirror the host user, if the box has one.
    public var user: String?
    public var cpus: Int
    public var memory: String
    public var createdAt: String?

    public var isRunning: Bool { state == .running }
    /// A box with its own account and persistent home, rather than a bare
    /// container running as root.
    public var isFullInstall: Bool { user != nil && homeDirectory != nil }
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
    /// The macOS account boxes' Linux user mirrors.
    public let user: HostUser

    public init(
        client: ContainerClient,
        config: Configuration,
        user: HostUser = .current()
    ) {
        self.client = client
        self.config = config
        self.user = user
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
        /// The Linux user created to mirror the host account.
        public static let user = "appbox.user"
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
            homeDirectory: record.configuration.mounts
                .first { $0.destination.hasPrefix("/home/") }
                .map { URL(fileURLWithPath: $0.source) },
            managed: Self.classify(record),
            // Labels are authoritative; fall back to reading the image
            // reference so pre-label boxes still report a distro.
            distro: record.labels[Label.distro]
                ?? Distro.infer(fromImage: record.image)?.distro.rawValue,
            user: record.labels[Label.user],
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
        /// Skip the standard toolset and the user account, giving a bare
        /// container. The default is a full Linux install, because that is what
        /// a "box" is meant to be.
        public var bare: Bool
        public var cpus: Int?
        public var memory: String?

        public init(
            name: String, token: String? = nil, bare: Bool = false,
            cpus: Int? = nil, memory: String? = nil
        ) {
            self.name = name
            self.token = token
            self.bare = bare
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
        let homeDirectory = config.homeDirectory(for: request.name)
        try FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: homeDirectory, withIntermediateDirectories: true)

        let cpus = request.cpus ?? config.cpus
        let memory = request.memory ?? config.memory

        // A full box is built from a cached image carrying the toolset and the
        // user account, so creation is near-instant after the first build of
        // each distro. Raw image references can't be prepared this way and fall
        // back to provisioning at runtime.
        var image = resolved.image
        var preparedImage = false

        if !request.bare,
           let token = request.token ?? resolved.viaDefault ?? config.forcedImage,
           let parsed = Distro.parse(token: token) {
            let base = BaseImage(distro: parsed.distro, version: parsed.version, user: user)
            try ensureBaseImage(base, reporter: reporter)
            image = base.reference
            preparedImage = true
        }

        reporter.info(
            "creating box '\(request.name)' from \(image) (cpus=\(cpus) mem=\(memory))")
        reporter.info(
            "host data: \(dataDirectory.path)  ->  \(Self.dataMountPoint)")
        if !request.bare {
            reporter.info(
                "host home: \(homeDirectory.path)  ->  \(user.homeDirectory)")
        }

        var labels = [
            Label.managed: "1",
            Label.schema: Label.currentSchema,
        ]
        if let distro = resolved.distro { labels[Label.distro] = distro }
        if let token = request.token,
           let parsed = Distro.parse(token: token), let version = parsed.version {
            labels[Label.version] = version
        }
        if !request.bare { labels[Label.user] = user.name }

        var volumes = [(host: dataDirectory.path, guest: Self.dataMountPoint)]
        if !request.bare {
            volumes.append((host: homeDirectory.path, guest: user.homeDirectory))
        }

        let spec = ContainerClient.RunSpec(
            name: request.name,
            image: image,
            cpus: cpus,
            memory: memory,
            volumes: volumes,
            labels: labels
        )

        try client.create(spec) { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { reporter.detail(trimmed) }
        }

        // Brief settle so the box reports an IP.
        Thread.sleep(forTimeInterval: 1.0)

        if !request.bare {
            // A raw image reference never went through the builder, so the
            // toolset and account still have to be installed here.
            if !preparedImage {
                try provision(request.name, reporter: reporter)
                try ensureUser(request.name, reporter: reporter)
            }
            try seedHome(request.name, reporter: reporter)
        }

        reporter.info("box '\(request.name)' is up.")
        return try requireBox(request.name)
    }

    // MARK: - Base images, user account and home

    /// Build the cached base image for a distro if it isn't already present.
    func ensureBaseImage(_ base: BaseImage, reporter: ProgressReporter) throws {
        if client.imageExists(base.reference) { return }

        reporter.info(
            "building \(base.reference) — one time per distro, later boxes reuse it")
        try client.ensureBuilderRunning()
        try client.build(dockerfile: base.dockerfile, tag: base.reference) { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { reporter.detail(trimmed) }
        }
    }

    /// Create the host-matching user in a box that wasn't built from a prepared
    /// image. Idempotent.
    public func ensureUser(_ name: String, reporter: ProgressReporter = SilentReporter()) throws {
        guard let manager = detectPackageManager(name) else {
            throw AppBoxError.noPackageManager(box: name)
        }
        if client.probe(name, shellCommand: "id -u \(user.name) >/dev/null 2>&1") { return }

        reporter.info("creating user '\(user.name)' (uid \(user.uid)) with sudo")
        let script = BaseImage
            .userCreationCommands(for: manager, user: user)
            .joined(separator: " && ")
        let result = try client.exec(name, ["sh", "-c", script])
        guard result.succeeded else {
            throw AppBoxError.commandFailed(
                command: "create user", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Populate an empty persistent home from `/etc/skel`.
    ///
    /// Bind-mounting the host directory over `/home/<user>` hides whatever the
    /// image put there, so without this you land in a shell with no `.bashrc`,
    /// no prompt and no completion.
    public func seedHome(_ name: String, reporter: ProgressReporter = SilentReporter()) throws {
        let guestHome = user.homeDirectory
        let hostHome = config.homeDirectory(for: name)
        let fm = FileManager.default

        // Only seed a home that has never been used.
        let existing = (try? fm.contentsOfDirectory(atPath: hostHome.path)) ?? []
        guard existing.filter({ $0 != ".DS_Store" }).isEmpty else { return }

        // Prefer the distribution's own skeleton where there is one.
        _ = try? client.exec(
            name, ["sh", "-c", "cp -a /etc/skel/. \(guestHome)/ 2>/dev/null || true"])

        // Alpine and some minimal images ship no /etc/skel, so fall back to our
        // own defaults. Written to the host side of the mount, which avoids
        // quoting a heredoc through `sh -c`.
        let seeded = (try? fm.contentsOfDirectory(atPath: hostHome.path)) ?? []
        if !seeded.contains(".bashrc") {
            reporter.info("writing a default shell configuration to \(guestHome)")
            for (filename, contents) in DefaultDotfiles.files {
                try? contents.write(
                    to: hostHome.appendingPathComponent(filename),
                    atomically: true, encoding: .utf8)
            }
        } else {
            reporter.info("seeded \(guestHome) from /etc/skel")
        }

        // Everything must belong to the box user, whichever route created it.
        _ = try? client.exec(
            name, ["sh", "-c", "chown -R \(user.uid):\(user.gid) \(guestHome)"])
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

    /// The account to drop into: the box's own user if it has one, otherwise
    /// root. A box you live in shouldn't put you at a root prompt with no home.
    public func loginUser(_ name: String) -> String? {
        guard let record = try? client.inspect(name),
              let user = record.labels[Label.user],
              client.probe(name, shellCommand: "id -u \(user) >/dev/null 2>&1")
        else { return nil }
        return user
    }

    /// Where an interactive shell should start.
    public func loginDirectory(_ name: String) -> String? {
        loginUser(name).map { "/home/\($0)" }
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
                "kept host data at \(config.dataDirectory(for: name).path)")
            let home = config.homeDirectory(for: name)
            if FileManager.default.fileExists(atPath: home.path) {
                reporter.info("kept home at \(home.path)")
                reporter.info(
                    "recreating '\(name)' will restore this environment "
                        + "(use --purge to delete it instead)")
            } else {
                reporter.info("use --purge to delete it too")
            }
        }
    }
}

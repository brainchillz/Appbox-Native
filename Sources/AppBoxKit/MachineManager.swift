import Foundation

/// appbox's policy layer for **container machines**: what appbox means by a
/// machine, how one is created, provisioned and destroyed.
///
/// Apple's `container machine` already does the hard parts appbox used to do by
/// hand — a real init system, an account matching your Mac user, your home
/// mounted in, storage that survives a stop. What it does not do is make the
/// machine feel furnished: stock images ship no toolset, no `sudo`, no `bash`
/// login shell and an empty home. That gap is this type's whole job, and it is
/// filled with the same `PackageSets` and `DefaultDotfiles` that furnish
/// containers, so the two kinds of box feel identical once you are inside.
public struct MachineManager: Sendable {
    public let client: MachineClient
    public let config: Configuration
    /// The macOS account machines mirror. `container` reads this itself; appbox
    /// keeps it for the paths it has to name before a machine exists.
    public let user: HostUser

    public init(
        client: MachineClient,
        config: Configuration,
        user: HostUser = .current()
    ) {
        self.client = client
        self.config = config
        self.user = user
    }

    // MARK: - Queries

    private func box(from record: MachineRecord) -> Box {
        // The Mac home really is the host directory a machine shares, so it is
        // what "Reveal in Finder" should open — not a per-box copy.
        let sharesHome = (record.homeMount ?? .rw) != HomeMount.none
        let hostHome = sharesHome ? FileManager.default.homeDirectoryForCurrentUser : nil

        return Box(
            kind: .machine,
            name: record.id,
            state: record.status,
            image: record.image?.reference ?? "unknown",
            ipv4: record.ipAddress,
            dataDirectory: nil,
            homeDirectory: hostHome,
            // A machine is by definition one of ours: nothing else can appear
            // in `container machine ls`.
            managed: .labelled,
            distro: record.image.flatMap { Distro.infer(fromImage: $0.reference)?.distro.rawValue },
            user: record.userSetup?.username,
            cpus: record.cpus,
            memory: record.memoryDescription,
            createdAt: record.createdDate,
            diskBytes: record.diskSize,
            homeMount: record.homeMount,
            isDefault: record.isDefault)
    }

    public func list() throws -> [Box] {
        try client.list()
            .map(box(from:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func find(_ name: String) throws -> Box? {
        guard let record = try client.inspect(name) else { return nil }
        // `inspect` carries no default flag, so ask the listing for it.
        var merged = record
        merged.default = (try? client.summaries())?.first { $0.id == name }?.default
        return box(from: merged)
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
        /// Skip the toolset, sudo, bash and dotfiles — the machine as the image
        /// shipped it, with only the account `container` creates.
        public var bare: Bool
        public var cpus: Int?
        public var memory: String?
        public var homeMount: HomeMount?
        public var setDefault: Bool

        public init(
            name: String, token: String? = nil, bare: Bool = false,
            cpus: Int? = nil, memory: String? = nil,
            homeMount: HomeMount? = nil, setDefault: Bool = false
        ) {
            self.name = name
            self.token = token
            self.bare = bare
            self.cpus = cpus
            self.memory = memory
            self.homeMount = homeMount
            self.setDefault = setDefault
        }
    }

    public func resolveImage(for request: CreateRequest) throws -> ResolvedImage {
        try ImageResolver.resolve(token: request.token, config: config, name: request.name)
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

        // Most upstream images cannot boot as a machine — only Alpine, of the
        // distros appbox offers, ships /sbin/init. So a known distro is built
        // into a cached image carrying an init system and the toolset; a raw
        // image reference is taken at its word and used as-is.
        var image = resolved.image
        var prepared = false

        if let distro = resolved.distro {
            let machineImage = MachineImage(distro: distro, version: resolved.version)
            if request.bare {
                reporter.warn(
                    "bare machines boot the image unchanged — "
                        + "\(resolved.image) needs /sbin/init to start at all")
            } else {
                try ensureImage(machineImage, reporter: reporter)
                image = machineImage.reference
                prepared = true
            }
        }

        reporter.info(
            "creating machine '\(request.name)' from \(image)"
                + resourceSummary(request))

        let spec = MachineClient.CreateSpec(
            name: request.name,
            image: image,
            cpus: request.cpus ?? config.cpus,
            memory: request.memory ?? config.memory,
            homeMount: request.homeMount,
            setDefault: request.setDefault)

        try client.create(spec) { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { reporter.detail(trimmed) }
        }

        if !request.bare {
            try waitUntilRunning(request.name, reporter: reporter)
            // Finish the machine's own first-boot setup before piping anything
            // into it. See `MachineClient.warmUp`.
            try? client.warmUp(request.name)

            // A raw image reference never went through the builder, so the
            // toolset still has to be installed here.
            if !prepared {
                try provision(request.name, reporter: reporter)
            }
            try polish(request.name, reporter: reporter)
        }

        let box = try requireBox(request.name)
        if let mount = box.homeMount, mount != HomeMount.none {
            reporter.info("your Mac home is mounted at /Users/\(user.name) (\(mount.summary))")
        }
        reporter.info("machine '\(request.name)' is up.")
        return box
    }

    private func resourceSummary(_ request: CreateRequest) -> String {
        var parts: [String] = []
        if let cpus = request.cpus ?? Optional(config.cpus) { parts.append("cpus=\(cpus)") }
        if let memory = request.memory ?? Optional(config.memory) { parts.append("mem=\(memory)") }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: " ")))"
    }

    /// Build the cached machine image for a distro if it isn't already present.
    func ensureImage(_ image: MachineImage, reporter: ProgressReporter) throws {
        if client.container.imageExists(image.reference) { return }

        reporter.info(
            "building \(image.reference) — one time per distro, later machines reuse it")
        reporter.info("this adds an init system and the standard toolset to \(image.sourceImage)")
        try client.container.ensureBuilderRunning()
        try client.container.build(dockerfile: image.dockerfile, tag: image.reference) { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { reporter.detail(trimmed) }
        }
    }

    // MARK: - Provision

    /// Detect the package manager inside a machine.
    public func detectPackageManager(_ name: String) -> PackageManager? {
        for manager in PackageManager.allCases
        where client.probe(name, script: manager.detectCommand) {
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

        guard let manager = detectPackageManager(name) else {
            throw AppBoxError.noPackageManager(box: name)
        }

        reporter.info("installing standard CLI toolset via \(manager.rawValue)…")

        try client.runScriptChecked(
            name, PackageSets.installCommand(for: manager), asRoot: true,
            describedAs: "\(manager.rawValue) install",
            onOutputLine: { reporter.detail($0) },
            onErrorLine: { reporter.detail($0) })

        reporter.info(
            "provisioning complete — 'ip', 'curl', 'dig', 'vim', 'sudo', etc. are now available.")
    }

    /// Finish what `container`'s first-boot setup leaves undone: sudo, a bash
    /// login shell, and a furnished home.
    ///
    /// Idempotent, and safe on a machine created from someone else's image —
    /// every step checks before it acts. Runs as root, since the point is to
    /// change things the box user cannot.
    public func polish(
        _ name: String,
        reporter: ProgressReporter = SilentReporter()
    ) throws {
        guard let account = try client.inspect(name)?.userSetup else {
            reporter.warn("no user account in '\(name)' — skipping sudo, shell and dotfiles")
            return
        }

        reporter.info("giving \(account.username) sudo, a bash shell and a starting home")

        let result = try client.runScript(
            name, polishScript(for: account), asRoot: true,
            onOutputLine: { reporter.detail($0) },
            onErrorLine: { reporter.detail($0) })

        // Cosmetic finishing: a machine that works but has /bin/sh is still a
        // working machine, so this reports rather than throws.
        if !result.succeeded {
            reporter.warn(
                "could not finish setting up \(account.username) "
                    + "(exit \(result.exitCode)) — the machine is usable regardless")
        }
    }

    /// The script `polish` pipes into the machine.
    ///
    /// Written for `/bin/sh`, since bash may be exactly what is missing, and
    /// with the dotfiles as heredocs — they go on the machine's own disk, which
    /// the Mac cannot write to directly.
    func polishScript(for account: MachineUser) -> String {
        let name = account.username
        let home = account.homeDirectory

        return """
            set -u

            # A bash login shell, if bash made it into the image. usermod comes
            # from shadow, which minimal images skip — hence the awk fallback.
            if [ -x /bin/bash ]; then
              if command -v usermod >/dev/null 2>&1; then
                usermod -s /bin/bash \(name) 2>/dev/null || true
              else
                awk -F: -v u=\(name) 'BEGIN{OFS=":"} $1==u{$7="/bin/bash"} {print}' \
                  /etc/passwd > /etc/passwd.appbox && mv /etc/passwd.appbox /etc/passwd
              fi
            fi

            # Passwordless sudo, matching how the account behaves on the Mac.
            if command -v sudo >/dev/null 2>&1; then
              mkdir -p /etc/sudoers.d
              printf '%s ALL=(ALL) NOPASSWD:ALL\\n' \(name) > /etc/sudoers.d/\(name)
              chmod 0440 /etc/sudoers.d/\(name)
            fi

            # Furnish an empty home. Prefer the distribution's own skeleton, and
            # fall back to appbox's defaults where there is none (Alpine ships
            # no /etc/skel at all).
            mkdir -p \(home)
            if [ ! -e \(home)/.bashrc ] && [ ! -e \(home)/.profile ]; then
              cp -a /etc/skel/. \(home)/ 2>/dev/null || true
            fi
            if [ ! -e \(home)/.bashrc ]; then
              cat > \(home)/.bashrc <<'APPBOX_BASHRC_EOF'
            \(DefaultDotfiles.bashrc)
            APPBOX_BASHRC_EOF
            fi
            if [ ! -e \(home)/.profile ]; then
              cat > \(home)/.profile <<'APPBOX_PROFILE_EOF'
            \(DefaultDotfiles.profile)
            APPBOX_PROFILE_EOF
            fi
            chown -R \(account.uid):\(account.gid) \(home) 2>/dev/null || true
            """
    }

    // MARK: - Lifecycle

    /// Boot the machine if it is not already running.
    public func ensureRunning(_ name: String) throws {
        guard try !client.isRunning(name) else { return }
        try client.boot(name)
    }

    /// Wait for a freshly created machine to finish booting.
    ///
    /// `container machine create` returns as soon as the machine is registered
    /// and the boot is still in flight. Running a command in that gap fails
    /// with "Inappropriate ioctl for device" — an error that says nothing about
    /// what is actually wrong — so provisioning waits for the machine to report
    /// itself running first.
    public func waitUntilRunning(
        _ name: String,
        timeout: TimeInterval = 60,
        reporter: ProgressReporter = SilentReporter()
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? client.isRunning(name)) == true { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        reporter.warn("'\(name)' has not finished booting after \(Int(timeout))s")
        throw AppBoxError.commandFailed(
            command: "boot machine '\(name)'",
            exitCode: 1,
            stderr: "the machine did not reach a running state — "
                + "check 'container machine logs --boot \(name)'")
    }

    public func start(_ name: String) throws {
        guard try client.exists(name) else { throw AppBoxError.boxNotFound(name: name) }
        try client.boot(name)
    }

    public func stop(_ name: String) throws {
        guard try client.exists(name) else { throw AppBoxError.boxNotFound(name: name) }
        try client.stop(name)
    }

    public func restart(_ name: String) throws {
        guard try client.exists(name) else { throw AppBoxError.boxNotFound(name: name) }
        try? client.stop(name)
        try client.boot(name)
    }

    /// Make this the machine `container machine` commands use with no `-n`.
    public func setDefault(_ name: String) throws {
        guard try client.exists(name) else { throw AppBoxError.boxNotFound(name: name) }
        try client.setDefault(name)
    }

    /// Change CPUs, memory or the home-mount mode.
    ///
    /// `container machine set` writes configuration that is read at boot, so a
    /// running machine is stopped first — otherwise the change appears to do
    /// nothing until the next time you happen to restart it.
    public func configure(
        _ name: String,
        cpus: Int? = nil,
        memory: String? = nil,
        homeMount: HomeMount? = nil,
        restart: Bool = true,
        reporter: ProgressReporter = SilentReporter()
    ) throws {
        var settings: [String: String] = [:]
        if let cpus { settings["cpus"] = String(cpus) }
        if let memory { settings["memory"] = memory }
        if let homeMount { settings["home-mount"] = homeMount.rawValue }
        guard !settings.isEmpty else { return }

        let wasRunning = (try? client.isRunning(name)) ?? false
        if wasRunning {
            reporter.info("stopping '\(name)' — machine settings are read at boot")
            try? client.stop(name)
        }

        try client.set(name, settings: settings)
        reporter.info(
            "set " + settings.keys.sorted().map { "\($0)=\(settings[$0]!)" }
                .joined(separator: " "))

        if wasRunning && restart {
            try client.boot(name)
            reporter.info("restarted '\(name)'")
        }
    }

    /// Delete a machine.
    ///
    /// Unlike destroying a container, this always takes the storage with it:
    /// a machine's disk *is* the machine, and `container machine delete` has no
    /// option to keep it. Anything in your Mac home is untouched — that lives
    /// on the Mac, mounted in, and is the reason not to keep work anywhere else.
    public func destroy(
        _ name: String,
        reporter: ProgressReporter = SilentReporter()
    ) throws {
        guard try client.exists(name) else { throw AppBoxError.boxNotFound(name: name) }

        try? client.stop(name)
        try client.delete(name)
        reporter.info("deleted machine '\(name)' and its disk")
        reporter.info("your Mac home was mounted in, not copied — nothing there was touched")
    }
}

import Foundation

/// Typed wrapper around `container machine`, Apple's container-machine
/// subcommand.
///
/// A machine is what appbox spent its first two versions imitating: a
/// persistent Linux environment running the image's own init, with an account
/// matching the host user and the Mac home mounted in. Where `ContainerClient`
/// drives `container run --init … sleep infinity`, this drives the real thing.
///
/// Composes `ContainerClient` rather than duplicating it — same binary, same
/// discovery, same process plumbing.
public struct MachineClient: Sendable {
    public let container: ContainerClient

    public init(container: ContainerClient) {
        self.container = container
    }

    public var binary: URL { container.binary }

    // MARK: - Availability

    /// Whether this `container` install has machine support at all.
    ///
    /// Machines arrived in `container` 1.1.0; an older CLI has no `machine`
    /// subcommand and simply exits non-zero. Callers must degrade gracefully
    /// rather than showing errors — plenty of people are still on 1.0.
    public func isSupported() -> Bool {
        (try? container.run(["machine", "list", "--quiet"]))?.succeeded ?? false
    }

    // MARK: - Raw invocation

    @discardableResult
    func run(
        _ arguments: [String],
        stdin: String? = nil,
        onOutputLine: (@Sendable (String) -> Void)? = nil,
        onErrorLine: (@Sendable (String) -> Void)? = nil
    ) throws -> ProcessResult {
        try ProcessRunner.run(
            binary, ["machine"] + arguments, stdin: stdin,
            onOutputLine: onOutputLine, onErrorLine: onErrorLine)
    }

    @discardableResult
    func runChecked(
        _ arguments: [String],
        stdin: String? = nil,
        onOutputLine: (@Sendable (String) -> Void)? = nil,
        onErrorLine: (@Sendable (String) -> Void)? = nil
    ) throws -> ProcessResult {
        let result = try run(
            arguments, stdin: stdin, onOutputLine: onOutputLine, onErrorLine: onErrorLine)
        guard result.succeeded else {
            throw AppBoxError.commandFailed(
                command: "container machine " + arguments.joined(separator: " "),
                exitCode: result.exitCode,
                stderr: result.stderr)
        }
        return result
    }

    // MARK: - Queries

    /// Machines with everything both `list` and `inspect` know.
    ///
    /// `list` is one cheap call but omits the image, the home-mount mode and
    /// the account; `inspect` has those but not the default flag. Merging costs
    /// one extra call per machine, which is fine for the handful of machines
    /// anyone actually keeps.
    public func list() throws -> [MachineRecord] {
        try summaries().map { summary in
            (try? inspect(summary.id)).flatMap { $0 }
                .map { summary.merging(detail: $0) } ?? summary
        }
    }

    /// The cheap listing, without per-machine detail.
    public func summaries() throws -> [MachineRecord] {
        let result = try run(["list", "--format", "json"])
        guard result.succeeded else {
            if result.stderr.contains("container system start")
                || result.stderr.contains("XPC connection error") {
                throw AppBoxError.containerServiceNotRunning
            }
            throw AppBoxError.commandFailed(
                command: "container machine list",
                exitCode: result.exitCode, stderr: result.stderr)
        }
        return try decode(result.stdout, command: "container machine list")
    }

    public func inspect(_ name: String) throws -> MachineRecord? {
        let result = try run(["inspect", name])
        guard result.succeeded else { return nil }
        return try decode(result.stdout, command: "container machine inspect").first
    }

    private func decode(_ json: String, command: String) throws -> [MachineRecord] {
        guard let data = json.data(using: .utf8) else {
            throw AppBoxError.malformedOutput(command: command, detail: "output was not UTF-8")
        }
        do {
            return try JSONDecoder().decode([MachineRecord].self, from: data)
        } catch {
            throw AppBoxError.malformedOutput(
                command: command, detail: String(describing: error))
        }
    }

    public func exists(_ name: String) throws -> Bool {
        try summaries().contains { $0.id == name }
    }

    public func isRunning(_ name: String) throws -> Bool {
        try summaries().contains { $0.id == name && $0.status == .running }
    }

    /// The machine `container machine run` uses when given no `-n`.
    public func defaultName() throws -> String? {
        try summaries().first { $0.isDefault }?.id
    }

    // MARK: - Create

    /// Everything needed to create a machine, in one place, so the CLI and the
    /// app cannot construct subtly different machines.
    public struct CreateSpec: Sendable {
        public var name: String
        public var image: String
        public var cpus: Int?
        public var memory: String?
        public var homeMount: HomeMount?
        public var setDefault: Bool
        public var boot: Bool
        /// Nested virtualization. Needs an M3 or later, macOS 15+, and a kernel
        /// built with CONFIG_KVM=y — which the stock kernel is not, so this
        /// travels with `kernel`.
        public var virtualization: Bool
        public var kernel: String?

        public init(
            name: String,
            image: String,
            cpus: Int? = nil,
            memory: String? = nil,
            homeMount: HomeMount? = nil,
            setDefault: Bool = false,
            boot: Bool = true,
            virtualization: Bool = false,
            kernel: String? = nil
        ) {
            self.name = name
            self.image = image
            self.cpus = cpus
            self.memory = memory
            self.homeMount = homeMount
            self.setDefault = setDefault
            self.boot = boot
            self.virtualization = virtualization
            self.kernel = kernel
        }

        public var arguments: [String] {
            var arguments = ["create", "--name", name]
            if let cpus { arguments += ["--cpus", String(cpus)] }
            if let memory { arguments += ["--memory", memory] }
            if let homeMount { arguments += ["--home-mount", homeMount.rawValue] }
            if setDefault { arguments.append("--set-default") }
            if !boot { arguments.append("--no-boot") }
            if virtualization { arguments.append("--virtualization") }
            if let kernel, !kernel.isEmpty { arguments += ["--kernel", kernel] }
            arguments.append(image)
            return arguments
        }
    }

    public func create(
        _ spec: CreateSpec, onProgressLine: (@Sendable (String) -> Void)? = nil
    ) throws {
        try runChecked(
            spec.arguments, onOutputLine: onProgressLine, onErrorLine: onProgressLine)
    }

    // MARK: - Lifecycle

    /// Boot a stopped machine.
    ///
    /// There is no `machine start`: booting happens as a side effect of `run`,
    /// so this runs the cheapest possible command in a detached process purely
    /// for that effect.
    public func boot(_ name: String) throws {
        try runChecked(["run", "--name", name, "--detach", "--", "/bin/true"])
    }

    public func stop(_ name: String) throws {
        try runChecked(["stop", name])
    }

    public func delete(_ name: String) throws {
        try runChecked(["delete", name])
    }

    public func setDefault(_ name: String) throws {
        try runChecked(["set-default", name])
    }

    /// Change configuration. Takes effect on the machine's next boot, which is
    /// why callers generally stop it first.
    public func set(_ name: String, settings: [String: String]) throws {
        guard !settings.isEmpty else { return }
        let pairs = settings.keys.sorted().map { "\($0)=\(settings[$0]!)" }
        try runChecked(["set", "--name", name] + pairs)
    }

    // MARK: - Running things inside

    /// Get a machine's first `run` out of the way.
    ///
    /// The first `container machine run` after a create does the last of the
    /// first-boot setup, and that path cannot cope with a piped stdin: it fails
    /// with "Inappropriate ioctl for device", which sounds like a terminal
    /// problem and is not. A plain command with no stdin gets past it, and
    /// every later run — piped or not — then works.
    public func warmUp(_ name: String) throws {
        try runChecked(["run", "--name", name, "--", "/bin/true"])
    }

    /// Run a shell script inside a machine, booting it first if needed.
    ///
    /// The script travels on **stdin**, not as `sh -c '<script>'`. `container
    /// machine run` re-tokenises its trailing arguments: a multi-word script
    /// arrives with words dropped or appended to the wrong place, so
    /// `apt-get install -y curl vim` silently becomes something else. Piping to
    /// `sh` sidesteps its argument handling entirely, and needs `--interactive`
    /// because stdin is otherwise not forwarded.
    @discardableResult
    public func runScript(
        _ name: String,
        _ script: String,
        asRoot: Bool = false,
        onOutputLine: (@Sendable (String) -> Void)? = nil,
        onErrorLine: (@Sendable (String) -> Void)? = nil
    ) throws -> ProcessResult {
        var arguments = ["run", "--name", name, "--interactive"]
        if asRoot { arguments.append("--root") }
        arguments += ["--", "/bin/sh"]

        let result = try run(
            arguments, stdin: script,
            onOutputLine: onOutputLine, onErrorLine: onErrorLine)

        // A machine nobody has run anything in yet refuses piped stdin. Warm it
        // up and try once more rather than reporting a puzzle.
        if !result.succeeded, Self.isFirstRunFailure(result) {
            try? warmUp(name)
            return try run(
                arguments, stdin: script,
                onOutputLine: onOutputLine, onErrorLine: onErrorLine)
        }

        return result
    }

    static func isFirstRunFailure(_ result: ProcessResult) -> Bool {
        (result.stderr + result.stdout).contains("Inappropriate ioctl for device")
    }

    /// Run a script and throw if it fails.
    @discardableResult
    public func runScriptChecked(
        _ name: String,
        _ script: String,
        asRoot: Bool = false,
        describedAs description: String,
        onOutputLine: (@Sendable (String) -> Void)? = nil,
        onErrorLine: (@Sendable (String) -> Void)? = nil
    ) throws -> ProcessResult {
        let result = try runScript(
            name, script, asRoot: asRoot,
            onOutputLine: onOutputLine, onErrorLine: onErrorLine)
        guard result.succeeded else {
            throw AppBoxError.commandFailed(
                command: description, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    /// True when a shell probe exits 0 inside the machine.
    public func probe(_ name: String, script: String) -> Bool {
        ((try? runScript(name, script, asRoot: true))?.succeeded) ?? false
    }

    /// Replace this process with an interactive shell in the machine. `machine
    /// run` already lands as the host-matching user in their home, so there is
    /// no `--user` or `--workdir` to work out. Only returns on failure.
    public func runInteractive(_ name: String, asRoot: Bool = false) throws -> Never {
        var arguments = ["machine", "run", "--name", name]
        if asRoot { arguments.append("--root") }
        try ProcessRunner.replaceCurrentProcess(binary, arguments)
    }

    /// Recent log output as one blob, for a view that shows rather than tails.
    public func logText(_ name: String, boot: Bool = false, lines: Int? = nil) -> String {
        var arguments = ["logs"]
        if boot { arguments.append("--boot") }
        if let lines { arguments += ["-n", String(lines)] }
        arguments.append(name)
        guard let result = try? run(arguments) else { return "" }
        return result.stdout + result.stderr
    }

    public func logs(
        _ name: String,
        boot: Bool = false,
        follow: Bool = false,
        lines: Int? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) throws {
        var arguments = ["logs"]
        if boot { arguments.append("--boot") }
        if follow { arguments.append("--follow") }
        if let lines { arguments += ["-n", String(lines)] }
        arguments.append(name)
        try run(arguments, onOutputLine: onLine, onErrorLine: onLine)
    }
}

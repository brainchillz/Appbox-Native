import Foundation

/// Typed wrapper around Apple's `container` CLI.
///
/// Everything appbox knows about talking to `container` lives here. The CLI and
/// the menu bar app both go through this type, so neither can accidentally
/// invent its own invocation or output parsing.
public struct ContainerClient: Sendable {
    public let binary: URL

    public init(binary: URL) {
        self.binary = binary
    }

    /// Locate the `container` binary without relying on an interactive shell's
    /// PATH. `APPBOX_CONTAINER_BIN` overrides discovery.
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ContainerClient {
        guard let binary = ProcessRunner.locate(
            "container",
            override: environment["APPBOX_CONTAINER_BIN"],
            environment: environment
        ) else {
            throw AppBoxError.containerCLINotFound
        }
        return ContainerClient(binary: binary)
    }

    // MARK: - Raw invocation

    @discardableResult
    public func run(
        _ arguments: [String],
        onOutputLine: (@Sendable (String) -> Void)? = nil,
        onErrorLine: (@Sendable (String) -> Void)? = nil
    ) throws -> ProcessResult {
        try ProcessRunner.run(
            binary, arguments, onOutputLine: onOutputLine, onErrorLine: onErrorLine)
    }

    /// Run and throw if the command failed.
    @discardableResult
    public func runChecked(
        _ arguments: [String],
        onOutputLine: (@Sendable (String) -> Void)? = nil,
        onErrorLine: (@Sendable (String) -> Void)? = nil
    ) throws -> ProcessResult {
        let result = try run(arguments, onOutputLine: onOutputLine, onErrorLine: onErrorLine)
        guard result.succeeded else {
            throw AppBoxError.commandFailed(
                command: "container " + arguments.joined(separator: " "),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result
    }

    // MARK: - Service health

    public func isServiceRunning() -> Bool {
        guard let result = try? run(["system", "status"]) else { return false }
        return result.succeeded
    }

    public func startService() throws {
        try runChecked(["system", "start"])
    }

    /// CLI and apiserver versions, for the skew check.
    ///
    /// A mismatch commonly breaks networking with
    /// "no available interface strategy for network default … variant=nil".
    /// The fix is `container system stop && container system start`.
    public func versions() -> (cli: String?, daemon: String?) {
        let cli = (try? run(["--version"]))
            .flatMap { Self.firstSemanticVersion(in: $0.stdout) }

        let daemon = (try? run(["system", "status"]))
            .flatMap { result -> String? in
                let line = result.stdout
                    .split(separator: "\n")
                    .first { $0.lowercased().contains("apiserver.version") }
                return line.flatMap { Self.firstSemanticVersion(in: String($0)) }
            }

        return (cli, daemon)
    }

    public func versionSkew() -> (cli: String, daemon: String)? {
        let found = versions()
        guard let cli = found.cli, let daemon = found.daemon, cli != daemon else {
            return nil
        }
        return (cli, daemon)
    }

    static func firstSemanticVersion(in text: String) -> String? {
        // Matches the first x.y.z in strings like
        // "container CLI version 1.1.0 (build: release, commit: 5973b9c)".
        guard let range = text.range(
            of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression
        ) else { return nil }
        return String(text[range])
    }

    // MARK: - Queries

    public func list(all: Bool = true) throws -> [ContainerRecord] {
        var arguments = ["list", "--format", "json"]
        if all { arguments.insert("--all", at: 1) }

        let result = try run(arguments)
        guard result.succeeded else {
            // The service being down is by far the most common cause and
            // deserves its own actionable error.
            if result.stderr.contains("container system start")
                || result.stderr.contains("XPC connection error") {
                throw AppBoxError.containerServiceNotRunning
            }
            throw AppBoxError.commandFailed(
                command: "container list", exitCode: result.exitCode, stderr: result.stderr)
        }

        return try decodeRecords(from: result.stdout, command: "container list")
    }

    public func inspect(_ name: String) throws -> ContainerRecord? {
        let result = try run(["inspect", name])
        guard result.succeeded else { return nil }
        return try decodeRecords(from: result.stdout, command: "container inspect").first
    }

    private func decodeRecords(from json: String, command: String) throws -> [ContainerRecord] {
        guard let data = json.data(using: .utf8) else {
            throw AppBoxError.malformedOutput(command: command, detail: "output was not UTF-8")
        }
        do {
            return try JSONDecoder().decode([ContainerRecord].self, from: data)
        } catch {
            throw AppBoxError.malformedOutput(
                command: command, detail: String(describing: error))
        }
    }

    public func exists(_ name: String) throws -> Bool {
        try list(all: true).contains { $0.id == name }
    }

    public func isRunning(_ name: String) throws -> Bool {
        try list(all: true).contains { $0.id == name && $0.state == .running }
    }

    // MARK: - Lifecycle

    /// Everything needed to create a box, in one place, so the CLI and the app
    /// cannot construct subtly different containers.
    public struct RunSpec: Sendable {
        public var name: String
        public var image: String
        public var cpus: Int
        public var memory: String
        public var volumes: [(host: String, guest: String)]
        public var labels: [String: String]
        /// Init process to keep a system container alive.
        public var command: [String]
        public var useInit: Bool

        public init(
            name: String,
            image: String,
            cpus: Int,
            memory: String,
            volumes: [(host: String, guest: String)] = [],
            labels: [String: String] = [:],
            command: [String] = ["sleep", "infinity"],
            useInit: Bool = true
        ) {
            self.name = name
            self.image = image
            self.cpus = cpus
            self.memory = memory
            self.volumes = volumes
            self.labels = labels
            self.command = command
            self.useInit = useInit
        }

        public var arguments: [String] {
            var arguments = ["run", "--detach", "--name", name]
            arguments += ["--cpus", String(cpus), "--memory", memory]
            if useInit { arguments.append("--init") }
            for volume in volumes {
                arguments += ["--volume", "\(volume.host):\(volume.guest)"]
            }
            // Sorted so the command line is deterministic and testable.
            for key in labels.keys.sorted() {
                arguments += ["--label", "\(key)=\(labels[key]!)"]
            }
            arguments.append(image)
            arguments += command
            return arguments
        }
    }

    public func create(_ spec: RunSpec, onProgressLine: (@Sendable (String) -> Void)? = nil) throws {
        try runChecked(spec.arguments, onOutputLine: onProgressLine, onErrorLine: onProgressLine)
    }

    public func start(_ name: String) throws {
        try runChecked(["start", name])
    }

    public func stop(_ name: String) throws {
        try runChecked(["stop", name])
    }

    /// Delete a container. Tolerates it already being gone.
    public func delete(_ name: String) throws {
        let result = try run(["delete", name])
        if !result.succeeded {
            _ = try? run(["rm", name])
        }
    }

    // MARK: - Exec and logs

    @discardableResult
    public func exec(
        _ name: String,
        _ command: [String],
        onOutputLine: (@Sendable (String) -> Void)? = nil,
        onErrorLine: (@Sendable (String) -> Void)? = nil
    ) throws -> ProcessResult {
        try run(["exec", name] + command,
                onOutputLine: onOutputLine, onErrorLine: onErrorLine)
    }

    /// Run a shell probe inside the box; true when it exits 0.
    public func probe(_ name: String, shellCommand: String) -> Bool {
        let result = try? exec(name, ["sh", "-c", shellCommand])
        return result?.succeeded ?? false
    }

    // MARK: - Images

    public func imageExists(_ reference: String) -> Bool {
        (try? run(["image", "inspect", reference]))?.succeeded ?? false
    }

    /// Build an image from a generated Dockerfile.
    ///
    /// The build context is a throwaway directory containing only the
    /// Dockerfile — nothing here needs local files, and an empty context keeps
    /// the build fast.
    public func build(
        dockerfile: String,
        tag: String,
        onProgressLine: (@Sendable (String) -> Void)? = nil
    ) throws {
        let context = FileManager.default.temporaryDirectory
            .appendingPathComponent("appbox-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: context) }

        let path = context.appendingPathComponent("Dockerfile")
        try dockerfile.write(to: path, atomically: true, encoding: .utf8)

        try runChecked(
            ["build", "--tag", tag, "--file", path.path, context.path],
            onOutputLine: onProgressLine, onErrorLine: onProgressLine)
    }

    /// `container build` needs the builder VM running; it is not started
    /// automatically.
    public func ensureBuilderRunning() throws {
        if let status = try? run(["builder", "status"]),
           status.succeeded, status.stdout.contains("running") {
            return
        }
        try runChecked(["builder", "start"])
    }

    /// Replace this process with an interactive `container exec -it`, so the
    /// child gets the real TTY. Only returns on failure.
    public func execInteractive(
        _ name: String,
        command: [String],
        user: String? = nil,
        workdir: String? = nil
    ) throws -> Never {
        var arguments = ["exec", "-it"]
        if let user { arguments += ["--user", user] }
        if let workdir { arguments += ["--workdir", workdir] }
        arguments.append(name)
        try ProcessRunner.replaceCurrentProcess(binary, arguments + command)
    }

    public func logs(
        _ name: String,
        follow: Bool = false,
        onLine: @escaping @Sendable (String) -> Void
    ) throws {
        var arguments = ["logs"]
        if follow { arguments.append("--follow") }
        arguments.append(name)
        try run(arguments, onOutputLine: onLine, onErrorLine: onLine)
    }
}

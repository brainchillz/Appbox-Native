import AppBoxKit
import ArgumentParser
import Foundation

let appboxVersion = "0.3.0"

/// Prints progress in the same idiom the bash script used, so muscle memory and
/// existing docs still apply. Everything goes to stderr, leaving stdout clean
/// for machine-readable output (`ip`, `list`).
struct CLIReporter: ProgressReporter {
    var quiet = false

    func info(_ message: String) {
        guard !quiet else { return }
        FileHandle.standardError.write(Data("\u{1B}[36m==>\u{1B}[0m \(message)\n".utf8))
    }

    func warn(_ message: String) {
        FileHandle.standardError.write(
            Data("\u{1B}[33mwarning:\u{1B}[0m \(message)\n".utf8))
    }

    func detail(_ line: String) {
        guard !quiet else { return }
        FileHandle.standardError.write(Data("    \(line)\n".utf8))
    }
}

/// Shared setup for every command that touches containers — the equivalent of
/// the script's `need_container`.
enum Context {
    /// Both kinds of box behind one door. Every command goes through this.
    static func makeService(reporter: CLIReporter = CLIReporter()) throws -> BoxService {
        let service = try BoxService.discover()

        guard service.isServiceRunning() else {
            throw AppBoxError.containerServiceNotRunning
        }

        // A CLI/daemon version skew commonly breaks networking with
        // "no available interface strategy for network default … variant=nil".
        if let skew = service.client.versionSkew() {
            reporter.warn(
                "container CLI (\(skew.cli)) and daemon (\(skew.daemon)) versions differ.")
            reporter.warn("  this commonly breaks networking. Restart the daemon to match:")
            reporter.warn("    container system stop && container system start")
        }

        return service
    }

    static func makeManager(reporter: CLIReporter = CLIReporter()) throws -> BoxManager {
        try makeService(reporter: reporter).boxes
    }

    /// Resolve a name to a box, or fail with a message naming what does exist.
    static func requireBox(_ name: String, in service: BoxService) throws -> Box {
        guard let box = try service.find(name) else {
            throw AppBoxError.boxNotFound(name: name)
        }
        return box
    }
}

/// Shown when `create <name>` runs with no distro and no configured default.
/// We deliberately refuse to silently pick Ubuntu.
func printCreateGuidance(name: String) {
    let text = """
        No distribution specified for '\(name)'. Pick one:

          appbox create-ubuntu  \(name) [24.04|26.04|latest]   (bare = newest LTS)
          appbox create-debian  \(name) [version|latest]
          appbox create-fedora  \(name) [43|44|latest]
          appbox create-rocky   \(name) [9|10|latest]          (latest = 10)
          appbox create-alpine  \(name) [version|latest]
          appbox create-arch    \(name)                        (rolling — always latest)

        Each makes a container machine, fully provisioned. Add --container for a
        classic box with a private home and /data, or --bare to skip the toolset.

        Tip: set a default so a plain 'appbox create <name>' just works:
          appbox set-default ubuntu

        """
    FileHandle.standardError.write(Data(text.utf8))
}

/// Common options shared by the create commands.
struct CreateOptions: ParsableArguments {
    @Option(name: .customLong("cpus"), help: "CPUs to allocate (default: $APPBOX_CPUS or 4).")
    var cpus: Int?

    @Option(name: .customLong("memory"), help: "Memory to allocate (default: $APPBOX_MEMORY or 2G).")
    var memory: String?

    @Flag(name: .customLong("machine"),
          help: "Make a container machine — real init, your Mac home mounted in. The default.")
    var machine = false

    @Flag(name: .customLong("container"),
          help: "Make a classic appbox container instead: private home plus /data, no init.")
    var container = false

    @Option(name: .customLong("home-mount"),
            help: "Machines only: how your Mac home is mounted (rw, ro, none).")
    var homeMount: String?

    @Flag(name: .customLong("default"),
          help: "Machines only: make this the default for 'container machine' commands.")
    var setDefault = false

    /// The kind to create, or nil to take the service's default.
    func kind() throws -> BoxKind? {
        switch (machine, container) {
        case (true, true):
            throw AppBoxError.usage("--machine and --container are mutually exclusive")
        case (true, false): return .machine
        case (false, true): return .container
        case (false, false): return nil
        }
    }

    func parsedHomeMount() throws -> HomeMount? {
        guard let homeMount else { return nil }
        guard let mount = HomeMount(rawValue: homeMount.lowercased()) else {
            throw AppBoxError.usage(
                "--home-mount must be rw, ro or none (got '\(homeMount)')")
        }
        return mount
    }
}

extension BoxService {
    /// Create from parsed options, reporting what kind you got and why.
    @discardableResult
    func create(
        name: String,
        token: String?,
        bare: Bool,
        options: CreateOptions,
        reporter: CLIReporter
    ) throws -> Box {
        let requested = try options.kind()
        let kind = requested ?? defaultKind

        if kind == .container && requested == nil {
            reporter.warn(
                "this 'container' has no machine support — making a classic box instead")
        }
        if kind == .container && (options.homeMount != nil || options.setDefault) {
            reporter.warn("--home-mount and --default apply to machines only; ignoring")
        }

        return try create(
            kind: kind,
            name: name,
            token: token,
            bare: bare,
            cpus: options.cpus,
            memory: options.memory,
            homeMount: try options.parsedHomeMount(),
            setDefault: options.setDefault,
            reporter: reporter)
    }
}

extension BoxService {
    /// Shared implementation behind every `create-<distro>` command.
    func createFromDistro(
        _ distro: Distro,
        arguments: [String],
        options: CreateOptions,
        reporter: CLIReporter
    ) throws {
        let parsed = try NameVersion.parse(arguments)

        guard let name = parsed.name else {
            throw AppBoxError.usage(
                "usage: appbox create-\(distro.rawValue) <name> "
                    + (distro.isRolling ? "[--bare]" : "[version|latest] [--bare]"))
        }

        var version = parsed.version

        if distro.isRolling, let requested = version, requested != "latest" {
            reporter.info(
                "\(distro.rawValue) is rolling-release; ignoring version "
                    + "'\(requested)' (always latest)")
            version = nil
        }

        // Rocky publishes no `latest` tag, so only the majors we know exist are
        // accepted rather than silently producing a 404 on pull.
        if distro == .rocky, let requested = version {
            guard ["9", "10", "latest"].contains(requested) else {
                throw AppBoxError.invalidRockyVersion(requested)
            }
        }

        let token = version.map { "\(distro.rawValue)\($0 == "latest" ? "" : $0)" }
            ?? distro.rawValue

        let box = try create(
            name: name, token: token, bare: parsed.bare,
            options: options, reporter: reporter)

        printInfo(box)
        FileHandle.standardError.write(
            Data("\nShell in with:  \u{1B}[1mappbox shell \(name)\u{1B}[0m\n".utf8))
    }
}

/// Render the `info` block. Shared by `info` and the tail of `create`.
func printInfo(_ box: Box) {
    func field(_ label: String, _ value: String) {
        print(label.padding(toLength: 11, withPad: " ", startingAt: 0) + value)
    }

    field("name:", box.name)
    field("kind:", box.kind.rawValue)
    field("state:", box.state.rawValue)
    field("ip:", box.ipv4 ?? "<none>")
    field("image:", box.image)
    if let distro = box.distro { field("distro:", distro) }
    field("cpus:", String(box.cpus))
    field("memory:", box.memory)
    if let user = box.user { field("user:", user) }

    switch box.kind {
    case .machine:
        if let disk = box.diskDescription {
            field("disk:", "\(disk) used (the volume inside reports ~500G — it is sparse)")
        }
        // Host and guest paths are the same string here: your Mac home is
        // mounted at its own path inside the machine.
        let mount = box.homeMount ?? .rw
        if mount == HomeMount.none {
            field("mac home:", "not mounted (--home-mount none)")
        } else if let home = box.homeDirectory {
            field("mac home:", "\(home.path)  (same path inside, \(mount.summary))")
        }
        field("linux home:", "/home/\(box.user ?? NSUserName())  (on the machine's own disk)")
        if box.isDefault {
            field("default:", "yes — 'container machine' commands with no -n use this one")
        }
    case .container:
        if let home = box.homeDirectory { field("home:", home.path) }
        if let data = box.dataDirectory { field("data:", "\(data.path)  (mounted at /data)") }
        if box.managed == .inferred {
            field("managed:", "yes (detected by shape — created before appbox added labels)")
        } else if box.managed == .foreign {
            field("managed:", "no (not an appbox box)")
        }
    }
}

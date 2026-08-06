import AppBoxKit
import ArgumentParser
import Foundation

@main
struct AppBox: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appbox",
        abstract: "Persistent Linux machines on Apple Silicon, from one command.",
        discussion: """
            A box is a named, persistent Linux environment you shell into,
            install packages in, and whose state survives stop/start. There are
            two kinds, and appbox drives both:

              machine    Apple's container machine. Runs the image's own init,
                         so systemd services work, and mounts your Mac home at
                         /Users/<you>. The default where 'container' supports it.
              container  appbox's original box. A private home directory and
                         $APPBOX_HOME/<name>/data mounted at /data, both kept
                         when the box is destroyed. No init system.

            Pass --machine or --container to 'create' to choose. Everything else
            works out which kind a box is on its own.

            CONFIG (environment overrides):
              APPBOX_HOME, APPBOX_IMAGE, APPBOX_CONFIG_DIR, APPBOX_CPUS,
              APPBOX_MEMORY, APPBOX_DEFAULT_DISTRO, APPBOX_CONTAINER_BIN
            """,
        version: appboxVersion,
        subcommands: [
            Create.self,
            CreateUbuntu.self, CreateDebian.self, CreateAlpine.self,
            CreateFedora.self, CreateRocky.self, CreateArch.self,
            SetDefault.self,
            Provision.self,
            Shell.self, Exec.self,
            Start.self, Stop.self, Restart.self,
            Use.self, Set.self,
            List.self, IP.self, Info.self, Destroy.self,
        ],
        defaultSubcommand: List.self
    )
}

// MARK: - Create

extension AppBox {
    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create and start a persistent box.",
            discussion: """
                With no distro argument, appbox uses $APPBOX_IMAGE, then the distro
                saved by 'set-default'. If neither is set it prints the distro menu
                rather than silently picking one.

                Creates a container machine unless you pass --container.
                """)

        @Argument(help: "Name of the box.")
        var name: String

        @Argument(help: "Distro shortcut (ubuntu, fedora43, rocky9…) or a raw image reference.")
        var token: String?

        @Flag(name: .long, help: "Skip the toolset and account setup — the image as it shipped.")
        var bare = false

        @OptionGroup var options: CreateOptions

        func run() throws {
            let reporter = CLIReporter()
            let service = try Context.makeService(reporter: reporter)

            // Surface the distro menu instead of a bare error.
            do {
                _ = try service.resolveImage(token: token, name: name)
            } catch AppBoxError.noDistroSpecified {
                printCreateGuidance(name: name)
                throw ExitCode(1)
            }

            let box = try service.create(
                name: name, token: token, bare: bare, options: options, reporter: reporter)
            printInfo(box)
            FileHandle.standardError.write(
                Data("\nShell in with:  \u{1B}[1mappbox shell \(name)\u{1B}[0m\n".utf8))
        }
    }
}

/// The per-distro create commands. Each accepts <name> and an optional
/// [version] in either order, plus --full anywhere.
protocol DistroCreateCommand: ParsableCommand {
    static var distro: Distro { get }
    var arguments: [String] { get }
    var bare: Bool { get }
    var options: CreateOptions { get }
}

extension DistroCreateCommand {
    func run() throws {
        let reporter = CLIReporter()
        let service = try Context.makeService(reporter: reporter)
        try service.createFromDistro(
            Self.distro,
            arguments: bare ? arguments + ["--bare"] : arguments,
            options: options,
            reporter: reporter)
    }
}

extension AppBox {
    struct CreateUbuntu: DistroCreateCommand {
        static let distro = Distro.ubuntu
        static let configuration = CommandConfiguration(
            commandName: "create-ubuntu",
            abstract: "Create an Ubuntu box (default: latest = newest LTS).")
        @Argument(help: "<name> and optional [24.04|26.04|latest], in either order.")
        var arguments: [String] = []
        @Flag(name: .long) var bare = false
        @OptionGroup var options: CreateOptions
    }

    struct CreateDebian: DistroCreateCommand {
        static let distro = Distro.debian
        static let configuration = CommandConfiguration(
            commandName: "create-debian",
            abstract: "Create a Debian box (default: latest).")
        @Argument(help: "<name> and optional [version|latest], in either order.")
        var arguments: [String] = []
        @Flag(name: .long) var bare = false
        @OptionGroup var options: CreateOptions
    }

    struct CreateAlpine: DistroCreateCommand {
        static let distro = Distro.alpine
        static let configuration = CommandConfiguration(
            commandName: "create-alpine",
            abstract: "Create an Alpine box (default: latest).")
        @Argument(help: "<name> and optional [version|latest], in either order.")
        var arguments: [String] = []
        @Flag(name: .long) var bare = false
        @OptionGroup var options: CreateOptions
    }

    struct CreateFedora: DistroCreateCommand {
        static let distro = Distro.fedora
        static let configuration = CommandConfiguration(
            commandName: "create-fedora",
            abstract: "Create a Fedora box (default: latest).")
        @Argument(help: "<name> and optional [43|44|latest], in either order.")
        var arguments: [String] = []
        @Flag(name: .long) var bare = false
        @OptionGroup var options: CreateOptions
    }

    struct CreateRocky: DistroCreateCommand {
        static let distro = Distro.rocky
        static let configuration = CommandConfiguration(
            commandName: "create-rocky",
            abstract: "Create a Rocky Linux box (latest = 10; Rocky has no 'latest' tag).")
        @Argument(help: "<name> and optional [9|10|latest], in either order.")
        var arguments: [String] = []
        @Flag(name: .long) var bare = false
        @OptionGroup var options: CreateOptions
    }

    struct CreateArch: DistroCreateCommand {
        static let distro = Distro.arch
        static let configuration = CommandConfiguration(
            commandName: "create-arch",
            abstract: "Create an Arch box (Arch Linux ARM — rolling, always latest).")
        @Argument(help: "<name>.")
        var arguments: [String] = []
        @Flag(name: .long) var bare = false
        @OptionGroup var options: CreateOptions
    }
}

// MARK: - Default distro

extension AppBox {
    struct SetDefault: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-default",
            abstract: "Set, show, or clear the distro used by a bare 'create'.")

        @Argument(help: "Distro to make the default. Omit to show the current one.")
        var distro: String?

        @Flag(name: .long, help: "Remove the saved default.")
        var clear = false

        func run() throws {
            let reporter = CLIReporter()
            let config = Configuration.fromEnvironment()

            if clear {
                try config.clearDefaultDistro()
                reporter.info("default distro cleared")
                return
            }

            guard let distro else {
                if let current = config.defaultDistro() {
                    reporter.info(
                        "default distro: \(current) -> \(Distro.resolveImage(token: current))")
                } else {
                    reporter.info("no default distro set (use 'appbox set-default <distro>')")
                }
                return
            }

            _ = try Distro.parseStrict(token: distro)
            try config.saveDefaultDistro(distro)
            reporter.info(
                "default distro set to '\(distro)' -> \(Distro.resolveImage(token: distro))")
            reporter.info("now 'appbox create <name>' creates a \(distro) box")
        }
    }
}

// MARK: - Lifecycle

extension AppBox {
    struct Provision: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install the standard Unix CLI toolset into an existing box.",
            discussion: """
                On a machine this also finishes the account setup that
                'container' leaves undone: passwordless sudo, a bash login
                shell, and dotfiles in an empty home.
                """)

        @Argument(help: "Name of the box.") var name: String

        func run() throws {
            let reporter = CLIReporter()
            let service = try Context.makeService(reporter: reporter)
            let box = try Context.requireBox(name, in: service)
            try service.ensureRunning(box)
            try service.provision(box, reporter: reporter)
        }
    }

    struct Shell: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open an interactive shell in the box (auto-starts if stopped).",
            aliases: ["attach", "sh"])

        @Argument(help: "Name of the box.") var name: String

        @Flag(name: .long, help: "Machines only: open the shell as root.")
        var root = false

        func run() throws {
            let reporter = CLIReporter()
            let service = try Context.makeService(reporter: reporter)
            let box = try Context.requireBox(name, in: service)

            if !box.isRunning {
                reporter.info("\(box.kind.rawValue) '\(name)' is stopped; starting it…")
            }

            switch box.kind {
            case .machine:
                // `machine run` boots it, picks the login shell and lands as
                // the host-matching user in their home — nothing to work out.
                try service.machines.client.runInteractive(name, asRoot: root)
            case .container:
                try service.ensureRunning(box)
                let manager = service.boxes
                try manager.client.execInteractive(
                    name,
                    command: [manager.preferredShell(name)],
                    user: root ? "root" : manager.loginUser(name),
                    workdir: root ? nil : manager.loginDirectory(name))
            }
        }
    }

    struct Exec: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a command inside the box.")

        @Argument(help: "Name of the box.") var name: String

        @Flag(name: .long, help: "Machines only: run as root.")
        var root = false

        @Argument(parsing: .captureForPassthrough, help: "Command to run.")
        var command: [String] = []

        func run() throws {
            guard !command.isEmpty else {
                throw AppBoxError.usage("usage: appbox exec <name> <command...>")
            }
            let service = try Context.makeService()
            let box = try Context.requireBox(name, in: service)
            try service.ensureRunning(box)

            let onOut: @Sendable (String) -> Void = { print($0) }
            let onErr: @Sendable (String) -> Void = {
                FileHandle.standardError.write(Data(($0 + "\n").utf8))
            }

            let result: ProcessResult
            switch box.kind {
            case .machine:
                // A shell string would be re-tokenised by `machine run`, so it
                // goes down stdin instead. Quoting behaves as you would expect.
                result = try service.machines.client.runScript(
                    name, command.joined(separator: " "), asRoot: root,
                    onOutputLine: onOut, onErrorLine: onErr)
            case .container:
                result = try service.boxes.client.exec(
                    name, command, onOutputLine: onOut, onErrorLine: onErr)
            }

            if !result.succeeded { throw ExitCode(result.exitCode) }
        }
    }

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start a stopped box.")
        @Argument(help: "Name of the box.") var name: String
        func run() throws {
            let reporter = CLIReporter()
            let service = try Context.makeService(reporter: reporter)
            try service.start(Context.requireBox(name, in: service))
            reporter.info("started \(name)")
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop a running box (state is preserved).")
        @Argument(help: "Name of the box.") var name: String
        func run() throws {
            let reporter = CLIReporter()
            let service = try Context.makeService(reporter: reporter)
            try service.stop(Context.requireBox(name, in: service))
            reporter.info("stopped \(name)")
        }
    }

    struct Restart: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop then start a box.")
        @Argument(help: "Name of the box.") var name: String
        func run() throws {
            let reporter = CLIReporter()
            let service = try Context.makeService(reporter: reporter)
            try service.restart(Context.requireBox(name, in: service))
            reporter.info("restarted \(name)")
        }
    }

    struct Use: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make a machine the default for bare 'container machine' commands.",
            discussion: """
                Machines only. After 'appbox use dev', 'container machine run'
                with no -n operates on dev.
                """)

        @Argument(help: "Name of the machine.") var name: String

        func run() throws {
            let reporter = CLIReporter()
            let service = try Context.makeService(reporter: reporter)
            let box = try Context.requireBox(name, in: service)
            guard box.kind == .machine else {
                throw AppBoxError.usage(
                    "'\(name)' is a container; only machines have a default")
            }
            try service.machines.setDefault(name)
            reporter.info("'\(name)' is now the default machine")
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change a machine's CPUs, memory or home-mount mode.",
            discussion: """
                Machines only, and read at boot — a running machine is stopped
                and started again so the change actually takes effect.

                  appbox set dev --cpus 8 --memory 16G
                  appbox set dev --home-mount ro
                """)

        @Argument(help: "Name of the machine.") var name: String

        @Option(name: .customLong("cpus"), help: "Number of virtual CPUs.")
        var cpus: Int?

        @Option(name: .customLong("memory"), help: "Memory allocation (e.g. 8G).")
        var memory: String?

        @Option(name: .customLong("home-mount"),
                help: "How your Mac home is mounted (rw, ro, none).")
        var homeMount: String?

        func run() throws {
            let reporter = CLIReporter()
            let service = try Context.makeService(reporter: reporter)
            let box = try Context.requireBox(name, in: service)
            guard box.kind == .machine else {
                throw AppBoxError.usage(
                    "'\(name)' is a container; recreate it to change its resources")
            }

            var mount: HomeMount?
            if let homeMount {
                guard let parsed = HomeMount(rawValue: homeMount.lowercased()) else {
                    throw AppBoxError.usage(
                        "--home-mount must be rw, ro or none (got '\(homeMount)')")
                }
                mount = parsed
            }

            guard cpus != nil || memory != nil || mount != nil else {
                throw AppBoxError.usage(
                    "nothing to set — pass --cpus, --memory or --home-mount")
            }

            try service.machines.configure(
                name, cpus: cpus, memory: memory, homeMount: mount, reporter: reporter)
        }
    }

    struct Destroy: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete the box. Containers keep their host data unless --purge.",
            discussion: """
                A machine's disk always goes with it — there is no way to keep
                it. Your Mac home was mounted in rather than copied, so nothing
                there is affected.
                """,
            aliases: ["rm"])

        @Argument(help: "Name of the box.") var name: String

        @Flag(name: .long, help: "Containers only: also delete the host data directory.")
        var purge = false

        func run() throws {
            let reporter = CLIReporter()
            let service = try Context.makeService(reporter: reporter)
            let box = try Context.requireBox(name, in: service)
            if purge && box.kind == .machine {
                reporter.warn("--purge means nothing for a machine; its disk always goes")
            }
            try service.destroy(box, purge: purge, reporter: reporter)
        }
    }
}

// MARK: - Inspection

extension AppBox {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List boxes and their state.",
            aliases: ["ls"])

        @Flag(name: .shortAndLong,
              help: "Include containers that were not created by appbox.")
        var all = false

        func run() throws {
            let service = try Context.makeService()
            let boxes = try service.list(includeForeign: true)
            let shown = all ? boxes : boxes.filter { $0.managed != .foreign }

            guard !shown.isEmpty else {
                print(all ? "No containers." : "No appbox boxes yet. Try: appbox create-ubuntu dev")
                return
            }

            let rows: [[String]] =
                [["NAME", "KIND", "STATE", "DISTRO", "IP", "CPUS", "MEMORY", "IMAGE"]]
                + shown.map { box in
                    [
                        box.name + (box.isDefault ? " *" : ""),
                        box.kind.rawValue,
                        box.state.rawValue,
                        box.distro ?? (box.managed == .foreign ? "-" : "?"),
                        box.ipv4 ?? "",
                        String(box.cpus),
                        box.memory,
                        box.image,
                    ]
                }

            let widths = (0..<rows[0].count).map { column in
                rows.map { $0[column].count }.max() ?? 0
            }
            for row in rows {
                let line = row.enumerated()
                    .map { index, cell in
                        index == row.count - 1
                            ? cell
                            : cell.padding(toLength: widths[index] + 2, withPad: " ", startingAt: 0)
                    }
                    .joined()
                print(line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : line)
            }

            let hidden = boxes.count - shown.count
            if hidden > 0 {
                // Flush stdout first, or the buffered table appears after this
                // unbuffered stderr note.
                fflush(stdout)
                FileHandle.standardError.write(
                    Data("\n\(hidden) non-appbox container(s) hidden — use --all to show them.\n"
                        .utf8))
            }
        }
    }

    struct IP: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ip", abstract: "Print the box's IP address.")
        @Argument(help: "Name of the box.") var name: String
        func run() throws {
            let service = try Context.makeService()
            let box = try Context.requireBox(name, in: service)
            if let ipv4 = box.ipv4 { print(ipv4) }
        }
    }

    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show what a box is, where its files are, and how it is configured.")
        @Argument(help: "Name of the box.") var name: String
        func run() throws {
            let service = try Context.makeService()
            printInfo(try Context.requireBox(name, in: service))
        }
    }
}

import AppBoxKit
import ArgumentParser
import Foundation

@main
struct AppBox: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appbox",
        abstract: "Apple containers that act like LXC system containers.",
        discussion: """
            A box is a named, persistent Linux machine that stays running in the
            background, that you shell into and install packages in, and whose
            state survives stop/start. The host directory $APPBOX_HOME/<name>/data
            is mounted at /data and survives even destroy (unless --purge).

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
                """)

        @Argument(help: "Name of the box.")
        var name: String

        @Argument(help: "Distro shortcut (ubuntu, fedora43, rocky9…) or a raw image reference.")
        var token: String?

        @Flag(name: .long, help: "Skip the toolset and user account — a bare container.")
        var bare = false

        @OptionGroup var options: CreateOptions

        func run() throws {
            let reporter = CLIReporter()
            let manager = try Context.makeManager(reporter: reporter)

            let request = BoxManager.CreateRequest(
                name: name, token: token, bare: bare,
                cpus: options.cpus, memory: options.memory)

            // Surface the distro menu instead of a bare error.
            do {
                _ = try manager.resolveImage(for: request)
            } catch AppBoxError.noDistroSpecified {
                printCreateGuidance(name: name)
                throw ExitCode(1)
            }

            let box = try manager.create(request, reporter: reporter)
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
        let manager = try Context.makeManager(reporter: reporter)
        try manager.createFromDistro(
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
            abstract: "Install the standard Unix CLI toolset into an existing box.")

        @Argument(help: "Name of the box.") var name: String

        func run() throws {
            let reporter = CLIReporter()
            try Context.makeManager(reporter: reporter).provision(name, reporter: reporter)
        }
    }

    struct Shell: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open an interactive shell in the box (auto-starts if stopped).",
            aliases: ["attach", "sh"])

        @Argument(help: "Name of the box.") var name: String

        func run() throws {
            let reporter = CLIReporter()
            let manager = try Context.makeManager(reporter: reporter)
            guard try manager.client.exists(name) else {
                throw AppBoxError.boxNotFound(name: name)
            }
            if try !manager.client.isRunning(name) {
                reporter.info("box '\(name)' is stopped; starting it…")
            }
            try manager.ensureRunning(name)
            let shell = manager.preferredShell(name)
            try manager.client.execInteractive(
                name,
                command: [shell],
                user: manager.loginUser(name),
                workdir: manager.loginDirectory(name))
        }
    }

    struct Exec: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a command inside the box.")

        @Argument(help: "Name of the box.") var name: String

        @Argument(parsing: .captureForPassthrough, help: "Command to run.")
        var command: [String] = []

        func run() throws {
            guard !command.isEmpty else {
                throw AppBoxError.usage("usage: appbox exec <name> <command...>")
            }
            let manager = try Context.makeManager()
            guard try manager.client.exists(name) else {
                throw AppBoxError.boxNotFound(name: name)
            }
            try manager.ensureRunning(name)

            let result = try manager.client.exec(
                name, command,
                onOutputLine: { print($0) },
                onErrorLine: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })

            if !result.succeeded { throw ExitCode(result.exitCode) }
        }
    }

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start a stopped box.")
        @Argument(help: "Name of the box.") var name: String
        func run() throws {
            let reporter = CLIReporter()
            try Context.makeManager(reporter: reporter).start(name)
            reporter.info("started \(name)")
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop a running box (state is preserved).")
        @Argument(help: "Name of the box.") var name: String
        func run() throws {
            let reporter = CLIReporter()
            try Context.makeManager(reporter: reporter).stop(name)
            reporter.info("stopped \(name)")
        }
    }

    struct Restart: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop then start a box.")
        @Argument(help: "Name of the box.") var name: String
        func run() throws {
            let reporter = CLIReporter()
            try Context.makeManager(reporter: reporter).restart(name)
            reporter.info("restarted \(name)")
        }
    }

    struct Destroy: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete the box (keeps host data unless --purge).",
            aliases: ["rm"])

        @Argument(help: "Name of the box.") var name: String

        @Flag(name: .long, help: "Also delete the host data directory.")
        var purge = false

        func run() throws {
            let reporter = CLIReporter()
            try Context.makeManager(reporter: reporter)
                .destroy(name, purge: purge, reporter: reporter)
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
            let manager = try Context.makeManager()
            let boxes = try manager.list(includeForeign: true)
            let shown = all ? boxes : boxes.filter { $0.managed != .foreign }

            guard !shown.isEmpty else {
                print(all ? "No containers." : "No appbox boxes yet. Try: appbox create-ubuntu dev")
                return
            }

            let rows: [[String]] = [["NAME", "STATE", "DISTRO", "IP", "CPUS", "MEMORY", "IMAGE"]]
                + shown.map { box in
                    [
                        box.name,
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
            let box = try Context.makeManager().requireBox(name)
            if let ipv4 = box.ipv4 { print(ipv4) }
        }
    }

    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show name/state/ip/data-dir for a box.")
        @Argument(help: "Name of the box.") var name: String
        func run() throws {
            printInfo(try Context.makeManager().requireBox(name))
        }
    }
}

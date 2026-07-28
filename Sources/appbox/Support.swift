import AppBoxKit
import ArgumentParser
import Foundation

let appboxVersion = "0.2.0"

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
    static func makeManager(reporter: CLIReporter = CLIReporter()) throws -> BoxManager {
        let client = try ContainerClient.discover()

        guard client.isServiceRunning() else {
            throw AppBoxError.containerServiceNotRunning
        }

        // A CLI/daemon version skew commonly breaks networking with
        // "no available interface strategy for network default … variant=nil".
        if let skew = client.versionSkew() {
            reporter.warn(
                "container CLI (\(skew.cli)) and daemon (\(skew.daemon)) versions differ.")
            reporter.warn("  this commonly breaks networking. Restart the daemon to match:")
            reporter.warn("    container system stop && container system start")
        }

        return BoxManager(client: client, config: .fromEnvironment())
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

        Add --full to any of these to also install the standard CLI toolset.

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
}

extension BoxManager {
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
            BoxManager.CreateRequest(
                name: name, token: token, bare: parsed.bare,
                cpus: options.cpus, memory: options.memory),
            reporter: reporter)

        printInfo(box)
        FileHandle.standardError.write(
            Data("\nShell in with:  \u{1B}[1mappbox shell \(name)\u{1B}[0m\n".utf8))
    }
}

/// Render the `info` block. Shared by `info` and the tail of `create`.
func printInfo(_ box: Box) {
    print("name:    \(box.name)")
    print("state:   \(box.state.rawValue)")
    print("ip:      \(box.ipv4 ?? "<none>")")
    print("image:   \(box.image)")
    if let distro = box.distro {
        print("distro:  \(distro)")
    }
    print("cpus:    \(box.cpus)")
    print("memory:  \(box.memory)")
    print("data:    \(box.dataDirectory.path)  (mounted at /data)")
    if box.managed == .inferred {
        print("managed: yes (detected by shape — created before appbox added labels)")
    } else if box.managed == .foreign {
        print("managed: no (not an appbox box)")
    }
}

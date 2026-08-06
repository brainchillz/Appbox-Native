import Foundation

/// Builds and caches images that can boot as a container machine.
///
/// A machine runs the image's **own init**, so `container machine create
/// ubuntu:latest` fails outright — the stock Ubuntu image has no `/sbin/init`
/// and the machine dies with "no PID data from sync pipe". Only Alpine, of the
/// distros appbox offers, boots as shipped.
///
/// So the recipe adds two things to the upstream image: an init system, and the
/// standard toolset (machines are bare images too — a fresh Alpine machine has
/// no `sudo`, no `curl`, no `bash`). Building that once per distro is what
/// keeps `create` near-instant afterwards.
///
/// What it deliberately does *not* add is the user account. `container` creates
/// one on first boot from the host's uid, gid and username; baking a second
/// account at the same uid would collide with it. The parts Apple's setup
/// leaves out — sudo, a bash login shell, dotfiles — are applied after first
/// boot instead, by `MachineManager.polish`.
public struct MachineImage: Sendable {

    /// Bump when the recipe below changes, so existing caches are rebuilt
    /// rather than silently serving a stale toolset.
    public static let recipeVersion = 1

    public let distro: Distro
    public let version: String?

    public init(distro: Distro, version: String? = nil) {
        self.distro = distro
        self.version = version
    }

    /// Tag for the cached image. Namespaced under `appbox-machine/` so it can
    /// never be confused with an upstream image or with the `appbox-base/`
    /// images that back plain containers.
    public var reference: String {
        let versionPart = (version.flatMap { $0.isEmpty ? nil : $0 } ?? "latest")
            .replacingOccurrences(of: ":", with: "-")
        return "appbox-machine/\(distro.rawValue):\(versionPart)-v\(Self.recipeVersion)"
    }

    /// The upstream image this is built from.
    public var sourceImage: String {
        distro.image(version: version)
    }

    // MARK: - Recipe

    /// Packages that provide `/sbin/init`.
    ///
    /// Alpine needs none — BusyBox already provides init, and it boots fine as
    /// a machine. Everywhere else this is systemd, which is the point: real
    /// services, `systemctl start postgresql`, the thing plain appbox
    /// containers could never do because nothing ran as PID 1 but `sleep`.
    var initPackages: [String] {
        switch distro.packageManager {
        // systemd-sysv is what actually installs /sbin/init on Debian and
        // Ubuntu; the systemd package alone does not.
        case .apt: ["systemd", "systemd-sysv", "dbus"]
        case .dnf: ["systemd"]
        case .apk: []
        // Arch ships systemd but not the /sbin/init symlink for it.
        case .pacman: ["systemd-sysvcompat"]
        }
    }

    /// Install command for the init packages, in each manager's idiom.
    var initInstallCommand: String? {
        let packages = initPackages
        guard !packages.isEmpty else { return nil }
        let list = packages.joined(separator: " ")

        switch distro.packageManager {
        case .apt:
            return "export DEBIAN_FRONTEND=noninteractive; "
                + "apt-get update -qq && apt-get install -y --no-install-recommends \(list)"
        case .dnf:
            return "dnf install -y \(list)"
        case .apk:
            return nil
        case .pacman:
            return "pacman -Syu --noconfirm --needed --disable-sandbox \(list)"
        }
    }

    /// Post-install configuration for systemd images.
    ///
    /// Empty machine-ids make systemd generate a fresh one per machine rather
    /// than every machine from an image sharing one. The masked units are the
    /// ones that fail or hang under virtualization; the list is Apple's, from
    /// the container-machine documentation.
    var initConfigurationCommands: [String] {
        guard distro.packageManager != .apk else { return [] }

        var commands = [
            ">/etc/machine-id",
            "rm -f /var/lib/dbus/machine-id 2>/dev/null || true",
            "systemctl set-default multi-user.target",
            // The machine kernel loads no modules, so this unit always fails
            // and leaves `systemctl is-system-running` reporting "degraded" on
            // an otherwise perfect machine.
            "systemctl mask systemd-modules-load.service",
        ]

        if distro.packageManager == .apt {
            commands.append(
                """
                systemctl mask dev-hugepages.mount sys-fs-fuse-connections.mount \
                systemd-update-utmp.service systemd-tmpfiles-setup.service \
                console-getty.service
                """)
            commands.append("systemctl disable networkd-dispatcher.service 2>/dev/null || true")
        } else {
            commands.append(
                "systemctl mask dev-hugepages.mount sys-fs-fuse-connections.mount")
        }

        return commands
    }

    /// Clean up package manager caches so the image doesn't carry them.
    var cacheCleanupCommand: String? {
        switch distro.packageManager {
        case .apt: "rm -rf /var/lib/apt/lists/*"
        case .dnf: "dnf clean all"
        case .apk: nil  // --no-cache already
        case .pacman: "rm -rf /var/cache/pacman/pkg/*"
        }
    }

    public var dockerfile: String {
        var lines = ["FROM \(sourceImage)", ""]

        if let initInstall = initInstallCommand {
            lines.append("# An init system, so this image can boot as a container machine.")
            lines.append("RUN \(initInstall)")
            lines.append("")
        }

        lines.append("# Standard CLI toolset — a machine should feel like a full Linux install.")
        var install = PackageSets.installCommand(for: distro.packageManager)
        if let cleanup = cacheCleanupCommand {
            install += " && \(cleanup)"
        }
        lines.append("RUN \(install)")
        lines.append("")

        let configuration = initConfigurationCommands
        if !configuration.isEmpty {
            lines.append("# Boot configuration for a headless machine.")
            lines.append("RUN \(configuration.joined(separator: " \\\n && "))")
            lines.append("")
        }

        // Fail the build rather than the boot. Without /sbin/init the machine
        // is created and then dies with an opaque "no PID data from sync pipe",
        // which is a miserable thing to debug from the other end.
        lines.append("# A machine image without /sbin/init creates fine and then dies on boot.")
        lines.append("RUN test -x /sbin/init")
        lines.append("")

        lines.append("LABEL appbox.machine=\"1\"")
        lines.append("LABEL appbox.distro=\"\(distro.rawValue)\"")
        lines.append("LABEL appbox.recipe=\"\(Self.recipeVersion)\"")

        return lines.joined(separator: "\n") + "\n"
    }
}

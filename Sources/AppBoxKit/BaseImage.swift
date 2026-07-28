import Foundation

/// Builds and caches "provisioned" base images.
///
/// Installing the standard toolset into every new box costs minutes and repeats
/// identical work. Building it once into an image instead makes box creation
/// near-instant, which is what lets provisioning be the *default* rather than
/// an opt-in flag — a box should feel like a full Linux install out of the box.
public struct BaseImage: Sendable {

    /// Bump when the Dockerfile recipe changes, so existing caches are rebuilt
    /// rather than silently serving a stale toolset.
    public static let recipeVersion = 1

    public let distro: Distro
    public let version: String?
    public let user: HostUser

    public init(distro: Distro, version: String?, user: HostUser) {
        self.distro = distro
        self.version = version
        self.user = user
    }

    /// Tag for the cached image. Namespaced under `appbox-base/` so it can
    /// never be mistaken for an upstream image.
    public var reference: String {
        let versionPart = (version.flatMap { $0.isEmpty ? nil : $0 } ?? "latest")
            .replacingOccurrences(of: ":", with: "-")
        return "appbox-base/\(distro.rawValue):\(versionPart)-v\(Self.recipeVersion)"
    }

    /// The upstream image this is built from.
    public var sourceImage: String {
        distro.image(version: version)
    }

    // MARK: - Dockerfile

    /// Commands that create a Linux account mirroring the host user.
    ///
    /// Alpine only ships BusyBox `adduser` unless the shadow package is
    /// installed, so it needs different syntax from the others.
    var userCreationCommands: [String] {
        Self.userCreationCommands(for: distro.packageManager, user: user)
    }

    /// Shared by the image recipe and by adding a user to an existing box.
    public static func userCreationCommands(
        for packageManager: PackageManager, user: HostUser
    ) -> [String] {
        let name = user.name
        let uid = String(user.uid)
        let gid = String(user.gid)
        let group = HostUser.hostGroupName

        // Ensure *some* group owns the host gid, then use whichever name that
        // is. Most distributions already have one at gid 20 (Debian, Ubuntu and
        // Alpine all call it "dialout"); renaming it would be invasive, and
        // ownership is numeric anyway — so `id` may read "dialout" inside while
        // macOS shows "staff". Cosmetic only, and safer than a rename.
        let ensureGroup = """
            if ! getent group \(gid) >/dev/null 2>&1; then \
            groupadd -g \(gid) \(group) 2>/dev/null || addgroup -g \(gid) \(group); fi
            """

        switch packageManager {
        case .apk:
            // BusyBox adduser needs a group *name*, and there is no groupmod.
            return [
                ensureGroup,
                "adduser -D -u \(uid) -G \"$(getent group \(gid) | cut -d: -f1)\" "
                    + "-s /bin/bash \(name)",
                "echo '\(name) ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/\(name)",
                "chmod 0440 /etc/sudoers.d/\(name)",
            ]
        default:
            // useradd accepts a numeric gid directly.
            return [
                ensureGroup,
                "useradd -u \(uid) -g \(gid) -m -s /bin/bash \(name)",
                "echo '\(name) ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/\(name)",
                "chmod 0440 /etc/sudoers.d/\(name)",
            ]
        }
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

        lines.append("# Standard CLI toolset — a box should feel like a full Linux install.")
        var install = PackageSets.installCommand(for: distro.packageManager)
        if let cleanup = cacheCleanupCommand {
            install += " && \(cleanup)"
        }
        lines.append("RUN \(install)")
        lines.append("")

        lines.append("# An account mirroring the host user, so bind-mounted files")
        lines.append("# have matching ownership on both sides.")
        lines.append("RUN \(userCreationCommands.joined(separator: " \\\n && "))")
        lines.append("")

        // Recorded so the cache can be identified and invalidated later.
        lines.append("LABEL appbox.base=\"1\"")
        lines.append("LABEL appbox.distro=\"\(distro.rawValue)\"")
        lines.append("LABEL appbox.recipe=\"\(Self.recipeVersion)\"")
        lines.append("LABEL appbox.user=\"\(user.name)\"")

        return lines.joined(separator: "\n") + "\n"
    }
}

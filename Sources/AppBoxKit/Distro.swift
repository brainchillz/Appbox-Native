import Foundation

/// A Linux distribution appbox knows how to create and provision.
///
/// This is the typed replacement for the bash `resolve_image` case statement.
/// The knowledge encoded here is hard-won and registry-verified — see the notes
/// on each case before changing anything.
public enum Distro: String, CaseIterable, Sendable {
    case ubuntu
    case debian
    case alpine
    case fedora
    case rocky
    case arch

    /// arm64 Arch image. The official `archlinux` image is amd64-only and will
    /// not run on Apple Silicon, so we use Arch Linux ARM (rolling, rebuilt
    /// daily, pacman-based). Technically ALARM rather than Arch proper.
    public static let archImage = "menci/archlinuxarm:base"

    /// Newest Rocky major. Rocky publishes **no `latest` tag** on
    /// quay.io/rockylinux/rockylinux — only numeric majors — so `latest` and
    /// the bare `rocky` shortcut both have to resolve to a real major.
    public static let rockyNewestMajor = "10"

    /// The package manager used inside boxes of this distro.
    public var packageManager: PackageManager {
        switch self {
        case .ubuntu, .debian: .apt
        case .fedora, .rocky: .dnf
        case .alpine: .apk
        case .arch: .pacman
        }
    }

    /// Arch is rolling-release — a version argument is meaningless.
    public var isRolling: Bool { self == .arch }

    /// Distros whose registry actually publishes a `latest` tag.
    public var publishesLatestTag: Bool { self != .rocky }

    /// Build the image reference for this distro at the given version.
    ///
    /// `version` is nil or "latest" for the default. Note that `ubuntu:latest`
    /// tracks the newest Ubuntu **LTS** by Docker convention (the `latest` tag
    /// never points at interim releases), which is exactly what we want.
    public func image(version: String? = nil) -> String {
        let requested = version.flatMap { $0.isEmpty ? nil : $0 } ?? "latest"

        switch self {
        case .arch:
            // Rolling — any version is ignored by the caller with a notice.
            return Self.archImage

        case .rocky:
            let major = (requested == "latest") ? Self.rockyNewestMajor : requested
            return "quay.io/rockylinux/rockylinux:\(major)"

        case .ubuntu, .debian, .alpine, .fedora:
            return "\(rawValue):\(requested)"
        }
    }

    /// Parse a distro token, which may carry an inline version suffix
    /// (`ubuntu24.04`, `fedora43`, `rocky9`). Returns nil for anything that
    /// isn't a known distro — callers treat that as a raw image reference.
    public static func parse(token: String) -> (distro: Distro, version: String?)? {
        let token = token.lowercased()

        for distro in Distro.allCases {
            let name = distro.rawValue
            guard token.hasPrefix(name) else { continue }

            let suffix = String(token.dropFirst(name.count))
            if suffix.isEmpty { return (distro, nil) }

            // Only a numeric suffix counts as an inline version, so that a name
            // like "ubuntu-server" is not mistaken for ubuntu version "-server".
            if suffix.first?.isNumber == true { return (distro, suffix) }
        }
        return nil
    }

    /// Resolve any user-supplied token to an image reference.
    ///
    /// Known distro shortcuts (with optional inline version) map to verified
    /// arm64 images; anything else is passed through untouched so that a raw
    /// image reference like `docker.io/library/busybox:latest` still works.
    public static func resolveImage(token: String) -> String {
        guard let (distro, version) = parse(token: token) else { return token }
        return distro.image(version: version)
    }

    /// Registry repository names that identify a distro but don't match its
    /// appbox token — `rockylinux` for rocky, ALARM's `archlinuxarm` for arch.
    private static let repositoryAliases: [String: Distro] = [
        "rockylinux": .rocky,
        "archlinuxarm": .arch,
        "archlinux": .arch,
    ]

    /// Best-effort distro identification from an image reference.
    ///
    /// Boxes created before appbox stamped labels carry no `appbox.distro`, but
    /// their image reference still says what they are — this is what lets the
    /// list and the menu bar app show a distro for them instead of "?".
    public static func infer(fromImage reference: String) -> (distro: Distro, version: String?)? {
        // Strip any tag, being careful not to mistake a registry port
        // (host:5000/foo) for a tag.
        let lastPathComponent = reference.split(separator: "/").last.map(String.init) ?? reference
        let parts = lastPathComponent.split(separator: ":", maxSplits: 1).map(String.init)
        let repository = parts[0].lowercased()
        let tag = parts.count > 1 ? parts[1] : nil

        // A concrete tag is a useful version; "latest" and ALARM's "base" are not.
        let version = (tag == "latest" || tag == "base") ? nil : tag

        if let alias = repositoryAliases[repository] { return (alias, version) }
        if let distro = Distro(rawValue: repository) { return (distro, version) }
        return nil
    }

    /// Validate a token for `set-default`, which only accepts real distros
    /// (a raw image reference there would be silently wrong later).
    public static func parseStrict(token: String) throws -> (distro: Distro, version: String?) {
        guard let parsed = parse(token: token) else {
            let known = Distro.allCases.map(\.rawValue).joined(separator: " ")
            throw AppBoxError.unknownDistro(token: token, known: known)
        }
        return parsed
    }
}

/// Package managers appbox can provision through.
public enum PackageManager: String, Sendable, CaseIterable {
    case apt, dnf, apk, pacman

    /// Shell probe used to detect this manager inside a box.
    public var detectCommand: String {
        switch self {
        case .apt: "command -v apt-get >/dev/null"
        default: "command -v \(rawValue) >/dev/null"
        }
    }
}

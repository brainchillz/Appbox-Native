import Foundation

/// Which image a new box is built from, and how appbox decided.
public struct ResolvedImage: Sendable {
    /// The image reference to create from.
    public var image: String
    /// The distro appbox recognised, if any. A raw image reference has none.
    public var distro: Distro?
    /// The version requested alongside the distro, if any.
    public var version: String?
    /// Set when the choice came from the saved default rather than the caller,
    /// so the UI can say so instead of appearing to guess.
    public var viaDefault: String?

    public var distroName: String? { distro?.rawValue }
}

/// Decides which image a `create` uses. Shared by containers and machines so
/// the two cannot disagree about what `create dev fedora43` means.
public enum ImageResolver {

    /// Order: the explicit token, then `APPBOX_IMAGE`, then the saved default
    /// distro. With none of those we refuse rather than silently picking
    /// Ubuntu — the caller shows the distro menu.
    public static func resolve(
        token: String?, config: Configuration, name: String
    ) throws -> ResolvedImage {
        if let token, !token.isEmpty {
            let parsed = Distro.parse(token: token)
            return ResolvedImage(
                image: Distro.resolveImage(token: token),
                distro: parsed?.distro,
                version: parsed?.version)
        }
        if let forced = config.forcedImage {
            let parsed = Distro.parse(token: forced)
            return ResolvedImage(
                image: forced, distro: parsed?.distro, version: parsed?.version)
        }
        if let saved = config.defaultDistro() {
            let parsed = Distro.parse(token: saved)
            return ResolvedImage(
                image: Distro.resolveImage(token: saved),
                distro: parsed?.distro,
                version: parsed?.version,
                viaDefault: saved)
        }
        throw AppBoxError.noDistroSpecified(name: name)
    }
}

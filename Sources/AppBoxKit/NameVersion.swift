import Foundation

/// Order-independent parsing of `create-<distro>` arguments.
///
/// `appbox create-ubuntu web 24.04` and `appbox create-ubuntu 24.04 web` are
/// equivalent. A token is treated as a *version* if it is "latest" or begins
/// with a digit; otherwise it is the box name.
///
/// Known caveat (documented in the README): a box name that starts with a digit
/// is read as a version by these commands.
public struct NameVersion: Equatable, Sendable {
    public var name: String?
    public var version: String?
    /// Skip the toolset and user account. `--full` is accepted and ignored,
    /// since a full box is now the default.
    public var bare: Bool

    public init(name: String? = nil, version: String? = nil, bare: Bool = false) {
        self.name = name
        self.version = version
        self.bare = bare
    }

    /// Is this token a version rather than a box name?
    public static func isVersionToken(_ token: String) -> Bool {
        if token == "latest" { return true }
        return token.first?.isNumber == true
    }

    /// Split positional arguments into name + version, order-independently.
    /// `--bare` (and the now-redundant `--full`) may appear anywhere.
    public static func parse(_ arguments: [String]) throws -> NameVersion {
        var result = NameVersion()

        for argument in arguments {
            if argument == "--bare" {
                result.bare = true
                continue
            }
            // Retained for compatibility with the shell script; a full box is
            // the default now, so this is a no-op.
            if argument == "--full" { continue }

            if isVersionToken(argument), result.version == nil {
                result.version = argument
            } else if result.name == nil {
                result.name = argument
            } else if result.version == nil {
                result.version = argument
            } else {
                throw AppBoxError.usage("unexpected extra argument: '\(argument)'")
            }
        }

        return result
    }
}

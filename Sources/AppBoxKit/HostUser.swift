import Foundation

/// The macOS account a box's Linux user is modelled on.
///
/// Matching the host uid/gid is what makes bind-mounted files behave: a file
/// written inside the box belongs to you on the Mac, and vice versa. Without
/// it, everything on the shared directories lands with the wrong owner and you
/// fight permissions forever.
public struct HostUser: Sendable, Equatable {
    public var name: String
    public var uid: UInt32
    public var gid: UInt32

    /// macOS names gid 20 "staff"; most Linux distributions already use 20 for
    /// something else (Debian/Ubuntu call it "dialout"). We rename it inside
    /// the box so `id` reads the same on both sides. Purely cosmetic —
    /// ownership is numeric — but confusing otherwise.
    public static let hostGroupName = "staff"

    public init(name: String, uid: UInt32, gid: UInt32) {
        self.name = name
        self.uid = uid
        self.gid = gid
    }

    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HostUser {
        // A Linux username must be lowercase and free of spaces; macOS short
        // names almost always already are, but sanitise defensively.
        let raw = environment["APPBOX_USER"] ?? NSUserName()
        let sanitized = raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }

        return HostUser(
            name: sanitized.isEmpty ? "user" : sanitized,
            uid: getuid(),
            gid: getgid())
    }

    public var homeDirectory: String { "/home/\(name)" }
}

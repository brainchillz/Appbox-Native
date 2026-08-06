import Foundation

/// Codable mirrors of `container machine list --format json` and
/// `container machine inspect`.
///
/// The two commands return **different shapes** of the same object, which is
/// the main thing to know here. `list` is a summary — id, status, resources,
/// disk, ip, and whether it is the default. `inspect` is the full record —
/// image, home-mount mode, the Linux account `container` created — but carries
/// no `default` flag. `MachineRecord` is the union of both, everything the
/// summary omits being optional, so one type decodes either and
/// `MachineClient.list` can merge them.

/// How a machine mounts your macOS home directory.
///
/// Unlike an appbox container, which gets a private per-box home on the host,
/// every machine sees your *real* Mac home at `/Users/<you>`. That is the point
/// of the feature — edit on the Mac, build inside — but it also means there is
/// no isolation, so `ro` and `none` exist for when that matters.
public enum HomeMount: String, Codable, Sendable, CaseIterable {
    case rw
    case ro
    case none

    public var summary: String {
        switch self {
        case .rw: "read/write"
        case .ro: "read-only"
        case .none: "not mounted"
        }
    }
}

/// The Linux account `container` provisions on first boot, mirroring the host
/// account. appbox no longer has to create this itself — see `MachineManager`
/// for the parts Apple's setup leaves out (sudo, bash, dotfiles).
public struct MachineUser: Codable, Sendable, Equatable {
    public var username: String
    public var uid: UInt32
    public var gid: UInt32

    /// Where this account's home lives *inside* the machine. Note this is the
    /// machine's own persistent disk, not the mounted Mac home — the Mac home
    /// is separately at `/Users/<username>`.
    public var homeDirectory: String { "/home/\(username)" }
}

/// One container machine, as reported by `list` and/or `inspect`.
public struct MachineRecord: Codable, Sendable {
    public var id: String
    public var status: BoxState
    public var cpus: Int
    /// Memory in bytes. `machine` reports raw bytes where `container` reports
    /// a nested resources object.
    public var memory: Int64
    /// Bytes actually consumed by the machine's disk image, which is sparse —
    /// the filesystem inside reports a 500G volume regardless.
    public var diskSize: Int64?
    public var ipAddress: String?
    public var createdDate: String?
    public var startedDate: String?

    /// `list` only.
    public var `default`: Bool?

    /// `inspect` only.
    public var containerId: String?
    public var image: ImageSpec?
    public var homeMount: HomeMount?
    public var userSetup: MachineUser?
    public var platform: Platform?

    public var isDefault: Bool { `default` ?? false }
    public var isRunning: Bool { status == .running }

    /// Human-readable memory, matching how `ContainerRecord` renders it.
    public var memoryDescription: String {
        let megabytes = memory / (1024 * 1024)
        if megabytes >= 1024, megabytes % 1024 == 0 {
            return "\(megabytes / 1024)G"
        }
        return "\(megabytes)M"
    }

    /// Fill in the fields only `inspect` knows about, keeping everything the
    /// summary already reported. Used to merge the two calls into one record.
    public func merging(detail: MachineRecord) -> MachineRecord {
        var merged = self
        merged.containerId = detail.containerId
        merged.image = detail.image
        merged.homeMount = detail.homeMount
        merged.userSetup = detail.userSetup
        merged.platform = detail.platform
        merged.startedDate = merged.startedDate ?? detail.startedDate
        return merged
    }
}

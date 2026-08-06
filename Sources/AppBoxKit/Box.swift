import Foundation

/// The two kinds of Linux environment appbox manages.
///
/// They are separate namespaces in Apple's CLI — `container machine ls` and
/// `container ls` do not see each other — so a machine and a container may even
/// share a name. Every operation therefore dispatches on a `Box`, which knows
/// its own kind, rather than on a bare name.
public enum BoxKind: String, Sendable, CaseIterable, Codable {
    /// A container machine: Apple's own persistent VM, running the image's init
    /// system, with your Mac home mounted at `/Users/<you>`. The default for
    /// new boxes wherever the installed `container` supports it.
    case machine

    /// appbox's original box: `container run --init … sleep infinity`, with a
    /// private per-box home and `/data` on the host. What every box created
    /// before 0.3 is, and still the only kind that gets its own isolated home.
    case container

    public var title: String {
        switch self {
        case .machine: "Machine"
        case .container: "Container"
        }
    }

    /// One line on what choosing this kind actually gets you.
    public var summary: String {
        switch self {
        case .machine:
            "Runs a real init system, so services work. Your Mac home is mounted "
                + "at /Users/<you>, shared with every other machine."
        case .container:
            "A private home directory and /data on the host, kept when the box is "
                + "destroyed. No init system, so no services."
        }
    }
}

/// How confident we are that a container is an appbox-managed box.
///
/// Machines need none of this — they live in their own namespace, so everything
/// `container machine ls` returns is a machine and nothing else is.
public enum Managed: String, Sendable {
    /// Created by a labelled appbox, or a container machine — definitive.
    case labelled
    /// Created by an older appbox: no label, but it has the appbox shape
    /// (init process holding it open plus a /data bind mount).
    case inferred
    /// Not an appbox box — some other container on the same machine.
    case foreign
}

/// The appbox-level view of a box, whichever kind it is.
///
/// Fields that only one kind can have are optional, and named for what they
/// mean rather than for the command that produced them.
public struct Box: Sendable, Identifiable {
    /// Unique across both kinds. A machine and a container are allowed to share
    /// a name, so the name alone will not do as an identity.
    public var id: String { "\(kind.rawValue):\(name)" }

    public var kind: BoxKind
    public var name: String
    public var state: BoxState
    public var image: String
    public var ipv4: String?
    /// Host directory bind-mounted at `/data`. Containers only — machines take
    /// no extra mounts.
    public var dataDirectory: URL?
    /// Host directory backing the box's home.
    ///
    /// For a container this is the private per-box home appbox created. For a
    /// machine it is your **actual Mac home**, mounted at `/Users/<you>` and
    /// shared with every other machine — the same path, not a copy.
    public var homeDirectory: URL?
    public var managed: Managed
    public var distro: String?
    /// The Linux account matching the host user, if the box has one.
    public var user: String?
    public var cpus: Int
    public var memory: String
    public var createdAt: String?

    // MARK: - Machine-only

    /// Bytes the machine's disk image actually occupies on the Mac. The volume
    /// inside reports ~500G regardless — it is sparse.
    public var diskBytes: Int64?
    /// How the Mac home is mounted, or nil for a container.
    public var homeMount: HomeMount?
    /// Whether `container machine` commands with no `-n` operate on this one.
    public var isDefault: Bool

    public init(
        kind: BoxKind,
        name: String,
        state: BoxState,
        image: String,
        ipv4: String? = nil,
        dataDirectory: URL? = nil,
        homeDirectory: URL? = nil,
        managed: Managed,
        distro: String? = nil,
        user: String? = nil,
        cpus: Int,
        memory: String,
        createdAt: String? = nil,
        diskBytes: Int64? = nil,
        homeMount: HomeMount? = nil,
        isDefault: Bool = false
    ) {
        self.kind = kind
        self.name = name
        self.state = state
        self.image = image
        self.ipv4 = ipv4
        self.dataDirectory = dataDirectory
        self.homeDirectory = homeDirectory
        self.managed = managed
        self.distro = distro
        self.user = user
        self.cpus = cpus
        self.memory = memory
        self.createdAt = createdAt
        self.diskBytes = diskBytes
        self.homeMount = homeMount
        self.isDefault = isDefault
    }

    public var isRunning: Bool { state == .running }

    /// Whether appbox can install the toolset and furnish the account here.
    /// Foreign containers are somebody else's business.
    public var isProvisionable: Bool { managed != .foreign }

    /// A box with its own account and a home, rather than a bare container
    /// running as root.
    public var isFullInstall: Bool {
        kind == .machine ? user != nil : (user != nil && homeDirectory != nil)
    }

    /// Does the host data directory actually exist on disk?
    public var hasHostData: Bool {
        guard let dataDirectory else { return false }
        return FileManager.default.fileExists(atPath: dataDirectory.path)
    }

    /// Disk usage rendered the way the rest of the UI renders sizes.
    public var diskDescription: String? {
        diskBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
    }
}

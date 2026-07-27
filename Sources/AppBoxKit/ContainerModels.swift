import Foundation

/// Codable mirrors of `container list --format json` / `container inspect`.
///
/// These decode only the fields appbox actually uses. Apple's schema carries a
/// good deal more (rlimits, sysctls, published ports, DNS…); decoding a subset
/// keeps us resilient to additive changes in the `container` CLI.

public enum BoxState: String, Codable, Sendable {
    case running
    case stopped
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BoxState(rawValue: raw) ?? .unknown
    }
}

public struct NetworkStatus: Codable, Sendable {
    public var network: String?
    public var hostname: String?
    /// Address in CIDR form, e.g. "192.168.64.2/24".
    public var ipv4Address: String?
    public var ipv4Gateway: String?
    public var macAddress: String?

    /// The bare IPv4 address with any CIDR suffix removed.
    public var ipv4: String? {
        ipv4Address?.split(separator: "/").first.map(String.init)
    }
}

public struct ContainerStatus: Codable, Sendable {
    public var state: BoxState
    public var networks: [NetworkStatus]
    public var startedDate: String?

    /// Networks are only populated while the box is running.
    public var ipv4: String? {
        networks.compactMap(\.ipv4).first
    }
}

public struct ImageDescriptor: Codable, Sendable {
    public var digest: String?
    public var mediaType: String?
    public var size: Int?
}

public struct ImageSpec: Codable, Sendable {
    public var reference: String
    public var descriptor: ImageDescriptor?
}

public struct InitProcess: Codable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String]?
    public var terminal: Bool?
    public var workingDirectory: String?
}

public struct Mount: Codable, Sendable {
    public var source: String
    public var destination: String
    public var options: [String]?
}

public struct Platform: Codable, Sendable {
    public var architecture: String
    public var os: String
}

public struct Resources: Codable, Sendable {
    public var cpus: Int
    public var memoryInBytes: Int64
    public var cpuOverhead: Int?

    /// Human-readable memory, matching how `container list` renders it.
    public var memoryDescription: String {
        let megabytes = memoryInBytes / (1024 * 1024)
        if megabytes >= 1024, megabytes % 1024 == 0 {
            return "\(megabytes / 1024)G"
        }
        return "\(megabytes)M"
    }
}

public struct ContainerConfiguration: Codable, Sendable {
    public var id: String
    public var creationDate: String?
    public var image: ImageSpec
    public var initProcess: InitProcess
    public var labels: [String: String]
    public var mounts: [Mount]
    public var platform: Platform
    public var resources: Resources
    public var useInit: Bool?
}

/// One entry from `container list --all --format json`.
public struct ContainerRecord: Codable, Sendable {
    public var id: String
    public var status: ContainerStatus
    public var configuration: ContainerConfiguration

    public var state: BoxState { status.state }
    public var image: String { configuration.image.reference }
    public var ipv4: String? { status.ipv4 }
    public var labels: [String: String] { configuration.labels }
}

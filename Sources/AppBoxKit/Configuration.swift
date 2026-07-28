import Foundation

/// appbox's configuration, resolved from the environment exactly as the bash
/// script does. The env var names and on-disk layout are a compatibility
/// contract: an old script, this CLI, and the menu bar app must all see the
/// same boxes and the same default distro.
public struct Configuration: Sendable {
    /// Where per-box host data lives (`$APPBOX_HOME/<name>/data` -> `/data`).
    public var home: URL
    /// Optional forced image for a bare `create <name>`. Empty means unset.
    public var forcedImage: String?
    /// appbox's own config directory.
    public var configDir: URL
    /// Default CPUs for new boxes.
    public var cpus: Int
    /// Default memory for new boxes (a `container`-style size string, e.g. "2G").
    public var memory: String
    /// Default distro forced by environment, overriding the saved file.
    public var defaultDistroOverride: String?

    public static let defaultCPUs = 4
    public static let defaultMemory = "2G"

    /// The file holding the persisted default distro for a bare `create`.
    public var defaultDistroFile: URL {
        configDir.appendingPathComponent("default-distro")
    }

    /// Host data directory bind-mounted at `/data` for a given box.
    public func dataDirectory(for name: String) -> URL {
        home.appendingPathComponent(name).appendingPathComponent("data")
    }

    /// The whole per-box host directory (removed by `destroy --purge`).
    public func boxDirectory(for name: String) -> URL {
        home.appendingPathComponent(name)
    }

    /// Host directory backing the box user's home.
    ///
    /// Keeping `/home/<user>` on the host is what lets a box be rebuilt — a new
    /// distro version, different resources, recovering from a broken box —
    /// without losing dotfiles, shell history, keys or checkouts. Everything
    /// inside the container already survives stop/start; this survives destroy.
    public func homeDirectory(for name: String) -> URL {
        home.appendingPathComponent(name).appendingPathComponent("home")
    }

    public init(
        home: URL,
        forcedImage: String? = nil,
        configDir: URL,
        cpus: Int = Configuration.defaultCPUs,
        memory: String = Configuration.defaultMemory,
        defaultDistroOverride: String? = nil
    ) {
        self.home = home
        self.forcedImage = forcedImage
        self.configDir = configDir
        self.cpus = cpus
        self.memory = memory
        self.defaultDistroOverride = defaultDistroOverride
    }

    /// Resolve configuration from a process environment.
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Configuration {
        // Treat empty-string env vars as unset, matching bash's `: "${X:=default}"`.
        func value(_ key: String) -> String? {
            guard let v = env[key], !v.isEmpty else { return nil }
            return v
        }

        let homeDir = value("HOME").map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser

        return Configuration(
            home: value("APPBOX_HOME").map(URL.init(fileURLWithPath:))
                ?? homeDir.appendingPathComponent("containers"),
            forcedImage: value("APPBOX_IMAGE"),
            configDir: value("APPBOX_CONFIG_DIR").map(URL.init(fileURLWithPath:))
                ?? homeDir.appendingPathComponent(".config/appbox"),
            cpus: value("APPBOX_CPUS").flatMap(Int.init) ?? defaultCPUs,
            memory: value("APPBOX_MEMORY") ?? defaultMemory,
            defaultDistroOverride: value("APPBOX_DEFAULT_DISTRO")
        )
    }

    // MARK: - Default distro persistence

    /// The default distro for a bare `create <name>`: env override first, then
    /// the saved file. Returns nil when neither is set — callers must then show
    /// the distro menu rather than silently picking Ubuntu.
    public func defaultDistro() -> String? {
        if let override = defaultDistroOverride { return override }
        guard let contents = try? String(contentsOf: defaultDistroFile, encoding: .utf8) else {
            return nil
        }
        let first = contents.split(separator: "\n", omittingEmptySubsequences: false).first
        let trimmed = first?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public func saveDefaultDistro(_ token: String) throws {
        try FileManager.default.createDirectory(
            at: configDir, withIntermediateDirectories: true)
        try (token + "\n").write(to: defaultDistroFile, atomically: true, encoding: .utf8)
    }

    public func clearDefaultDistro() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: defaultDistroFile.path) {
            try fm.removeItem(at: defaultDistroFile)
        }
    }
}

import Foundation

/// Installs the `appbox` CLI that ships inside the app bundle onto the user's
/// PATH.
///
/// The subtlety this exists for: PATH order. A copy in `~/bin` beats one in
/// `/usr/local/bin` on a typical setup, so naively symlinking into
/// `/usr/local/bin` can be silently shadowed by an older `appbox` earlier in
/// PATH — leaving the GUI on one engine and the terminal on another, both
/// driving the same boxes and disagreeing. So we always look at *every* copy on
/// PATH, not just the first.
public enum CLIInstaller {

    /// One `appbox` found on PATH.
    public struct Installation: Sendable, Equatable {
        public var path: URL
        /// Directory index within PATH — lower wins.
        public var priority: Int
        /// True when this is our symlink into the app bundle.
        public var isManaged: Bool
        /// Where the symlink points, if it is one.
        public var resolvesTo: URL?
    }

    public enum Status: Sendable, Equatable {
        /// No `appbox` anywhere on PATH.
        case notInstalled
        /// Ours is installed and wins on PATH.
        case installed(at: URL)
        /// Ours is installed but something earlier on PATH shadows it.
        case shadowed(ours: URL, winner: URL)
        /// An `appbox` exists that isn't ours — e.g. the original bash script.
        case foreign(at: URL)
    }

    /// Where the CLI lives inside the app bundle.
    public static func bundledCLI(appBundle: URL) -> URL {
        appBundle.appendingPathComponent("Contents/Helpers/appbox")
    }

    /// Compare two file URLs by path.
    ///
    /// URLs cannot be compared directly here: `URL(fileURLWithPath:)` stats the
    /// filesystem and appends a trailing slash for an existing directory, so a
    /// URL built from a PATH entry is unequal to the same directory built with
    /// `appendingPathComponent` — despite identical `.path`. Symlinks are
    /// resolved too, since /var and /private/var name the same directory.
    static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    static func normalized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Directories we're willing to install into, best first. `~/bin` is
    /// offered because it usually wins on PATH and never needs admin rights.
    public static func candidateDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let home = environment["HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
        ]
    }

    /// Every `appbox` on PATH, in PATH order.
    public static func discover(
        appBundle: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Installation] {
        let fm = FileManager.default
        let managedTarget = appBundle.map(bundledCLI(appBundle:))

        let directories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }

        var found: [Installation] = []
        var seen = Set<String>()

        for (index, directory) in directories.enumerated() {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("appbox")
            guard fm.isExecutableFile(atPath: candidate.path) else { continue }
            // The same directory can appear twice in PATH.
            guard seen.insert(candidate.path).inserted else { continue }

            let destination = try? fm.destinationOfSymbolicLink(atPath: candidate.path)
            let resolved = destination.map {
                URL(fileURLWithPath: $0, relativeTo: candidate.deletingLastPathComponent())
                    .standardizedFileURL
            }

            found.append(
                Installation(
                    path: candidate,
                    priority: index,
                    isManaged: managedTarget.map { target in
                        resolved.map { samePath($0, target) } ?? false
                    } ?? false,
                    resolvesTo: resolved))
        }

        return found
    }

    public static func status(
        appBundle: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Status {
        let installations = discover(appBundle: appBundle, environment: environment)
        guard let winner = installations.first else { return .notInstalled }

        guard let ours = installations.first(where: \.isManaged) else {
            return .foreign(at: winner.path)
        }

        return ours.path == winner.path
            ? .installed(at: ours.path)
            : .shadowed(ours: ours.path, winner: winner.path)
    }

    /// The directory to install into.
    ///
    /// Prefers a directory that already holds an `appbox`, so that installing
    /// *replaces the copy that currently wins* rather than adding a second one
    /// further down PATH that never runs.
    public static func recommendedDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let candidates = candidateDirectories(environment: environment)
        let existing = discover(appBundle: nil, environment: environment)

        if let winner = existing.first {
            let directory = winner.path.deletingLastPathComponent()
            if candidates.contains(where: { samePath($0, directory) }) {
                return directory
            }
        }

        // Otherwise the first candidate we can actually write to.
        let fm = FileManager.default
        for candidate in candidates {
            if fm.isWritableFile(atPath: candidate.path) { return candidate }
            // A missing ~/bin is fine — we can create it.
            if !fm.fileExists(atPath: candidate.path),
               fm.isWritableFile(atPath: candidate.deletingLastPathComponent().path) {
                return candidate
            }
        }
        return candidates[0]
    }

    public struct InstallResult: Sendable {
        public var linkPath: URL
        /// Where an existing file was moved, if one was in the way.
        public var backedUpTo: URL?
        /// Copies still earlier on PATH that will continue to win.
        public var shadowedBy: [URL]
        /// PATH does not contain the install directory at all.
        public var directoryNotOnPath: Bool
    }

    /// Symlink the bundled CLI into `directory`.
    ///
    /// An existing regular file is moved aside rather than deleted — it may be
    /// the original bash script, which the user may well want back.
    @discardableResult
    public static func install(
        appBundle: URL,
        into directory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> InstallResult {
        let fm = FileManager.default
        let source = bundledCLI(appBundle: appBundle)

        guard fm.isExecutableFile(atPath: source.path) else {
            throw AppBoxError.usage(
                "the bundled CLI is missing at \(source.path)")
        }

        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let link = directory.appendingPathComponent("appbox")
        var backedUpTo: URL?

        if fm.fileExists(atPath: link.path)
            || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
        {
            let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
            if isSymlink {
                // Replacing one symlink with another loses nothing.
                try fm.removeItem(at: link)
            } else {
                // A real file — probably the original script. Keep it.
                let backup = directory.appendingPathComponent("appbox.previous")
                if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
                try fm.moveItem(at: link, to: backup)
                backedUpTo = backup
            }
        }

        try fm.createSymbolicLink(at: link, withDestinationURL: source)

        // Report anything still ahead of us on PATH.
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let ourIndex = pathDirectories.firstIndex {
            samePath(URL(fileURLWithPath: $0), directory)
        }

        let shadowedBy = discover(appBundle: appBundle, environment: environment)
            .filter { installation in
                guard let ourIndex else { return false }
                return installation.priority < ourIndex
            }
            .map(\.path)

        return InstallResult(
            linkPath: link,
            backedUpTo: backedUpTo,
            shadowedBy: shadowedBy,
            directoryNotOnPath: ourIndex == nil)
    }

    /// Remove our symlink. Leaves anything we didn't create alone.
    public static func uninstall(
        appBundle: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        for installation in discover(appBundle: appBundle, environment: environment)
        where installation.isManaged {
            try FileManager.default.removeItem(at: installation.path)
        }
    }
}

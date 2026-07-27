import Foundation

public enum AppBoxError: Error, LocalizedError, Sendable {
    case containerCLINotFound
    case containerServiceNotRunning
    case boxNotFound(name: String)
    case boxAlreadyExists(name: String)
    case noDistroSpecified(name: String)
    case unknownDistro(token: String, known: String)
    case invalidRockyVersion(String)
    case noPackageManager(box: String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case malformedOutput(command: String, detail: String)
    case usage(String)

    public var errorDescription: String? {
        switch self {
        case .containerCLINotFound:
            return "Apple 'container' CLI not found. Install it first: "
                + "https://github.com/apple/container/releases"
        case .containerServiceNotRunning:
            return "container service not running. Run: container system start"
        case .boxNotFound(let name):
            return "no such box: \(name)"
        case .boxAlreadyExists(let name):
            return "box '\(name)' already exists (use 'appbox destroy \(name)' first)."
        case .noDistroSpecified(let name):
            return "no distribution specified for '\(name)'"
        case .unknownDistro(let token, let known):
            return "unknown distro '\(token)' (try: \(known))"
        case .invalidRockyVersion(let version):
            return "Rocky version must be 9, 10, or latest (got '\(version)')"
        case .noPackageManager(let box):
            return "no supported package manager (apt/dnf/apk/pacman) found in '\(box)'"
        case .commandFailed(let command, let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(command) failed (exit \(exitCode))"
                : "\(command) failed (exit \(exitCode)): \(detail)"
        case .malformedOutput(let command, let detail):
            return "could not understand output of \(command): \(detail)"
        case .usage(let message):
            return message
        }
    }
}

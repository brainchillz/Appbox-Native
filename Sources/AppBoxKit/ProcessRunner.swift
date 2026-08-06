import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { exitCode == 0 }
}

/// Locates and runs external executables.
///
/// Deliberately does **not** go through a login shell. A GUI app's `Process`
/// does not inherit the user's interactive PATH, so the menu bar app and the
/// CLI must find `container` the same explicit way or they will disagree about
/// whether it is installed.
public enum ProcessRunner {

    /// Directories searched for `container` when PATH does not resolve it.
    /// Covers the Apple .pkg location and a Homebrew-style prefix.
    public static let fallbackSearchPaths = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
    ]

    /// Find an executable by name, honouring an explicit override first, then
    /// PATH, then known install locations.
    public static func locate(
        _ name: String,
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fm = FileManager.default

        func executable(at path: String) -> URL? {
            guard fm.isExecutableFile(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }

        if let override, !override.isEmpty {
            return executable(at: override)
        }

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for directory in pathEntries + fallbackSearchPaths {
            guard !directory.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(name).path
            if let found = executable(at: candidate) { return found }
        }

        return nil
    }

    /// Run a command to completion, capturing stdout and stderr.
    ///
    /// Both pipes are drained on background queues before waiting, so a command
    /// that writes more than a pipe buffer's worth of output cannot deadlock.
    /// - Parameter stdin: Text to feed the command on standard input. This is
    ///   how appbox runs scripts inside a container machine: `container machine
    ///   run` re-tokenises its trailing arguments, so a `sh -c '<script>'` on
    ///   the command line arrives mangled, while a script on stdin arrives
    ///   byte-for-byte. See `MachineClient.runScript`.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        stdin: String? = nil,
        onOutputLine: (@Sendable (String) -> Void)? = nil,
        onErrorLine: (@Sendable (String) -> Void)? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe = stdin.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice

        try process.run()

        // Written on a background queue: a script larger than the pipe buffer
        // would otherwise block here before anything drains the output.
        if let inPipe, let stdin {
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = inPipe.fileHandleForWriting
                try? handle.write(contentsOf: Data(stdin.utf8))
                try? handle.close()
            }
        }

        let collector = OutputCollector()
        let group = DispatchGroup()

        func drain(_ pipe: Pipe, isStdout: Bool, lineHandler: (@Sendable (String) -> Void)?) {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                var pending = ""
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    let text = String(decoding: chunk, as: UTF8.self)
                    collector.append(text, isStdout: isStdout)

                    guard let lineHandler else { continue }
                    pending += text
                    while let newline = pending.firstIndex(of: "\n") {
                        lineHandler(String(pending[pending.startIndex..<newline]))
                        pending = String(pending[pending.index(after: newline)...])
                    }
                }
                if let lineHandler, !pending.isEmpty { lineHandler(pending) }
            }
        }

        drain(outPipe, isStdout: true, lineHandler: onOutputLine)
        drain(errPipe, isStdout: false, lineHandler: onErrorLine)

        group.wait()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: collector.stdout,
            stderr: collector.stderr
        )
    }

    /// Replace the current process with the given command, exactly like bash's
    /// `exec`. Used for interactive shells so the child inherits the real TTY
    /// and job control behaves normally. Only returns on failure.
    public static func replaceCurrentProcess(
        _ executable: URL,
        _ arguments: [String]
    ) throws -> Never {
        let argv = [executable.path] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        defer { for pointer in cArgs where pointer != nil { free(pointer) } }

        execv(executable.path, &cArgs)

        // execv only returns if it failed.
        throw AppBoxError.commandFailed(
            command: executable.lastPathComponent,
            exitCode: errno,
            stderr: String(cString: strerror(errno))
        )
    }
}

/// Thread-safe accumulator for the two output streams.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outBuffer = ""
    private var errBuffer = ""

    func append(_ text: String, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout { outBuffer += text } else { errBuffer += text }
    }

    var stdout: String {
        lock.lock(); defer { lock.unlock() }
        return outBuffer
    }

    var stderr: String {
        lock.lock(); defer { lock.unlock() }
        return errBuffer
    }
}

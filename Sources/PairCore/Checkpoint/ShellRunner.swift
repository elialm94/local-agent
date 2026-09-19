import Foundation

public struct ShellResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }
}

public enum ShellError: Error, LocalizedError {
    case launchFailed(String, String)
    case nonZeroExit(command: String, code: Int32, stderr: String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let cmd, let why): return "Could not launch \(cmd): \(why)"
        case .nonZeroExit(let cmd, let code, let err): return "\(cmd) exited with \(code): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .timedOut(let cmd): return "\(cmd) timed out"
        }
    }
}

/// Small synchronous process runner used by the checkpoint manager and project
/// detection. Callers are expected to invoke it off the main thread.
public struct ShellRunner: Sendable {
    public var defaultTimeout: TimeInterval = 60

    public init() {}

    @discardableResult
    public func run(_ executable: String, _ arguments: [String], cwd: String? = nil, environment: [String: String]? = nil, stdin: Data? = nil, timeout: TimeInterval? = nil) throws -> ShellResult {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        if let environment { for (k, v) in environment { env[k] = v } }
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }

        do { try process.run() } catch {
            throw ShellError.launchFailed(([executable] + arguments).joined(separator: " "), error.localizedDescription)
        }

        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        let group = DispatchGroup()
        var outData = Data(), errData = Data()
        let q = DispatchQueue(label: "pair.shell", attributes: .concurrent)
        group.enter(); q.async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = DispatchTime.now() + (timeout ?? defaultTimeout)
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw ShellError.timedOut(([executable] + arguments).joined(separator: " "))
        }
        process.waitUntilExit()
        return ShellResult(exitCode: process.terminationStatus, stdout: outData, stderr: errData)
    }

    /// Run and throw on non-zero exit; returns trimmed stdout.
    public func output(_ executable: String, _ arguments: [String], cwd: String? = nil, environment: [String: String]? = nil, timeout: TimeInterval? = nil) throws -> String {
        let r = try run(executable, arguments, cwd: cwd, environment: environment, timeout: timeout)
        guard r.succeeded else {
            throw ShellError.nonZeroExit(command: ([executable] + arguments).joined(separator: " "), code: r.exitCode, stderr: r.stderrText)
        }
        return r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Locate an executable in PATH plus a few well-known user locations.
    public static func which(_ name: String, extraPaths: [String] = []) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "\(home)/.cursor/bin", "/usr/local/bin", "/opt/homebrew/bin"] + extraPaths
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

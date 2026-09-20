import Foundation

/// Local coding agent driven through the official Cursor CLI in headless mode.
///
/// Verified CLI surface (cursor.com/docs/cli, Sept 2026):
///   agent -p --force --trust --workspace <dir> --output-format stream-json [--resume <chatId>] "<prompt>"
/// NDJSON events: system/init (session_id), user, assistant, tool_call
/// (started/completed with readToolCall / writeToolCall / function), result.
public final class CursorCLIAgentProvider: CodingAgentProvider, @unchecked Sendable {
    public let name = "cursor-cli"
    public let executionTarget: AgentExecutionTarget = .local
    public let executablePath: String?
    public var model: String?
    public var extraArguments: [String] = []

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "pair.cursor-cli.io")
    private var runs: [String: RunState] = [:]

    private final class RunState {
        var task: RunningAgentTask
        var process: Process?
        var sessionID: String?
        var buffer = Data()
        var stderr = Data()
        var changedFiles = Set<String>()
        var lastAssistantText = ""
        var sawFirstEdit = false
        init(task: RunningAgentTask) { self.task = task }
    }

    /// `executablePath` defaults to the first of `agent` / `cursor-agent` found in PATH or ~/.local/bin.
    public init(executablePath: String? = nil, model: String? = nil) {
        self.executablePath = executablePath ?? ShellRunner.which("agent") ?? ShellRunner.which("cursor-agent")
        self.model = model
    }

    public var isAvailable: Bool { executablePath != nil }

    public func start(task: AgentTask, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentRunHandle {
        guard let exe = executablePath else { throw CursorAgentError.cliNotInstalled }
        let runID = "local-" + String(UUID().uuidString.prefix(8)).lowercased()
        let state = RunState(task: RunningAgentTask(id: runID, title: task.title, state: .queued))
        setRun(runID, state)

        var args = ["-p", "--force", "--trust", "--workspace", task.projectRoot, "--output-format", "stream-json"]
        if let model { args += ["--model", model] }
        if let resume = task.resumeSessionID { args += ["--resume", resume] }
        args += extraArguments
        args.append(task.renderPrompt())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: task.projectRoot)
        var env = ProcessInfo.processInfo.environment
        env["CI"] = "1"
        env.removeValue(forKey: "XAI_API_KEY")
        env.removeValue(forKey: "TYPESAFE_API_KEY")
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // All reads, parsing and the final `finished` event go through one serial
        // queue so events are delivered in stream order (a readability callback
        // must never race the termination handler).
        let io = ioQueue
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            guard let provider = self else { return }
            io.async {
                let data = fh.availableData
                if data.isEmpty { fh.readabilityHandler = nil; return }
                provider.consume(runID: runID, data: data, onEvent: onEvent)
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] fh in
            guard let provider = self else { return }
            io.async {
                let data = fh.availableData
                if data.isEmpty { fh.readabilityHandler = nil; return }
                provider.appendStderr(runID: runID, data)
            }
        }
        process.terminationHandler = { [weak self] p in
            guard let provider = self else { return }
            let exitCode = p.terminationStatus
            io.async {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                // Drain anything left in the pipes.
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { provider.consume(runID: runID, data: rest, onEvent: onEvent) }
                let errRest = err.fileHandleForReading.readDataToEndOfFile()
                provider.finish(runID: runID, exitCode: exitCode, extraStderr: errRest, onEvent: onEvent)
            }
        }

        LatencyTracer.shared.begin(.agentStart, key: runID)
        LatencyTracer.shared.begin(.agentFirstEdit, key: runID)
        LatencyTracer.shared.begin(.agentFinished, key: runID)
        do { try process.run() } catch {
            setRun(runID, nil)
            throw CursorAgentError.launchFailed(error.localizedDescription)
        }
        state.process = process
        state.task.state = .running
        Log.info("cursor-cli", "started", ["run": runID, "workspace": task.projectRoot, "resume": task.resumeSessionID ?? "-"])
        return AgentRunHandle(runID: runID, executionTarget: .local)
    }

    public func status(runID: String) async -> RunningAgentTask? {
        currentTask(runID: runID)
    }

    public func cancel(runID: String) async throws {
        terminateAndMarkCancelled(runID: runID)
    }

    // Synchronous helpers keep NSLock usage out of async contexts.
    private func setRun(_ runID: String, _ state: RunState?) {
        lock.lock(); runs[runID] = state; lock.unlock()
    }

    private func appendStderr(runID: String, _ data: Data) {
        lock.lock(); runs[runID]?.stderr.append(data); lock.unlock()
    }

    private func currentTask(runID: String) -> RunningAgentTask? {
        lock.lock(); defer { lock.unlock() }
        return runs[runID]?.task
    }

    private func terminateAndMarkCancelled(runID: String) {
        lock.lock()
        let state = runs[runID]
        lock.unlock()
        guard let state, let p = state.process, p.isRunning else { return }
        p.terminate()
        lock.lock()
        state.task.state = .cancelled
        state.task.finishedAt = Date()
        lock.unlock()
    }

    // MARK: - NDJSON parsing

    private func consume(runID: String, data: Data, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        lock.lock()
        guard let state = runs[runID] else { lock.unlock(); return }
        state.buffer.append(data)
        var lines: [Data] = []
        while let nl = state.buffer.firstIndex(of: 0x0A) {
            lines.append(state.buffer.subdata(in: state.buffer.startIndex..<nl))
            state.buffer.removeSubrange(state.buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            handle(runID: runID, line: line, onEvent: onEvent)
        }
    }

    func handle(runID: String, line: Data, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        guard let event = try? JSONDecoder().decode(JSONValue.self, from: line) else { return }
        guard let type = event["type"]?.stringValue else { return }
        lock.lock()
        guard let state = runs[runID] else { lock.unlock(); return }
        lock.unlock()

        switch type {
        case "system":
            if event["subtype"]?.stringValue == "init" {
                let sid = event["session_id"]?.stringValue
                lock.lock(); state.sessionID = sid; lock.unlock()
                LatencyTracer.shared.end(.agentStart, key: runID)
                onEvent(.started(runID: runID, sessionID: sid))
            }
        case "assistant":
            // Skip duplicate buffered flushes when partial streaming is on.
            if event["model_call_id"] != nil { return }
            let text = event["message"]?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined() ?? ""
            if !text.isEmpty {
                lock.lock(); state.lastAssistantText = text; lock.unlock()
                onEvent(.assistantText(text))
            }
        case "tool_call":
            guard let call = event["tool_call"]?.objectValue else { return }
            let subtype = event["subtype"]?.stringValue ?? ""
            if let write = call["writeToolCall"] {
                let path = write["args"]?["path"]?.stringValue
                if subtype == "started" { onEvent(.toolCall(name: "write", path: path)) }
                if subtype == "completed", let p = write["result"]?["success"]?["path"]?.stringValue ?? path {
                    recordChange(runID: runID, state: state, path: p, onEvent: onEvent)
                }
            } else if let read = call["readToolCall"] {
                if subtype == "started" { onEvent(.toolCall(name: "read", path: read["args"]?["path"]?.stringValue)) }
            } else if let fn = call["function"] {
                let fname = fn["name"]?.stringValue ?? "tool"
                if subtype == "started" { onEvent(.toolCall(name: fname, path: nil)) }
                // Edits made through other tools (e.g. search_replace / edit_file) carry a path in arguments.
                if subtype == "completed", let argsText = fn["arguments"]?.stringValue, let args = try? JSONValue.parse(argsText),
                   let p = args["path"]?.stringValue ?? args["target_file"]?.stringValue ?? args["file_path"]?.stringValue,
                   ["edit_file", "search_replace", "write", "delete_file", "edit", "apply_patch", "str_replace", "StrReplace", "Write", "Delete"].contains(where: { fname.localizedCaseInsensitiveContains($0) }) {
                    recordChange(runID: runID, state: state, path: p, onEvent: onEvent)
                }
            } else if let (toolName, body) = call.first, let obj = body.objectValue {
                // Unknown tool shapes: surface the name; detect path-bearing edits heuristically.
                if subtype == "started" { onEvent(.toolCall(name: toolName, path: obj["args"]?["path"]?.stringValue)) }
                if subtype == "completed", toolName.lowercased().contains("edit") || toolName.lowercased().contains("write") || toolName.lowercased().contains("replace"),
                   let p = obj["args"]?["path"]?.stringValue ?? obj["result"]?["success"]?["path"]?.stringValue {
                    recordChange(runID: runID, state: state, path: p, onEvent: onEvent)
                }
            }
        case "result":
            let text = event["result"]?.stringValue ?? state.lastAssistantText
            lock.lock()
            state.task.summary = text
            lock.unlock()
        default:
            break
        }
    }

    private func recordChange(runID: String, state: RunState, path: String, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        lock.lock()
        let isNew = state.changedFiles.insert(path).inserted
        let first = !state.sawFirstEdit
        state.sawFirstEdit = true
        state.task.changedFiles = state.changedFiles.sorted()
        lock.unlock()
        if first { LatencyTracer.shared.end(.agentFirstEdit, key: runID) }
        if isNew { onEvent(.fileChanged(path: path)) }
    }

    private func finish(runID: String, exitCode: Int32, extraStderr: Data, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        lock.lock()
        guard let state = runs[runID] else { lock.unlock(); return }
        state.stderr.append(extraStderr)
        let wasCancelled = state.task.state == .cancelled
        state.task.finishedAt = Date()
        let stderrText = String(decoding: state.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = state.task.summary ?? state.lastAssistantText
        if wasCancelled {
            lock.unlock()
            onEvent(.cancelled)
            return
        }
        if exitCode == 0 {
            state.task.state = .finished
            lock.unlock()
            LatencyTracer.shared.end(.agentFinished, key: runID)
            Log.info("cursor-cli", "finished", ["run": runID, "files": "\(state.changedFiles.count)"])
            onEvent(.finished(summary: summary.isEmpty ? "Done." : summary))
        } else {
            state.task.state = .failed
            let message = stderrText.isEmpty ? "Cursor agent exited with code \(exitCode)" : stderrText
            state.task.error = message
            lock.unlock()
            LatencyTracer.shared.end(.agentFinished, key: runID)
            Log.error("cursor-cli", "failed", ["run": runID, "code": "\(exitCode)", "stderr": String(message.prefix(300))])
            onEvent(.failed(error: message))
        }
    }

    /// Session id captured from the `system/init` event, for `--resume`.
    public func sessionID(runID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return runs[runID]?.sessionID
    }
}

public enum CursorAgentError: Error, LocalizedError {
    case cliNotInstalled
    case launchFailed(String)
    case notConfigured(String)
    case http(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .cliNotInstalled: return "Cursor CLI not found. Install with: curl https://cursor.com/install -fsS | bash  (then run `agent login`)."
        case .launchFailed(let s): return "Could not launch Cursor CLI: \(s)"
        case .notConfigured(let s): return "Cursor integration not configured: \(s)"
        case .http(let status, let body): return "Cursor API HTTP \(status): \(body)"
        }
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cursor Cloud Agents API (public beta). Verified against
/// cursor.com/docs/cloud-agent/api/endpoints (Sept 2026):
///   POST https://api.cursor.com/v1/agents  (basic auth: API key as username)
///   body: { prompt: { text }, repos: [{ url, startingRef }], autoCreatePR }
///   → { agent: { id, status, url, ... }, run: { id, status } }
///   GET  https://api.cursor.com/v1/agents/{id}
///   POST https://api.cursor.com/v1/agents/{id}/runs/{runId}/cancel
///
/// Cloud agents work on a *remote clone*, so results arrive as a branch/PR, not
/// as edits to the local working tree. This provider is therefore reserved for
/// large/background tasks; small UI changes always go through the local CLI.
public final class CursorCloudAgentProvider: CodingAgentProvider, @unchecked Sendable {
    public let name = "cursor-cloud"
    public let executionTarget: AgentExecutionTarget = .cloud
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let lock = NSLock()
    private var runs: [String: (task: RunningAgentTask, agentID: String, runID: String)] = [:]
    /// Optional model id from GET /v1/models; nil uses the account default.
    public var modelID: String?

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.cursor.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        session = URLSession(configuration: .ephemeral)
    }

    public var isAvailable: Bool { !apiKey.isEmpty }

    public func start(task: AgentTask, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentRunHandle {
        guard isAvailable else { throw CursorAgentError.notConfigured("CURSOR_API_KEY missing") }
        guard let remote = repoURL(for: task) else {
            throw CursorAgentError.notConfigured("project has no GitHub remote; cloud agents need a repository URL")
        }
        var body: [String: JSONValue] = [
            "prompt": .object(["text": .string(task.renderPrompt())]),
            "repos": .array([.object(["url": .string(remote), "startingRef": .string(task.branch ?? "main")])]),
            "autoCreatePR": .bool(false),
        ]
        if let modelID { body["model"] = .object(["id": .string(modelID)]) }

        var req = URLRequest(url: baseURL.appendingPathComponent("v1/agents"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Basic " + Data("\(apiKey):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CursorAgentError.http(status: status, body: String(String(decoding: data, as: UTF8.self).prefix(400)))
        }
        let parsed = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let agentID = parsed["agent"]?["id"]?.stringValue, let runID = parsed["run"]?["id"]?.stringValue else {
            throw CursorAgentError.http(status: http.statusCode, body: "unexpected response shape")
        }
        let localID = "cloud-" + String(agentID.suffix(8))
        var running = RunningAgentTask(id: localID, title: task.title, state: .running)
        running.summary = parsed["agent"]?["url"]?.stringValue
        lock.lock(); runs[localID] = (running, agentID, runID); lock.unlock()
        onEvent(.started(runID: localID, sessionID: agentID))
        Log.info("cursor-cloud", "started", ["agent": agentID, "run": runID])
        return AgentRunHandle(runID: localID, executionTarget: .cloud)
    }

    public func status(runID: String) async -> RunningAgentTask? {
        lock.lock()
        guard let entry = runs[runID] else { lock.unlock(); return nil }
        lock.unlock()
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/agents/\(entry.agentID)"))
        req.setValue("Basic " + Data("\(apiKey):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await session.data(for: req), let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return entry.task
        }
        var t = entry.task
        switch parsed["status"]?.stringValue ?? "" {
        case "FINISHED": t.state = .finished
        case "ERROR", "EXPIRED": t.state = .failed
        case "CANCELLED": t.state = .cancelled
        default: t.state = .running
        }
        if let url = parsed["url"]?.stringValue { t.summary = url }
        lock.lock(); runs[runID]?.task = t; lock.unlock()
        return t
    }

    public func cancel(runID: String) async throws {
        lock.lock()
        guard let entry = runs[runID] else { lock.unlock(); return }
        lock.unlock()
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/agents/\(entry.agentID)/runs/\(entry.runID)/cancel"))
        req.httpMethod = "POST"
        req.setValue("Basic " + Data("\(apiKey):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: req)
        lock.lock(); runs[runID]?.task.state = .cancelled; lock.unlock()
    }

    func repoURL(for task: AgentTask) -> String? {
        // Derived by the project detector from `git remote get-url origin`.
        guard let remote = ProjectDetection.httpsRemote(fromGitRemote: (try? ShellRunner().output("git", ["remote", "get-url", "origin"], cwd: task.projectRoot)) ?? "") else { return nil }
        return remote
    }
}

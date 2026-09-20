import Foundation

// MARK: - Fast decision mock

/// Deterministic stand-in for Jev. Answers by simple keyword rules so the
/// pipeline behaves sensibly without credentials.
public final class MockFastDecisionProvider: FastDecisionProvider, @unchecked Sendable {
    public let name = "mock-jev"
    public var isAvailable: Bool
    public var simulatedLatencyMs: Double = 25
    private let router = IntentRouter()

    public init(available: Bool = true) {
        isAvailable = available
    }

    public func decide(_ request: DecisionRequest) async throws -> DecisionResponse {
        try? await Task.sleep(nanoseconds: UInt64(simulatedLatencyMs * 1_000_000))
        let utterance = request.state["utterance"]?.stringValue ?? request.state.stringValue ?? ""
        var answers: [String: DecisionAnswer] = [:]
        for (id, q) in request.questions {
            switch q {
            case .noul(let instr):
                let low = instr.lowercased()
                let yes: Double
                if low.contains("go ahead") || low.contains("make a change now") { yes = router.isExecutionCommand(utterance) ? 0.95 : 0.05 }
                else if low.contains("pixels") { yes = ["color", "look", "cluttered", "align", "spacing"].contains(where: utterance.lowercased().contains) ? 0.8 : 0.15 }
                else if low.contains("this, that, here") { yes = ["this", "that", "here", "these"].contains(where: { utterance.lowercased().split(separator: " ").map(String.init).contains($0) }) ? 0.9 : 0.1 }
                else if low.contains("ambiguous") { yes = utterance.split(separator: " ").count <= 1 ? 0.8 : 0.1 }
                else { yes = 0.5 }
                answers[id] = .noul(probability: yes)
            case .choice(_, let options):
                let routed = router.route(utterance)
                if options[routed.intent.rawValue] != nil {
                    var probs = options.mapValues { _ in 0.0 }
                    probs[routed.intent.rawValue] = 0.9
                    answers[id] = .choice(choice: routed.intent.rawValue, probabilities: probs, confidence: 0.9)
                } else {
                    let first = options.keys.sorted().first ?? ""
                    answers[id] = .choice(choice: first, probabilities: options.mapValues { _ in 1.0 / Double(max(1, options.count)) }, confidence: 0.3)
                }
            case .score(_, let levels):
                let words = utterance.split(separator: " ").count
                let level = min(levels.count - 1, words / 25)
                answers[id] = .score(score: Double(level), probabilities: [String(level): 1.0], confidence: 0.7)
            }
        }
        return DecisionResponse(answers: answers, model: "mock-jev", latencyMs: simulatedLatencyMs)
    }
}

// MARK: - Coding agent mock

/// Simulates a coding agent by making a trivially reversible edit: it appends a
/// CSS comment or a marker to a file the task points at (or a scratch file), so
/// the checkpoint/undo path can be exercised end to end with no Cursor install.
public final class MockCodingAgentProvider: CodingAgentProvider, @unchecked Sendable {
    public let name = "mock-cursor"
    public let executionTarget: AgentExecutionTarget
    public let isAvailable = true
    public var simulatedDurationMs: Double = 400
    /// When true the mock does not touch the file system (pure dry run).
    public var dryRun = false

    private let lock = NSLock()
    private var runs: [String: RunningAgentTask] = [:]

    public init(executionTarget: AgentExecutionTarget = .local) {
        self.executionTarget = executionTarget
    }

    public func start(task: AgentTask, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentRunHandle {
        let runID = "mock-" + String(UUID().uuidString.prefix(8)).lowercased()
        lock.lock(); runs[runID] = RunningAgentTask(id: runID, title: task.title, state: .running); lock.unlock()
        onEvent(.started(runID: runID, sessionID: "mock-session-\(runID)"))
        let duration = simulatedDurationMs
        let dry = dryRun
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000))
            onEvent(.assistantText("Applying: \(task.title)"))
            var changed: [String] = []
            if !dry {
                let rel = task.sourceReference?.file ?? "PAIR_MOCK_CHANGES.md"
                let abs = (task.projectRoot as NSString).appendingPathComponent(rel)
                let marker = "\n/* pair-mock: \(task.title) (\(task.id.prefix(8))) */\n"
                do {
                    try FileManager.default.createDirectory(atPath: (abs as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    if let h = FileHandle(forWritingAtPath: abs) {
                        h.seekToEndOfFile(); h.write(Data(marker.utf8)); try? h.close()
                    } else {
                        try marker.write(toFile: abs, atomically: true, encoding: .utf8)
                    }
                    changed.append(rel)
                    onEvent(.toolCall(name: "write", path: rel))
                    onEvent(.fileChanged(path: rel))
                } catch {
                    self?.setState(runID, .failed, error: error.localizedDescription)
                    onEvent(.failed(error: error.localizedDescription))
                    return
                }
            }
            self?.setState(runID, .finished, changed: changed)
            onEvent(.finished(summary: "Mock agent applied \"\(task.title)\"" + (changed.isEmpty ? " (dry run)." : " by editing \(changed.joined(separator: ", "))." )))
        }
        return AgentRunHandle(runID: runID, executionTarget: executionTarget)
    }

    private func setState(_ runID: String, _ s: AgentRunState, changed: [String] = [], error: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        runs[runID]?.state = s
        runs[runID]?.finishedAt = Date()
        runs[runID]?.changedFiles = changed
        runs[runID]?.error = error
    }

    public func status(runID: String) async -> RunningAgentTask? {
        lock.lock(); defer { lock.unlock() }
        return runs[runID]
    }

    public func cancel(runID: String) async throws {
        setState(runID, .cancelled)
    }
}

// MARK: - Voice mock

/// Text-only stand-in for Grok Voice. It does not do speech; it echoes the
/// user's typed utterance through the same delegate callbacks and applies a
/// tiny rule set so the tool loop (propose → execute → undo) can be exercised
/// offline. Tool calls are emitted exactly as the real provider would.
public final class MockVoiceProvider: VoiceReasoningProvider, @unchecked Sendable {
    public let name = "mock-grok"
    public private(set) var state: VoiceConnectionState = .disconnected
    public weak var delegate: VoiceReasoningDelegate?
    private let router = IntentRouter()
    private var pendingContext: String?
    private var lastProposal: String?
    private var callCounter = 0
    private var turnBuffer = Data()

    public init() {}

    public func connect(config: VoiceSessionConfig) async throws {
        state = .connected
        delegate?.voiceProvider(self, didChangeState: .connected)
    }

    public func disconnect() {
        state = .disconnected
        delegate?.voiceProvider(self, didChangeState: .disconnected)
    }

    public func beginUserTurn() { turnBuffer.removeAll() }
    public func beginLiveSession() { beginUserTurn() }
    public func endLiveSession() { interrupt() }
    public func completeServerTurn(context: String?) { endUserTurn(context: context) }
    public func appendAudio(_ pcm16: Data) { turnBuffer.append(pcm16) }

    public func endUserTurn(context: String?) {
        // No ASR in the mock: audio turns produce a canned transcript so the UI flow can be tested.
        pendingContext = context
        let seconds = Double(turnBuffer.count) / (24000 * 2)
        guard seconds > 0.2 else { return }
        sendUserText("(mock transcript, \(String(format: "%.1f", seconds))s of audio)", context: context)
    }

    public func sendUserText(_ text: String, context: String?) {
        pendingContext = context
        delegate?.voiceProvider(self, didReceiveUserTranscript: text, isFinal: true)
        delegate?.voiceProvider(self, didStartResponse: ())
        let decision = router.route(text)
        callCounter += 1
        let callID = "mockcall-\(callCounter)"
        switch decision.intent {
        case .executePreviousProposal:
            emitToolCall(callID, ToolName.executeChange.rawValue, ["proposal_ordinal": decision.proposalOrdinal.map { JSONValue.number(Double($0)) } ?? .null])
        case .modifyUI, .modifyCode:
            if decision.isExecutionCommand {
                emitToolCall(callID, ToolName.executeChange.rawValue, ["requested_change": .string(text), "context": .string("User asked directly.")])
            } else {
                lastProposal = text
                emitToolCall(callID, ToolName.proposeChange.rawValue, ["summary": .string(Self.proposalSummary(from: text, context: context)), "rationale": .string("User request.")])
            }
        case .undo:
            emitToolCall(callID, ToolName.undoLastChange.rawValue, ["steps": .number(Double(decision.undoSteps == Int.max ? 99 : decision.undoSteps))])
        case .redo:
            emitToolCall(callID, ToolName.redoChange.rawValue, [:])
        case .checkAgent:
            emitToolCall(callID, ToolName.getAgentStatus.rawValue, [:])
        case .cancelAgent:
            emitToolCall(callID, ToolName.cancelAgent.rawValue, [:])
        case .inspectUI, .question, .discuss, .inspectCode:
            speak("(mock) I'm looking at " + (context.map { Self.targetSummary(from: $0) } ?? "nothing in particular") + ". Tell me what you'd like to change and then say \"do it\".")
        default:
            speak("(mock) Okay.")
        }
    }

    public func sendToolResult(callID: String, outputJSON: String) {
        let parsed = try? JSONValue.parse(outputJSON)
        let ok = parsed?["ok"]?.boolValue ?? false
        if let spoken = parsed?["spoken"]?.stringValue {
            speak(spoken)
        } else if ok, parsed?["proposal_id"] != nil, let p = lastProposal {
            speak("(mock) Got it — \(p). Say \"do it\" and I'll have Cursor make the change.")
        } else if ok {
            speak("(mock) Done.")
        } else {
            speak("(mock) " + (parsed?["error"]?.stringValue ?? "That didn't work."))
        }
    }

    public func injectSystemNote(_ text: String, requestResponse: Bool) {
        if requestResponse { speak("(mock) Noted: " + String(text.prefix(140))) }
    }

    public func interrupt() {}

    private func emitToolCall(_ id: String, _ name: String, _ args: [String: JSONValue]) {
        let json = (try? JSONValue.object(args.filter { $0.value != .null }).toString()) ?? "{}"
        delegate?.voiceProvider(self, didRequestToolCall: ToolCallRequest(callID: id, name: name, argumentsJSON: json))
    }

    private func speak(_ text: String) {
        delegate?.voiceProvider(self, didReceiveAssistantTranscriptDelta: text)
        delegate?.voiceProvider(self, didFinishAssistantTurn: text)
        delegate?.voiceProvider(self, didFinishResponse: ())
    }

    static func proposalSummary(from text: String, context: String?) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ctx = context, let target = try? JSONValue.parse(ctx), let label = target["target"]?["label"]?.stringValue, let role = target["target"]?["role"]?.stringValue {
            for w in ["this button", "this element", "this thing", "this", "that"] where s.lowercased().contains(w) {
                if let r = s.range(of: w, options: .caseInsensitive) { s.replaceSubrange(r, with: "the \"\(label)\" \(role.lowercased())"); break }
            }
        }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func targetSummary(from context: String) -> String {
        guard let j = try? JSONValue.parse(context), let t = j["target"] else { return "the screen" }
        return "the \(t["role"]?.stringValue ?? "element") \"\(t["label"]?.stringValue ?? "")\""
    }
}

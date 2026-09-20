import Foundation

// MARK: - Fast decision (Jev)

public enum DecisionQuestion: Codable, Sendable {
    /// Yes/no; answer is a probability of "yes".
    case noul(instructions: String)
    /// Pick one of the named options; values are short descriptions.
    case choice(instructions: String, options: [String: String])
    /// Position on an ordered rubric (low → high).
    case score(instructions: String, levels: [String])

    enum CodingKeys: String, CodingKey { case type, instructions, criteria }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let instructions = try c.decode(String.self, forKey: .instructions)
        switch type {
        case "noul": self = .noul(instructions: instructions)
        case "choice": self = .choice(instructions: instructions, options: try c.decode([String: String].self, forKey: .criteria))
        case "score": self = .score(instructions: instructions, levels: try c.decode([String].self, forKey: .criteria))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown question type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noul(let i):
            try c.encode("noul", forKey: .type); try c.encode(i, forKey: .instructions)
        case .choice(let i, let o):
            try c.encode("choice", forKey: .type); try c.encode(i, forKey: .instructions); try c.encode(o, forKey: .criteria)
        case .score(let i, let l):
            try c.encode("score", forKey: .type); try c.encode(i, forKey: .instructions); try c.encode(l, forKey: .criteria)
        }
    }
}

public enum DecisionAnswer: Codable, Equatable, Sendable {
    case noul(probability: Double)
    case choice(choice: String, probabilities: [String: Double], confidence: Double)
    case score(score: Double, probabilities: [String: Double], confidence: Double)

    enum CodingKeys: String, CodingKey { case type, noul, choice, score, probabilities, confidence }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "noul":
            self = .noul(probability: try c.decode(Double.self, forKey: .noul))
        case "choice":
            self = .choice(
                choice: try c.decode(String.self, forKey: .choice),
                probabilities: try c.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:],
                confidence: try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
            )
        case "score":
            self = .score(
                score: try c.decode(Double.self, forKey: .score),
                probabilities: try c.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:],
                confidence: try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
            )
        case let t:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown answer type \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noul(let p):
            try c.encode("noul", forKey: .type); try c.encode(p, forKey: .noul)
        case .choice(let ch, let pr, let cf):
            try c.encode("choice", forKey: .type); try c.encode(ch, forKey: .choice); try c.encode(pr, forKey: .probabilities); try c.encode(cf, forKey: .confidence)
        case .score(let s, let pr, let cf):
            try c.encode("score", forKey: .type); try c.encode(s, forKey: .score); try c.encode(pr, forKey: .probabilities); try c.encode(cf, forKey: .confidence)
        }
    }

    public var yesProbability: Double? { if case .noul(let p) = self { return p }; return nil }
    public var choiceValue: String? { if case .choice(let c, _, _) = self { return c }; return nil }
    public var confidenceValue: Double {
        switch self {
        case .noul(let p): return abs(p - 0.5) * 2
        case .choice(_, _, let c), .score(_, _, let c): return c
        }
    }
}

public struct DecisionRequest: Sendable {
    /// JSON-serializable state (String, [String: Any], or [Any]).
    public var state: JSONValue
    public var questions: [String: DecisionQuestion]

    public init(state: JSONValue, questions: [String: DecisionQuestion]) {
        self.state = state
        self.questions = questions
    }
}

public struct DecisionResponse: Sendable {
    public var answers: [String: DecisionAnswer]
    public var model: String
    public var latencyMs: Double

    public init(answers: [String: DecisionAnswer], model: String, latencyMs: Double) {
        self.answers = answers
        self.model = model
        self.latencyMs = latencyMs
    }
}

/// Fast, typed, structured decisions (Jev). Never used for prose.
public protocol FastDecisionProvider: Sendable {
    var name: String { get }
    var isAvailable: Bool { get }
    func decide(_ request: DecisionRequest) async throws -> DecisionResponse
}

// MARK: - Coding agent (Cursor)

public enum AgentEvent: Sendable {
    case started(runID: String, sessionID: String?)
    case assistantText(String)
    case toolCall(name: String, path: String?)
    case fileChanged(path: String)
    case finished(summary: String)
    case failed(error: String)
    case cancelled
}

public struct AgentRunHandle: Sendable {
    public var runID: String
    public var executionTarget: AgentExecutionTarget

    public init(runID: String, executionTarget: AgentExecutionTarget) {
        self.runID = runID
        self.executionTarget = executionTarget
    }
}

/// Executes compiled `AgentTask`s. Local (Cursor CLI) and cloud (Cursor Cloud
/// Agents API) providers implement the same interface.
public protocol CodingAgentProvider: Sendable {
    var name: String { get }
    var executionTarget: AgentExecutionTarget { get }
    var isAvailable: Bool { get }
    func start(task: AgentTask, onEvent: @escaping @Sendable (AgentEvent) -> Void) async throws -> AgentRunHandle
    func status(runID: String) async -> RunningAgentTask?
    func cancel(runID: String) async throws
}

// MARK: - Voice reasoning (Grok Voice)

public enum VoiceConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case failed
}

public struct ToolCallRequest: Sendable {
    public var callID: String
    public var name: String
    public var argumentsJSON: String

    public init(callID: String, name: String, argumentsJSON: String) {
        self.callID = callID
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct VoiceSessionConfig: Sendable {
    public var instructions: String
    public var voice: String
    public var sampleRate: Int
    public var tools: [ToolDefinition]
    /// When true the server decides turn boundaries; when false the client
    /// commits on hotkey release (push-to-talk).
    public var serverVAD: Bool
    /// How long the user may pause, in a live session, before the turn ends.
    /// Long enough to think or move the mouse; short enough that a reply still feels conversational.
    public var silenceDurationMs: Int
    /// When false, a server-VAD turn commits the audio but the client sends `response.create`
    /// itself, after attaching fresh screen context.
    public var vadCreatesResponse: Bool
    public var languageHint: String?
    public var keyterms: [String]

    public init(instructions: String, voice: String = "eve", sampleRate: Int = 24000, tools: [ToolDefinition] = [], serverVAD: Bool = false, silenceDurationMs: Int = 1400, vadCreatesResponse: Bool = false, languageHint: String? = nil, keyterms: [String] = []) {
        self.instructions = instructions
        self.voice = voice
        self.sampleRate = sampleRate
        self.tools = tools
        self.serverVAD = serverVAD
        self.silenceDurationMs = silenceDurationMs
        self.vadCreatesResponse = vadCreatesResponse
        self.languageHint = languageHint
        self.keyterms = keyterms
    }
}

public protocol VoiceReasoningDelegate: AnyObject, Sendable {
    func voiceProvider(_ provider: VoiceReasoningProvider, didChangeState state: VoiceConnectionState)
    func voiceProvider(_ provider: VoiceReasoningProvider, didReceiveAudio pcm16: Data)
    func voiceProvider(_ provider: VoiceReasoningProvider, didReceiveUserTranscript text: String, isFinal: Bool)
    func voiceProvider(_ provider: VoiceReasoningProvider, didReceiveAssistantTranscriptDelta delta: String)
    func voiceProvider(_ provider: VoiceReasoningProvider, didFinishAssistantTurn transcript: String)
    func voiceProvider(_ provider: VoiceReasoningProvider, didRequestToolCall call: ToolCallRequest)
    func voiceProvider(_ provider: VoiceReasoningProvider, didStartResponse: Void)
    func voiceProvider(_ provider: VoiceReasoningProvider, didFinishResponse: Void)
    func voiceProvider(_ provider: VoiceReasoningProvider, didDetectUserSpeechStart: Void)
    /// Server VAD decided the user finished a phrase (after `silenceDurationMs` of quiet).
    func voiceProvider(_ provider: VoiceReasoningProvider, didDetectUserSpeechStop: Void)
    func voiceProvider(_ provider: VoiceReasoningProvider, didFail error: Error)
}

/// Persistent realtime conversational intelligence.
public protocol VoiceReasoningProvider: AnyObject, Sendable {
    var name: String { get }
    var state: VoiceConnectionState { get }
    var delegate: VoiceReasoningDelegate? { get set }
    func connect(config: VoiceSessionConfig) async throws
    func disconnect()
    /// Called when the user starts holding the hotkey.
    func beginUserTurn()
    func appendAudio(_ pcm16: Data)
    /// Called when the user releases the hotkey. `context` is compact
    /// structured screen context injected before the model responds.
    func endUserTurn(context: String?)
    /// Open a hands-free session. Audio streams until `endLiveSession`; the server
    /// detects pauses. Does not end the turn.
    func beginLiveSession()
    /// Close a hands-free session: stop any reply and discard audio still buffered.
    func endLiveSession()
    /// A server-VAD pause just ended the user's phrase. Attach context and ask for a reply.
    func completeServerTurn(context: String?)
    /// Typed-text path (debug panel / CLI); goes through the same conversation.
    func sendUserText(_ text: String, context: String?)
    func sendToolResult(callID: String, outputJSON: String)
    /// Post a note into the conversation (e.g. "agent finished") and optionally ask for a spoken reaction.
    func injectSystemNote(_ text: String, requestResponse: Bool)
    /// Stop the assistant mid-sentence.
    func interrupt()
}

// MARK: - Perception (macOS)

public protocol PerceptionProvider: AnyObject {
    var name: String { get }
    func start()
    func stop()
    /// Cheap read of the latest world state.
    func snapshot() -> WorldState
    /// Resolve the UI element at a screen point right now (may be slower).
    func target(at point: Point) -> AttentionTarget?
    /// PNG crop of a screen rect, for `capture_target`. Nil if not permitted.
    func capture(rect: Rect) async -> VisualCrop?
}

import Foundation

public enum Speaker: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct TranscriptTurn: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var speaker: Speaker
    public var text: String
    public var at: Date = Date()
    public var targetID: String?
}

/// A concrete change the assistant suggested during conversation. Registered
/// either through the `propose_change` tool or by parsing a numbered list out
/// of the assistant's spoken transcript.
public struct Proposal: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var summary: String
    public var targetID: String?
    public var targetDescription: String?
    public var constraints: [String]
    public var rationale: String?
    public var createdAt: Date
    /// Position within the assistant turn that produced it (1-based) so
    /// "do the second one" is resolvable.
    public var ordinalInTurn: Int
    public var turnID: String
    public var executedTaskID: String?

    public init(
        id: String = UUID().uuidString,
        summary: String,
        targetID: String? = nil,
        targetDescription: String? = nil,
        constraints: [String] = [],
        rationale: String? = nil,
        createdAt: Date = Date(),
        ordinalInTurn: Int = 1,
        turnID: String,
        executedTaskID: String? = nil
    ) {
        self.id = id
        self.summary = summary
        self.targetID = targetID
        self.targetDescription = targetDescription
        self.constraints = constraints
        self.rationale = rationale
        self.createdAt = createdAt
        self.ordinalInTurn = ordinalInTurn
        self.turnID = turnID
        self.executedTaskID = executedTaskID
    }
}

/// A completed or in-flight code action, for undo/redo bookkeeping and for
/// letting the model reason about "the last change".
public struct CodeAction: Codable, Identifiable, Sendable {
    public var id: String
    public var task: AgentTask
    public var checkpointID: String
    public var agentRunID: String?
    public var agentSessionID: String?
    public var state: AgentRunState
    public var changedFiles: [String]
    public var summary: String?
    public var undone: Bool
    public var startedAt: Date
    public var finishedAt: Date?

    public init(
        id: String = UUID().uuidString,
        task: AgentTask,
        checkpointID: String,
        agentRunID: String? = nil,
        agentSessionID: String? = nil,
        state: AgentRunState = .queued,
        changedFiles: [String] = [],
        summary: String? = nil,
        undone: Bool = false,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.task = task
        self.checkpointID = checkpointID
        self.agentRunID = agentRunID
        self.agentSessionID = agentSessionID
        self.state = state
        self.changedFiles = changedFiles
        self.summary = summary
        self.undone = undone
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// Short-lived, bounded memory for one coding session.
public final class SessionMemory: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var transcript: [TranscriptTurn] = []
    public private(set) var proposals: [Proposal] = []
    public private(set) var actions: [CodeAction] = []
    public private(set) var recentTargets: [AttentionTarget] = []
    public var currentProject: ProjectContext?
    /// The target that was active during the most recent user utterance.
    public private(set) var currentTarget: AttentionTarget?

    public var maxTranscriptTurns = 60
    public var maxProposals = 30
    public var maxTargets = 10

    public init() {}

    // MARK: Transcript

    @discardableResult
    public func addTurn(_ speaker: Speaker, _ text: String, targetID: String? = nil) -> TranscriptTurn {
        lock.lock(); defer { lock.unlock() }
        let turn = TranscriptTurn(speaker: speaker, text: text, targetID: targetID)
        transcript.append(turn)
        if transcript.count > maxTranscriptTurns { transcript.removeFirst(transcript.count - maxTranscriptTurns) }
        if speaker == .assistant {
            registerProposalsFromTranscript(turn)
        }
        return turn
    }

    public func recentTranscript(turns: Int = 8) -> [TranscriptTurn] {
        lock.lock(); defer { lock.unlock() }
        return Array(transcript.suffix(turns))
    }

    public var lastUserTurn: TranscriptTurn? {
        lock.lock(); defer { lock.unlock() }
        return transcript.last { $0.speaker == .user }
    }

    // MARK: Targets

    public func setCurrentTarget(_ t: AttentionTarget?) {
        lock.lock(); defer { lock.unlock() }
        currentTarget = t
        if let t {
            recentTargets.removeAll { $0.id == t.id }
            recentTargets.append(t)
            if recentTargets.count > maxTargets { recentTargets.removeFirst(recentTargets.count - maxTargets) }
        }
    }

    public func target(id: String) -> AttentionTarget? {
        lock.lock(); defer { lock.unlock() }
        return recentTargets.first { $0.id == id }
    }

    // MARK: Proposals

    @discardableResult
    public func addProposal(summary: String, targetID: String? = nil, targetDescription: String? = nil, constraints: [String] = [], rationale: String? = nil, ordinal: Int? = nil, turnID: String? = nil) -> Proposal {
        lock.lock(); defer { lock.unlock() }
        let tid = turnID ?? transcript.last(where: { $0.speaker == .assistant })?.id ?? "tool"
        let ord = ordinal ?? (proposals.filter { $0.turnID == tid }.count + 1)
        let p = Proposal(summary: summary, targetID: targetID ?? currentTarget?.id, targetDescription: targetDescription ?? currentTarget?.summary, constraints: constraints, rationale: rationale, ordinalInTurn: ord, turnID: tid)
        proposals.append(p)
        if proposals.count > maxProposals { proposals.removeFirst(proposals.count - maxProposals) }
        return p
    }

    public func proposal(id: String) -> Proposal? {
        lock.lock(); defer { lock.unlock() }
        return proposals.first { $0.id == id }
    }

    /// Resolve "do that" / "do the second one" against the most recent
    /// assistant turn that contained proposals.
    public func resolveProposal(ordinal: Int?) -> Proposal? {
        lock.lock(); defer { lock.unlock() }
        guard let lastTurnID = proposals.last?.turnID else { return nil }
        let inTurn = proposals.filter { $0.turnID == lastTurnID }.sorted { $0.ordinalInTurn < $1.ordinalInTurn }
        guard let ordinal else { return inTurn.count == 1 ? inTurn.first : (inTurn.last) }
        if ordinal == -1 { return inTurn.last }
        return inTurn.first { $0.ordinalInTurn == ordinal }
    }

    public func proposalsInLatestTurn() -> [Proposal] {
        lock.lock(); defer { lock.unlock() }
        guard let lastTurnID = proposals.last?.turnID else { return [] }
        return proposals.filter { $0.turnID == lastTurnID }.sorted { $0.ordinalInTurn < $1.ordinalInTurn }
    }

    public func markProposalExecuted(_ id: String, taskID: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = proposals.firstIndex(where: { $0.id == id }) { proposals[i].executedTaskID = taskID }
    }

    /// Pull numbered options ("1. …", "First, …", "Option A: …") out of what the
    /// assistant said, so the user can refer to them even if the model did not
    /// call `propose_change`. Only used when the turn has no tool-registered proposals.
    private func registerProposalsFromTranscript(_ turn: TranscriptTurn) {
        let existing = proposals.filter { $0.turnID == turn.id }
        guard existing.isEmpty else { return }
        let items = Self.extractNumberedItems(turn.text)
        guard items.count >= 2 else { return }
        for (i, item) in items.enumerated() {
            proposals.append(Proposal(summary: item, targetID: currentTarget?.id, targetDescription: currentTarget?.summary, ordinalInTurn: i + 1, turnID: turn.id))
        }
        if proposals.count > maxProposals { proposals.removeFirst(proposals.count - maxProposals) }
    }

    static func extractNumberedItems(_ text: String) -> [String] {
        let pattern = #"(?:(?:^|\s)(?:\d+[\.\)]|[Oo]ption\s+[A-Ca-c1-3][:\.]|[Ff]irst,|[Ss]econd,|[Tt]hird,)\s+)([^\n]+?)(?=(?:\s+(?:\d+[\.\)]|[Oo]ption\s+[A-Ca-c1-3][:\.]|[Ss]econd,|[Tt]hird,)\s)|$)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > 1 else { return nil }
            let s = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
    }

    // MARK: Actions

    public func addAction(_ a: CodeAction) {
        lock.lock(); defer { lock.unlock() }
        actions.append(a)
    }

    public func updateAction(id: String, _ mutate: (inout CodeAction) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let i = actions.firstIndex(where: { $0.id == id }) { mutate(&actions[i]) }
    }

    public func action(id: String) -> CodeAction? {
        lock.lock(); defer { lock.unlock() }
        return actions.first { $0.id == id }
    }

    public func action(agentRunID: String) -> CodeAction? {
        lock.lock(); defer { lock.unlock() }
        return actions.first { $0.agentRunID == agentRunID }
    }

    /// Most recent action that is applied (not undone).
    public var lastAppliedAction: CodeAction? {
        lock.lock(); defer { lock.unlock() }
        return actions.last { !$0.undone && ($0.state == .finished || $0.state == .running) }
    }

    /// Most recent action that was undone (for redo).
    public var lastUndoneAction: CodeAction? {
        lock.lock(); defer { lock.unlock() }
        return actions.last { $0.undone }
    }

    /// Last finished action, whether or not undone — for "keep that but…" follow-ups.
    public var lastFinishedAction: CodeAction? {
        lock.lock(); defer { lock.unlock() }
        return actions.last { $0.state == .finished }
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        transcript.removeAll(); proposals.removeAll(); actions.removeAll(); recentTargets.removeAll(); currentTarget = nil
    }
}

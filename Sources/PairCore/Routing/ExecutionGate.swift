import Foundation

/// The single place that decides whether an action may touch the world.
///
/// The conversational model may *request* execution via a tool call, but the
/// gate independently verifies that the most recent user utterance contained
/// an explicit execution command. Casual discussion never opens the gate.
public final class ExecutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let router = IntentRouter()

    /// How long an execution command stays valid. A "do it" said 90 seconds ago
    /// should not authorize a change proposed just now.
    public var commandValidity: TimeInterval = 45

    private var lastExecutionCommandAt: Date?
    /// "Undo that" / "redo" are explicit imperatives too, but they only
    /// authorize reversal tools — never a fresh edit.
    private var lastReversalCommandAt: Date?
    private var lastUtterance: String = ""
    private var explicitConfirmations: [String: Date] = [:]

    public init() {}

    /// Feed every final user transcript through here.
    public func observeUserUtterance(_ text: String, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        lastUtterance = text
        if router.isExecutionCommand(text) {
            lastExecutionCommandAt = at
        }
        let intent = router.route(text).intent
        if intent == .undo || intent == .redo {
            lastReversalCommandAt = at
        }
    }

    /// Record that the user explicitly confirmed a specific dangerous action.
    public func recordExplicitConfirmation(actionKey: String, at: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        explicitConfirmations[actionKey] = at
    }

    /// Consume the pending execution command so one "do it" authorizes one edit.
    public func consumeExecutionCommand() {
        lock.lock(); defer { lock.unlock() }
        lastExecutionCommandAt = nil
    }

    public var hasPendingExecutionCommand: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = lastExecutionCommandAt else { return false }
        return Date().timeIntervalSince(t) <= commandValidity
    }

    public var hasPendingReversalCommand: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = lastReversalCommandAt else { return false }
        return Date().timeIntervalSince(t) <= commandValidity
    }

    /// - Parameter isReversal: the action undoes/redoes a previous checkpointed
    ///   change; a spoken "undo"/"redo" is sufficient authorization for it.
    public func evaluate(level: PermissionLevel, project: ProjectContext?, actionKey: String? = nil, isReversal: Bool = false, now: Date = Date()) -> PermissionDecision {
        if level.isAutomatic { return .allowed }
        lock.lock(); defer { lock.unlock() }

        if level.allowsConversationalConfirmation {
            if isReversal {
                // Reversal restores a state the user already saw; it does not need a trusted project.
                if let t = lastReversalCommandAt, now.timeIntervalSince(t) <= commandValidity { return .allowed }
            }
            if let project, !project.isTrusted { return .deniedUntrustedProject }
            if project == nil { return .deniedUntrustedProject }
            guard let t = lastExecutionCommandAt, now.timeIntervalSince(t) <= commandValidity else {
                return .deniedNeedsExecutionCommand
            }
            return .allowed
        }

        // Destructive and above: need a fresh, action-specific confirmation.
        if let key = actionKey, let t = explicitConfirmations[key], now.timeIntervalSince(t) <= commandValidity {
            return .allowed
        }
        return .deniedNeedsExplicitConfirmation(level)
    }
}

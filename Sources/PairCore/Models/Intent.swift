import Foundation

/// Constrained set of things an utterance can mean to the system. Produced by
/// the deterministic `IntentRouter` first and refined by the fast-decision
/// provider (Jev) only when the deterministic pass is unsure.
public enum Intent: String, Codable, CaseIterable, Sendable {
    case discuss = "DISCUSS"
    case question = "QUESTION"
    case inspectUI = "INSPECT_UI"
    case inspectCode = "INSPECT_CODE"
    case modifyUI = "MODIFY_UI"
    case modifyCode = "MODIFY_CODE"
    case executePreviousProposal = "EXECUTE_PREVIOUS_PROPOSAL"
    case undo = "UNDO"
    case redo = "REDO"
    case startLocalAgent = "START_LOCAL_AGENT"
    case startCloudAgent = "START_CLOUD_AGENT"
    case checkAgent = "CHECK_AGENT"
    case cancelAgent = "CANCEL_AGENT"
    case compareVariants = "COMPARE_VARIANTS"
    case needsClarification = "NEEDS_CLARIFICATION"
    case noAction = "NO_ACTION"

    /// Intents that will (after gating) cause code to change.
    public var mutatesCode: Bool {
        switch self {
        case .modifyUI, .modifyCode, .executePreviousProposal, .undo, .redo, .startLocalAgent, .startCloudAgent, .compareVariants:
            return true
        default:
            return false
        }
    }
}

/// Result of routing one utterance.
public struct IntentDecision: Codable, Equatable, Sendable {
    public var intent: Intent
    public var confidence: Double
    /// Whether the utterance contains an explicit execution command ("do it").
    public var isExecutionCommand: Bool
    /// Whether the utterance refers to something on screen ("this", "that", "here").
    public var hasDeicticReference: Bool
    /// Whether answering probably requires looking at pixels rather than structure.
    public var needsVisualReasoning: Bool
    /// Which of the model's numbered proposals the user picked, if any (1-based).
    public var proposalOrdinal: Int?
    /// How many undo steps were requested (for "go back two changes").
    public var undoSteps: Int
    /// Which stage produced the decision — useful in the debug panel.
    public var decidedBy: String

    public init(
        intent: Intent,
        confidence: Double,
        isExecutionCommand: Bool = false,
        hasDeicticReference: Bool = false,
        needsVisualReasoning: Bool = false,
        proposalOrdinal: Int? = nil,
        undoSteps: Int = 1,
        decidedBy: String
    ) {
        self.intent = intent
        self.confidence = confidence
        self.isExecutionCommand = isExecutionCommand
        self.hasDeicticReference = hasDeicticReference
        self.needsVisualReasoning = needsVisualReasoning
        self.proposalOrdinal = proposalOrdinal
        self.undoSteps = undoSteps
        self.decidedBy = decidedBy
    }
}

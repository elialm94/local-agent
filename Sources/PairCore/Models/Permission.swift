import Foundation

/// Permission levels for actions the assistant may take. Ordered by risk.
public enum PermissionLevel: Int, Codable, Comparable, Sendable {
    /// Reading screen/accessibility/project state.
    case read = 0
    /// Model analysis with no side effects.
    case analyze = 1
    /// Conversation only.
    case discuss = 2
    /// Reversible edit to the local working tree behind a checkpoint.
    case localReversibleEdit = 3
    /// Anything that cannot be undone by restoring the checkpoint.
    case destructive = 4
    case deployment = 5
    case databaseModification = 6
    case mergeOrPush = 7

    public static func < (lhs: PermissionLevel, rhs: PermissionLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whether the action may proceed with no user confirmation at all.
    public var isAutomatic: Bool { self <= .discuss }

    /// Whether a conversational execution command ("do it") is sufficient.
    public var allowsConversationalConfirmation: Bool { self == .localReversibleEdit }

    /// Whether an explicit, separate confirmation is required.
    public var requiresExplicitConfirmation: Bool { self >= .destructive }
}

public enum PermissionDecision: Equatable, Sendable {
    case allowed
    case deniedNeedsExecutionCommand
    case deniedNeedsExplicitConfirmation(PermissionLevel)
    case deniedUntrustedProject

    public var isAllowed: Bool { self == .allowed }

    /// Text returned to the model so it can tell the user what is needed.
    public var modelMessage: String {
        switch self {
        case .allowed:
            return "allowed"
        case .deniedNeedsExecutionCommand:
            return "Not executed: the user has not given an explicit execution command yet (for example \"do it\", \"try it\", \"build it\"). Confirm the plan and ask them to say so."
        case .deniedNeedsExplicitConfirmation(let level):
            return "Not executed: this action is classified as \(level) and requires the user's explicit, separate confirmation. Describe exactly what will happen and ask for confirmation."
        case .deniedUntrustedProject:
            return "Not executed: the system is not confident which local project the visible app belongs to. Ask the user to select the project."
        }
    }
}

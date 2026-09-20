import Foundation

/// Every tool the conversational model may invoke. Definitions are
/// provider-independent; `ToolExecutor` binds them to system actions.
public enum ToolName: String, CaseIterable, Sendable {
    case getCurrentContext = "get_current_context"
    case inspectTarget = "inspect_target"
    case captureTarget = "capture_target"
    case captureRegion = "capture_region"
    case getRecentInteraction = "get_recent_interaction"
    case getProjectContext = "get_project_context"
    case resolveSourceComponent = "resolve_source_component"
    case proposeChange = "propose_change"
    case executeChange = "execute_change"
    case startCursorLocalAgent = "start_cursor_local_agent"
    case startCursorCloudAgent = "start_cursor_cloud_agent"
    case getAgentStatus = "get_agent_status"
    case cancelAgent = "cancel_agent"
    case showAgentDiff = "show_agent_diff"
    case acceptAgentResult = "accept_agent_result"
    case undoLastChange = "undo_last_change"
    case redoChange = "redo_change"
    case createCheckpoint = "create_checkpoint"
    case compareVariants = "compare_variants"
}

public enum ToolCatalog {
    public static let all: [ToolDefinition] = [
        ToolDefinition(
            name: ToolName.getCurrentContext.rawValue,
            description: "Get compact structured context: what app/window the user is looking at, what they are pointing at, the current project, and any running agents. Prefer this over asking the user what they mean.",
            parameters: Schema.object([:]),
            permission: .read
        ),
        ToolDefinition(
            name: ToolName.inspectTarget.rawValue,
            description: "Get full structured accessibility details for the current (or a specific) target element, including its DOM id/classes and ancestor path.",
            parameters: Schema.object(["target_id": Schema.string("Target id from context; omit for the current target.")]),
            permission: .read
        ),
        ToolDefinition(
            name: ToolName.captureTarget.rawValue,
            description: "Capture a small screenshot crop of the current target element for visual reasoning (colors, alignment, clutter). Only use when structured context is insufficient.",
            parameters: Schema.object(["target_id": Schema.string("Target id from context; omit for the current target."), "padding": Schema.integer("Extra pixels around the element (default 24).")]),
            permission: .read
        ),
        ToolDefinition(
            name: ToolName.captureRegion.rawValue,
            description: "Capture a screenshot of the region the user selected by dragging, or of the active window if no region is selected.",
            parameters: Schema.object([:]),
            permission: .read
        ),
        ToolDefinition(
            name: ToolName.getRecentInteraction.rawValue,
            description: "Get the last ~20 seconds of local interaction history: clicks, what was clicked, window changes. Use for 'why did that move' / 'what happened when I clicked'.",
            parameters: Schema.object([:]),
            permission: .read
        ),
        ToolDefinition(
            name: ToolName.getProjectContext.rawValue,
            description: "Get the detected local project (name, root path, branch, dev server) and detection confidence.",
            parameters: Schema.object([:]),
            permission: .read
        ),
        ToolDefinition(
            name: ToolName.resolveSourceComponent.rawValue,
            description: "Try to map the current target UI element to its source component/file in the project.",
            parameters: Schema.object(["target_id": Schema.string("Target id; omit for the current target.")]),
            permission: .analyze
        ),
        ToolDefinition(
            name: ToolName.proposeChange.rawValue,
            description: "Register a concrete change you are suggesting so the user can later say 'do that' or 'do the second one'. Call once per distinct option, in the order you speak them. Does NOT modify anything.",
            parameters: Schema.object([
                "summary": Schema.string("One precise sentence describing the change, e.g. 'Reduce the vertical padding of the Send Offer button from 16px to 10px, keeping its width.'"),
                "rationale": Schema.string("Why this helps (one sentence)."),
                "constraints": Schema.stringArray("Things that must not change."),
            ], required: ["summary"]),
            permission: .discuss
        ),
        ToolDefinition(
            name: ToolName.executeChange.rawValue,
            description: "Execute the agreed change with the coding agent. ONLY call this after the user gives an explicit go-ahead such as 'do it', 'try it', 'build it', 'go ahead'. Never call it during discussion. Pass either proposal_id/proposal_ordinal for a registered proposal or a precise requested_change.",
            parameters: Schema.object([
                "requested_change": Schema.string("Precise description of the change to implement (what, where, preserving what)."),
                "proposal_id": Schema.string("Id returned by propose_change."),
                "proposal_ordinal": Schema.integer("1-based index of the proposal in your last list, if the user said 'the second one'."),
                "context": Schema.string("Why the user wants this — one sentence."),
                "constraints": Schema.stringArray("Additional constraints."),
                "is_follow_up": Schema.boolean("True if this refines the previous change ('keep that but…')."),
                "prefer_cloud": Schema.boolean("True for large/background tasks that should run as a cloud agent."),
            ]),
            permission: .localReversibleEdit
        ),
        ToolDefinition(
            name: ToolName.startCursorLocalAgent.rawValue,
            description: "Lower-level: start a local Cursor agent with an explicit task. Prefer execute_change. Requires explicit user go-ahead.",
            parameters: Schema.object(["task": Schema.string("Full task description.")], required: ["task"]),
            permission: .localReversibleEdit
        ),
        ToolDefinition(
            name: ToolName.startCursorCloudAgent.rawValue,
            description: "Start a Cursor cloud agent for a larger background task. Requires explicit user go-ahead. Not for tiny UI tweaks.",
            parameters: Schema.object(["task": Schema.string("Full task description.")], required: ["task"]),
            permission: .localReversibleEdit
        ),
        ToolDefinition(
            name: ToolName.getAgentStatus.rawValue,
            description: "Check the status of a running or recent coding agent.",
            parameters: Schema.object(["agent_id": Schema.string("Agent run id; omit for the most recent.")]),
            permission: .read
        ),
        ToolDefinition(
            name: ToolName.cancelAgent.rawValue,
            description: "Cancel a running coding agent.",
            parameters: Schema.object(["agent_id": Schema.string("Agent run id; omit for the most recent.")]),
            permission: .discuss
        ),
        ToolDefinition(
            name: ToolName.showAgentDiff.rawValue,
            description: "List the files changed by a coding agent run.",
            parameters: Schema.object(["agent_id": Schema.string("Agent run id; omit for the most recent.")]),
            permission: .read
        ),
        ToolDefinition(
            name: ToolName.acceptAgentResult.rawValue,
            description: "Mark the most recent change as accepted (keeps it; clears redo state).",
            parameters: Schema.object(["agent_id": Schema.string("Agent run id; omit for the most recent.")]),
            permission: .discuss
        ),
        ToolDefinition(
            name: ToolName.undoLastChange.rawValue,
            description: "Revert the most recent coding change(s) by restoring the checkpoint taken before the agent ran. Use when the user says 'undo', 'revert', 'go back', 'that's worse'.",
            parameters: Schema.object(["steps": Schema.integer("How many changes to undo (default 1).")]),
            permission: .localReversibleEdit
        ),
        ToolDefinition(
            name: ToolName.redoChange.rawValue,
            description: "Re-apply the most recently undone change.",
            parameters: Schema.object([:]),
            permission: .localReversibleEdit
        ),
        ToolDefinition(
            name: ToolName.createCheckpoint.rawValue,
            description: "Snapshot the working tree so the user can return to this exact state later.",
            parameters: Schema.object(["label": Schema.string("Short label.")]),
            permission: .discuss
        ),
        ToolDefinition(
            name: ToolName.compareVariants.rawValue,
            description: "Build two alternative implementations (A and B) so the user can compare them. Requires explicit go-ahead. V1: runs them sequentially as separate undoable changes.",
            parameters: Schema.object([
                "variant_a": Schema.string("Precise description of variant A."),
                "variant_b": Schema.string("Precise description of variant B."),
            ], required: ["variant_a", "variant_b"]),
            permission: .localReversibleEdit
        ),
    ]

    public static func definition(_ name: ToolName) -> ToolDefinition {
        all.first { $0.name == name.rawValue }!
    }

    public static func permission(for name: String) -> PermissionLevel? {
        all.first { $0.name == name }?.permission
    }
}

/// What a tool returns to the model. Always JSON; `spoken` is an optional hint
/// for how to describe the result briefly.
public struct ToolResult: Sendable {
    public var ok: Bool
    public var payload: JSONValue
    public var spoken: String?

    public init(ok: Bool, payload: JSONValue, spoken: String? = nil) {
        self.ok = ok
        self.payload = payload
        self.spoken = spoken
    }

    public static func success(_ obj: [String: JSONValue], spoken: String? = nil) -> ToolResult {
        var o = obj
        o["ok"] = .bool(true)
        return ToolResult(ok: true, payload: .object(o), spoken: spoken)
    }

    public static func failure(_ message: String, extra: [String: JSONValue] = [:]) -> ToolResult {
        var o = extra
        o["ok"] = .bool(false)
        o["error"] = .string(message)
        return ToolResult(ok: false, payload: .object(o), spoken: nil)
    }

    public var json: String { (try? payload.toString()) ?? "{\"ok\":false,\"error\":\"unserializable\"}" }
}

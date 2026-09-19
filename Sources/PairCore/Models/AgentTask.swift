import Foundation

public enum AgentExecutionTarget: String, Codable, Sendable {
    case local
    case cloud
}

/// The precise, compiled coding task handed to a coding agent. This is what
/// `TaskCompiler` produces from the conversation; the conversation itself is
/// never forwarded.
public struct AgentTask: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var createdAt: Date
    public var projectName: String
    public var projectRoot: String
    public var branch: String?
    /// Short imperative title, e.g. "Make Send Offer button red".
    public var title: String
    /// Human-facing description of the UI element (role + label).
    public var targetDescription: String?
    public var target: AttentionTarget?
    public var sourceReference: SourceReference?
    /// The change to make, phrased as a precise instruction.
    public var requestedChange: String
    /// Why the user wants it — helps the agent make good judgment calls.
    public var context: String?
    public var constraints: [String]
    public var verification: [String]
    public var executionTarget: AgentExecutionTarget
    /// Link to the conversation-side proposal this task implements, if any.
    public var proposalID: String?
    /// For follow-up edits, the agent session to resume so it keeps its own context.
    public var resumeSessionID: String?

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        projectName: String,
        projectRoot: String,
        branch: String? = nil,
        title: String,
        targetDescription: String? = nil,
        target: AttentionTarget? = nil,
        sourceReference: SourceReference? = nil,
        requestedChange: String,
        context: String? = nil,
        constraints: [String] = [],
        verification: [String] = [],
        executionTarget: AgentExecutionTarget = .local,
        proposalID: String? = nil,
        resumeSessionID: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.projectName = projectName
        self.projectRoot = projectRoot
        self.branch = branch
        self.title = title
        self.targetDescription = targetDescription
        self.target = target
        self.sourceReference = sourceReference
        self.requestedChange = requestedChange
        self.context = context
        self.constraints = constraints
        self.verification = verification
        self.executionTarget = executionTarget
        self.proposalID = proposalID
        self.resumeSessionID = resumeSessionID
    }

    /// Render the task as the prompt given to the coding agent.
    public func renderPrompt() -> String {
        var lines: [String] = []
        lines.append("Project: \(projectName)")
        if let branch { lines.append("Branch: \(branch)") }
        lines.append("")
        if let targetDescription {
            lines.append("Target:")
            lines.append(targetDescription)
            lines.append("")
        }
        if let src = sourceReference, src.file != nil || src.component != nil {
            lines.append("Source:")
            var s = ""
            if let f = src.file { s = f }
            if let l = src.line { s += ":\(l)" }
            if let c = src.component { s += s.isEmpty ? c : "  (component \(c))" }
            lines.append(s)
            if src.confidence < 0.8 {
                lines.append("(source mapping confidence \(Int(src.confidence * 100))% — verify before editing)")
            }
            lines.append("")
        } else if let t = target {
            lines.append("Source:")
            lines.append("Unknown. Locate the component that renders the \(t.role.lowercased()) labelled \"\(t.label)\"" +
                         (t.accessibility.domIdentifier.map { " (DOM id \"\($0)\")" } ?? "") +
                         (t.accessibility.domClassList.isEmpty ? "" : " (classes: \(t.accessibility.domClassList.prefix(5).joined(separator: " ")))") +
                         " by searching the codebase for its text and attributes before editing.")
            lines.append("")
        }
        lines.append("Requested change:")
        lines.append(requestedChange)
        lines.append("")
        if let context, !context.isEmpty {
            lines.append("Context:")
            lines.append(context)
            lines.append("")
        }
        if !constraints.isEmpty {
            lines.append("Constraints:")
            for c in constraints { lines.append("- \(c)") }
            lines.append("")
        }
        if !verification.isEmpty {
            lines.append("Verification:")
            for v in verification { lines.append("- \(v)") }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

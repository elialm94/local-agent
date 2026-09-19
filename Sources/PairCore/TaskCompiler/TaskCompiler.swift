import Foundation

/// What the conversation layer asks the system to execute. Comes from the
/// `execute_change` tool call (Grok) or from the deterministic path
/// ("do the second one" → a stored proposal).
public struct ExecutionRequest: Codable, Sendable {
    public var requestedChange: String?
    public var proposalID: String?
    public var proposalOrdinal: Int?
    public var context: String?
    public var constraints: [String]
    public var targetID: String?
    /// True when the user is refining the previous change ("keep that but reduce the padding").
    public var isFollowUp: Bool
    public var preferCloud: Bool

    public init(
        requestedChange: String? = nil,
        proposalID: String? = nil,
        proposalOrdinal: Int? = nil,
        context: String? = nil,
        constraints: [String] = [],
        targetID: String? = nil,
        isFollowUp: Bool = false,
        preferCloud: Bool = false
    ) {
        self.requestedChange = requestedChange
        self.proposalID = proposalID
        self.proposalOrdinal = proposalOrdinal
        self.context = context
        self.constraints = constraints
        self.targetID = targetID
        self.isFollowUp = isFollowUp
        self.preferCloud = preferCloud
    }
}

public enum TaskCompilerError: Error, Equatable, LocalizedError {
    case noProject
    case untrustedProject(String)
    case nothingToExecute
    case proposalNotFound

    public var errorDescription: String? {
        switch self {
        case .noProject: return "No local project is associated with the visible application."
        case .untrustedProject(let n): return "Not confident that the visible app belongs to project \(n); please confirm the project."
        case .nothingToExecute: return "There is no agreed change to execute yet."
        case .proposalNotFound: return "Could not find the proposal the user referred to."
        }
    }
}

/// Compiles the *agreed* change into a precise `AgentTask`. Never forwards the
/// raw conversation.
public struct TaskCompiler: Sendable {
    public var defaultConstraints: [String] = [
        "Make the smallest change that achieves the request; do not refactor unrelated code.",
        "Do not alter other components, files, or behavior beyond what the request needs.",
        "Preserve existing design-system conventions, tokens, and code style.",
        "Do not run git commands (no commit, stash, checkout, reset) and do not touch files outside the project.",
        "Do not modify environment files, secrets, lockfiles, or dependencies.",
    ]
    public var defaultVerification: [String] = [
        "Run the project's type-check or lint for the touched files if a fast command exists.",
        "Confirm the component still renders and the dev server hot-reloads without errors.",
        "Finish with a one-sentence summary of exactly what changed and which files.",
    ]

    public init() {}

    public func compile(
        request: ExecutionRequest,
        memory: SessionMemory,
        target explicitTarget: AttentionTarget?,
        project: ProjectContext?,
        sourceReference: SourceReference? = nil
    ) throws -> AgentTask {
        guard let project else { throw TaskCompilerError.noProject }
        guard project.isTrusted else { throw TaskCompilerError.untrustedProject(project.name) }

        var proposal: Proposal?
        if let id = request.proposalID {
            proposal = memory.proposal(id: id)
            if proposal == nil { throw TaskCompilerError.proposalNotFound }
        } else if request.requestedChange == nil || request.proposalOrdinal != nil {
            proposal = memory.resolveProposal(ordinal: request.proposalOrdinal)
        }

        let change = (request.requestedChange?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? proposal?.summary
        guard let requestedChange = change else { throw TaskCompilerError.nothingToExecute }

        let target = explicitTarget
            ?? request.targetID.flatMap { memory.target(id: $0) }
            ?? proposal?.targetID.flatMap { memory.target(id: $0) }
            ?? memory.currentTarget

        var constraints = defaultConstraints
        constraints.append(contentsOf: (proposal?.constraints ?? []) + request.constraints)
        if let t = target {
            constraints.insert("Only change the \(t.role.lowercased()) labelled \"\(t.label)\" (and its own styles); leave sibling elements untouched.", at: 0)
        }

        var context = request.context ?? proposal?.rationale
        let previous = memory.lastFinishedAction
        if request.isFollowUp, let previous {
            let prior = "This refines your previous change (\(previous.task.title)); keep it and adjust as requested."
            context = [prior, context].compactMap { $0 }.joined(separator: " ")
        }

        let follow = request.isFollowUp ? previous : nil
        let resolvedSource = sourceReference ?? target?.sourceReference

        return AgentTask(
            projectName: project.name,
            projectRoot: project.rootPath,
            branch: project.branch,
            title: Self.title(from: requestedChange, target: target),
            targetDescription: target.map { describe($0) },
            target: target,
            sourceReference: resolvedSource,
            requestedChange: requestedChange,
            context: context,
            constraints: dedupe(constraints),
            verification: defaultVerification,
            executionTarget: request.preferCloud ? .cloud : .local,
            proposalID: proposal?.id,
            resumeSessionID: follow?.agentSessionID
        )
    }

    func describe(_ t: AttentionTarget) -> String {
        var parts: [String] = ["\(t.role) labelled \"\(t.label)\""]
        if let w = t.window, !w.isEmpty { parts.append("in window \"\(w)\"") }
        parts.append("(app: \(t.application))")
        if let v = t.accessibility.value, !v.isEmpty, v != t.label { parts.append("current value: \"\(String(v.prefix(80)))\"") }
        if let dom = t.accessibility.domIdentifier { parts.append("DOM id: \(dom)") }
        if !t.accessibility.domClassList.isEmpty { parts.append("classes: \(t.accessibility.domClassList.prefix(6).joined(separator: " "))") }
        if !t.accessibility.ancestorPath.isEmpty { parts.append("path: \(t.accessibility.ancestorPath.prefix(5).joined(separator: " > "))") }
        parts.append("bounds: \(Int(t.bounds.width))×\(Int(t.bounds.height))")
        return parts.joined(separator: "; ")
    }

    static func title(from change: String, target: AttentionTarget?) -> String {
        var s = change.split(whereSeparator: { $0 == "." || $0 == "\n" }).first.map(String.init) ?? change
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = target, !t.label.isEmpty {
            // Replace deictic words with the actual label for a readable title.
            for w in ["this button", "this element", "this thing", "this one", "this"] where s.lowercased().contains(w) {
                if let r = s.range(of: w, options: .caseInsensitive) {
                    s.replaceSubrange(r, with: "the \"\(t.label)\" \(t.role.lowercased())")
                    break
                }
            }
        }
        if s.count > 90 { s = String(s.prefix(87)) + "…" }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    func dedupe(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0).inserted }
    }
}

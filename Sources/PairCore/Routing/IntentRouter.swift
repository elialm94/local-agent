import Foundation

/// Deterministic, zero-latency first pass over an utterance. It is intentionally
/// conservative: it only claims high confidence for phrases that are
/// unambiguous ("do it", "undo that"). Everything else is handed to the
/// fast-decision provider (Jev) or simply treated as conversation for Grok.
public struct IntentRouter: Sendable {
    public init() {}

    // Phrases that constitute explicit permission to execute a reversible edit.
    static let executionPhrases: [String] = [
        "do it", "do that", "do this", "do the", "do both", "do all",
        "try it", "try that", "try this", "try the",
        "build it", "build that", "build this",
        "make it so", "make the change", "make that change", "make those changes",
        "change it", "apply it", "apply that", "apply the",
        "go ahead", "go for it", "ship it", "let's do it", "lets do it",
        "implement it", "implement that", "implement the", "implement this",
        "yes do it", "yeah do it", "ok do it", "okay do it", "please do it",
        "just do it", "just do that", "do the first", "do the second", "do the third",
        "do number", "do option", "execute", "run it", "run that",
    ]

    static let undoPhrases: [String] = ["undo", "revert", "go back", "roll back", "rollback", "put it back", "restore"]
    static let redoPhrases: [String] = ["redo", "bring it back", "re-apply", "reapply", "do it again"]
    static let cancelPhrases: [String] = ["cancel", "stop the agent", "stop that", "abort", "never mind the change"]
    static let checkAgentPhrases: [String] = ["is it done", "are you done", "how's it going", "hows it going", "status", "still working", "did it finish", "is it finished"]
    static let comparePhrases: [String] = ["show me both", "both versions", "try both", "a/b", "compare", "two versions", "the other version", "other variant"]

    static let deicticWords: Set<String> = ["this", "that", "these", "those", "here", "there", "it"]
    static let visualWords: [String] = ["look", "looks", "cluttered", "premium", "ugly", "alignment", "aligned", "spacing", "flicker", "color", "colour", "feel", "feels", "design", "visual", "layout", "busy", "crowded", "polish"]
    static let questionStarters: [String] = ["what", "why", "how", "where", "which", "who", "is ", "are ", "does ", "do ", "can ", "could ", "should ", "would ", "did "]
    static let modifyVerbs: [String] = ["make", "move", "change", "set", "reduce", "increase", "remove", "delete", "add", "put", "shrink", "grow", "align", "center", "centre", "hide", "show", "rename", "swap", "replace", "turn", "resize", "widen", "narrow", "tighten", "loosen", "darken", "lighten", "bold", "fix"]
    static let codeWords: [String] = ["function", "variable", "error", "exception", "stack", "trace", "bug", "crash", "log", "console", "type", "compile", "test", "import", "module", "api", "endpoint", "state", "prop", "hook", "class"]

    static let ordinals: [(String, Int)] = [
        ("first", 1), ("1st", 1), ("one", 1), ("number one", 1), ("option one", 1), ("option 1", 1), ("number 1", 1),
        ("second", 2), ("2nd", 2), ("two", 2), ("number two", 2), ("option two", 2), ("option 2", 2), ("number 2", 2),
        ("third", 3), ("3rd", 3), ("three", 3), ("number three", 3), ("option three", 3), ("option 3", 3), ("number 3", 3),
        ("fourth", 4), ("4th", 4), ("last", -1), ("latter", -1), ("former", 1),
    ]

    public func route(_ utterance: String) -> IntentDecision {
        let text = normalize(utterance)
        let words = text.split(separator: " ").map(String.init)
        let wordSet = Set(words)
        let deictic = !wordSet.isDisjoint(with: Self.deicticWords)
        let visual = Self.visualWords.contains { text.contains($0) }
        let ordinal = Self.ordinal(in: text)

        if let steps = undoSteps(in: text) {
            return IntentDecision(intent: .undo, confidence: 0.95, hasDeicticReference: deictic, undoSteps: steps, decidedBy: "router:undo")
        }
        if Self.redoPhrases.contains(where: { text.contains($0) }) {
            return IntentDecision(intent: .redo, confidence: 0.9, hasDeicticReference: deictic, decidedBy: "router:redo")
        }
        if Self.cancelPhrases.contains(where: { text.contains($0) }) {
            return IntentDecision(intent: .cancelAgent, confidence: 0.85, decidedBy: "router:cancel")
        }
        if Self.checkAgentPhrases.contains(where: { text.contains($0) }) {
            return IntentDecision(intent: .checkAgent, confidence: 0.8, decidedBy: "router:check")
        }
        if Self.comparePhrases.contains(where: { text.contains($0) }) {
            let exec = isExecutionCommand(text)
            return IntentDecision(intent: .compareVariants, confidence: 0.75, isExecutionCommand: exec, hasDeicticReference: deictic, decidedBy: "router:compare")
        }
        if isExecutionCommand(text) {
            // Short utterances that are mostly the execution phrase refer to a previous proposal.
            let isBare = words.count <= 6 || ordinal != nil
            return IntentDecision(
                intent: isBare ? .executePreviousProposal : .modifyUI,
                confidence: isBare ? 0.95 : 0.7,
                isExecutionCommand: true,
                hasDeicticReference: deictic,
                needsVisualReasoning: false,
                proposalOrdinal: ordinal,
                decidedBy: "router:execute"
            )
        }
        if Self.questionStarters.contains(where: { text.hasPrefix($0) }) || text.hasSuffix("?") {
            let code = Self.codeWords.contains { wordSet.contains($0) }
            return IntentDecision(
                intent: code ? .inspectCode : (deictic || visual ? .inspectUI : .question),
                confidence: 0.6,
                hasDeicticReference: deictic,
                needsVisualReasoning: visual,
                decidedBy: "router:question"
            )
        }
        if let first = words.first, Self.modifyVerbs.contains(first) || Self.modifyVerbs.contains(where: { text.hasPrefix("please \($0)") || text.hasPrefix("can you \($0)") || text.hasPrefix("could you \($0)") }) {
            let code = Self.codeWords.contains { wordSet.contains($0) }
            return IntentDecision(
                intent: code ? .modifyCode : .modifyUI,
                confidence: 0.6,
                isExecutionCommand: false,
                hasDeicticReference: deictic,
                needsVisualReasoning: visual,
                decidedBy: "router:modify"
            )
        }
        if text.isEmpty {
            return IntentDecision(intent: .noAction, confidence: 1, decidedBy: "router:empty")
        }
        // Default: it's conversation. Low confidence so Jev may refine.
        return IntentDecision(intent: .discuss, confidence: 0.4, hasDeicticReference: deictic, needsVisualReasoning: visual, decidedBy: "router:default")
    }

    /// True when the utterance contains an explicit go-ahead. Negations
    /// ("don't do it", "not yet") suppress it.
    public func isExecutionCommand(_ utterance: String) -> Bool {
        let text = normalize(utterance)
        let negations = ["don't", "dont", "do not", "not yet", "wait", "hold on", "before you", "should i", "should we", "would you", "what if", "if you", "if we"]
        if negations.contains(where: { text.contains($0) }) { return false }
        return Self.executionPhrases.contains { phrase in
            text == phrase || text.hasPrefix(phrase + " ") || text.hasSuffix(" " + phrase) || text.contains(" " + phrase + " ") || text.contains(" " + phrase + ",")
        }
    }

    /// Returns the number of undo steps requested, or nil if this is not an undo.
    func undoSteps(in text: String) -> Int? {
        guard Self.undoPhrases.contains(where: { text.contains($0) }) else { return nil }
        if text.contains("redo") { return nil }
        // "go back two changes", "undo the last 3"
        let numberWords: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5]
        for (w, n) in numberWords where text.contains(" \(w) change") || text.contains(" \(w) step") || text.contains("last \(w)") || text.contains("back \(w)") {
            return n
        }
        if text.contains("everything") || text.contains("all of it") || text.contains("all changes") { return Int.max }
        return 1
    }

    static func ordinal(in text: String) -> Int? {
        // Longest match first so "number two" beats "two".
        for (word, n) in ordinals.sorted(by: { $0.0.count > $1.0.count }) {
            if text.contains(" \(word)") || text.hasPrefix(word) { return n }
        }
        return nil
    }

    func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: "’", with: "'")
        t = t.replacingOccurrences(of: #"[^a-z0-9'?/ \-]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
}

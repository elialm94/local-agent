import Foundation

/// The fast decision layer. Wraps a `FastDecisionProvider` (Jev) behind the
/// small set of structured questions the system actually needs, and only asks
/// them when deterministic logic was not confident.
public final class ReflexLayer: @unchecked Sendable {
    public let provider: FastDecisionProvider
    /// Router confidence at or above this skips the model entirely.
    public var deterministicConfidenceThreshold = 0.75
    /// Model answers below this confidence are treated as "unsure".
    public var minimumModelConfidence = 0.55

    public init(provider: FastDecisionProvider) {
        self.provider = provider
    }

    // MARK: Intent refinement

    static let intentOptions: [String: String] = [
        Intent.discuss.rawValue: "Casual discussion, opinion, or brainstorming; no action requested",
        Intent.question.rawValue: "A general question not about a specific on-screen element",
        Intent.inspectUI.rawValue: "A question about a specific visible UI element or its look/behavior",
        Intent.inspectCode.rawValue: "A question about code, errors, logs, or program behavior",
        Intent.modifyUI.rawValue: "Describes a desired visual/UI change but does not yet say to execute it",
        Intent.modifyCode.rawValue: "Describes a desired code/logic change but does not yet say to execute it",
        Intent.executePreviousProposal.rawValue: "Tells the assistant to go ahead with a previously discussed change (do it, try that, build it)",
        Intent.undo.rawValue: "Asks to revert or undo a recent change",
        Intent.redo.rawValue: "Asks to re-apply an undone change",
        Intent.checkAgent.rawValue: "Asks whether a running task is finished",
        Intent.cancelAgent.rawValue: "Asks to stop or cancel a running task",
        Intent.compareVariants.rawValue: "Asks to build or see multiple alternative versions",
        Intent.needsClarification.rawValue: "Too ambiguous to act on without asking",
        Intent.noAction.rawValue: "Not addressed to the assistant / noise",
    ]

    /// Ask the model to refine a low-confidence routing decision. Returns the
    /// original decision unchanged when the router was already confident or the
    /// provider is unavailable.
    public func refine(_ decision: IntentDecision, utterance: String, target: AttentionTarget?, recentAssistantText: String?) async -> IntentDecision {
        guard provider.isAvailable, decision.confidence < deterministicConfidenceThreshold else { return decision }

        var state: [String: JSONValue] = ["utterance": .string(utterance)]
        if let t = target { state["pointing_at"] = .string(t.summary) }
        if let r = recentAssistantText { state["assistant_just_said"] = .string(String(r.prefix(600))) }

        let request = DecisionRequest(state: .object(state), questions: [
            "intent": .choice(instructions: "What is the user in `utterance` doing?", options: Self.intentOptions),
            "execute": .noul(instructions: "Does `utterance` explicitly tell the assistant to go ahead and make a change now (e.g. do it, try it, build it, go ahead)?"),
            "visual": .noul(instructions: "Would answering `utterance` well require actually seeing the pixels (colors, alignment, clutter) rather than just the element's name and role?"),
            "deictic": .noul(instructions: "Does `utterance` refer to something on screen with words like this, that, here, these?"),
            "clarify": .noul(instructions: "Is `utterance` too ambiguous to act on without asking the user a question first?"),
        ])

        do {
            let r = try await provider.decide(request)
            var refined = decision
            if let intentAnswer = r.answers["intent"], case .choice(let choice, _, let conf) = intentAnswer, conf >= minimumModelConfidence, let intent = Intent(rawValue: choice) {
                refined.intent = intent
                refined.confidence = conf
            }
            if let p = r.answers["execute"]?.yesProbability { refined.isExecutionCommand = decision.isExecutionCommand || p > 0.85 }
            if let p = r.answers["visual"]?.yesProbability { refined.needsVisualReasoning = p > 0.6 }
            if let p = r.answers["deictic"]?.yesProbability { refined.hasDeicticReference = refined.hasDeicticReference || p > 0.6 }
            if let p = r.answers["clarify"]?.yesProbability, p > 0.75 { refined.intent = .needsClarification }
            refined.decidedBy = "\(decision.decidedBy)+\(provider.name)"
            return refined
        } catch {
            Log.warn("reflex", "refine failed; keeping deterministic decision", ["error": error.localizedDescription])
            return decision
        }
    }

    // MARK: Target disambiguation

    /// Pick which candidate the user most likely means. Returns nil when unsure.
    public func pickTarget(utterance: String, candidates: [AttentionTarget]) async -> (AttentionTarget, Double)? {
        guard provider.isAvailable, candidates.count >= 2 else { return nil }
        let limited = Array(candidates.prefix(6))
        var options: [String: String] = [:]
        for (i, c) in limited.enumerated() {
            options["c\(i)"] = "\(c.summary) — \(Int(c.bounds.width))×\(Int(c.bounds.height)) via \(c.source.rawValue)"
        }
        options["none"] = "None of these"
        let request = DecisionRequest(state: .object(["utterance": .string(utterance)]), questions: [
            "target": .choice(instructions: "Which on-screen element is the user in `utterance` most likely referring to?", options: options),
        ])
        do {
            let r = try await provider.decide(request)
            guard case .choice(let choice, _, let conf)? = r.answers["target"], choice != "none", conf >= minimumModelConfidence else { return nil }
            guard let idx = Int(choice.dropFirst()), idx < limited.count else { return nil }
            return (limited[idx], conf)
        } catch {
            Log.warn("reflex", "pickTarget failed", ["error": error.localizedDescription])
            return nil
        }
    }

    // MARK: Task sizing

    /// Should this change run as a small local edit or a larger background task?
    public func prefersCloud(requestedChange: String) async -> Bool {
        guard provider.isAvailable else { return false }
        let request = DecisionRequest(state: .string(requestedChange), questions: [
            "size": .score(instructions: "How large is the coding change described?", levels: [
                "Single-component tweak: styling, copy, spacing, a small conditional",
                "Multi-file feature work confined to one area",
                "Cross-cutting change: new pages, data model, migrations, refactors across many files",
            ]),
        ])
        guard let r = try? await provider.decide(request), case .score(let s, _, let conf)? = r.answers["size"] else { return false }
        return s >= 1.6 && conf >= minimumModelConfidence
    }
}

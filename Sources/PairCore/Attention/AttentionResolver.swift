import Foundation

/// Output of a resolution pass. `chosen` is nil when no candidate is good
/// enough or two candidates are too close to call.
public struct AttentionResolution: Sendable {
    public var candidates: [AttentionTarget]
    public var chosen: AttentionTarget?
    public var needsClarification: Bool
    public var reason: String

    public init(candidates: [AttentionTarget], chosen: AttentionTarget?, needsClarification: Bool, reason: String) {
        self.candidates = candidates
        self.chosen = chosen
        self.needsClarification = needsClarification
        self.reason = reason
    }
}

/// Ranks candidate targets from the world state using cheap, deterministic
/// rules. Structured (accessibility / dev-bridge) information always beats
/// visual guesses. The fast-decision provider is only consulted by the caller
/// when this resolver reports `needsClarification`.
public struct AttentionResolver: Sendable {
    public var explicitValidity: TimeInterval = 30
    public var recentClickValidity: TimeInterval = 12
    public var minimumConfidence: Double = 0.45
    /// If the top two candidates are within this margin, ask instead of guessing.
    public var ambiguityMargin: Double = 0.08

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuItem", "AXSlider", "AXTab", "AXComboBox", "AXImage", "AXStaticText", "AXCell", "AXRow",
        "button", "link", "input", "textarea", "select", "img", "a", "h1", "h2", "h3", "label", "li", "td",
    ]
    static let containerRoles: Set<String> = [
        "AXWindow", "AXWebArea", "AXGroup", "AXScrollArea", "AXApplication", "AXSplitGroup", "AXLayoutArea",
        "div", "section", "main", "body", "html", "article", "nav",
    ]

    public init() {}

    public func resolve(world: WorldState, decision: IntentDecision?, now: Date = Date()) -> AttentionResolution {
        var scored: [(AttentionTarget, Double)] = []

        if let sel = world.selectedElement, now.timeIntervalSince(sel.observedAt) <= explicitValidity {
            var t = sel
            t.source = sel.source == .devBridge ? .devBridge : .explicitClick
            scored.append((t, sel.source == .explicitRegion ? 0.9 : 0.95))
        }

        if let region = world.selectedRegion, !region.isEmpty {
            let t = AttentionTarget(
                role: "Region",
                label: "selected screen region",
                bounds: region,
                application: world.activeApplication?.name ?? "",
                applicationBundleID: world.activeApplication?.bundleID,
                window: world.activeWindow?.title,
                confidence: 0.9,
                source: .explicitRegion
            )
            scored.append((t, 0.9))
        }

        if let hovered = world.hoveredElement {
            scored.append((hovered, hoverScore(hovered, world: world, now: now)))
        }

        if let click = world.lastClick, let target = click.target, now.timeIntervalSince(click.at) <= recentClickValidity {
            var t = target
            t.source = .recentInteraction
            var s = 0.5 + max(0, (recentClickValidity - now.timeIntervalSince(click.at)) / recentClickValidity) * 0.2
            if t.bounds.contains(world.cursorPosition) { s += 0.1 }
            scored.append((t, s))
        }

        // Non-deictic utterances ("why is the build failing?") usually don't need a target.
        if let decision, !decision.hasDeicticReference, decision.intent == .question || decision.intent == .inspectCode || decision.intent == .discuss {
            scored = scored.map { ($0.0, $0.1 * 0.8) }
        }

        let merged = merge(scored).sorted { $0.1 > $1.1 }
        let candidates = merged.map { t, s in
            var c = t
            c.confidence = min(1, max(0, s))
            return c
        }

        guard let top = candidates.first else {
            return AttentionResolution(candidates: [], chosen: nil, needsClarification: decision?.hasDeicticReference ?? false, reason: "no candidates")
        }
        if top.confidence < minimumConfidence {
            return AttentionResolution(candidates: candidates, chosen: nil, needsClarification: true, reason: "top confidence \(fmt(top.confidence)) below minimum")
        }
        if candidates.count > 1 {
            let second = candidates[1]
            let sameThing = second.bounds.overlapFraction(with: top.bounds) > 0.9 && top.bounds.overlapFraction(with: second.bounds) > 0.9
            if !sameThing && top.confidence - second.confidence < ambiguityMargin && top.source != .explicitClick {
                return AttentionResolution(candidates: candidates, chosen: nil, needsClarification: true, reason: "ambiguous: \(top.summary) \(fmt(top.confidence)) vs \(second.summary) \(fmt(second.confidence))")
            }
        }
        return AttentionResolution(candidates: candidates, chosen: top, needsClarification: false, reason: "top \(top.source.rawValue) \(fmt(top.confidence))")
    }

    func hoverScore(_ t: AttentionTarget, world: WorldState, now: Date) -> Double {
        var s = t.source == .devBridge ? 0.82 : 0.7
        if Self.interactiveRoles.contains(t.role) || Self.interactiveRoles.contains(t.accessibility.role ?? "") { s += 0.1 }
        if !t.label.isEmpty { s += 0.05 }
        if t.sourceReference != nil { s += 0.05 }
        if Self.containerRoles.contains(t.role) {
            s -= 0.2
            if let w = world.activeWindow, w.bounds.area > 0, t.bounds.area / w.bounds.area > 0.4 { s -= 0.15 }
        }
        if !t.bounds.contains(world.cursorPosition) { s -= 0.15 }
        let age = now.timeIntervalSince(t.observedAt)
        if age > 2 { s -= min(0.3, (age - 2) * 0.05) }
        return s
    }

    /// Collapse candidates that describe the same on-screen element.
    func merge(_ items: [(AttentionTarget, Double)]) -> [(AttentionTarget, Double)] {
        var out: [(AttentionTarget, Double)] = []
        for (t, s) in items {
            if let i = out.firstIndex(where: { same($0.0, t) }) {
                let (existing, es) = out[i]
                var winner = s >= es ? t : existing
                let loser = s >= es ? existing : t
                if winner.sourceReference == nil { winner.sourceReference = loser.sourceReference }
                if winner.label.isEmpty { winner.label = loser.label }
                // Corroboration from two sources is worth a small bump.
                out[i] = (winner, min(1, max(s, es) + 0.03))
            } else {
                out.append((t, s))
            }
        }
        return out
    }

    func same(_ a: AttentionTarget, _ b: AttentionTarget) -> Bool {
        if a.id == b.id { return true }
        let closeBounds = abs(a.bounds.x - b.bounds.x) <= 2 && abs(a.bounds.y - b.bounds.y) <= 2
            && abs(a.bounds.width - b.bounds.width) <= 2 && abs(a.bounds.height - b.bounds.height) <= 2
        return closeBounds && (a.role == b.role || a.label == b.label)
    }

    private func fmt(_ d: Double) -> String { String(format: "%.2f", d) }
}

import Foundation

/// Selects the small slice of `WorldState` worth sending to the conversational
/// model and renders it as compact JSON. No pixels, no full trees, no secrets.
public struct ContextBuilder: Sendable {
    public var redactor = Redactor.shared
    public var maxCharacters = 1200

    public init() {}

    public func build(world: WorldState, target: AttentionTarget?, resolution: AttentionResolution?, project: ProjectContext?, actions: [CodeAction], decision: IntentDecision?) -> String {
        LatencyTracer.shared.begin(.contextBuild)
        defer { LatencyTracer.shared.end(.contextBuild) }

        var ctx: [String: JSONValue] = [:]
        if let app = world.activeApplication { ctx["app"] = .string(app.name) }
        if let title = world.activeWindow?.title, !title.isEmpty { ctx["window"] = .string(String(redactor.redact(title).prefix(120))) }
        if let url = world.currentURL { ctx["url"] = .string(String(redactor.redact(url).prefix(160))) }

        if let t = target {
            ctx["target"] = JSONValue(any: t.contextDictionary())
        } else if let res = resolution, res.needsClarification, !res.candidates.isEmpty {
            ctx["target"] = .null
            ctx["ambiguous_candidates"] = .array(res.candidates.prefix(3).map { .string($0.summary) })
        } else {
            ctx["target"] = .null
        }
        if let region = world.selectedRegion, !region.isEmpty {
            ctx["selected_region"] = .object(["w": .number(region.width.rounded()), "h": .number(region.height.rounded())])
        }
        if let p = project {
            ctx["project"] = JSONValue(any: p.contextDictionary())
        } else {
            ctx["project"] = .string("unknown — ask the user to select the project before executing")
        }
        let running = actions.filter { $0.state == .running }
        if !running.isEmpty {
            ctx["agents_running"] = .array(running.map { .string($0.task.title) })
        }
        if let last = actions.last(where: { $0.state == .finished }) {
            ctx["last_change"] = .object([
                "title": .string(last.task.title),
                "files": .array(last.changedFiles.prefix(5).map(JSONValue.string)),
                "undone": .bool(last.undone),
            ])
        }
        if let d = decision, d.needsVisualReasoning {
            ctx["hint"] = .string("The question is visual; call capture_target if structure is not enough.")
        }
        let clicks = world.recentInteractions.filter { $0.kind == .click }.suffix(2)
        if !clicks.isEmpty {
            ctx["recent_clicks"] = .array(clicks.map { .string($0.target?.summary ?? "unknown element") })
        }

        var text = (try? JSONValue.object(ctx).toString()) ?? "{}"
        text = redactor.redact(text)
        if text.count > maxCharacters { text = String(text.prefix(maxCharacters)) + "…\"}" }
        return "[screen context] " + text
    }
}

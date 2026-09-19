import Foundation

/// Tool execution: binds the provider-independent tool catalog to system
/// actions. Every mutating tool passes through `ExecutionGate` first.
extension AssistantCoordinator {
    func executeTool(_ call: ToolCallRequest) async -> ToolResult {
        guard let tool = ToolName(rawValue: call.name) else {
            return .failure("Unknown tool \(call.name)")
        }
        let args = (try? JSONValue.parse(call.argumentsJSON)) ?? .object([:])
        let level = ToolCatalog.permission(for: call.name) ?? .destructive

        if !level.isAutomatic {
            let isReversal = tool == .undoLastChange || tool == .redoChange
            // The transcript may arrive a beat after the tool call; give it a moment.
            var pending: Bool { isReversal ? deps.gate.hasPendingReversalCommand : deps.gate.hasPendingExecutionCommand }
            if !pending {
                for _ in 0..<15 where !pending {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            let decision = deps.gate.evaluate(level: level, project: syncRead { self.project }, actionKey: call.name, isReversal: isReversal)
            if !decision.isAllowed {
                Log.warn("gate", "denied", ["tool": call.name, "why": decision.modelMessage])
                return .failure(decision.modelMessage, extra: ["denied": .bool(true)])
            }
        }

        switch tool {
        case .getCurrentContext:
            return .success(["context": .string(syncRead { self.buildContext() })])
        case .inspectTarget:
            return inspectTarget(id: args["target_id"]?.stringValue)
        case .captureTarget:
            return await captureTarget(id: args["target_id"]?.stringValue, padding: args["padding"]?.doubleValue ?? 24)
        case .captureRegion:
            return await captureRegion()
        case .getRecentInteraction:
            return recentInteraction()
        case .getProjectContext:
            let p = syncRead { self.project }
            return .success(["project": p.map { JSONValue(any: $0.contextDictionary()) } ?? .null, "trusted": .bool(p?.isTrusted ?? false)])
        case .resolveSourceComponent:
            return await resolveSource(id: args["target_id"]?.stringValue)
        case .proposeChange:
            return proposeChange(args)
        case .executeChange:
            return await executeChange(args)
        case .startCursorLocalAgent:
            return await executeChange(.object(["requested_change": args["task"] ?? .null]))
        case .startCursorCloudAgent:
            return await executeChange(.object(["requested_change": args["task"] ?? .null, "prefer_cloud": .bool(true)]))
        case .getAgentStatus:
            return await agentStatus(id: args["agent_id"]?.stringValue)
        case .cancelAgent:
            return await cancelAgent(id: args["agent_id"]?.stringValue)
        case .showAgentDiff:
            return agentDiff(id: args["agent_id"]?.stringValue)
        case .acceptAgentResult:
            return .success(["accepted": .bool(true)], spoken: "Kept.")
        case .undoLastChange:
            return await performUndo(steps: args["steps"]?.intValue ?? 1)
        case .redoChange:
            return await performRedo()
        case .createCheckpoint:
            return createCheckpoint(label: args["label"]?.stringValue ?? "manual")
        case .compareVariants:
            return await compareVariants(a: args["variant_a"]?.stringValue ?? "", b: args["variant_b"]?.stringValue ?? "")
        }
    }

    // MARK: Read tools

    func inspectTarget(id: String?) -> ToolResult {
        let t = syncRead { id.flatMap { self.deps.memory.target(id: $0) } ?? self.currentTarget }
        guard let t else { return .failure("No current target. Ask the user to point at or click the element.") }
        var d = JSONValue(any: t.contextDictionary())
        if case .object(var o) = d {
            o["accessibility"] = (try? JSONValue(any: JSONSerialization.jsonObject(with: JSONEncoder().encode(t.accessibility)))) ?? .null
            d = .object(o)
        }
        return .success(["target": d])
    }

    func captureTarget(id: String?, padding: Double) async -> ToolResult {
        let t = syncRead { id.flatMap { self.deps.memory.target(id: $0) } ?? self.currentTarget }
        guard let t else { return .failure("No current target to capture.") }
        LatencyTracer.shared.begin(.screenCapture)
        let rect = t.bounds.insetBy(-padding)
        guard let crop = await deps.perception.capture(rect: rect) else {
            LatencyTracer.shared.end(.screenCapture)
            return .failure("Screen capture unavailable (Screen Recording permission missing or not supported here). Reason from structure instead.")
        }
        LatencyTracer.shared.end(.screenCapture)
        // The realtime session is audio/text; images travel as a compact
        // description plus a data URL the app-level tooling can inspect. V1 keeps
        // the payload small by sending dimensions and a truncated PNG only.
        let b64 = crop.png.base64EncodedString()
        return .success([
            "target": .string(t.summary),
            "png_bytes": .number(Double(crop.png.count)),
            "bounds": .object(["w": .number(crop.bounds.width), "h": .number(crop.bounds.height)]),
            "image_data_url": .string("data:image/png;base64," + String(b64.prefix(200_000))),
        ], spoken: nil)
    }

    func captureRegion() async -> ToolResult {
        let world = deps.perception.snapshot()
        let rect = syncRead { self.selectedRegion } ?? world.activeWindow?.bounds
        guard let rect, !rect.isEmpty else { return .failure("No region or window to capture.") }
        guard let crop = await deps.perception.capture(rect: rect) else { return .failure("Screen capture unavailable.") }
        return .success(["png_bytes": .number(Double(crop.png.count)), "bounds": .object(["w": .number(rect.width), "h": .number(rect.height)]), "image_data_url": .string("data:image/png;base64," + String(crop.png.base64EncodedString().prefix(200_000)))])
    }

    func recentInteraction() -> ToolResult {
        let world = deps.perception.snapshot()
        let items: [JSONValue] = world.recentInteractions.suffix(20).map { e in
            var o: [String: JSONValue] = ["kind": .string(e.kind.rawValue), "seconds_ago": .number((Date().timeIntervalSince(e.at) * 10).rounded() / 10)]
            if let t = e.target { o["target"] = .string(t.summary) }
            if let n = e.note { o["note"] = .string(n) }
            return .object(o)
        }
        return .success(["events": .array(items)])
    }

    func resolveSource(id: String?) async -> ToolResult {
        let (t, p) = syncRead { (id.flatMap { self.deps.memory.target(id: $0) } ?? self.currentTarget, self.project) }
        guard let t else { return .failure("No current target.") }
        guard let p else { return .failure("No project detected.") }
        guard let ref = await deps.sourceResolver.resolve(target: t, project: p) else {
            return .success(["resolved": .bool(false)], spoken: nil)
        }
        syncWrite {
            var updated = t
            updated.sourceReference = ref
            self.deps.memory.setCurrentTarget(updated)
            if self.currentTarget?.id == t.id { self.currentTarget = updated }
        }
        return .success(["resolved": .bool(true), "component": ref.component.map(JSONValue.string) ?? .null, "file": ref.file.map(JSONValue.string) ?? .null, "line": ref.line.map { .number(Double($0)) } ?? .null, "confidence": .number(ref.confidence), "method": .string(ref.method)])
    }

    // MARK: Proposals

    func proposeChange(_ args: JSONValue) -> ToolResult {
        guard let summary = args["summary"]?.stringValue, !summary.isEmpty else { return .failure("summary is required") }
        let p = deps.memory.addProposal(summary: summary, constraints: args["constraints"]?.stringArray ?? [], rationale: args["rationale"]?.stringValue)
        return .success([
            "proposal_id": .string(p.id),
            "ordinal": .number(Double(p.ordinalInTurn)),
            "note": .string("Recorded. Nothing has been changed yet; the user must say something like \"do it\" before execute_change is allowed."),
        ])
    }

    // MARK: Execution

    func executeChange(_ args: JSONValue) async -> ToolResult {
        let request = ExecutionRequest(
            requestedChange: args["requested_change"]?.stringValue,
            proposalID: args["proposal_id"]?.stringValue,
            proposalOrdinal: args["proposal_ordinal"]?.intValue ?? syncRead { self.lastDecision?.proposalOrdinal },
            context: args["context"]?.stringValue,
            constraints: args["constraints"]?.stringArray ?? [],
            targetID: args["target_id"]?.stringValue,
            isFollowUp: args["is_follow_up"]?.boolValue ?? false,
            preferCloud: args["prefer_cloud"]?.boolValue ?? false
        )
        return await runTask(request: request)
    }

    func runTask(request: ExecutionRequest) async -> ToolResult {
        let (target, project) = syncRead { (self.currentTarget, self.project) }
        guard let project else { return .failure(PermissionDecision.deniedUntrustedProject.modelMessage) }

        // Source resolution runs before compiling so the task carries file:line.
        var resolvedTarget = target
        if let t = target, (t.sourceReference?.confidence ?? 0) < 0.75 {
            if let ref = await deps.sourceResolver.resolve(target: t, project: project) {
                resolvedTarget?.sourceReference = ref
                syncWrite { if self.currentTarget?.id == t.id { self.currentTarget = resolvedTarget } }
            }
        }

        LatencyTracer.shared.begin(.taskCompile)
        let task: AgentTask
        do {
            task = try deps.taskCompiler.compile(request: request, memory: deps.memory, target: resolvedTarget, project: project)
        } catch {
            LatencyTracer.shared.end(.taskCompile)
            return .failure(error.localizedDescription)
        }
        LatencyTracer.shared.end(.taskCompile)
        let prompt = task.renderPrompt()
        emit(.taskCompiled(task, prompt: prompt))

        // Checkpoint first; never edit without a way back.
        let checkpoint: Checkpoint
        do {
            let store = try syncRead { try self.store(for: project.rootPath) }
            checkpoint = try store.createCheckpoint(label: task.title)
            syncWrite { self.checkpoints[checkpoint.id] = checkpoint }
        } catch {
            return .failure("Could not create a checkpoint, so nothing was changed: \(error.localizedDescription)")
        }

        let provider: CodingAgentProvider
        if task.executionTarget == .cloud, let cloud = deps.cloudAgent, cloud.isAvailable {
            provider = cloud
        } else {
            provider = deps.localAgent
        }
        guard provider.isAvailable else {
            return .failure("Coding agent \(provider.name) is not available. " + (provider is CursorCLIAgentProvider ? CursorAgentError.cliNotInstalled.localizedDescription : ""))
        }

        var action = CodeAction(task: task, checkpointID: checkpoint.id, state: .queued)
        deps.memory.addAction(action)
        if let pid = task.proposalID { deps.memory.markProposalExecuted(pid, taskID: task.id) }
        emit(.action(action))
        deps.gate.consumeExecutionCommand()
        setStateAsync(.executing)

        // Visual verification baseline (cheap, best-effort, non-blocking).
        if let t = resolvedTarget, t.source != .synthetic {
            let actionID = action.id
            Task { if let crop = await self.deps.perception.capture(rect: t.bounds.insetBy(-8)) { self.syncWrite { self.beforeCrops[actionID] = crop } } }
        }

        let actionID = action.id
        do {
            let handle = try await provider.start(task: task) { [weak self] event in
                self?.handleAgentEvent(event, actionID: actionID)
            }
            action.agentRunID = handle.runID
            deps.memory.updateAction(id: actionID) { $0.agentRunID = handle.runID; $0.state = .running }
            emit(.action(deps.memory.action(id: actionID) ?? action))
            return .success([
                "agent_id": .string(handle.runID),
                "status": .string("started"),
                "task": .string(task.title),
                "checkpoint": .string(checkpoint.id),
                "execution": .string(handle.executionTarget.rawValue),
                "source": task.sourceReference?.file.map(JSONValue.string) ?? .null,
            ], spoken: "On it.")
        } catch {
            deps.memory.updateAction(id: actionID) { $0.state = .failed; $0.summary = error.localizedDescription }
            setStateAsync(.error)
            return .failure("Agent failed to start: \(error.localizedDescription)")
        }
    }

    func handleAgentEvent(_ event: AgentEvent, actionID: String) {
        work.async {
            switch event {
            case .started(let runID, let sessionID):
                self.deps.memory.updateAction(id: actionID) { $0.agentRunID = runID; $0.agentSessionID = sessionID; $0.state = .running }
            case .assistantText(let text):
                Log.debug("agent", String(text.prefix(200)))
            case .toolCall(let name, let path):
                Log.debug("agent", "tool \(name)", ["path": path ?? "-"])
            case .fileChanged(let path):
                self.deps.memory.updateAction(id: actionID) { if !$0.changedFiles.contains(path) { $0.changedFiles.append(path) } }
            case .finished(let summary):
                self.finishAction(actionID: actionID, summary: summary, failed: nil)
            case .failed(let error):
                self.finishAction(actionID: actionID, summary: nil, failed: error)
            case .cancelled:
                self.deps.memory.updateAction(id: actionID) { $0.state = .cancelled; $0.finishedAt = Date() }
                if let a = self.deps.memory.action(id: actionID) { self.emit(.action(a)) }
                self.setState(.idle)
                self.deps.voice.injectSystemNote("[agent] The coding agent was cancelled; no summary.", requestResponse: false)
            }
        }
    }

    func finishAction(actionID: String, summary: String?, failed: String?) {
        guard var action = deps.memory.action(id: actionID) else { return }
        // Ground truth for changed files: diff against the checkpoint tree.
        if let cp = checkpoints[action.checkpointID], let store = stores[action.task.projectRoot], let changes = try? store.changes(since: cp) {
            let paths = changes.map(\.path)
            if !paths.isEmpty { action.changedFiles = paths }
        }
        action.state = failed == nil ? .finished : .failed
        action.summary = failed ?? summary
        action.finishedAt = Date()
        deps.memory.updateAction(id: actionID) { $0 = action }
        emit(.action(action))
        if let started = utteranceStartedAt {
            LatencyTracer.shared.record(.requestToVisibleResult, milliseconds: Date().timeIntervalSince(started) * 1000)
        }
        setState(failed == nil ? .success : .error)

        let files = action.changedFiles.isEmpty ? "no files changed" : action.changedFiles.prefix(6).joined(separator: ", ")
        if let failed {
            deps.voice.injectSystemNote("[agent] The coding agent FAILED: \(String(failed.prefix(300))). Files touched: \(files). Tell the user briefly and offer to retry or undo.", requestResponse: true)
            return
        }
        let target = action.task.target
        let hasBaseline = beforeCrops[actionID] != nil
        Task {
            var observation = ""
            if hasBaseline, let t = target {
                // Give the dev server a moment to hot-reload before looking.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let after = await self.deps.perception.capture(rect: t.bounds.insetBy(-8)) {
                    let before = self.syncRead { self.beforeCrops.removeValue(forKey: actionID) }
                    if let before {
                        observation = before.png == after.png ? " Visual check: the target region looks UNCHANGED on screen so far — the change may not have applied or the page may not have reloaded." : " Visual check: the target region changed on screen."
                    }
                }
            }
            let note = "[agent] Finished \"\(action.task.title)\". Changed: \(files). Agent summary: \(String((summary ?? "").prefix(400))).\(observation) Tell the user in one short sentence what changed and invite them to react (keep / undo / adjust)."
            self.deps.voice.injectSystemNote(note, requestResponse: true)
            self.work.async { if self.state == .success { self.setState(.idle) } }
        }
    }

    // MARK: Undo / redo

    func performUndo(steps: Int) async -> ToolResult {
        // Idempotency for the fast path + tool call double trigger.
        if let last = syncRead({ self.lastUndoAt }), Date().timeIntervalSince(last) < 3 {
            return .success(["already_undone": .bool(true)], spoken: "Already undone.")
        }
        var undone: [String] = []
        var restoredFiles: [String] = []
        for _ in 0..<max(1, steps) {
            guard let action = deps.memory.lastAppliedAction else { break }
            if action.state == .running, let runID = action.agentRunID {
                try? await deps.localAgent.cancel(runID: runID)
            }
            guard let cp = syncRead({ self.checkpoints[action.checkpointID] }) else {
                return .failure("Checkpoint for \(action.task.title) not found in this session.")
            }
            do {
                let um = try syncRead { try self.undoManager(for: action.task.projectRoot) }
                let result = try um.undo(action: action, checkpoint: cp)
                deps.memory.updateAction(id: action.id) { $0.undone = true }
                if let a = deps.memory.action(id: action.id) { emit(.action(a)) }
                undone.append(action.task.title)
                restoredFiles += result.restoredFiles + result.deletedFiles
            } catch {
                return .failure("Undo failed: \(error.localizedDescription)")
            }
        }
        guard !undone.isEmpty else { return .failure("There is no applied change to undo.") }
        syncWrite { self.lastUndoAt = Date() }
        setStateAsync(.success)
        work.asyncAfter(deadline: .now() + 1.2) { if self.state == .success { self.setState(.idle) } }
        return .success(["undone": .array(undone.map(JSONValue.string)), "files": .array(restoredFiles.map(JSONValue.string))], spoken: "Reverted.")
    }

    func performRedo() async -> ToolResult {
        guard let action = deps.memory.lastUndoneAction else { return .failure("Nothing to redo.") }
        do {
            let um = try syncRead { try self.undoManager(for: action.task.projectRoot) }
            guard let result = try um.redo(action: action) else { return .failure("Redo state for \(action.task.title) is no longer available.") }
            deps.memory.updateAction(id: action.id) { $0.undone = false }
            if let a = deps.memory.action(id: action.id) { emit(.action(a)) }
            syncWrite { self.lastUndoAt = nil }
            return .success(["redone": .string(action.task.title), "files": .array((result.restoredFiles + result.deletedFiles).map(JSONValue.string))], spoken: "Re-applied.")
        } catch {
            return .failure("Redo failed: \(error.localizedDescription)")
        }
    }

    func createCheckpoint(label: String) -> ToolResult {
        guard let project = syncRead({ self.project }) else { return .failure("No project.") }
        do {
            let store = try syncRead { try self.store(for: project.rootPath) }
            let cp = try store.createCheckpoint(label: label)
            syncWrite { self.checkpoints[cp.id] = cp }
            return .success(["checkpoint": .string(cp.id)])
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: Agents

    func agentStatus(id: String?) async -> ToolResult {
        let action = id.flatMap { deps.memory.action(agentRunID: $0) } ?? deps.memory.actions.last
        guard let action else { return .success(["status": .string("none")], spoken: "Nothing is running.") }
        var live = action.state
        if let runID = action.agentRunID, let s = await deps.localAgent.status(runID: runID) { live = s.state }
        return .success(["agent_id": .string(action.agentRunID ?? "-"), "task": .string(action.task.title), "status": .string(live.rawValue), "files": .array(action.changedFiles.map(JSONValue.string)), "summary": action.summary.map(JSONValue.string) ?? .null])
    }

    func cancelAgent(id: String?) async -> ToolResult {
        let action = id.flatMap { deps.memory.action(agentRunID: $0) } ?? deps.memory.actions.last { $0.state == .running }
        guard let action, let runID = action.agentRunID else { return .failure("No running agent.") }
        try? await deps.localAgent.cancel(runID: runID)
        if let cloud = deps.cloudAgent { try? await cloud.cancel(runID: runID) }
        return .success(["cancelled": .string(action.task.title)], spoken: "Cancelled.")
    }

    func agentDiff(id: String?) -> ToolResult {
        let action = id.flatMap { deps.memory.action(agentRunID: $0) } ?? deps.memory.lastFinishedAction
        guard let action else { return .failure("No finished agent run.") }
        return .success(["task": .string(action.task.title), "files": .array(action.changedFiles.map(JSONValue.string)), "undone": .bool(action.undone)])
    }

    /// V1: variants run sequentially as two separate undoable actions; the
    /// user can flip with undo/redo. Isolated worktrees are the next step.
    func compareVariants(a: String, b: String) async -> ToolResult {
        guard !a.isEmpty, !b.isEmpty else { return .failure("Both variants are required.") }
        let first = await runTask(request: ExecutionRequest(requestedChange: a, context: "Variant A of two alternatives the user wants to compare."))
        guard first.ok else { return first }
        return .success(["variant_a": first.payload, "variant_b": .string("queued: say 'try the other version' after reviewing A to run: \(b)")], spoken: "Building variant A first.")
    }

    // MARK: Queue helpers

    func syncRead<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { return try body() }
        return try work.sync(execute: body)
    }

    func syncWrite(_ body: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { body() } else { work.sync(execute: body) }
    }

    func setStateAsync(_ s: AssistantState) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { setState(s) } else { work.async { self.setState(s) } }
    }

    nonisolated(unsafe) static let queueKey = DispatchSpecificKey<Bool>()
}

public enum AssistantPrompts {
    public static let grokInstructions = """
    You are a senior engineer pair-programming by voice with the user, who is building software on their Mac. You can see compact structured context about what they are looking at and pointing at (delivered as [screen context] notes), and you have tools to inspect the screen, register proposals, and hand precise coding tasks to Cursor.

    Style: speak like a colleague sitting next to them. Be brief — one to three short sentences unless asked for more. No preambles, no lists read aloud. React to what they point at ("this", "that") using the target in the screen context; if there is no target and they use those words, ask what they mean in a few words.

    Discussion vs. execution: discuss freely and suggest concrete changes. When you suggest a change, call propose_change once per option, in speaking order, with a precise one-sentence summary — this lets the user later say "do that" or "do the second one". NEVER call execute_change, undo_last_change, redo_change or compare_variants unless the user has just explicitly told you to go ahead (e.g. "do it", "try it", "build it", "go ahead", "undo that"). Casual agreement in discussion is not permission.

    Execution: when the user says to go ahead, call execute_change with proposal_id/proposal_ordinal for a registered proposal, or with a precise requested_change describing exactly what to change and what to preserve. Say a very short acknowledgment ("On it.") and wait; you will get an [agent] note when it finishes. Then say in one sentence what changed and invite a reaction. If they say it's worse, call undo_last_change. If they say "keep that but…", call execute_change with is_follow_up=true.

    Use capture_target only when a question is truly visual (colors, alignment, clutter) and the structured context is not enough. Prefer inspect_target and resolve_source_component. If the project is unknown or untrusted, ask the user to select it before executing. Never read secrets, environment variables or keys aloud.
    """
}

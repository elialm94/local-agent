import Foundation

public enum AssistantState: String, Codable, Sendable {
    case idle, listening, thinking, speaking, targeting, executing, success, error, muted
}

/// Everything the UI layer needs to render the orb, highlight, transcript and
/// debug panel. Delivered on the coordinator's work queue; UI must hop to main.
public enum AssistantUIEvent: Sendable {
    case state(AssistantState)
    case transcript(TranscriptTurn)
    case partialUserTranscript(String)
    case assistantDelta(String)
    case targetChanged(AttentionTarget?, explicit: Bool)
    case resolution(AttentionResolution)
    case decision(IntentDecision)
    case contextSent(String)
    case toolCall(name: String, argumentsJSON: String)
    case toolResult(name: String, json: String, ms: Double)
    case taskCompiled(AgentTask, prompt: String)
    case action(CodeAction)
    case project(ProjectContext?)
    case notice(String)
}

public struct AssistantDependencies {
    public var voice: VoiceReasoningProvider
    public var reflex: ReflexLayer
    public var localAgent: CodingAgentProvider
    public var cloudAgent: CodingAgentProvider?
    public var perception: PerceptionProvider
    public var projectResolver: @Sendable (WorldState) -> ProjectContext?
    public var checkpointStoreFactory: @Sendable (String) throws -> CheckpointStore
    public var sourceResolver: SourceResolver
    public var taskCompiler = TaskCompiler()
    public var attentionResolver = AttentionResolver()
    public var contextBuilder = ContextBuilder()
    public var gate = ExecutionGate()
    public var memory = SessionMemory()
    public var instructions = AssistantPrompts.grokInstructions
    public var voiceName = "eve"
    public var serverVAD = false

    public init(
        voice: VoiceReasoningProvider,
        reflex: ReflexLayer,
        localAgent: CodingAgentProvider,
        cloudAgent: CodingAgentProvider? = nil,
        perception: PerceptionProvider,
        projectResolver: @escaping @Sendable (WorldState) -> ProjectContext?,
        checkpointStoreFactory: @escaping @Sendable (String) throws -> CheckpointStore,
        sourceResolver: SourceResolver = CompositeSourceResolver([DevBridgeSourceResolver(), GrepSourceResolver()])
    ) {
        self.voice = voice
        self.reflex = reflex
        self.localAgent = localAgent
        self.cloudAgent = cloudAgent
        self.perception = perception
        self.projectResolver = projectResolver
        self.checkpointStoreFactory = checkpointStoreFactory
        self.sourceResolver = sourceResolver
    }
}

/// Runs the interaction loop. Platform-independent: the macOS app feeds it
/// hotkey/click/audio events and renders its `AssistantUIEvent`s; the CLI feeds
/// it typed text.
public final class AssistantCoordinator: VoiceReasoningDelegate, @unchecked Sendable {
    public let deps: AssistantDependencies
    let work = DispatchQueue(label: "pair.coordinator", qos: .userInteractive)

    public private(set) var state: AssistantState = .idle
    public var onEvent: (@Sendable (AssistantUIEvent) -> Void)?
    /// PCM16 audio from the assistant, for playback.
    public var onAudioOut: (@Sendable (Data) -> Void)?
    /// The user started talking over the assistant; playback should flush.
    public var onInterrupt: (@Sendable () -> Void)?

    // Per-utterance working set.
    var explicitTarget: AttentionTarget?
    var selectedRegion: Rect?
    var currentTarget: AttentionTarget?
    var lastResolution: AttentionResolution?
    var lastDecision: IntentDecision?
    var project: ProjectContext?
    /// A project the user picked by hand. Overrides detection until cleared.
    var explicitProject: ProjectContext?
    var utteranceStartedAt: Date?
    var lastUndoAt: Date?

    // Checkpoints by id; stores per project root.
    var checkpoints: [String: Checkpoint] = [:]
    var stores: [String: CheckpointStore] = [:]
    var undoManagers: [String: ActionUndoManager] = [:]
    var beforeCrops: [String: VisualCrop] = [:]

    public init(deps: AssistantDependencies) {
        self.deps = deps
        work.setSpecific(key: Self.queueKey, value: true)
        deps.voice.delegate = self
    }

    // MARK: - Lifecycle

    public func start() async {
        deps.perception.start()
        refreshProject()
        let cfg = VoiceSessionConfig(instructions: deps.instructions, voice: deps.voiceName, tools: ToolCatalog.all, serverVAD: deps.serverVAD, silenceDurationMs: 1400, vadCreatesResponse: false, keyterms: ["Cursor", "padding", "margin", "flexbox", "Tailwind", "component", "undo", "redo"])
        do {
            try await deps.voice.connect(config: cfg)
        } catch {
            emit(.notice("Voice connection failed: \(error.localizedDescription)"))
            setState(.error)
        }
    }

    public func stop() {
        deps.voice.disconnect()
        deps.perception.stop()
        setState(.idle)
    }

    public func setMuted(_ muted: Bool) {
        work.async { self.setState(muted ? .muted : .idle) }
    }

    /// Force a project (explicit selection from the menu).
    public func setExplicitProject(_ p: ProjectContext?) {
        work.async {
            self.explicitProject = p
            self.project = p
            self.deps.memory.currentProject = p
            self.emit(.project(p))
            if p == nil { self.refreshProject() }
        }
    }

    func refreshProject() {
        if explicitProject != nil { return }
        let world = deps.perception.snapshot()
        if let p = deps.projectResolver(world) {
            if p.rootPath != project?.rootPath || p.confidence != project?.confidence {
                project = p
                deps.memory.currentProject = p
                emit(.project(p))
            }
        }
    }

    // MARK: - Hotkey / pointer input

    public func hotkeyDown() {
        work.async {
            guard self.state != .muted else { return }
            LatencyTracer.shared.begin(.hotkeyToListening)
            self.utteranceStartedAt = Date()
            self.explicitTarget = nil
            self.selectedRegion = nil
            self.deps.voice.beginUserTurn()
            self.setState(.listening)
            self.resolveTargetNow(explicit: false)
            LatencyTracer.shared.end(.hotkeyToListening)
        }
    }

    private let sessionLock = NSLock()
    private var voiceSessionOpen = false

    /// Press once to open a hands-free voice session; press again to close it.
    /// While open, audio streams continuously and a pause of about 1.4s ends a turn.
    public func toggleVoiceSession() {
        sessionLock.lock()
        let open = voiceSessionOpen
        sessionLock.unlock()
        if open { leaveVoiceSession() } else { enterVoiceSession() }
    }

    public func enterVoiceSession() {
        sessionLock.lock(); voiceSessionOpen = true; sessionLock.unlock()
        work.async {
            guard self.state != .muted else {
                self.sessionLock.lock(); self.voiceSessionOpen = false; self.sessionLock.unlock()
                return
            }
            LatencyTracer.shared.begin(.hotkeyToListening)
            self.deps.voice.beginLiveSession()
            self.setState(.listening)
            self.resolveTargetNow(explicit: false)
            LatencyTracer.shared.end(.hotkeyToListening)
            self.emit(.notice("Voice on. Speak whenever you like — press ⌥ Space again to stop."))
        }
    }

    public func leaveVoiceSession() {
        sessionLock.lock(); voiceSessionOpen = false; sessionLock.unlock()
        work.async {
            self.deps.voice.endLiveSession()
            self.onInterrupt?()
            if self.state != .executing { self.setState(.idle) }
            self.emit(.notice("Voice off."))
        }
    }

    private func isVoiceSessionOpen() -> Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return voiceSessionOpen
    }

    /// Microphone PCM16 (24 kHz mono). Forwarded directly — not queued — so audio
    /// never waits behind state work. During a live session this includes the time
    /// the assistant is speaking, so a barge-in is heard.
    public func appendAudio(_ pcm16: Data) {
        if isVoiceSessionOpen() || state == .listening || state == .targeting {
            deps.voice.appendAudio(pcm16)
        }
    }

    public func hotkeyUp() {
        work.async {
            guard self.state == .listening || self.state == .targeting else { return }
            self.refreshProject()
            // Re-resolve at release: the user may have moved the pointer while talking.
            if self.explicitTarget == nil { self.resolveTargetNow(explicit: false) }
            let context = self.buildContext()
            self.emit(.contextSent(context))
            self.deps.voice.endUserTurn(context: context)
            self.setState(.thinking)
        }
    }

    /// Option+Space+click: the element under the pointer becomes the explicit target.
    public func explicitClick(at point: Point) {
        work.async {
            LatencyTracer.shared.begin(.targetResolution, key: "click")
            guard var t = self.deps.perception.target(at: point) else {
                LatencyTracer.shared.end(.targetResolution, key: "click")
                return
            }
            t.source = .explicitClick
            t.confidence = 0.95
            t.observedAt = Date()
            self.explicitTarget = t
            self.selectedRegion = nil
            self.currentTarget = t
            self.deps.memory.setCurrentTarget(t)
            LatencyTracer.shared.end(.targetResolution, key: "click")
            self.emit(.targetChanged(t, explicit: true))
            if self.state == .listening { self.setState(.targeting) }
        }
    }

    /// Option+Space+drag: a screen region becomes the explicit target.
    public func explicitRegion(_ rect: Rect) {
        work.async {
            guard !rect.isEmpty else { return }
            self.selectedRegion = rect
            let t = AttentionTarget(role: "Region", label: "selected region", bounds: rect, application: self.deps.perception.snapshot().activeApplication?.name ?? "", confidence: 0.9, source: .explicitRegion)
            self.explicitTarget = t
            self.currentTarget = t
            self.deps.memory.setCurrentTarget(t)
            self.emit(.targetChanged(t, explicit: true))
            if self.state == .listening { self.setState(.targeting) }
        }
    }

    public func cancel() {
        work.async {
            self.deps.voice.interrupt()
            self.onInterrupt?()
            self.setState(.idle)
        }
    }

    /// Typed utterance (debug panel / CLI). Same pipeline as voice.
    public func submitText(_ text: String) {
        work.async {
            guard self.state != .muted else { return }
            self.utteranceStartedAt = Date()
            self.refreshProject()
            if self.explicitTarget == nil { self.resolveTargetNow(explicit: false) }
            let context = self.buildContext()
            self.emit(.contextSent(context))
            self.setState(.thinking)
            self.deps.voice.sendUserText(text, context: context)
        }
    }

    // MARK: - Target resolution

    func resolveTargetNow(explicit: Bool) {
        LatencyTracer.shared.begin(.targetResolution)
        var world = deps.perception.snapshot()
        if let e = explicitTarget { world.selectedElement = e }
        if let r = selectedRegion { world.selectedRegion = r }
        if world.hoveredElement == nil, explicitTarget == nil {
            world.hoveredElement = deps.perception.target(at: world.cursorPosition)
        }
        let res = deps.attentionResolver.resolve(world: world, decision: lastDecision)
        lastResolution = res
        LatencyTracer.shared.end(.targetResolution)
        let chosen = explicitTarget ?? res.chosen
        if chosen?.id != currentTarget?.id {
            currentTarget = chosen
            deps.memory.setCurrentTarget(chosen)
            emit(.targetChanged(chosen, explicit: explicitTarget != nil))
        }
        emit(.resolution(res))
    }

    func buildContext() -> String {
        var world = deps.perception.snapshot()
        if let r = selectedRegion { world.selectedRegion = r }
        return deps.contextBuilder.build(world: world, target: currentTarget, resolution: lastResolution, project: project, actions: deps.memory.actions, decision: lastDecision)
    }

    // MARK: - VoiceReasoningDelegate

    public func voiceProvider(_ provider: VoiceReasoningProvider, didChangeState s: VoiceConnectionState) {
        work.async {
            switch s {
            case .connected: if self.state == .error { self.setState(.idle) }
            case .failed: self.setState(.error)
            case .disconnected: if self.state != .idle && self.state != .muted { self.emit(.notice("Voice disconnected")) }
            case .connecting: break
            }
        }
    }

    public func voiceProvider(_ provider: VoiceReasoningProvider, didReceiveAudio pcm16: Data) {
        onAudioOut?(pcm16)
        work.async { if self.state == .thinking { self.setState(.speaking) } }
    }

    public func voiceProvider(_ provider: VoiceReasoningProvider, didReceiveUserTranscript text: String, isFinal: Bool) {
        work.async {
            guard isFinal else { self.emit(.partialUserTranscript(text)); return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.deps.gate.observeUserUtterance(trimmed)
            let turn = self.deps.memory.addTurn(.user, trimmed, targetID: self.currentTarget?.id)
            self.emit(.transcript(turn))
            let routed = IntentRouter().route(trimmed)
            self.lastDecision = routed
            self.emit(.decision(routed))
            self.applyDeterministicFastPaths(routed)
            // Refine asynchronously; the result only affects context hints and the debug panel.
            let target = self.currentTarget
            let lastAssistant = self.deps.memory.recentTranscript(turns: 4).last(where: { $0.speaker == .assistant })?.text
            Task {
                let refined = await self.deps.reflex.refine(routed, utterance: trimmed, target: target, recentAssistantText: lastAssistant)
                if refined != routed {
                    self.work.async { self.lastDecision = refined; self.emit(.decision(refined)) }
                }
            }
        }
    }

    public func voiceProvider(_ provider: VoiceReasoningProvider, didReceiveAssistantTranscriptDelta delta: String) {
        emit(.assistantDelta(delta))
    }

    public func voiceProvider(_ provider: VoiceReasoningProvider, didFinishAssistantTurn transcript: String) {
        work.async {
            let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let turn = self.deps.memory.addTurn(.assistant, t)
            self.emit(.transcript(turn))
        }
    }

    public func voiceProvider(_ provider: VoiceReasoningProvider, didRequestToolCall call: ToolCallRequest) {
        work.async {
            self.emit(.toolCall(name: call.name, argumentsJSON: call.argumentsJSON))
            let start = Date()
            Task {
                let result = await self.executeTool(call)
                let ms = Date().timeIntervalSince(start) * 1000
                self.emit(.toolResult(name: call.name, json: result.json, ms: ms))
                var payload = result.payload
                if let spoken = result.spoken, case .object(var o) = payload { o["spoken"] = .string(spoken); payload = .object(o) }
                self.deps.voice.sendToolResult(callID: call.callID, outputJSON: (try? payload.toString()) ?? result.json)
            }
        }
    }

    public func voiceProvider(_ provider: VoiceReasoningProvider, didStartResponse: Void) {
        work.async { if self.state == .listening || self.state == .idle || self.state == .success { self.setState(.thinking) } }
    }

    public func voiceProvider(_ provider: VoiceReasoningProvider, didFinishResponse: Void) {
        work.async {
            let executing = self.deps.memory.actions.contains { $0.state == .running }
            if self.state == .speaking || self.state == .thinking {
                if self.isVoiceSessionOpen() {
                    self.setState(executing ? .executing : .listening)
                } else {
                    self.setState(executing ? .executing : .idle)
                }
            }
        }
    }

    public func voiceProvider(_ provider: VoiceReasoningProvider, didDetectUserSpeechStart: Void) {
        onInterrupt?()
        work.async {
            guard self.isVoiceSessionOpen() else { return }
            if self.state == .speaking || self.state == .thinking { self.setState(.listening) }
        }
    }

    public func voiceProvider(_ provider: VoiceReasoningProvider, didDetectUserSpeechStop: Void) {
        work.async {
            guard self.isVoiceSessionOpen() else { return }
            self.refreshProject()
            if self.explicitTarget == nil { self.resolveTargetNow(explicit: false) }
            let context = self.buildContext()
            self.emit(.contextSent(context))
            self.deps.voice.completeServerTurn(context: context)
            if self.state == .listening || self.state == .targeting { self.setState(.thinking) }
        }
    }

    public func voiceProvider(_ provider: VoiceReasoningProvider, didFail error: Error) {
        work.async {
            self.emit(.notice(error.localizedDescription))
            self.setState(.error)
        }
    }

    // MARK: - Deterministic fast paths

    /// Undo is the one action fast enough and safe enough to run before the
    /// model responds. The later tool call is idempotent.
    func applyDeterministicFastPaths(_ d: IntentDecision) {
        guard d.intent == .undo, d.confidence >= 0.9 else { return }
        guard deps.memory.lastAppliedAction != nil else { return }
        Task {
            let r = await self.performUndo(steps: d.undoSteps == Int.max ? 99 : d.undoSteps)
            if r.ok { self.emit(.notice("Undo applied (fast path)")) }
        }
    }

    // MARK: - Helpers

    func setState(_ s: AssistantState) {
        guard s != state else { return }
        state = s
        emit(.state(s))
    }

    func emit(_ e: AssistantUIEvent) {
        onEvent?(e)
    }

    func store(for root: String) throws -> CheckpointStore {
        if let s = stores[root] { return s }
        let s = try deps.checkpointStoreFactory(root)
        stores[root] = s
        undoManagers[root] = ActionUndoManager(store: s)
        return s
    }

    func undoManager(for root: String) throws -> ActionUndoManager {
        _ = try store(for: root)
        return undoManagers[root]!
    }
}

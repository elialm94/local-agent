import AppKit
import Combine
import Foundation
import PairCore

/// Observable state for the menu bar, orb, highlight, and debug panel. Owns
/// the coordinator and the platform adapters; everything UI-facing is on the
/// main actor.
@MainActor
final class AppModel: ObservableObject {
    // Published UI state
    @Published var state: AssistantState = .idle
    @Published var transcript: [TranscriptTurn] = []
    @Published var partialUserText = ""
    @Published var assistantLive = ""
    @Published var target: AttentionTarget?
    @Published var targetIsExplicit = false
    @Published var resolution: AttentionResolution?
    @Published var decision: IntentDecision?
    @Published var lastContext = ""
    @Published var toolLog: [ToolLogEntry] = []
    @Published var compiledTasks: [(task: AgentTask, prompt: String)] = []
    @Published var actions: [CodeAction] = []
    @Published var project: ProjectContext?
    @Published var notices: [String] = []
    @Published var latencies: [LatencySample] = []
    @Published var logLines: [LogEntry] = []
    @Published var regionPreview: Rect?
    @Published var running = false
    @Published var voiceProviderName = ""
    @Published var agentProviderName = ""
    @Published var fastProviderName = ""
    @Published var permissions = Permissions()
    @Published var lastError: String?

    struct ToolLogEntry: Identifiable {
        let id = UUID()
        let at = Date()
        var name: String
        var arguments: String
        var result: String?
        var ms: Double?
    }

    struct Permissions {
        var accessibility = false
        var screenRecording = false
        var microphone = false
        var allGranted: Bool { accessibility && microphone }
    }

    // Platform adapters
    let perception = MacPerceptionProvider()
    let hotkey = GlobalHotkey()
    let audio = AudioEngine()
    let projectDetector = MacProjectDetector()
    private(set) var coordinator: AssistantCoordinator?
    private var cursorCLI: CursorCLIAgentProvider?

    var explicitProjectPath: String? { projectDetector.explicitPath }

    init() {
        Log.shared.addSink { [weak self] entry in
            Task { @MainActor in
                guard let self else { return }
                self.logLines.append(entry)
                if self.logLines.count > 400 { self.logLines.removeFirst(self.logLines.count - 400) }
            }
        }
        LatencyTracer.shared.addListener { [weak self] sample in
            Task { @MainActor in
                guard let self else { return }
                self.latencies.append(sample)
                if self.latencies.count > 200 { self.latencies.removeFirst(self.latencies.count - 200) }
            }
        }
        refreshPermissions()
        wireHotkey()
    }

    // MARK: Permissions

    func refreshPermissions() {
        permissions.accessibility = MacPerceptionProvider.accessibilityTrusted
        permissions.screenRecording = MacPerceptionProvider.screenRecordingGranted
        permissions.microphone = AudioEngine.microphoneGranted
    }

    func requestPermissions() {
        MacPerceptionProvider.requestAccessibility()
        AudioEngine.requestMicrophone { _ in Task { @MainActor in self.refreshPermissions() } }
        MacPerceptionProvider.requestScreenRecording()
        refreshPermissions()
    }

    // MARK: Lifecycle

    /// Build providers from Keychain configuration and start the loop.
    func start() {
        guard coordinator == nil else { return }
        refreshPermissions()

        let xai = KeychainStore.read(.xaiAPIKey) ?? ""
        let typesafe = KeychainStore.read(.typesafeAPIKey) ?? ""
        let cursorKey = KeychainStore.read(.cursorAPIKey)

        let voice: VoiceReasoningProvider = xai.isEmpty ? MockVoiceProvider() : GrokVoiceProvider(apiKey: xai)
        let fast: FastDecisionProvider = typesafe.isEmpty ? MockFastDecisionProvider() : JevProvider(apiKey: typesafe)
        let cli = CursorCLIAgentProvider(executablePath: UserDefaults.standard.string(forKey: "pair.cursorAgentPath").flatMap { $0.isEmpty ? nil : $0 })
        cursorCLI = cli
        let local: CodingAgentProvider = cli.isAvailable ? cli : MockCodingAgentProvider()
        let cloud: CodingAgentProvider? = cursorKey.flatMap { $0.isEmpty ? nil : CursorCloudAgentProvider(apiKey: $0) }

        voiceProviderName = voice.name
        agentProviderName = local.name
        fastProviderName = fast.name

        let detector = projectDetector
        var deps = AssistantDependencies(
            voice: voice,
            reflex: ReflexLayer(provider: fast),
            localAgent: local,
            cloudAgent: cloud,
            perception: perception,
            projectResolver: { world in detector.resolve(world: world) },
            checkpointStoreFactory: { root in try GitCheckpointManager(projectPath: root) }
        )
        deps.serverVAD = false // push-to-talk; the hotkey bounds each turn
        let c = AssistantCoordinator(deps: deps)
        coordinator = c
        c.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        c.onAudioOut = { [audio] data in audio.play(pcm16: data) }
        c.onInterrupt = { [audio] in audio.flushPlayback() }
        audio.onCapturedPCM16 = { [weak c] data in c?.appendAudio(data) }

        do { try audio.start(capture: permissions.microphone) } catch { notices.append("Audio: \(error.localizedDescription)") }
        if !permissions.microphone { notices.append("Microphone not granted — you can type in the panel, but voice is off until you allow it and restart.") }
        if permissions.accessibility {
            if !hotkey.install() { notices.append("Could not install the global shortcut. Grant Accessibility access and restart.") }
        }
        Task { await c.start() }
        running = true
        if !cli.isAvailable {
            notices.append("Cursor CLI (`agent`) not found — using the mock coding agent. Install: curl https://cursor.com/install -fsS | bash")
        }
        if xai.isEmpty { notices.append("No xAI key — voice is mocked (text only). Add it in Settings.") }
    }

    func stop() {
        hotkey.uninstall()
        audio.stop()
        coordinator?.stop()
        coordinator = nil
        running = false
        state = .idle
    }

    func restart() {
        stop()
        start()
    }

    func toggleMute() {
        let muted = state == .muted
        coordinator?.setMuted(!muted)
    }

    func selectProject(path: String?) {
        projectDetector.explicitPath = path
        projectDetector.invalidate()
        let ctx = path.flatMap { ProjectDetection.context(forPath: $0, signals: [.explicitSelection], confidence: 0.95) }
        coordinator?.setExplicitProject(ctx)
    }

    func submitText(_ text: String) {
        coordinator?.submitText(text)
    }

    // MARK: Hotkey wiring

    private func wireHotkey() {
        hotkey.onHotkeyDown = { [weak self] in
            guard let self, let c = self.coordinator else { return }
            self.perception.hotkeyHeld = true
            self.audio.beginCapture()
            c.hotkeyDown()
        }
        hotkey.onHotkeyUp = { [weak self] in
            guard let self, let c = self.coordinator else { return }
            self.perception.hotkeyHeld = false
            self.audio.endCapture()
            self.regionPreview = nil
            c.hotkeyUp()
        }
        hotkey.onExplicitClick = { [weak self] p in self?.coordinator?.explicitClick(at: p) }
        hotkey.onExplicitRegion = { [weak self] r in
            self?.perception.setSelectedRegion(r)
            self?.coordinator?.explicitRegion(r)
        }
        hotkey.onRegionPreview = { [weak self] r in self?.regionPreview = r }
        hotkey.onCancel = { [weak self] in
            self?.perception.hotkeyHeld = false
            self?.audio.endCapture()
            self?.coordinator?.cancel()
        }
        hotkey.onObservedClick = { [weak self] p in self?.perception.noteClick(at: p) }
        hotkey.cancelRelevance = { [weak self] in
            guard let s = self?.state else { return false }
            return s == .listening || s == .thinking || s == .speaking || s == .targeting
        }
    }

    // MARK: Coordinator events → UI

    private func handle(_ event: AssistantUIEvent) {
        switch event {
        case .state(let s):
            state = s
            if s == .idle || s == .success || s == .error { assistantLive = "" }
        case .transcript(let t):
            transcript.append(t)
            if transcript.count > 200 { transcript.removeFirst(transcript.count - 200) }
            if t.speaker == .user { partialUserText = "" } else { assistantLive = "" }
        case .partialUserTranscript(let s):
            partialUserText = s
        case .assistantDelta(let d):
            assistantLive += d
        case .targetChanged(let t, let explicit):
            target = t
            targetIsExplicit = explicit
        case .resolution(let r):
            resolution = r
        case .decision(let d):
            decision = d
        case .contextSent(let c):
            lastContext = c
        case .toolCall(let name, let args):
            toolLog.append(ToolLogEntry(name: name, arguments: args))
            if toolLog.count > 100 { toolLog.removeFirst(toolLog.count - 100) }
        case .toolResult(let name, let json, let ms):
            if let i = toolLog.lastIndex(where: { $0.name == name && $0.result == nil }) {
                toolLog[i].result = json
                toolLog[i].ms = ms
            }
        case .taskCompiled(let task, let prompt):
            compiledTasks.append((task, prompt))
            if compiledTasks.count > 20 { compiledTasks.removeFirst() }
        case .action(let a):
            if let i = actions.firstIndex(where: { $0.id == a.id }) { actions[i] = a } else { actions.append(a) }
        case .project(let p):
            project = p
        case .notice(let n):
            notices.append(n)
            if notices.count > 30 { notices.removeFirst(notices.count - 30) }
            if n.lowercased().contains("failed") || n.lowercased().contains("error") { lastError = n }
        }
    }
}

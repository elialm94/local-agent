import Foundation
import PairCore

// pair-cli: headless harness for the interaction loop.
//
//   pair-cli --project ~/code/driva --target-label "Send Offer" \
//            --say "make this button red" --say "do it" --say "undo that"
//
// Voice is text-only here (no microphone); everything else — routing, target
// resolution, task compilation, checkpoints, the Cursor agent, undo — is the
// same code the Mac app runs.

struct Options {
    var project = FileManager.default.currentDirectoryPath
    var targetLabel = "Send Offer"
    var targetRole = "AXButton"
    var targetDomID: String?
    var utterances: [String] = []
    var agent = "auto"      // auto | mock | cursor | dry
    var voice = "auto"      // auto | mock | grok
    var jev = "auto"        // auto | mock | jev
    var interactive = false
    var showPrompt = true
    var verbose = false
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func next() -> String? { args.isEmpty ? nil : args.removeFirst() }
    while let a = next() {
        switch a {
        case "--project": o.project = next() ?? o.project
        case "--target-label": o.targetLabel = next() ?? o.targetLabel
        case "--target-role": o.targetRole = next() ?? o.targetRole
        case "--target-dom-id": o.targetDomID = next()
        case "--say": if let s = next() { o.utterances.append(s) }
        case "--agent": o.agent = next() ?? o.agent
        case "--voice": o.voice = next() ?? o.voice
        case "--jev": o.jev = next() ?? o.jev
        case "--interactive", "-i": o.interactive = true
        case "--no-prompt": o.showPrompt = false
        case "--verbose", "-v": o.verbose = true
        case "--help", "-h":
            print("""
            pair-cli — headless harness for the Pair interaction loop

              --project <path>        project root (default: cwd)
              --target-label <text>   label of the synthetic UI target (default: "Send Offer")
              --target-role <role>    AX role (default: AXButton)
              --target-dom-id <id>    DOM id hint for source resolution
              --say "<utterance>"     utterance to process (repeatable, in order)
              --agent auto|mock|cursor|dry   coding agent (auto = cursor if installed else mock)
              --voice auto|mock|grok  conversational model (grok needs XAI_API_KEY; text in/out)
              --jev auto|mock|jev     fast decision model (jev needs TYPESAFE_API_KEY)
              -i, --interactive       read utterances from stdin after --say ones
              --no-prompt             don't print the compiled Cursor prompt
              -v, --verbose           debug logging
            """)
            exit(0)
        default:
            FileHandle.standardError.write("unknown argument \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

let opts = parse()
Log.shared.minimumLevel = opts.verbose ? .debug : .warn
let env = ProcessInfo.processInfo.environment

// Providers
let fast: FastDecisionProvider = {
    let key = env["TYPESAFE_API_KEY"] ?? ""
    if opts.jev == "jev" || (opts.jev == "auto" && !key.isEmpty) { return JevProvider(apiKey: key) }
    return MockFastDecisionProvider()
}()

let cli = CursorCLIAgentProvider()
let agent: CodingAgentProvider = {
    switch opts.agent {
    case "cursor": return cli
    case "mock": return MockCodingAgentProvider()
    case "dry": let m = MockCodingAgentProvider(); m.dryRun = true; return m
    default: return cli.isAvailable ? cli : MockCodingAgentProvider()
    }
}()

let voice: VoiceReasoningProvider = {
    let key = env["XAI_API_KEY"] ?? ""
    if opts.voice == "grok" || (opts.voice == "auto" && !key.isEmpty) { return GrokVoiceProvider(apiKey: key) }
    return MockVoiceProvider()
}()

let perception = SyntheticPerceptionProvider()
let target = SyntheticPerceptionProvider.demoTarget(label: opts.targetLabel, role: opts.targetRole, domID: opts.targetDomID)
perception.update { w in
    w.activeApplication = ApplicationInfo(name: "Google Chrome", bundleID: "com.google.Chrome")
    w.activeWindow = WindowInfo(title: "localhost:5173", bounds: Rect(x: 0, y: 0, width: 1440, height: 900))
    w.cursorPosition = target.bounds.center
    w.hoveredElement = target
    w.currentURL = "http://localhost:5173/"
}

let projectPath = URL(fileURLWithPath: opts.project).standardizedFileURL.path
let project = ProjectDetection.context(forPath: projectPath, signals: [.explicitSelection], confidence: 0.95)

var deps = AssistantDependencies(
    voice: voice,
    reflex: ReflexLayer(provider: fast),
    localAgent: agent,
    cloudAgent: (env["CURSOR_API_KEY"]).map { CursorCloudAgentProvider(apiKey: $0) },
    perception: perception,
    projectResolver: { _ in project },
    checkpointStoreFactory: { root in try GitCheckpointManager(projectPath: root) }
)
deps.serverVAD = false

let coordinator = AssistantCoordinator(deps: deps)

// Event printing + quiescence tracking
final class Tracker: @unchecked Sendable {
    let lock = NSLock()
    var lastEventAt = Date()
    var running = 0
    var assistantLine = ""
    func touch() { lock.lock(); lastEventAt = Date(); lock.unlock() }
    var idleFor: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastEventAt) }
}
let tracker = Tracker()

func out(_ s: String) { print(s); fflush(stdout) }

coordinator.onEvent = { event in
    tracker.touch()
    switch event {
    case .state(let s):
        out("  · state → \(s.rawValue)")
    case .transcript(let t):
        if t.speaker == .assistant { out("\u{1F5E3} grok: \(t.text)") } else { out("\u{1F399} you: \(t.text)") }
    case .partialUserTranscript, .assistantDelta:
        break
    case .targetChanged(let t, let explicit):
        out("  · target: \(t?.summary ?? "none") \(explicit ? "(explicit)" : "") conf=\(t.map { String(format: "%.2f", $0.confidence) } ?? "-")")
    case .resolution(let r):
        if opts.verbose { out("  · resolution: \(r.reason)") }
    case .decision(let d):
        out("  · intent: \(d.intent.rawValue) conf=\(String(format: "%.2f", d.confidence)) exec=\(d.isExecutionCommand) by \(d.decidedBy)")
    case .contextSent(let c):
        if opts.verbose { out("  · context: \(c)") }
    case .toolCall(let name, let args):
        out("  ⚙︎ tool \(name) \(args)")
    case .toolResult(let name, let json, let ms):
        out("  ⚙︎ \(name) → \(json.prefix(220)) (\(Int(ms))ms)")
    case .taskCompiled(let task, let prompt):
        out("  ▶ compiled task: \(task.title)")
        if opts.showPrompt { out("  ┌─ Cursor prompt ─────────────────────────\n" + prompt.split(separator: "\n").map { "  │ " + $0 }.joined(separator: "\n") + "\n  └──────────────────────────────────────────") }
    case .action(let a):
        out("  ▶ action \(a.task.title): \(a.state.rawValue)\(a.undone ? " (undone)" : "") files=\(a.changedFiles)")
    case .project(let p):
        out("  · project: \(p?.name ?? "none") @ \(p?.rootPath ?? "-") conf=\(p.map { String(format: "%.2f", $0.confidence) } ?? "-")")
    case .notice(let n):
        out("  ! \(n)")
    }
}
coordinator.onAudioOut = { _ in }

out("pair-cli — voice=\(voice.name) agent=\(agent.name) jev=\(fast.name) project=\(project?.name ?? "none")")
if agent.name == "cursor-cli" { out("  (Cursor CLI at \(cli.executablePath ?? "?") will edit \(projectPath))") }

let sema = DispatchSemaphore(value: 0)
Task {
    await coordinator.start()
    sema.signal()
}
sema.wait()

func settle(timeout: TimeInterval = 180) {
    let start = Date()
    Thread.sleep(forTimeInterval: 0.2)
    while Date().timeIntervalSince(start) < timeout {
        let running = deps.memory.actions.contains { $0.state == .running || $0.state == .queued }
        if !running && tracker.idleFor > 0.8 && coordinator.state != .thinking && coordinator.state != .executing { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
    out("  ! timed out waiting for the turn to settle")
}

for u in opts.utterances {
    out("")
    coordinator.submitText(u)
    settle()
}

if opts.interactive {
    out("\nType utterances (blank line to quit):")
    while let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty {
        coordinator.submitText(line)
        settle()
    }
}

coordinator.onEvent = nil
coordinator.stop()
out("")
out("latencies:")
for (stage, ms) in LatencyTracer.shared.latestPerStage().sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
    out("  " + stage.rawValue.padding(toLength: 26, withPad: " ", startingAt: 0) + String(format: "%6.0f ms", ms))
}

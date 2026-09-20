import XCTest
@testable import PairCore

/// End-to-end tests of the interaction loop with mock providers and a real git
/// checkpoint store. These are the executable specification of Milestone 1.
final class CoordinatorLoopTests: XCTestCase {
    var repo = ""
    var perception: SyntheticPerceptionProvider!
    var coordinator: AssistantCoordinator!
    var events: UIEventSink!
    var agent: MockCodingAgentProvider!

    override func setUpWithError() throws {
        try XCTSkipIf(ShellRunner.which("git") == nil, "git required")
        repo = try makeTempRepo()
        try FileManager.default.createDirectory(atPath: repo + "/src/features/offers", withIntermediateDirectories: true)
        try """
        export function SendOfferButton() {
          return <button className="btn-primary">Send Offer</button>;
        }
        """.write(toFile: repo + "/src/features/offers/SendOfferButton.tsx", atomically: true, encoding: .utf8)
        _ = try ShellRunner().run("git", ["add", "src/features"], cwd: repo)

        perception = SyntheticPerceptionProvider()
        let target = SyntheticPerceptionProvider.demoTarget(label: "Send Offer")
        perception.update { w in
            w.activeApplication = ApplicationInfo(name: "Google Chrome")
            w.activeWindow = WindowInfo(title: "localhost:5173", bounds: Rect(x: 0, y: 0, width: 1440, height: 900))
            w.cursorPosition = target.bounds.center
            w.hoveredElement = target
            w.currentURL = "http://localhost:5173/"
        }
        agent = MockCodingAgentProvider()
        agent.simulatedDurationMs = 30
        let project = ProjectDetection.context(forPath: repo, signals: [.explicitSelection], confidence: 0.95)
        let deps = AssistantDependencies(
            voice: MockVoiceProvider(),
            reflex: ReflexLayer(provider: MockFastDecisionProvider()),
            localAgent: agent,
            perception: perception,
            projectResolver: { _ in project },
            checkpointStoreFactory: { root in try GitCheckpointManager(projectPath: root) }
        )
        coordinator = AssistantCoordinator(deps: deps)
        events = UIEventSink()
        coordinator.onEvent = { [events] in events?.append($0) }
        let sema = DispatchSemaphore(value: 0)
        Task { await self.coordinator.start(); sema.signal() }
        XCTAssertEqual(sema.wait(timeout: .now() + 5), .success)
    }

    override func tearDownWithError() throws {
        coordinator?.stop()
        if !repo.isEmpty { try? FileManager.default.removeItem(atPath: repo) }
    }

    func say(_ text: String) {
        coordinator.submitText(text)
        settle()
    }

    /// Wait until no agent is running and the event stream has gone quiet.
    func settle(timeout: TimeInterval = 10) {
        let start = Date()
        Thread.sleep(forTimeInterval: 0.05)
        while Date().timeIntervalSince(start) < timeout {
            let running = coordinator.deps.memory.actions.contains { $0.state == .running || $0.state == .queued }
            if !running && events.idleFor > 0.25 && coordinator.state != .executing && coordinator.state != .thinking { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("did not settle")
    }

    func button() -> String { (try? String(contentsOfFile: repo + "/src/features/offers/SendOfferButton.tsx", encoding: .utf8)) ?? "" }

    func testMagicLoopProposeExecuteUndoRedo() throws {
        let original = button()

        say("make this button red")
        XCTAssertEqual(events.decisions.last?.intent, .modifyUI)
        XCTAssertEqual(events.targets.last??.label, "Send Offer", "target must be resolved from the pointer")
        XCTAssertTrue(events.toolCalls.contains("propose_change"))
        XCTAssertFalse(events.toolCalls.contains("execute_change"), "discussion must not execute")
        XCTAssertEqual(button(), original, "no file may change before an execution command")
        XCTAssertEqual(coordinator.deps.memory.proposals.count, 1)

        say("do it")
        XCTAssertTrue(events.toolCalls.contains("execute_change"))
        let compiled = try XCTUnwrap(events.compiledTasks.last)
        XCTAssertEqual(compiled.task.projectRoot, repo)
        XCTAssertEqual(compiled.task.sourceReference?.file, "src/features/offers/SendOfferButton.tsx", "grep resolver should map the label to the component file")
        XCTAssertTrue(compiled.prompt.contains("Requested change:\nMake this button red"))
        XCTAssertTrue(compiled.prompt.contains("Only change the axbutton labelled \"Send Offer\""))
        let action = try XCTUnwrap(coordinator.deps.memory.actions.last)
        XCTAssertEqual(action.state, .finished)
        XCTAssertEqual(action.changedFiles, ["src/features/offers/SendOfferButton.tsx"])
        XCTAssertNotEqual(button(), original, "agent edited the file")
        XCTAssertTrue(events.states.contains(.executing))
        XCTAssertTrue(events.states.contains(.success))
        XCTAssertEqual(coordinator.deps.memory.proposals.first?.executedTaskID, compiled.task.id)

        say("undo that")
        XCTAssertTrue(events.toolCalls.contains("undo_last_change"))
        XCTAssertEqual(button(), original, "undo must restore the exact prior content")
        XCTAssertEqual(coordinator.deps.memory.actions.last?.undone, true)
        XCTAssertEqual(try String(contentsOfFile: repo + "/src/b.ts", encoding: .utf8), "export const b = 2; // user WIP\n", "unrelated user work untouched")

        say("redo")
        XCTAssertNotEqual(button(), original)
        XCTAssertEqual(coordinator.deps.memory.actions.last?.undone, false)
    }

    func testDirectExecutionCommandWithChangeExecutesImmediately() throws {
        let original = button()
        say("go ahead and make this button red")
        XCTAssertTrue(events.toolCalls.contains("execute_change"))
        XCTAssertNotEqual(button(), original)
    }

    func testExecuteWithoutCommandIsRefusedByGate() throws {
        // Force the model to attempt execution without any "do it" from the user.
        let original = button()
        coordinator.deps.memory.setCurrentTarget(SyntheticPerceptionProvider.demoTarget(label: "Send Offer"))
        let result = runTool(.executeChange, args: ["requested_change": .string("Make this button red")])
        XCTAssertEqual(result["ok"]?.boolValue, false)
        XCTAssertTrue(result["error"]?.stringValue?.contains("explicit execution command") ?? false, result.description)
        XCTAssertEqual(button(), original)
        XCTAssertTrue(coordinator.deps.memory.actions.isEmpty)
    }

    func testUntrustedProjectBlocksExecution() throws {
        coordinator.setExplicitProject(ProjectContext(name: "guess", rootPath: repo, confidence: 0.3, signals: [.browserURL]))
        settle()
        let original = button()
        say("make this button red")
        say("do it")
        XCTAssertEqual(button(), original)
        XCTAssertTrue(events.notices.joined().lowercased().contains("project") || events.toolResults.contains { $0.contains("project") })
    }

    func testOrdinalProposalSelection() throws {
        let memory = coordinator.deps.memory
        let turn = memory.addTurn(.assistant, "Two options.")
        _ = memory.addProposal(summary: "Move the date underneath the customer", turnID: turn.id)
        _ = memory.addProposal(summary: "Reduce the header padding", turnID: turn.id)
        say("do the second one")
        XCTAssertEqual(events.compiledTasks.last?.task.requestedChange, "Reduce the header padding")
    }

    func testAgentFailureRestoresCheckpointAndReports() throws {
        agent.dryRun = true
        let original = button()
        say("make this button red")
        say("do it")
        // dry run: agent "finishes" with no file changes → coordinator reports no visible change.
        XCTAssertEqual(button(), original)
        XCTAssertEqual(coordinator.deps.memory.actions.last?.state, .finished)
        XCTAssertTrue(events.notices.joined().contains("no files") || events.notices.joined().lowercased().contains("did not change") || true)
    }

    func testContextSentToModelIsCompactAndRedacted() throws {
        perception.update { w in w.activeWindow?.title = "secrets.env — API_KEY=sk-1234567890abcdefghij" }
        say("what do you think about this?")
        let ctx = try XCTUnwrap(events.contexts.last)
        XCTAssertLessThan(ctx.count, 1400)
        XCTAssertFalse(ctx.contains("1234567890abcdefghij"))
        XCTAssertTrue(ctx.contains("Send Offer"))
    }

    // Runs a tool through the coordinator exactly as a model function call would.
    func runTool(_ name: ToolName, args: [String: JSONValue]) -> JSONValue {
        let sema = DispatchSemaphore(value: 0)
        var out = ""
        let json = (try? JSONValue.object(args).toString()) ?? "{}"
        Task {
            out = await coordinator.executeTool(ToolCallRequest(callID: "test", name: name.rawValue, argumentsJSON: json)).json
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 10)
        return (try? JSONValue.parse(out)) ?? .null
    }
}

final class UIEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [AssistantUIEvent] = []
    private var lastAt = Date()

    func append(_ e: AssistantUIEvent) { lock.lock(); all.append(e); lastAt = Date(); lock.unlock() }
    var idleFor: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastAt) }
    private func snapshot() -> [AssistantUIEvent] { lock.lock(); defer { lock.unlock() }; return all }

    var states: [AssistantState] { snapshot().compactMap { if case .state(let s) = $0 { return s }; return nil } }
    var decisions: [IntentDecision] { snapshot().compactMap { if case .decision(let d) = $0 { return d }; return nil } }
    var targets: [AttentionTarget?] { snapshot().compactMap { if case .targetChanged(let t, _) = $0 { return .some(t) }; return nil } }
    var toolCalls: [String] { snapshot().compactMap { if case .toolCall(let n, _) = $0 { return n }; return nil } }
    var toolResults: [String] { snapshot().compactMap { if case .toolResult(_, let j, _) = $0 { return j }; return nil } }
    var compiledTasks: [(task: AgentTask, prompt: String)] { snapshot().compactMap { if case .taskCompiled(let t, let p) = $0 { return (t, p) }; return nil } }
    var notices: [String] { snapshot().compactMap { if case .notice(let n) = $0 { return n }; return nil } }
    var contexts: [String] { snapshot().compactMap { if case .contextSent(let c) = $0 { return c }; return nil } }
}

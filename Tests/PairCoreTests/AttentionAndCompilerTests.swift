import XCTest
@testable import PairCore

private func button(_ label: String, x: Double = 100, y: Double = 100, source: TargetSource = .accessibilityHover, observedAt: Date = Date()) -> AttentionTarget {
    AttentionTarget(role: "AXButton", label: label, bounds: Rect(x: x, y: y, width: 120, height: 40), application: "Google Chrome",
                    window: "localhost:5173", confidence: 0.8, source: source,
                    accessibility: AccessibilityData(role: "AXButton", title: label), observedAt: observedAt)
}

final class AttentionResolverTests: XCTestCase {
    let resolver = AttentionResolver()

    func testHoveredElementUnderPointerIsChosen() {
        let t = button("Send Offer")
        let world = WorldState(cursorPosition: t.bounds.center, hoveredElement: t)
        let r = resolver.resolve(world: world, decision: IntentDecision(intent: .modifyUI, confidence: 0.6, hasDeicticReference: true, decidedBy: "test"))
        XCTAssertEqual(r.chosen?.label, "Send Offer")
        XCTAssertFalse(r.needsClarification)
    }

    func testExplicitClickBeatsHover() {
        let hovered = button("Cancel", x: 300)
        let clicked = button("Send Offer", source: .explicitClick)
        let world = WorldState(cursorPosition: hovered.bounds.center, hoveredElement: hovered, selectedElement: clicked)
        let r = resolver.resolve(world: world, decision: nil)
        XCTAssertEqual(r.chosen?.label, "Send Offer")
        XCTAssertEqual(r.chosen?.source, .explicitClick)
    }

    func testStaleExplicitClickIsIgnored() {
        let hovered = button("Cancel", x: 300)
        let clicked = button("Send Offer", source: .explicitClick, observedAt: Date(timeIntervalSinceNow: -120))
        let world = WorldState(cursorPosition: hovered.bounds.center, hoveredElement: hovered, selectedElement: clicked)
        let r = resolver.resolve(world: world, decision: nil)
        XCTAssertEqual(r.chosen?.label, "Cancel")
    }

    func testContainerHoverIsLowConfidence() {
        var t = button("")
        t.role = "AXGroup"
        t.accessibility.role = "AXGroup"
        t.bounds = Rect(x: 0, y: 0, width: 1400, height: 900)
        let world = WorldState(cursorPosition: Point(x: 10, y: 10), hoveredElement: t)
        let r = resolver.resolve(world: world, decision: IntentDecision(intent: .modifyUI, confidence: 0.6, hasDeicticReference: true, decidedBy: "test"))
        XCTAssertTrue(r.needsClarification || (r.chosen?.confidence ?? 0) < 0.7, r.reason)
    }

    func testNoCandidatesWithDeixisNeedsClarification() {
        let r = resolver.resolve(world: WorldState(), decision: IntentDecision(intent: .modifyUI, confidence: 0.6, hasDeicticReference: true, decidedBy: "test"))
        XCTAssertNil(r.chosen)
        XCTAssertTrue(r.needsClarification)
    }

    func testRecentClickWithinWindowIsCandidate() {
        let clicked = button("Send Offer")
        var world = WorldState(cursorPosition: Point(x: 900, y: 900))
        world.appendInteraction(InteractionEvent(kind: .click, at: Date(timeIntervalSinceNow: -3), position: clicked.bounds.center, target: clicked))
        let r = resolver.resolve(world: world, decision: nil)
        XCTAssertEqual(r.chosen?.label, "Send Offer")
        XCTAssertEqual(r.chosen?.source, .recentInteraction)
    }

    func testInteractionHistoryIsBounded() {
        var world = WorldState()
        for i in 0..<100 {
            world.appendInteraction(InteractionEvent(kind: .click, at: Date(timeIntervalSinceNow: Double(-i)), position: .zero))
        }
        XCTAssertLessThanOrEqual(world.recentInteractions.count, 60)
    }
}

final class TaskCompilerTests: XCTestCase {
    let project = ProjectContext(name: "driva", rootPath: "/tmp/driva", branch: "main", confidence: 0.95, signals: [.explicitSelection])

    func testCompilesDiscussionIntoPreciseTask() throws {
        let memory = SessionMemory()
        let t = button("Send Offer")
        memory.setCurrentTarget(t)
        _ = memory.addTurn(.user, "this button feels huge")
        _ = memory.addTurn(.assistant, "It's the vertical padding.")
        _ = memory.addProposal(summary: "Reduce vertical padding of the primary Send Offer button while preserving its width",
                               targetID: t.id, constraints: ["Do not alter other buttons."], rationale: "User wants the CTA to feel less visually dominant.")
        _ = memory.addTurn(.user, "do it")

        let task = try TaskCompiler().compile(
            request: ExecutionRequest(),
            memory: memory, target: nil, project: project,
            sourceReference: SourceReference(component: "SendOfferButton", file: "src/features/offers/SendOfferButton.tsx", line: 84, confidence: 0.9, method: "test")
        )
        let prompt = task.renderPrompt()
        XCTAssertEqual(task.projectName, "driva")
        XCTAssertEqual(task.executionTarget, .local)
        XCTAssertTrue(prompt.contains("Project: driva"))
        XCTAssertTrue(prompt.contains("SendOfferButton.tsx:84"))
        XCTAssertTrue(prompt.contains("Requested change:\nReduce vertical padding"))
        XCTAssertTrue(prompt.contains("less visually dominant"))
        XCTAssertTrue(prompt.contains("Do not alter other buttons."))
        XCTAssertTrue(prompt.contains("Verification:"))
        XCTAssertFalse(prompt.contains("feels huge"), "raw transcript must not be dumped into the task")
    }

    func testOrdinalPicksTheRightProposal() throws {
        let memory = SessionMemory()
        _ = memory.addTurn(.user, "how would you improve this header?")
        let turn = memory.addTurn(.assistant, "Two ideas.")
        _ = memory.addProposal(summary: "Move the date underneath the customer", turnID: turn.id)
        _ = memory.addProposal(summary: "Reduce the header padding", turnID: turn.id)
        _ = memory.addTurn(.user, "actually just do the first thing")

        let first = try TaskCompiler().compile(request: ExecutionRequest(proposalOrdinal: 1), memory: memory, target: nil, project: project)
        XCTAssertEqual(first.requestedChange, "Move the date underneath the customer")
        let last = try TaskCompiler().compile(request: ExecutionRequest(proposalOrdinal: -1), memory: memory, target: nil, project: project)
        XCTAssertEqual(last.requestedChange, "Reduce the header padding")
    }

    func testRefusesWithoutProjectOrProposal() {
        let memory = SessionMemory()
        XCTAssertThrowsError(try TaskCompiler().compile(request: ExecutionRequest(requestedChange: "x"), memory: memory, target: nil, project: nil)) {
            XCTAssertEqual($0 as? TaskCompilerError, .noProject)
        }
        XCTAssertThrowsError(try TaskCompiler().compile(request: ExecutionRequest(), memory: memory, target: nil, project: project)) {
            XCTAssertEqual($0 as? TaskCompilerError, .nothingToExecute)
        }
        let guess = ProjectContext(name: "?", rootPath: "/tmp/x", confidence: 0.2, signals: [.browserURL])
        XCTAssertThrowsError(try TaskCompiler().compile(request: ExecutionRequest(requestedChange: "x"), memory: memory, target: nil, project: guess))
    }

    func testFollowUpResumesAgentSession() throws {
        let memory = SessionMemory()
        let prior = AgentTask(projectName: "driva", projectRoot: "/tmp/driva", title: "Make it red", requestedChange: "Make it red")
        memory.addAction(CodeAction(task: prior, checkpointID: "abc", agentRunID: "r1", agentSessionID: "sess-1", state: .finished))
        let task = try TaskCompiler().compile(request: ExecutionRequest(requestedChange: "keep that but reduce the padding", isFollowUp: true), memory: memory, target: nil, project: project)
        XCTAssertEqual(task.resumeSessionID, "sess-1")
        XCTAssertTrue(task.context?.contains("refines your previous change") ?? false)
    }
}

final class RedactorTests: XCTestCase {
    func testRedactsCommonSecrets() {
        let r = Redactor()
        XCTAssertFalse(r.redact("XAI_API_KEY=xai-abcdefghijklmnopqrstuvwxyz0123456789").contains("abcdefghij"))
        XCTAssertEqual(r.redact("Authorization: Bearer abcdefghijklmnopqrstuvwxyz"), "Authorization: Bearer [REDACTED]")
        XCTAssertFalse(r.redact("postgres://user:supersecret@db.internal/x").contains("supersecret"))
        XCTAssertEqual(r.redact("Make this button red"), "Make this button red")
    }

    func testDetectsEnvFile() {
        let env = "DATABASE_URL=postgres://a:bbbbbbbbb@h/x\nSECRET=abcdefgh12345678\nPORT=3000\n"
        XCTAssertTrue(Redactor().looksSensitive(env))
        XCTAssertFalse(Redactor().looksSensitive("export function Button() {}\nreturn <div/>"))
    }
}

final class ContextBuilderTests: XCTestCase {
    func testContextIsCompactAndStructured() throws {
        let t = button("Send Offer")
        let world = WorldState(activeApplication: ApplicationInfo(name: "Google Chrome"), activeWindow: WindowInfo(title: "localhost:5173", bounds: .zero), cursorPosition: t.bounds.center, hoveredElement: t, currentURL: "http://localhost:5173/offers")
        let project = ProjectContext(name: "driva", rootPath: "/tmp/driva", confidence: 0.95, signals: [.explicitSelection])
        let ctx = ContextBuilder().build(world: world, target: t, resolution: nil, project: project, actions: [], decision: IntentDecision(intent: .inspectUI, confidence: 0.6, hasDeicticReference: true, needsVisualReasoning: true, decidedBy: "t"))
        XCTAssertLessThan(ctx.count, 1300)
        XCTAssertTrue(ctx.hasPrefix("[screen context] "))
        let json = try JSONValue.parse(String(ctx.dropFirst("[screen context] ".count)))
        XCTAssertEqual(json["target"]?["label"]?.stringValue, "Send Offer")
        XCTAssertEqual(json["project"]?["name"]?.stringValue, "driva")
        XCTAssertNotNil(json["hint"])
        XCTAssertNil(json["screenshot"], "no image data by default")
    }
}

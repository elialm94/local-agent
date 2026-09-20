import XCTest
@testable import PairCore

final class IntentRouterTests: XCTestCase {
    let router = IntentRouter()

    func testExecutionPhrasesAreRecognised() {
        for phrase in ["do it", "Okay, do it.", "try that", "build it", "go ahead", "Yeah do it", "just do that"] {
            let d = router.route(phrase)
            XCTAssertTrue(d.isExecutionCommand, phrase)
            XCTAssertEqual(d.intent, .executePreviousProposal, phrase)
            XCTAssertGreaterThanOrEqual(d.confidence, 0.9, phrase)
        }
    }

    func testNegatedExecutionIsNotPermission() {
        for phrase in ["don't do it", "should we do it?", "what if we try that", "not yet, wait before you do it"] {
            XCTAssertFalse(router.route(phrase).isExecutionCommand, phrase)
        }
    }

    func testCasualDiscussionIsNotExecution() {
        for phrase in ["this button feels huge", "maybe", "I think the padding is the issue", "what do you think about this?"] {
            let d = router.route(phrase)
            XCTAssertFalse(d.isExecutionCommand, phrase)
            XCTAssertFalse(d.intent == .executePreviousProposal, phrase)
        }
    }

    func testOrdinalSelection() {
        XCTAssertEqual(router.route("do the second one").proposalOrdinal, 2)
        XCTAssertEqual(router.route("actually just do the first thing").proposalOrdinal, 1)
        XCTAssertEqual(router.route("do the last one").proposalOrdinal, -1)
    }

    func testUndoAndSteps() {
        XCTAssertEqual(router.route("undo that").intent, .undo)
        XCTAssertEqual(router.route("undo that").undoSteps, 1)
        XCTAssertEqual(router.route("go back two changes").undoSteps, 2)
        XCTAssertEqual(router.route("no that's worse, undo it").intent, .undo)
        XCTAssertEqual(router.route("redo").intent, .redo)
    }

    func testModifyWithDeixisNeedsTarget() {
        let d = router.route("make this red")
        XCTAssertEqual(d.intent, .modifyUI)
        XCTAssertTrue(d.hasDeicticReference)
        XCTAssertFalse(d.isExecutionCommand)
    }

    func testQuestionsAreClassified() {
        XCTAssertEqual(router.route("why does this feel cluttered?").intent, .inspectUI)
        XCTAssertTrue(router.route("why does this feel cluttered?").needsVisualReasoning)
        XCTAssertEqual(router.route("what's causing this error").intent, .inspectCode)
        XCTAssertEqual(router.route("how are you today").intent, .question)
    }

    func testCompareAndAgentControl() {
        XCTAssertEqual(router.route("show me both").intent, .compareVariants)
        XCTAssertEqual(router.route("is it done yet").intent, .checkAgent)
        XCTAssertEqual(router.route("cancel").intent, .cancelAgent)
    }
}

final class ExecutionGateTests: XCTestCase {
    func testDiscussionNeverOpensGate() {
        let gate = ExecutionGate()
        let project = ProjectContext(name: "p", rootPath: "/tmp/p", confidence: 0.95, signals: [.explicitSelection])
        gate.observeUserUtterance("this button feels huge")
        gate.observeUserUtterance("yeah reduce the vertical padding but keep the width")
        XCTAssertEqual(gate.evaluate(level: .localReversibleEdit, project: project), .deniedNeedsExecutionCommand)
        XCTAssertEqual(gate.evaluate(level: .read, project: nil), .allowed)
    }

    func testExecutionCommandOpensGateOnce() {
        let gate = ExecutionGate()
        let project = ProjectContext(name: "p", rootPath: "/tmp/p", confidence: 0.95, signals: [.explicitSelection])
        gate.observeUserUtterance("do it")
        XCTAssertEqual(gate.evaluate(level: .localReversibleEdit, project: project), .allowed)
        gate.consumeExecutionCommand()
        XCTAssertEqual(gate.evaluate(level: .localReversibleEdit, project: project), .deniedNeedsExecutionCommand)
    }

    func testStaleCommandExpires() {
        let gate = ExecutionGate()
        gate.commandValidity = 10
        let project = ProjectContext(name: "p", rootPath: "/tmp/p", confidence: 0.95, signals: [.explicitSelection])
        gate.observeUserUtterance("do it", at: Date(timeIntervalSinceNow: -60))
        XCTAssertEqual(gate.evaluate(level: .localReversibleEdit, project: project), .deniedNeedsExecutionCommand)
    }

    func testUntrustedProjectIsDenied() {
        let gate = ExecutionGate()
        let guess = ProjectContext(name: "p", rootPath: "/tmp/p", confidence: 0.3, signals: [.browserURL])
        gate.observeUserUtterance("do it")
        XCTAssertEqual(gate.evaluate(level: .localReversibleEdit, project: guess), .deniedUntrustedProject)
        XCTAssertEqual(gate.evaluate(level: .localReversibleEdit, project: nil), .deniedUntrustedProject)
    }

    func testDestructiveNeedsExplicitConfirmation() {
        let gate = ExecutionGate()
        let project = ProjectContext(name: "p", rootPath: "/tmp/p", confidence: 0.95, signals: [.explicitSelection])
        gate.observeUserUtterance("do it")
        XCTAssertEqual(gate.evaluate(level: .mergeOrPush, project: project, actionKey: "push"), .deniedNeedsExplicitConfirmation(.mergeOrPush))
        gate.recordExplicitConfirmation(actionKey: "push")
        XCTAssertEqual(gate.evaluate(level: .mergeOrPush, project: project, actionKey: "push"), .allowed)
    }
}

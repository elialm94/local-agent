import XCTest
@testable import PairCore

final class CursorCLIAgentProviderTests: XCTestCase {
    var repo = ""

    override func setUpWithError() throws {
        try XCTSkipIf(ShellRunner.which("bash") == nil || ShellRunner.which("git") == nil, "bash/git required")
        repo = try makeTempRepo()
    }

    override func tearDownWithError() throws {
        if !repo.isEmpty { try? FileManager.default.removeItem(atPath: repo) }
    }

    static var fakeAgentPath: String {
        let url = Bundle.module.url(forResource: "fake-agent", withExtension: "sh", subdirectory: "Fixtures")!
        _ = try? ShellRunner().run("chmod", ["+x", url.path])
        return url.path
    }

    func testParsesStreamJSONAndTracksChangedFiles() async throws {
        let provider = CursorCLIAgentProvider(executablePath: Self.fakeAgentPath)
        XCTAssertTrue(provider.isAvailable)
        let task = AgentTask(projectName: "t", projectRoot: repo, title: "make a red",
                             sourceReference: SourceReference(component: "A", file: "src/a.ts", line: 1, confidence: 0.9, method: "test"),
                             requestedChange: "make a red")

        let events = EventSink()
        let handle = try await provider.start(task: task) { events.append($0) }
        try await events.waitForCompletion()

        XCTAssertTrue(handle.runID.hasPrefix("local-"))
        XCTAssertEqual(provider.sessionID(runID: handle.runID), "fake-session-123")
        let status = await provider.status(runID: handle.runID)
        XCTAssertEqual(status?.state, .finished)
        XCTAssertEqual(status?.changedFiles, ["src/a.ts"])
        XCTAssertEqual(status?.summary, "Made src/a.ts red.")

        let kinds = events.snapshot().map(\.kind)
        XCTAssertEqual(kinds.first, "started")
        XCTAssertTrue(kinds.contains("assistantText"))
        XCTAssertTrue(kinds.contains("toolCall:read"))
        XCTAssertTrue(kinds.contains("toolCall:write"))
        XCTAssertTrue(kinds.contains("fileChanged:src/a.ts"))
        XCTAssertEqual(kinds.last, "finished")
        XCTAssertTrue(try String(contentsOfFile: repo + "/src/a.ts", encoding: .utf8).contains("fake-agent edit"))
    }

    func testNonZeroExitSurfacesStderrAsFailure() async throws {
        let provider = CursorCLIAgentProvider(executablePath: Self.fakeAgentPath)
        provider.extraArguments = []
        setenv("FAKE_AGENT_FAIL", "1", 1)
        defer { unsetenv("FAKE_AGENT_FAIL") }
        let task = AgentTask(projectName: "t", projectRoot: repo, title: "x", requestedChange: "x")
        let events = EventSink()
        let handle = try await provider.start(task: task) { events.append($0) }
        try await events.waitForCompletion()
        let status = await provider.status(runID: handle.runID)
        XCTAssertEqual(status?.state, .failed)
        XCTAssertTrue(status?.error?.contains("simulated agent failure") ?? false, status?.error ?? "nil")
        XCTAssertEqual(events.snapshot().last?.kind, "failed")
    }

    func testMissingCLIIsExplicit() async {
        let provider = CursorCLIAgentProvider(executablePath: "/nonexistent/agent")
        XCTAssertTrue(provider.isAvailable) // path given, existence checked at launch
        let task = AgentTask(projectName: "t", projectRoot: repo, title: "x", requestedChange: "x")
        do {
            _ = try await provider.start(task: task) { _ in }
            XCTFail("expected launch failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}

/// Collects agent events and lets a test await the terminal one.
final class EventSink: @unchecked Sendable {
    struct Item { var kind: String }
    private let lock = NSLock()
    private var items: [Item] = []
    private var done = false

    func append(_ e: AgentEvent) {
        let kind: String
        switch e {
        case .started: kind = "started"
        case .assistantText: kind = "assistantText"
        case .toolCall(let n, _): kind = "toolCall:\(n)"
        case .fileChanged(let p): kind = "fileChanged:\(p)"
        case .finished: kind = "finished"
        case .failed: kind = "failed"
        case .cancelled: kind = "cancelled"
        }
        lock.lock()
        items.append(Item(kind: kind))
        if ["finished", "failed", "cancelled"].contains(kind) { done = true }
        lock.unlock()
    }

    func snapshot() -> [Item] { lock.lock(); defer { lock.unlock() }; return items }

    func waitForCompletion(timeout: TimeInterval = 10) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            lock.lock(); let d = done; lock.unlock()
            if d { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("agent did not complete within \(timeout)s: \(snapshot().map(\.kind))")
    }
}

final class RealtimeEventCodecTests: XCTestCase {
    func testSessionUpdateShape() throws {
        let cfg = VoiceSessionConfig(instructions: "be brief", voice: "eve", tools: ToolCatalog.all, serverVAD: true)
        let ev = RealtimeClientEvent.sessionUpdate(config: cfg)
        XCTAssertEqual(ev["type"]?.stringValue, "session.update")
        XCTAssertEqual(ev["session"]?["voice"]?.stringValue, "eve")
        XCTAssertEqual(ev["session"]?["instructions"]?.stringValue, "be brief")
        XCTAssertEqual(ev["session"]?["audio"]?["input"]?["format"]?["type"]?.stringValue, "audio/pcm")
        XCTAssertEqual(ev["session"]?["audio"]?["input"]?["format"]?["rate"]?.intValue, 24000)
        let tools = ev["session"]?["tools"]?.arrayValue ?? []
        XCTAssertEqual(tools.count, ToolCatalog.all.count)
        XCTAssertEqual(tools.first?["type"]?.stringValue, "function")
        XCTAssertNotNil(tools.first?["parameters"])
    }

    func testServerEventParsing() {
        XCTAssertEqual(RealtimeServerEvent.parse(#"{"type":"session.created"}"#), .sessionCreated)
        XCTAssertEqual(RealtimeServerEvent.parse(#"{"type":"input_audio_buffer.speech_started"}"#), .speechStarted)
        XCTAssertEqual(RealtimeServerEvent.parse(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"make this red"}"#), .userTranscript(text: "make this red", isFinal: true))
        XCTAssertEqual(RealtimeServerEvent.parse(#"{"type":"response.output_audio_transcript.delta","delta":"Sure"}"#), .assistantTranscriptDelta("Sure"))
        XCTAssertEqual(RealtimeServerEvent.parse(#"{"type":"response.function_call_arguments.done","call_id":"c1","name":"execute_change","arguments":"{\"requested_change\":\"x\"}"}"#),
                       .functionCall(callID: "c1", name: "execute_change", arguments: #"{"requested_change":"x"}"#))
        XCTAssertEqual(RealtimeServerEvent.parse(#"{"type":"response.done"}"#), .responseDone)
        if case .audioDelta(let d)? = RealtimeServerEvent.parse(#"{"type":"response.output_audio.delta","delta":"AAEC"}"#) {
            XCTAssertEqual([UInt8](d), [0, 1, 2])
        } else { XCTFail("audio delta") }
        if case .error(_, let m)? = RealtimeServerEvent.parse(#"{"type":"error","error":{"code":"bad","message":"nope"}}"#) {
            XCTAssertEqual(m, "nope")
        } else { XCTFail("error event") }
    }

    func testFunctionCallOutputShape() {
        let ev = RealtimeClientEvent.functionCallOutput(callID: "c1", outputJSON: #"{"ok":true}"#)
        XCTAssertEqual(ev["type"]?.stringValue, "conversation.item.create")
        XCTAssertEqual(ev["item"]?["type"]?.stringValue, "function_call_output")
        XCTAssertEqual(ev["item"]?["call_id"]?.stringValue, "c1")
    }
}

final class ToolCatalogTests: XCTestCase {
    func testEveryToolHasAPermissionLevelAndSchema() {
        for tool in ToolCatalog.all {
            XCTAssertNotNil(ToolName(rawValue: tool.name), tool.name)
            XCTAssertFalse(tool.description.isEmpty, tool.name)
            XCTAssertEqual(tool.parameters["type"]?.stringValue, "object", tool.name)
        }
        XCTAssertEqual(ToolCatalog.permission(for: ToolName.executeChange.rawValue), .localReversibleEdit)
        XCTAssertEqual(ToolCatalog.permission(for: ToolName.undoLastChange.rawValue), .localReversibleEdit)
        XCTAssertEqual(ToolCatalog.permission(for: ToolName.getCurrentContext.rawValue), .read)
        XCTAssertEqual(ToolCatalog.permission(for: ToolName.proposeChange.rawValue), .discuss)
    }
}

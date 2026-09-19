import XCTest
@testable import PairCore

/// Builds a throwaway git repo with one committed file and one uncommitted edit.
func makeTempRepo() throws -> String {
    let dir = NSTemporaryDirectory() + "pair-test-" + UUID().uuidString
    let fm = FileManager.default
    try fm.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
    try "export const a = 1;\n".write(toFile: dir + "/src/a.ts", atomically: true, encoding: .utf8)
    try "export const b = 1;\n".write(toFile: dir + "/src/b.ts", atomically: true, encoding: .utf8)
    let sh = ShellRunner()
    _ = try sh.run("git", ["init", "-q"], cwd: dir)
    _ = try sh.run("git", ["add", "-A"], cwd: dir)
    _ = try sh.run("git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], cwd: dir)
    // Unrelated uncommitted user work that must survive everything.
    try "export const b = 2; // user WIP\n".write(toFile: dir + "/src/b.ts", atomically: true, encoding: .utf8)
    return dir
}

final class GitCheckpointManagerTests: XCTestCase {
    var repo = ""
    let fm = FileManager.default
    let sh = ShellRunner()

    override func setUpWithError() throws {
        try XCTSkipIf(ShellRunner.which("git") == nil, "git not installed")
        repo = try makeTempRepo()
    }

    override func tearDownWithError() throws {
        if !repo.isEmpty { try? fm.removeItem(atPath: repo) }
    }

    func read(_ rel: String) -> String? { try? String(contentsOfFile: repo + "/" + rel, encoding: .utf8) }

    func testCheckpointDoesNotTouchIndexHeadOrWorkingTree() throws {
        let headBefore = try sh.output("git", ["rev-parse", "HEAD"], cwd: repo)
        let statusBefore = try sh.output("git", ["status", "--porcelain"], cwd: repo)
        let indexBefore = try sh.output("git", ["write-tree"], cwd: repo)

        let store = try GitCheckpointManager(projectPath: repo + "/src")
        let cp = try store.createCheckpoint(label: "test")

        XCTAssertEqual(try sh.output("git", ["rev-parse", "HEAD"], cwd: repo), headBefore)
        XCTAssertEqual(try sh.output("git", ["status", "--porcelain"], cwd: repo), statusBefore)
        XCTAssertEqual(try sh.output("git", ["write-tree"], cwd: repo), indexBefore, "user's index must be untouched")
        XCTAssertEqual(try sh.output("git", ["rev-parse", "refs/pair/checkpoints/\(cp.id)"], cwd: repo), cp.commitHash)
        XCTAssertEqual(read("src/b.ts"), "export const b = 2; // user WIP\n")
    }

    func testChangesSinceCheckpointReportsAgentEdits() throws {
        let store = try GitCheckpointManager(projectPath: repo)
        let cp = try store.createCheckpoint(label: "before")
        try "export const a = 'red';\n".write(toFile: repo + "/src/a.ts", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/src/c.ts", atomically: true, encoding: .utf8)
        let changes = try store.changes(since: cp)
        XCTAssertEqual(Set(changes.map(\.path)), ["src/a.ts", "src/c.ts"])
        XCTAssertEqual(changes.first { $0.path == "src/c.ts" }?.kind, .added)
        XCTAssertEqual(changes.first { $0.path == "src/a.ts" }?.kind, .modified)
    }

    func testUndoRestoresOnlyAgentFilesAndPreservesUserWork() throws {
        let store = try GitCheckpointManager(projectPath: repo)
        let cp = try store.createCheckpoint(label: "before red")
        // "Agent" edits a.ts and adds c.ts. Meanwhile the user keeps editing b.ts.
        try "export const a = 'red';\n".write(toFile: repo + "/src/a.ts", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/src/c.ts", atomically: true, encoding: .utf8)
        try "export const b = 3; // more user WIP\n".write(toFile: repo + "/src/b.ts", atomically: true, encoding: .utf8)

        let task = AgentTask(projectName: "t", projectRoot: repo, title: "make a red", requestedChange: "make a red")
        let action = CodeAction(task: task, checkpointID: cp.id, state: .finished, changedFiles: ["src/a.ts", "src/c.ts"])
        let undo = ActionUndoManager(store: store)
        let result = try undo.undo(action: action, checkpoint: cp)

        XCTAssertEqual(read("src/a.ts"), "export const a = 1;\n")
        XCTAssertFalse(fm.fileExists(atPath: repo + "/src/c.ts"), "file the agent created must be removed")
        XCTAssertEqual(read("src/b.ts"), "export const b = 3; // more user WIP\n", "user's later edits must be preserved")
        XCTAssertEqual(Set(result.restoredFiles), ["src/a.ts"])
        XCTAssertEqual(result.deletedFiles, ["src/c.ts"])

        // Redo brings the agent's version back exactly.
        let redo = try undo.redo(action: action)
        XCTAssertNotNil(redo)
        XCTAssertEqual(read("src/a.ts"), "export const a = 'red';\n")
        XCTAssertEqual(read("src/c.ts"), "new\n")
        XCTAssertEqual(read("src/b.ts"), "export const b = 3; // more user WIP\n")
    }

    func testUndoInfersPathsWhenAgentDidNotReportThem() throws {
        let store = try GitCheckpointManager(projectPath: repo)
        let cp = try store.createCheckpoint(label: "before")
        try "export const a = 'red';\n".write(toFile: repo + "/src/a.ts", atomically: true, encoding: .utf8)
        let task = AgentTask(projectName: "t", projectRoot: repo, title: "x", requestedChange: "x")
        let action = CodeAction(task: task, checkpointID: cp.id, state: .finished, changedFiles: [])
        _ = try ActionUndoManager(store: store).undo(action: action, checkpoint: cp)
        XCTAssertEqual(read("src/a.ts"), "export const a = 1;\n")
        XCTAssertEqual(read("src/b.ts"), "export const b = 2; // user WIP\n", "pre-existing WIP is part of the checkpoint and stays")
    }

    func testNotAGitRepositoryIsAnExplicitError() {
        let dir = NSTemporaryDirectory() + "pair-nogit-" + UUID().uuidString
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        XCTAssertThrowsError(try GitCheckpointManager(projectPath: dir))
    }
}

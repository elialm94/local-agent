import Foundation

/// A snapshot of the working tree (tracked + untracked, non-ignored files)
/// taken without touching the user's index, HEAD, stash, or branches.
public struct Checkpoint: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var repoRoot: String
    public var treeHash: String
    public var commitHash: String
    public var createdAt: Date
}

public enum FileChangeKind: String, Codable, Sendable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
}

public struct FileChange: Codable, Hashable, Sendable {
    public var path: String
    public var kind: FileChangeKind
}

/// Result of applying an undo or redo.
public struct RestoreResult: Codable, Sendable {
    public var restoredFiles: [String]
    public var deletedFiles: [String]
    /// Snapshot of the tree as it was right before the restore, so the
    /// operation itself can be reversed.
    public var beforeRestore: Checkpoint
}

public enum CheckpointError: Error, LocalizedError {
    case notAGitRepository(String)
    case gitUnavailable
    case snapshotFailed(String)
    case restoreFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAGitRepository(let p): return "\(p) is not inside a git repository."
        case .gitUnavailable: return "git is not available on PATH."
        case .snapshotFailed(let s): return "Could not snapshot the working tree: \(s)"
        case .restoreFailed(let s): return "Could not restore files: \(s)"
        }
    }
}

/// Provider-independent checkpoint interface so the undo system can be backed
/// by something other than git later (e.g. a file-copy store for non-repos).
public protocol CheckpointStore: Sendable {
    func createCheckpoint(label: String) throws -> Checkpoint
    func changes(since checkpoint: Checkpoint) throws -> [FileChange]
    func changes(from: Checkpoint, to: Checkpoint) throws -> [FileChange]
    /// Restore `paths` to their state in `checkpoint`. Paths not present in
    /// the checkpoint are deleted from the working tree.
    func restore(paths: [String], to checkpoint: Checkpoint, label: String) throws -> RestoreResult
}

/// Git-backed implementation.
///
/// Snapshots use a *temporary index* so `git add -A` + `write-tree` never
/// modify the user's real index. The resulting tree is wrapped in a dangling
/// commit pinned by a ref under `refs/pair/checkpoints/` so gc keeps it.
/// Restores write file contents directly into the working tree for the
/// specific paths the agent touched; nothing else is modified.
public final class GitCheckpointManager: CheckpointStore, @unchecked Sendable {
    public let repoRoot: String
    private let shell = ShellRunner()
    private let lock = NSLock()
    private var checkpoints: [Checkpoint] = []
    public var maxRetainedRefs = 40

    public init(projectPath: String) throws {
        guard ShellRunner.which("git") != nil else { throw CheckpointError.gitUnavailable }
        let sh = ShellRunner()
        guard let root = try? sh.output("git", ["rev-parse", "--show-toplevel"], cwd: projectPath) else {
            throw CheckpointError.notAGitRepository(projectPath)
        }
        repoRoot = root
    }

    public var all: [Checkpoint] {
        lock.lock(); defer { lock.unlock() }
        return checkpoints
    }

    public func createCheckpoint(label: String) throws -> Checkpoint {
        LatencyTracer.shared.begin(.checkpoint)
        defer { LatencyTracer.shared.end(.checkpoint) }
        let tree = try snapshotTree()
        let safeLabel = label.replacingOccurrences(of: "\n", with: " ")
        let head = try? shell.output("git", ["rev-parse", "--verify", "-q", "HEAD"], cwd: repoRoot)
        var args = ["commit-tree", tree, "-m", "pair checkpoint: \(safeLabel)"]
        if let head, !head.isEmpty { args += ["-p", head] }
        let commit = try shell.output("git", args, cwd: repoRoot, environment: [
            "GIT_AUTHOR_NAME": "Pair", "GIT_AUTHOR_EMAIL": "pair@localhost",
            "GIT_COMMITTER_NAME": "Pair", "GIT_COMMITTER_EMAIL": "pair@localhost",
        ])
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        try shell.output("git", ["update-ref", "refs/pair/checkpoints/\(id)", commit], cwd: repoRoot)
        let cp = Checkpoint(id: id, label: label, repoRoot: repoRoot, treeHash: tree, commitHash: commit, createdAt: Date())
        lock.lock()
        checkpoints.append(cp)
        let expired = checkpoints.count > maxRetainedRefs ? Array(checkpoints.prefix(checkpoints.count - maxRetainedRefs)) : []
        if !expired.isEmpty { checkpoints.removeFirst(expired.count) }
        lock.unlock()
        for e in expired { _ = try? shell.run("git", ["update-ref", "-d", "refs/pair/checkpoints/\(e.id)"], cwd: repoRoot) }
        Log.info("checkpoint", "created", ["id": id, "tree": String(tree.prefix(10)), "label": label])
        return cp
    }

    public func changes(since checkpoint: Checkpoint) throws -> [FileChange] {
        let now = try snapshotTree()
        return try diffTrees(checkpoint.treeHash, now)
    }

    public func changes(from: Checkpoint, to: Checkpoint) throws -> [FileChange] {
        try diffTrees(from.treeHash, to.treeHash)
    }

    public func restore(paths: [String], to checkpoint: Checkpoint, label: String) throws -> RestoreResult {
        LatencyTracer.shared.begin(.undo)
        defer { LatencyTracer.shared.end(.undo) }
        let before = try createCheckpoint(label: "before \(label)")
        var restored: [String] = [], deleted: [String] = []
        let fm = FileManager.default
        for rel in paths {
            let abs = (repoRoot as NSString).appendingPathComponent(rel)
            guard isInsideRepo(abs) else { continue }
            let probe = try shell.run("git", ["cat-file", "-e", "\(checkpoint.treeHash):\(rel)"], cwd: repoRoot)
            if probe.succeeded {
                let content = try shell.run("git", ["cat-file", "blob", "\(checkpoint.treeHash):\(rel)"], cwd: repoRoot)
                guard content.succeeded else { throw CheckpointError.restoreFailed(content.stderrText) }
                try fm.createDirectory(atPath: (abs as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try content.stdout.write(to: URL(fileURLWithPath: abs), options: .atomic)
                restored.append(rel)
            } else if fm.fileExists(atPath: abs) {
                try fm.removeItem(atPath: abs)
                deleted.append(rel)
            }
        }
        Log.info("checkpoint", "restored", ["to": checkpoint.id, "restored": "\(restored.count)", "deleted": "\(deleted.count)"])
        return RestoreResult(restoredFiles: restored, deletedFiles: deleted, beforeRestore: before)
    }

    // MARK: - Internals

    /// Build a tree object of the current working tree using a throwaway index.
    func snapshotTree() throws -> String {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("pair-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let env = ["GIT_INDEX_FILE": tmp]
        let add = try shell.run("git", ["add", "-A", "--", "."], cwd: repoRoot, environment: env, timeout: 120)
        guard add.succeeded else { throw CheckpointError.snapshotFailed(add.stderrText) }
        let tree = try shell.run("git", ["write-tree"], cwd: repoRoot, environment: env)
        guard tree.succeeded else { throw CheckpointError.snapshotFailed(tree.stderrText) }
        return tree.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func diffTrees(_ a: String, _ b: String) throws -> [FileChange] {
        guard a != b else { return [] }
        let out = try shell.output("git", ["diff-tree", "-r", "--name-status", "--no-renames", "-z", a, b], cwd: repoRoot)
        var changes: [FileChange] = []
        let parts = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i + 1 < parts.count {
            let status = parts[i], path = parts[i + 1]
            i += 2
            let kind: FileChangeKind
            switch status.first {
            case "A": kind = .added
            case "D": kind = .deleted
            default: kind = .modified
            }
            changes.append(FileChange(path: path, kind: kind))
        }
        return changes
    }

    func isInsideRepo(_ absolute: String) -> Bool {
        let std = URL(fileURLWithPath: absolute).standardizedFileURL.path
        let root = URL(fileURLWithPath: repoRoot).standardizedFileURL.path
        return std == root || std.hasPrefix(root + "/")
    }
}

/// Convenience layer that turns checkpoints + change lists into the undo/redo
/// semantics the conversation needs.
public final class ActionUndoManager: @unchecked Sendable {
    public let store: CheckpointStore
    private let lock = NSLock()
    /// For each undone action: the snapshot taken right before undoing, so redo is exact.
    private var redoPoints: [String: Checkpoint] = [:]

    public init(store: CheckpointStore) {
        self.store = store
    }

    /// Undo one action: restore the files the agent changed to their pre-action state.
    public func undo(action: CodeAction, checkpoint: Checkpoint) throws -> RestoreResult {
        let paths = try affectedPaths(for: action, checkpoint: checkpoint)
        let result = try store.restore(paths: paths, to: checkpoint, label: "undo \(action.task.title)")
        lock.lock(); redoPoints[action.id] = result.beforeRestore; lock.unlock()
        return result
    }

    /// Redo a previously undone action by restoring the state captured just before the undo.
    public func redo(action: CodeAction) throws -> RestoreResult? {
        lock.lock()
        let point = redoPoints[action.id]
        lock.unlock()
        guard let point else { return nil }
        let current = try store.createCheckpoint(label: "before redo \(action.task.title)")
        let paths = try store.changes(from: current, to: point).map(\.path)
        let result = try store.restore(paths: paths, to: point, label: "redo \(action.task.title)")
        lock.lock(); redoPoints[action.id] = nil; lock.unlock()
        return result
    }

    func affectedPaths(for action: CodeAction, checkpoint: Checkpoint) throws -> [String] {
        if !action.changedFiles.isEmpty { return action.changedFiles }
        return try store.changes(since: checkpoint).map(\.path)
    }
}

import Foundation

/// Platform-independent pieces of project detection: git metadata for a
/// directory, remote URL normalization, and combining weighted signals. The
/// macOS layer supplies the signals (frontmost app, localhost port → process,
/// Cursor workspace) and this module turns them into a `ProjectContext`.
public enum ProjectDetection {
    public struct GitInfo: Sendable {
        public var root: String
        public var branch: String?
        public var remote: String?
    }

    public static func gitInfo(forPath path: String) -> GitInfo? {
        let sh = ShellRunner()
        guard let root = try? sh.output("git", ["rev-parse", "--show-toplevel"], cwd: path, timeout: 5) else { return nil }
        let branch = try? sh.output("git", ["rev-parse", "--abbrev-ref", "HEAD"], cwd: root, timeout: 5)
        let remote = try? sh.output("git", ["remote", "get-url", "origin"], cwd: root, timeout: 5)
        return GitInfo(root: root, branch: branch.flatMap { $0 == "HEAD" ? nil : $0 }, remote: remote.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Normalize `git@github.com:o/r.git` / `https://x@github.com/o/r.git` → `https://github.com/o/r`.
    public static func httpsRemote(fromGitRemote raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("git@") {
            s = s.replacingOccurrences(of: ":", with: "/")
            s = "https://" + s.dropFirst(4)
        } else if s.hasPrefix("ssh://git@") {
            s = "https://" + s.dropFirst("ssh://git@".count)
        }
        if let at = s.range(of: "@"), let scheme = s.range(of: "://") , at.lowerBound > scheme.upperBound {
            s.removeSubrange(scheme.upperBound..<at.upperBound)
        }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }

    public static func projectName(forRoot root: String) -> String {
        // package.json name beats the directory name when present.
        let pkg = (root as NSString).appendingPathComponent("package.json")
        if let data = FileManager.default.contents(atPath: pkg),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data),
           let name = json["name"]?.stringValue, !name.isEmpty {
            return name.split(separator: "/").last.map(String.init) ?? name
        }
        return (root as NSString).lastPathComponent
    }

    /// Build a context for a known directory, with the given signals and confidence.
    public static func context(forPath path: String, signals: [ProjectSignal], confidence: Double, devServerPort: Int? = nil, devServerURL: String? = nil) -> ProjectContext? {
        guard let git = gitInfo(forPath: path) else {
            // Not a git repo: still usable for discussion, but checkpoints (undo) need git.
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return ProjectContext(name: projectName(forRoot: path), rootPath: path, confidence: confidence * 0.8, signals: signals)
        }
        return ProjectContext(
            name: projectName(forRoot: git.root),
            rootPath: git.root,
            repositoryRemote: git.remote.flatMap(httpsRemote(fromGitRemote:)),
            branch: git.branch,
            devServerPort: devServerPort,
            devServerURL: devServerURL,
            confidence: confidence,
            signals: signals
        )
    }

    /// Extract a localhost port from a URL or window title, e.g. "http://localhost:5173/app".
    public static func localhostPort(in text: String) -> Int? {
        let pattern = #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::(\d{2,5}))"#
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    /// Combine candidates from several signals; the highest-confidence wins and
    /// agreeing signals reinforce each other.
    public static func combine(_ candidates: [ProjectContext]) -> ProjectContext? {
        guard !candidates.isEmpty else { return nil }
        var byRoot: [String: ProjectContext] = [:]
        for c in candidates {
            if var existing = byRoot[c.rootPath] {
                existing.confidence = min(1, existing.confidence + c.confidence * 0.5)
                existing.signals = Array(Set(existing.signals + c.signals))
                existing.devServerPort = existing.devServerPort ?? c.devServerPort
                existing.devServerURL = existing.devServerURL ?? c.devServerURL
                existing.branch = existing.branch ?? c.branch
                byRoot[c.rootPath] = existing
            } else {
                byRoot[c.rootPath] = c
            }
        }
        let sorted = byRoot.values.sorted { $0.confidence > $1.confidence }
        guard var best = sorted.first else { return nil }
        // Two different roots with similar confidence → not confident at all.
        if sorted.count > 1, best.confidence - sorted[1].confidence < 0.15 {
            best.confidence = min(best.confidence, ProjectContext.trustThreshold - 0.05)
        }
        return best
    }
}

import Foundation
import PairCore

/// Turns macOS signals into a `ProjectContext`:
///
///   1. explicit selection from the menu                          (0.95)
///   2. localhost port in the browser URL → listening process cwd (0.85)
///   3. Cursor / VS Code window title "file — project"            (0.7)
///
/// Results are cached briefly because `lsof` and `git` are not free. The
/// resolver never guesses when signals disagree (see `ProjectDetection.combine`).
final class MacProjectDetector: @unchecked Sendable {
    static let defaultsKey = "pair.explicitProjectPath"
    static let recentKey = "pair.recentProjectPaths"

    private let lock = NSLock()
    private var portCache: [Int: (root: String?, at: Date)] = [:]
    private var contextCache: [String: (ctx: ProjectContext?, at: Date)] = [:]
    private let shell = ShellRunner()

    var explicitPath: String? {
        get { UserDefaults.standard.string(forKey: Self.defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            if let p = newValue { remember(p) }
        }
    }

    var recentPaths: [String] {
        (UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func remember(_ path: String) {
        var r = recentPaths.filter { $0 != path }
        r.insert(path, at: 0)
        UserDefaults.standard.set(Array(r.prefix(8)), forKey: Self.recentKey)
    }

    func resolve(world: WorldState) -> ProjectContext? {
        var candidates: [ProjectContext] = []

        if let p = explicitPath, let ctx = cachedContext(path: p, signals: [.explicitSelection], confidence: 0.95) {
            candidates.append(ctx)
        }

        if let port = world.currentLocalhostPort ?? world.currentURL.flatMap(ProjectDetection.localhostPort(in:)) {
            if let root = listeningProcessCWD(port: port),
               let ctx = cachedContext(path: root, signals: [.localhostPortProcess], confidence: 0.85, port: port, url: world.currentURL) {
                candidates.append(ctx)
            }
        }

        if let bundle = world.activeApplication?.bundleID, Self.editorBundles.contains(bundle),
           let title = world.activeWindow?.title, let name = Self.workspaceName(fromEditorTitle: title),
           let root = knownRoot(named: name),
           let ctx = cachedContext(path: root, signals: [.cursorWorkspace], confidence: 0.7) {
            candidates.append(ctx)
        }

        if candidates.isEmpty, recentPaths.count == 1, let only = recentPaths.first,
           let ctx = cachedContext(path: only, signals: [.singleKnownProject], confidence: 0.5) {
            candidates.append(ctx)
        }

        return ProjectDetection.combine(candidates)
    }

    // MARK: Signals

    static let editorBundles: Set<String> = ["com.todesktop.230313mzl4w4u92" /* Cursor */, "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "dev.zed.Zed"]

    /// "SendOfferButton.tsx — driva" / "driva — SendOfferButton.tsx" / "● App.tsx — driva — Cursor"
    static func workspaceName(fromEditorTitle title: String) -> String? {
        let parts = title.replacingOccurrences(of: "●", with: "").split(separator: "—").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let notEditor = parts.filter { !["Cursor", "Visual Studio Code", "Code", "Zed"].contains($0) }
        // The workspace is the part that does not look like a file name.
        return notEditor.first { !$0.contains(".") && !$0.hasPrefix("/") } ?? notEditor.last
    }

    private func knownRoot(named name: String) -> String? {
        if let hit = recentPaths.first(where: { ($0 as NSString).lastPathComponent == name }) { return hit }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for base in ["code", "Code", "Projects", "projects", "dev", "src", "Developer", "repos", "work", "workspace"] {
            let p = "\(home)/\(base)/\(name)"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// The working directory of the process listening on a localhost port (the dev server).
    func listeningProcessCWD(port: Int) -> String? {
        lock.lock()
        if let c = portCache[port], Date().timeIntervalSince(c.at) < 30 { lock.unlock(); return c.root }
        lock.unlock()
        var root: String?
        if let out = try? shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"], timeout: 3), out.exitCode == 0,
           let pidLine = out.stdoutText.split(separator: "\n").first(where: { $0.hasPrefix("p") }), let pid = Int(pidLine.dropFirst()) {
            if let cwd = try? shell.run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"], timeout: 3), cwd.exitCode == 0,
               let n = cwd.stdoutText.split(separator: "\n").first(where: { $0.hasPrefix("n") }) {
                root = String(n.dropFirst())
            }
        }
        lock.lock(); portCache[port] = (root, Date()); lock.unlock()
        return root
    }

    private func cachedContext(path: String, signals: [ProjectSignal], confidence: Double, port: Int? = nil, url: String? = nil) -> ProjectContext? {
        let key = path + "|" + signals.map(\.rawValue).joined()
        lock.lock()
        if let c = contextCache[key], Date().timeIntervalSince(c.at) < 20 { lock.unlock(); return c.ctx }
        lock.unlock()
        let ctx = ProjectDetection.context(forPath: path, signals: signals, confidence: confidence, devServerPort: port, devServerURL: url)
        lock.lock(); contextCache[key] = (ctx, Date()); lock.unlock()
        return ctx
    }

    func invalidate() {
        lock.lock(); contextCache.removeAll(); portCache.removeAll(); lock.unlock()
    }
}

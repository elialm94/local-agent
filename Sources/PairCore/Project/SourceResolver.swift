import Foundation

/// Maps a runtime UI target to source code. Implementations are tried in order
/// until one returns a confident answer.
public protocol SourceResolver: Sendable {
    var name: String { get }
    func resolve(target: AttentionTarget, project: ProjectContext) async -> SourceReference?
}

/// Chains resolvers; returns the first result above `minimumConfidence`, else the best seen.
public struct CompositeSourceResolver: SourceResolver, Sendable {
    public let name = "composite"
    public var resolvers: [SourceResolver]
    public var minimumConfidence = 0.75

    public init(_ resolvers: [SourceResolver]) { self.resolvers = resolvers }

    public func resolve(target: AttentionTarget, project: ProjectContext) async -> SourceReference? {
        if let existing = target.sourceReference, existing.confidence >= minimumConfidence { return existing }
        var best = target.sourceReference
        for r in resolvers {
            if let ref = await r.resolve(target: target, project: project) {
                if ref.confidence >= minimumConfidence { return ref }
                if ref.confidence > (best?.confidence ?? 0) { best = ref }
            }
        }
        return best
    }
}

/// Zero-setup resolver: `git grep` the project for the target's visible label
/// (and DOM id / test id) inside UI source files. Unique hits are reasonably
/// trustworthy; multiple hits are reported with low confidence so the coding
/// agent knows to verify.
public struct GrepSourceResolver: SourceResolver, Sendable {
    public let name = "git-grep"
    public var fileGlobs = ["*.tsx", "*.jsx", "*.ts", "*.js", "*.vue", "*.svelte", "*.html", "*.astro", "*.swift", "*.kt", "*.dart", "*.erb", "*.blade.php", "*.mdx"]
    public var excludeDirs = ["node_modules", "dist", "build", ".next", "coverage", "out", "target", "Pods", ".git"]
    public var maxResults = 40

    public init() {}

    public func resolve(target: AttentionTarget, project: ProjectContext) async -> SourceReference? {
        let start = Date()
        defer { Log.debug("source", "grep resolve", ["ms": String(format: "%.0f", Date().timeIntervalSince(start) * 1000)]) }

        var needles: [(String, Double)] = []
        if let dom = target.accessibility.domIdentifier, dom.count >= 3 { needles.append((dom, 0.85)) }
        if let ident = target.accessibility.identifier, ident.count >= 3, ident != target.accessibility.domIdentifier { needles.append((ident, 0.8)) }
        let label = target.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.count >= 3, label.count <= 60 { needles.append((label, 0.7)) }

        for (needle, base) in needles {
            let hits = grep(needle, in: project.rootPath)
            guard !hits.isEmpty else { continue }
            let uiHits = hits.filter { h in ["tsx", "jsx", "vue", "svelte", "html", "astro", "swift", "mdx", "erb"].contains((h.file as NSString).pathExtension) }
            let pool = uiHits.isEmpty ? hits : uiHits
            let distinctFiles = Set(pool.map(\.file))
            let confidence = distinctFiles.count == 1 ? base : max(0.35, base - 0.15 * Double(min(4, distinctFiles.count - 1)))
            let best = pool.sorted { ($0.file.contains("/components/") ? 0 : 1, $0.file.count) < ($1.file.contains("/components/") ? 0 : 1, $1.file.count) }[0]
            let component = Self.componentName(fromFile: best.file, lineText: best.text)
            return SourceReference(component: component, file: best.file, line: best.line, confidence: confidence,
                                   method: "git grep \"\(needle)\" (\(pool.count) hit\(pool.count == 1 ? "" : "s") in \(distinctFiles.count) file\(distinctFiles.count == 1 ? "" : "s"))")
        }
        return nil
    }

    struct Hit { var file: String; var line: Int; var text: String }

    func grep(_ needle: String, in root: String) -> [Hit] {
        let sh = ShellRunner()
        var args = ["grep", "-n", "-I", "-F", "--", needle]
        args += fileGlobs
        guard let out = try? sh.run("git", args, cwd: root, timeout: 5), out.exitCode == 0 || out.exitCode == 1 else { return [] }
        var hits: [Hit] = []
        for line in out.stdoutText.split(separator: "\n").prefix(maxResults) {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let n = Int(parts[1]) else { continue }
            let file = String(parts[0])
            if excludeDirs.contains(where: { file.hasPrefix($0 + "/") || file.contains("/" + $0 + "/") }) { continue }
            hits.append(Hit(file: file, line: n, text: String(parts[2])))
        }
        return hits
    }

    static func componentName(fromFile file: String, lineText: String) -> String? {
        let base = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        if base.first?.isUppercase == true { return base }
        if let re = try? NSRegularExpression(pattern: #"<([A-Z][A-Za-z0-9]+)"#), let m = re.firstMatch(in: lineText, range: NSRange(lineText.startIndex..., in: lineText)),
           let r = Range(m.range(at: 1), in: lineText) {
            return String(lineText[r])
        }
        return base == "index" ? ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent : base
    }
}

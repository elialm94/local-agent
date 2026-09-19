import Foundation

/// Removes obvious secrets from text before it becomes model context. This is
/// a best-effort filter for accidental leakage (an .env file visible in the
/// editor, a token in a window title) — not a security boundary.
public struct Redactor: Sendable {
    public static let shared = Redactor()

    private let patterns: [(NSRegularExpression, String)]

    public init() {
        let raw: [(String, String)] = [
            // Common provider key prefixes.
            (#"\b(sk|xai|rk|ghp|gho|ghu|ghs|ghr|glpat|AKIA|ASIA)[-_][A-Za-z0-9_\-]{12,}\b"#, "[REDACTED_KEY]"),
            (#"\bxai-[A-Za-z0-9]{20,}\b"#, "[REDACTED_KEY]"),
            (#"\b(?:key|token|secret|password|passwd|pwd|api[_-]?key|authorization)\b\s*[:=]\s*["']?([A-Za-z0-9_\-\./+=]{8,})["']?"#, "$0"),
            (#"\bBearer\s+[A-Za-z0-9_\-\./+=]{16,}"#, "Bearer [REDACTED]"),
            (#"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#, "[REDACTED_JWT]"),
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]"),
            (#"\b[A-Za-z0-9._%+-]+:[^@\s/]{6,}@[A-Za-z0-9.-]+\b"#, "[REDACTED_CREDENTIAL_URL]"),
        ]
        patterns = raw.compactMap { p, r in
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return nil }
            return (re, r)
        }
    }

    public func redact(_ text: String) -> String {
        var out = text
        for (re, replacement) in patterns {
            let range = NSRange(out.startIndex..., in: out)
            if replacement == "$0" {
                // key=value form: keep the key name, hide the value.
                let matches = re.matches(in: out, options: [], range: range).reversed()
                for m in matches where m.numberOfRanges > 1 {
                    if let r = Range(m.range(at: 1), in: out) {
                        out.replaceSubrange(r, with: "[REDACTED]")
                    }
                }
            } else {
                out = re.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: replacement)
            }
        }
        return out
    }

    /// Whether the text looks like it is dominated by secrets (e.g. an .env file).
    public func looksSensitive(_ text: String) -> Bool {
        let lines = text.split(separator: "\n")
        guard !lines.isEmpty else { return false }
        let hits = lines.filter { redact(String($0)) != String($0) }.count
        return Double(hits) / Double(lines.count) > 0.3
    }
}

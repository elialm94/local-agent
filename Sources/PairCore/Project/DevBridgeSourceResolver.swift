import Foundation

/// Decodes the source reference that the optional browser dev runtime
/// (`devtools/vite-plugin-ai-pair`) mirrors onto the hovered DOM element.
///
/// Browsers do not expose arbitrary `data-*` attributes through Accessibility,
/// but Chromium-based browsers do expose the element's class list
/// (`AXDOMClassList`). The runtime therefore adds one synthetic class to the
/// element under the pointer:
///
///     pair-src--<base64url("file:line:component")>
///
/// The class is removed when the pointer leaves, so it never leaks into styling
/// or screen readers. Decoding is pure and runs in microseconds, which is why
/// this resolver sits first in the chain.
public struct DevBridgeSourceResolver: SourceResolver, Sendable {
    public static let classPrefix = "pair-src--"
    public let name = "dev-bridge"

    public init() {}

    public func resolve(target: AttentionTarget, project: ProjectContext) async -> SourceReference? {
        Self.decode(classList: target.accessibility.domClassList)
    }

    /// Pure decoder, exposed for the perception layer so hover targets carry the
    /// reference before any resolver runs.
    public static func decode(classList: [String]) -> SourceReference? {
        guard let cls = classList.first(where: { $0.hasPrefix(classPrefix) }) else { return nil }
        var b64 = String(cls.dropFirst(classPrefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64), let payload = String(data: data, encoding: .utf8) else { return nil }
        return decode(payload: payload)
    }

    /// `file:line:component` — line and component are optional.
    static func decode(payload: String) -> SourceReference? {
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let file = parts.first, !file.isEmpty else { return nil }
        let line = parts.count > 1 ? Int(parts[1]) : nil
        let component = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        // A manually authored data-ai-source attribute is authoritative; a React
        // dev-fiber name without a file is only a hint.
        let confidence = line != nil ? 0.97 : 0.9
        return SourceReference(component: component, file: file, line: line, confidence: confidence, method: "dev-bridge class")
    }

    public static func encode(file: String, line: Int?, component: String?) -> String {
        let payload = [file, line.map(String.init) ?? "", component ?? ""].joined(separator: ":")
        let b64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return classPrefix + b64
    }
}

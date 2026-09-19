import Foundation

/// How a candidate target was produced. Used for ranking and for the debug panel.
public enum TargetSource: String, Codable, Sendable {
    /// macOS Accessibility element under the pointer.
    case accessibilityHover
    /// Accessibility element the user explicitly clicked while holding the hotkey.
    case explicitClick
    /// Screen region the user dragged out while holding the hotkey.
    case explicitRegion
    /// Reported by an instrumented local web app via the dev bridge.
    case devBridge
    /// Element the user recently interacted with (temporal context).
    case recentInteraction
    /// Recovered from OCR / screen crop only.
    case visual
    /// Supplied by a test or the CLI harness.
    case synthetic
}

/// Structured accessibility information for a target. Mirrors the useful
/// subset of the AX attributes we read, plus DOM hints browsers expose.
public struct AccessibilityData: Codable, Hashable, Sendable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var descriptionText: String?
    public var value: String?
    public var identifier: String?
    public var domIdentifier: String?
    public var domClassList: [String]
    /// Roles/titles from the element up to the window, nearest first.
    public var ancestorPath: [String]
    public var isEnabled: Bool?
    public var isFocused: Bool?

    public init(
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        descriptionText: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        domIdentifier: String? = nil,
        domClassList: [String] = [],
        ancestorPath: [String] = [],
        isEnabled: Bool? = nil,
        isFocused: Bool? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.descriptionText = descriptionText
        self.value = value
        self.identifier = identifier
        self.domIdentifier = domIdentifier
        self.domClassList = domClassList
        self.ancestorPath = ancestorPath
        self.isEnabled = isEnabled
        self.isFocused = isFocused
    }
}

/// A reference from a runtime UI element back to source code.
public struct SourceReference: Codable, Hashable, Sendable {
    public var component: String?
    public var file: String?
    public var line: Int?
    /// 0...1 — how sure we are the mapping is correct.
    public var confidence: Double
    /// Human-readable description of how the mapping was obtained
    /// (e.g. "data-ai-source attribute", "react fiber _debugSource", "grep").
    public var method: String

    public init(component: String? = nil, file: String? = nil, line: Int? = nil, confidence: Double, method: String) {
        self.component = component
        self.file = file
        self.line = line
        self.confidence = confidence
        self.method = method
    }
}

/// A small image crop (PNG bytes) plus the screen rect it covers.
public struct VisualCrop: Codable, Hashable, Sendable {
    public var png: Data
    public var bounds: Rect
    public var capturedAt: Date

    public init(png: Data, bounds: Rect, capturedAt: Date = Date()) {
        self.png = png
        self.bounds = bounds
        self.capturedAt = capturedAt
    }
}

/// A candidate answer to "what is the user referring to?"
public struct AttentionTarget: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var role: String
    public var label: String
    public var bounds: Rect
    public var application: String
    public var applicationBundleID: String?
    public var window: String?
    public var confidence: Double
    public var source: TargetSource
    public var accessibility: AccessibilityData
    public var visualCrop: VisualCrop?
    public var sourceReference: SourceReference?
    public var observedAt: Date

    public init(
        id: String = UUID().uuidString,
        role: String,
        label: String,
        bounds: Rect,
        application: String,
        applicationBundleID: String? = nil,
        window: String? = nil,
        confidence: Double,
        source: TargetSource,
        accessibility: AccessibilityData = AccessibilityData(),
        visualCrop: VisualCrop? = nil,
        sourceReference: SourceReference? = nil,
        observedAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.bounds = bounds
        self.application = application
        self.applicationBundleID = applicationBundleID
        self.window = window
        self.confidence = confidence
        self.source = source
        self.accessibility = accessibility
        self.visualCrop = visualCrop
        self.sourceReference = sourceReference
        self.observedAt = observedAt
    }

    /// Short one-line description suitable for model context and the UI.
    public var summary: String {
        var parts: [String] = [role]
        if !label.isEmpty { parts.append("\"\(label)\"") }
        if let src = sourceReference?.component { parts.append("<\(src)>") }
        return parts.joined(separator: " ")
    }

    /// Compact structured context for the model. Excludes image bytes.
    public func contextDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "role": role,
            "label": label,
            "application": application,
            "confidence": (confidence * 100).rounded() / 100,
            "bounds": ["x": Int(bounds.x), "y": Int(bounds.y), "w": Int(bounds.width), "h": Int(bounds.height)],
        ]
        if let window { d["window"] = window }
        if let v = accessibility.value, !v.isEmpty { d["value"] = String(v.prefix(200)) }
        if let dom = accessibility.domIdentifier { d["domId"] = dom }
        if !accessibility.domClassList.isEmpty { d["classes"] = Array(accessibility.domClassList.prefix(8)) }
        if !accessibility.ancestorPath.isEmpty { d["path"] = Array(accessibility.ancestorPath.prefix(6)) }
        if let s = sourceReference {
            var sd: [String: Any] = ["confidence": (s.confidence * 100).rounded() / 100, "method": s.method]
            if let c = s.component { sd["component"] = c }
            if let f = s.file { sd["file"] = f }
            if let l = s.line { sd["line"] = l }
            d["source"] = sd
        }
        return d
    }
}

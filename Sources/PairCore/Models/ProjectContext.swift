import Foundation

public enum ProjectSignal: String, Codable, Sendable {
    case explicitSelection
    case localhostPortProcess
    case cursorWorkspace
    case browserURL
    case activeEditorDocument
    case singleKnownProject
}

/// Which local code project the visible development application belongs to.
public struct ProjectContext: Codable, Hashable, Sendable {
    public var name: String
    public var rootPath: String
    public var repositoryRemote: String?
    public var branch: String?
    public var devServerPort: Int?
    public var devServerURL: String?
    /// 0...1. Below `ProjectContext.trustThreshold` the system asks instead of guessing.
    public var confidence: Double
    public var signals: [ProjectSignal]

    public static let trustThreshold = 0.6

    public init(
        name: String,
        rootPath: String,
        repositoryRemote: String? = nil,
        branch: String? = nil,
        devServerPort: Int? = nil,
        devServerURL: String? = nil,
        confidence: Double,
        signals: [ProjectSignal]
    ) {
        self.name = name
        self.rootPath = rootPath
        self.repositoryRemote = repositoryRemote
        self.branch = branch
        self.devServerPort = devServerPort
        self.devServerURL = devServerURL
        self.confidence = confidence
        self.signals = signals
    }

    public var isTrusted: Bool { confidence >= Self.trustThreshold }

    public func contextDictionary() -> [String: Any] {
        var d: [String: Any] = ["name": name, "root": rootPath, "confidence": (confidence * 100).rounded() / 100]
        if let branch { d["branch"] = branch }
        if let devServerURL { d["devServer"] = devServerURL }
        return d
    }
}

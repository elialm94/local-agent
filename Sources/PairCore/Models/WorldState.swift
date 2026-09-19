import Foundation

public struct ApplicationInfo: Codable, Hashable, Sendable {
    public var name: String
    public var bundleID: String?
    public var pid: Int32?

    public init(name: String, bundleID: String? = nil, pid: Int32? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
    }
}

public struct WindowInfo: Codable, Hashable, Sendable {
    public var title: String?
    public var bounds: Rect
    public var windowID: UInt32?

    public init(title: String? = nil, bounds: Rect, windowID: UInt32? = nil) {
        self.title = title
        self.bounds = bounds
        self.windowID = windowID
    }
}

public enum InteractionKind: String, Codable, Sendable {
    case click
    case drag
    case keyboard
    case windowChange
    case screenChange
    case hotkeyDown
    case hotkeyUp
}

/// One entry of the bounded local interaction history (temporal context).
public struct InteractionEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: InteractionKind
    public var at: Date
    public var position: Point?
    public var target: AttentionTarget?
    public var note: String?

    public init(
        id: String = UUID().uuidString,
        kind: InteractionKind,
        at: Date = Date(),
        position: Point? = nil,
        target: AttentionTarget? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.at = at
        self.position = position
        self.target = target
        self.note = note
    }
}

public enum AgentRunState: String, Codable, Sendable {
    case queued
    case running
    case finished
    case failed
    case cancelled
}

public struct RunningAgentTask: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var state: AgentRunState
    public var startedAt: Date
    public var finishedAt: Date?
    public var checkpointID: String?
    public var changedFiles: [String]
    public var summary: String?
    public var error: String?

    public init(
        id: String,
        title: String,
        state: AgentRunState,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        checkpointID: String? = nil,
        changedFiles: [String] = [],
        summary: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.checkpointID = checkpointID
        self.changedFiles = changedFiles
        self.summary = summary
        self.error = error
    }
}

/// Local-only snapshot of everything the assistant knows about the user's
/// machine right now. Nothing in here is sent externally as-is; `ContextBuilder`
/// selects and redacts the relevant slice.
public struct WorldState: Codable, Sendable {
    public var updatedAt: Date
    public var activeApplication: ApplicationInfo?
    public var activeWindow: WindowInfo?
    public var cursorPosition: Point
    public var hoveredElement: AttentionTarget?
    public var selectedElement: AttentionTarget?
    public var selectedRegion: Rect?
    public var recentInteractions: [InteractionEvent]
    public var currentProject: ProjectContext?
    public var currentURL: String?
    public var currentLocalhostPort: Int?
    public var runningAgentTasks: [RunningAgentTask]
    public var isHotkeyHeld: Bool

    public init(
        updatedAt: Date = Date(),
        activeApplication: ApplicationInfo? = nil,
        activeWindow: WindowInfo? = nil,
        cursorPosition: Point = .zero,
        hoveredElement: AttentionTarget? = nil,
        selectedElement: AttentionTarget? = nil,
        selectedRegion: Rect? = nil,
        recentInteractions: [InteractionEvent] = [],
        currentProject: ProjectContext? = nil,
        currentURL: String? = nil,
        currentLocalhostPort: Int? = nil,
        runningAgentTasks: [RunningAgentTask] = [],
        isHotkeyHeld: Bool = false
    ) {
        self.updatedAt = updatedAt
        self.activeApplication = activeApplication
        self.activeWindow = activeWindow
        self.cursorPosition = cursorPosition
        self.hoveredElement = hoveredElement
        self.selectedElement = selectedElement
        self.selectedRegion = selectedRegion
        self.recentInteractions = recentInteractions
        self.currentProject = currentProject
        self.currentURL = currentURL
        self.currentLocalhostPort = currentLocalhostPort
        self.runningAgentTasks = runningAgentTasks
        self.isHotkeyHeld = isHotkeyHeld
    }

    /// Bound the interaction history to a time window and a max count.
    public mutating func appendInteraction(_ e: InteractionEvent, window: TimeInterval = 20, maxCount: Int = 60) {
        recentInteractions.append(e)
        let cutoff = e.at.addingTimeInterval(-window)
        recentInteractions.removeAll { $0.at < cutoff }
        if recentInteractions.count > maxCount {
            recentInteractions.removeFirst(recentInteractions.count - maxCount)
        }
    }

    public var lastClick: InteractionEvent? {
        recentInteractions.last { $0.kind == .click }
    }
}

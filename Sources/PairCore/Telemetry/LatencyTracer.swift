import Foundation

/// Named latency stages. Every stage of the interaction loop reports here so
/// the debug panel can show what makes the product feel slow.
public enum LatencyStage: String, CaseIterable, Codable, Sendable {
    case hotkeyToListening = "hotkey→listening"
    case voiceFirstPacket = "voice first packet"
    case targetResolution = "target resolution"
    case contextBuild = "context build"
    case fastDecision = "jev decision"
    case transcriptReceived = "user transcript"
    case grokFirstAudio = "grok first audio"
    case grokToolCall = "grok tool call"
    case taskCompile = "task compile"
    case checkpoint = "checkpoint"
    case agentStart = "agent started"
    case agentFirstEdit = "agent first edit"
    case agentFinished = "agent finished"
    case undo = "undo"
    case screenCapture = "screen capture"
    case requestToVisibleResult = "request→visible result"
}

public struct LatencySample: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var stage: LatencyStage
    public var milliseconds: Double
    public var at: Date
}

/// Thread-safe, bounded recorder of latency samples.
public final class LatencyTracer: @unchecked Sendable {
    public static let shared = LatencyTracer()

    private let lock = NSLock()
    private var samples: [LatencySample] = []
    private var openMarks: [String: Date] = [:]
    private let maxSamples = 500
    private var listeners: [@Sendable (LatencySample) -> Void] = []

    public init() {}

    public func addListener(_ l: @escaping @Sendable (LatencySample) -> Void) {
        lock.lock(); defer { lock.unlock() }
        listeners.append(l)
    }

    /// Start timing a stage. Multiple concurrent timers are distinguished by `key`.
    public func begin(_ stage: LatencyStage, key: String = "") {
        lock.lock(); defer { lock.unlock() }
        openMarks[stage.rawValue + "|" + key] = Date()
    }

    /// Finish timing a stage started with `begin`. Returns the measured ms, or nil if no mark existed.
    @discardableResult
    public func end(_ stage: LatencyStage, key: String = "") -> Double? {
        lock.lock()
        guard let start = openMarks.removeValue(forKey: stage.rawValue + "|" + key) else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        let ms = Date().timeIntervalSince(start) * 1000
        record(stage, milliseconds: ms)
        return ms
    }

    public func record(_ stage: LatencyStage, milliseconds: Double) {
        let sample = LatencySample(stage: stage, milliseconds: milliseconds, at: Date())
        lock.lock()
        samples.append(sample)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        let ls = listeners
        lock.unlock()
        Log.debug("latency", stage.rawValue, ["ms": String(format: "%.0f", milliseconds)])
        for l in ls { l(sample) }
    }

    public func recent(limit: Int = 50) -> [LatencySample] {
        lock.lock(); defer { lock.unlock() }
        return Array(samples.suffix(limit))
    }

    /// Latest sample per stage, for a compact dashboard.
    public func latestPerStage() -> [LatencyStage: Double] {
        lock.lock(); defer { lock.unlock() }
        var out: [LatencyStage: Double] = [:]
        for s in samples { out[s.stage] = s.milliseconds }
        return out
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll()
        openMarks.removeAll()
    }
}

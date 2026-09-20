import Foundation

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info, warn, error
    public static func < (l: LogLevel, r: LogLevel) -> Bool { l.rawValue < r.rawValue }
    var tag: String {
        switch self {
        case .debug: return "DBG"
        case .info: return "INF"
        case .warn: return "WRN"
        case .error: return "ERR"
        }
    }
}

public struct LogEntry: Sendable {
    public let at: Date
    public let level: LogLevel
    public let component: String
    public let message: String
    public let fields: [String: String]
}

/// Minimal structured logger. Sinks are pluggable so the debug panel can show
/// the same stream that goes to stderr.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = NSLock()
    private var sinks: [@Sendable (LogEntry) -> Void] = []
    public var minimumLevel: LogLevel = .debug

    private init() {
        sinks.append { entry in
            let f = entry.fields.isEmpty ? "" : " " + entry.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            FileHandle.standardError.write("[\(entry.level.tag)] \(entry.component): \(entry.message)\(f)\n".data(using: .utf8)!)
        }
    }

    public func addSink(_ sink: @escaping @Sendable (LogEntry) -> Void) {
        lock.lock(); defer { lock.unlock() }
        sinks.append(sink)
    }

    public func log(_ level: LogLevel, _ component: String, _ message: String, _ fields: [String: String] = [:]) {
        guard level >= minimumLevel else { return }
        let entry = LogEntry(at: Date(), level: level, component: component, message: message, fields: fields)
        lock.lock()
        let sinks = self.sinks
        lock.unlock()
        for s in sinks { s(entry) }
    }

    public static func debug(_ c: String, _ m: String, _ f: [String: String] = [:]) { shared.log(.debug, c, m, f) }
    public static func info(_ c: String, _ m: String, _ f: [String: String] = [:]) { shared.log(.info, c, m, f) }
    public static func warn(_ c: String, _ m: String, _ f: [String: String] = [:]) { shared.log(.warn, c, m, f) }
    public static func error(_ c: String, _ m: String, _ f: [String: String] = [:]) { shared.log(.error, c, m, f) }
}

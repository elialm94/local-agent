import Foundation

/// Minimal JSON model so provider payloads can be built and inspected without
/// `Any` casts leaking through the codebase.
public enum JSONValue: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Build from Foundation JSON objects (the output of JSONSerialization).
    public init(any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let b as Bool: self = .bool(b)
        case let n as NSNumber:
            // NSNumber booleans are handled above on Darwin; on Linux check objCType.
            if String(cString: n.objCType) == "c" { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
        case is NSNull: self = .null
        default: self = .string(String(describing: any))
        }
    }

    public var description: String { (try? toString(pretty: false)) ?? "<invalid json>" }

    public func toString(pretty: Bool = false) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var intValue: Int? { doubleValue.map { Int($0) } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var stringArray: [String]? { arrayValue?.compactMap(\.stringValue) }
}

/// JSON-schema description of a tool the conversational model may call.
public struct ToolDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    /// Permission level required to run this tool.
    public var permission: PermissionLevel

    public init(name: String, description: String, parameters: JSONValue, permission: PermissionLevel) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.permission = permission
    }

    /// Realtime-API function tool payload.
    public var realtimeFunctionSpec: JSONValue {
        .object([
            "type": .string("function"),
            "name": .string(name),
            "description": .string(description),
            "parameters": parameters,
        ])
    }
}

/// Helper for building JSON-schema objects tersely.
public enum Schema {
    public static func object(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("object"), "properties": .object(props)]
        if !required.isEmpty { o["required"] = .array(required.map(JSONValue.string)) }
        return .object(o)
    }
    public static func string(_ desc: String, enumValues: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("string"), "description": .string(desc)]
        if let e = enumValues { o["enum"] = .array(e.map(JSONValue.string)) }
        return .object(o)
    }
    public static func integer(_ desc: String) -> JSONValue { .object(["type": .string("integer"), "description": .string(desc)]) }
    public static func boolean(_ desc: String) -> JSONValue { .object(["type": .string("boolean"), "description": .string(desc)]) }
    public static func stringArray(_ desc: String) -> JSONValue {
        .object(["type": .string("array"), "description": .string(desc), "items": .object(["type": .string("string")])])
    }
}

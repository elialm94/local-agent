import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// TypeSafe AI "System One" decision model.
///
/// Endpoint (verified against public docs, Sept 2026):
///   POST https://api.typesafe.ai/v1/systemone
///   Authorization: Bearer <TYPESAFE_API_KEY>
///   { "model": "jev-latest", "state": <string|object|array>, "questions": { id: {type, instructions, criteria?} } }
/// Response: { "model": "jev-1.13.0", "answers": { id: {type, noul|choice|score, probabilities?, confidence?} }, "usage": {...} }
public final class JevProvider: FastDecisionProvider, @unchecked Sendable {
    public let name = "jev"
    public let endpoint: URL
    public let model: String
    private let apiKey: String
    private let session: URLSession
    public var timeout: TimeInterval = 4

    public init(apiKey: String, model: String = "jev-latest", endpoint: URL = URL(string: "https://api.typesafe.ai/v1/systemone")!) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: cfg)
    }

    public var isAvailable: Bool { !apiKey.isEmpty }

    struct RequestBody: Encodable {
        var model: String
        var state: JSONValue
        var questions: [String: DecisionQuestion]
    }

    struct ResponseBody: Decodable {
        var model: String
        var answers: [String: DecisionAnswer]
    }

    struct ErrorBody: Decodable {
        var error: String?
        var message: String?
        var detail: JSONValue?
    }

    public func decide(_ request: DecisionRequest) async throws -> DecisionResponse {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(RequestBody(model: model, state: request.state, questions: request.questions))
        req.timeoutInterval = timeout

        let start = Date()
        let (data, response) = try await session.data(for: req)
        let ms = Date().timeIntervalSince(start) * 1000
        LatencyTracer.shared.record(.fastDecision, milliseconds: ms)

        guard let http = response as? HTTPURLResponse else { throw JevError.transport("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw JevError.http(status: http.statusCode, body: String(body.prefix(400)))
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        Log.debug("jev", "decided", ["ms": String(format: "%.0f", ms), "model": decoded.model, "questions": "\(request.questions.count)"])
        return DecisionResponse(answers: decoded.answers, model: decoded.model, latencyMs: ms)
    }
}

public enum JevError: Error, LocalizedError {
    case transport(String)
    case http(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .transport(let s): return "Jev transport error: \(s)"
        case .http(let status, let body): return "Jev HTTP \(status): \(body)"
        }
    }
}

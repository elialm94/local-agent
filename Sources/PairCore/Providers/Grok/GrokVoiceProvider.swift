import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal WebSocket abstraction so the provider can be tested with a fake.
public protocol RealtimeTransport: AnyObject, Sendable {
    func connect(url: URL, headers: [String: String], onText: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (Error?) -> Void) async throws
    func send(text: String, completion: @escaping @Sendable (Error?) -> Void)
    func close()
}

/// URLSession-backed transport (macOS; also builds against FoundationNetworking).
public final class URLSessionRealtimeTransport: NSObject, RealtimeTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var onClose: (@Sendable (Error?) -> Void)?
    private var opened: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    public override init() { super.init() }

    public func connect(url: URL, headers: [String: String], onText: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (Error?) -> Void) async throws {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.timeoutInterval = 15
        let cfg = URLSessionConfiguration.default
        #if canImport(Darwin)
        cfg.waitsForConnectivity = false
        #endif
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        self.onClose = onClose
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock(); opened = c; lock.unlock()
            task.resume()
        }
        receiveLoop(task: task, onText: onText)
    }

    private func receiveLoop(task: URLSessionWebSocketTask, onText: @escaping @Sendable (String) -> Void) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let s): onText(s)
                case .data(let d): onText(String(decoding: d, as: UTF8.self))
                @unknown default: break
                }
                self?.receiveLoop(task: task, onText: onText)
            case .failure(let error):
                self?.onClose?(error)
            }
        }
    }

    public func send(text: String, completion: @escaping @Sendable (Error?) -> Void) {
        guard let task else { completion(GrokVoiceError.notConnected); return }
        task.send(.string(text)) { error in completion(error) }
    }

    public func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock(); let c = opened; opened = nil; lock.unlock()
        c?.resume()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?(nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let c = opened; opened = nil; lock.unlock()
        if let c {
            c.resume(throwing: error ?? GrokVoiceError.connectionFailed("closed before open"))
        } else if let error {
            onClose?(error)
        }
    }
}

public enum GrokVoiceError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case server(code: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Grok Voice is not connected."
        case .connectionFailed(let s): return "Grok Voice connection failed: \(s)"
        case .server(let code, let message): return "Grok Voice error \(code ?? ""): \(message)"
        }
    }
}

/// Persistent Grok Voice session.
///
/// Endpoint: wss://api.x.ai/v1/realtime?model=grok-voice-latest with
/// `Authorization: Bearer <XAI_API_KEY>`. Audio is PCM16 mono at the configured
/// rate, base64 in JSON events. Push-to-talk uses manual turn detection
/// (`turn_detection: null` + `input_audio_buffer.commit`); if the server rejects
/// that configuration the provider falls back to `server_vad` automatically.
public final class GrokVoiceProvider: VoiceReasoningProvider, @unchecked Sendable {
    public let name = "grok-voice"
    public private(set) var state: VoiceConnectionState = .disconnected
    public weak var delegate: VoiceReasoningDelegate?

    public var model = "grok-voice-latest"
    public var baseURL = URL(string: "wss://api.x.ai/v1/realtime")!
    /// Role used for injected screen context. "system" keeps it out of the
    /// user's own words; falls back to "user" if the server rejects it.
    public var contextRole = "system"

    private let apiKey: String
    private let transport: RealtimeTransport
    private let queue = DispatchQueue(label: "pair.grok", qos: .userInteractive)
    private var config: VoiceSessionConfig?
    private var usingServerVAD = false
    private var awaitingFirstAudio = false
    private var assistantBuffer = ""
    private var responseInFlight = false
    private var turnAudioBytes = 0
    private var outbox: [String] = []
    private var sending = false

    public init(apiKey: String, transport: RealtimeTransport? = nil) {
        self.apiKey = apiKey
        self.transport = transport ?? URLSessionRealtimeTransport()
    }

    public var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: Connection

    public func connect(config: VoiceSessionConfig) async throws {
        guard isConfigured else { throw GrokVoiceError.connectionFailed("XAI_API_KEY missing") }
        self.config = config
        usingServerVAD = config.serverVAD
        setState(.connecting)
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "model", value: model)]
        do {
            try await transport.connect(
                url: comps.url!,
                headers: ["Authorization": "Bearer \(apiKey)"],
                onText: { [weak self] text in self?.handle(text: text) },
                onClose: { [weak self] error in
                    guard let self else { return }
                    Log.warn("grok", "socket closed", ["error": error?.localizedDescription ?? "-"])
                    self.setState(.disconnected)
                    if let error { self.delegate?.voiceProvider(self, didFail: error) }
                }
            )
        } catch {
            setState(.failed)
            throw GrokVoiceError.connectionFailed(error.localizedDescription)
        }
        enqueue(RealtimeClientEvent.sessionUpdate(config: config))
        setState(.connected)
        Log.info("grok", "connected", ["model": model, "vad": usingServerVAD ? "server" : "push-to-talk"])
    }

    public func disconnect() {
        transport.close()
        queue.async { [weak self] in self?.outbox.removeAll(); self?.sending = false }
        setState(.disconnected)
    }

    // MARK: User turn

    public func beginUserTurn() {
        turnAudioBytes = 0
        LatencyTracer.shared.begin(.voiceFirstPacket)
        if responseInFlight { interrupt() }
        enqueue(RealtimeClientEvent.audioClear)
    }

    public func beginLiveSession() {
        turnAudioBytes = 0
        if responseInFlight { interrupt() }
        enqueue(RealtimeClientEvent.audioClear)
    }

    public func endLiveSession() {
        if responseInFlight { interrupt() }
        enqueue(RealtimeClientEvent.audioClear)
    }

    public func completeServerTurn(context: String?) {
        guard state == .connected else { return }
        if let context { enqueue(RealtimeClientEvent.message(role: contextRole, text: context)) }
        if !usingServerVAD { enqueue(RealtimeClientEvent.audioCommit) }
        enqueue(RealtimeClientEvent.responseCreate)
        awaitingFirstAudio = true
        LatencyTracer.shared.begin(.grokFirstAudio)
        LatencyTracer.shared.begin(.transcriptReceived)
    }

    public func appendAudio(_ pcm16: Data) {
        guard state == .connected, !pcm16.isEmpty else { return }
        if turnAudioBytes == 0 { LatencyTracer.shared.end(.voiceFirstPacket) }
        turnAudioBytes += pcm16.count
        enqueue(RealtimeClientEvent.audioAppend(pcm16: pcm16))
    }

    public func endUserTurn(context: String?) {
        guard state == .connected else { return }
        guard let rate = config?.sampleRate, Double(turnAudioBytes) / Double(rate * 2) > 0.25 else {
            // Too short to be speech (accidental tap) — discard.
            enqueue(RealtimeClientEvent.audioClear)
            return
        }
        if let context { enqueue(RealtimeClientEvent.message(role: contextRole, text: context)) }
        if !usingServerVAD {
            enqueue(RealtimeClientEvent.audioCommit)
            enqueue(RealtimeClientEvent.responseCreate)
        }
        awaitingFirstAudio = true
        LatencyTracer.shared.begin(.grokFirstAudio)
        LatencyTracer.shared.begin(.transcriptReceived)
    }

    public func sendUserText(_ text: String, context: String?) {
        guard state == .connected else { return }
        if responseInFlight { interrupt() }
        if let context { enqueue(RealtimeClientEvent.message(role: contextRole, text: context)) }
        enqueue(RealtimeClientEvent.message(role: "user", text: text))
        enqueue(RealtimeClientEvent.responseCreate)
        awaitingFirstAudio = true
        LatencyTracer.shared.begin(.grokFirstAudio)
        delegate?.voiceProvider(self, didReceiveUserTranscript: text, isFinal: true)
    }

    public func sendToolResult(callID: String, outputJSON: String) {
        enqueue(RealtimeClientEvent.functionCallOutput(callID: callID, outputJSON: outputJSON))
        enqueue(RealtimeClientEvent.responseCreate)
        awaitingFirstAudio = true
        LatencyTracer.shared.begin(.grokFirstAudio)
    }

    public func injectSystemNote(_ text: String, requestResponse: Bool) {
        enqueue(RealtimeClientEvent.message(role: contextRole, text: text))
        if requestResponse {
            enqueue(RealtimeClientEvent.responseCreate)
            awaitingFirstAudio = true
            LatencyTracer.shared.begin(.grokFirstAudio)
        }
    }

    public func interrupt() {
        guard responseInFlight else { return }
        enqueue(RealtimeClientEvent.responseCancel)
        responseInFlight = false
        delegate?.voiceProvider(self, didFinishResponse: ())
    }

    // MARK: Inbound

    private func handle(text: String) {
        guard let event = RealtimeServerEvent.parse(text) else { return }
        switch event {
        case .sessionCreated:
            break
        case .sessionUpdated:
            break
        case .speechStarted:
            if responseInFlight {
                enqueue(RealtimeClientEvent.responseCancel)
                responseInFlight = false
            }
            delegate?.voiceProvider(self, didDetectUserSpeechStart: ())
        case .speechStopped:
            delegate?.voiceProvider(self, didDetectUserSpeechStop: ())
        case .userTranscript(let t, let final):
            if final { LatencyTracer.shared.end(.transcriptReceived) }
            delegate?.voiceProvider(self, didReceiveUserTranscript: t, isFinal: final)
        case .responseCreated:
            responseInFlight = true
            assistantBuffer = ""
            delegate?.voiceProvider(self, didStartResponse: ())
        case .audioDelta(let data):
            if awaitingFirstAudio { awaitingFirstAudio = false; LatencyTracer.shared.end(.grokFirstAudio) }
            delegate?.voiceProvider(self, didReceiveAudio: data)
        case .audioDone:
            break
        case .assistantTranscriptDelta(let d):
            assistantBuffer += d
            delegate?.voiceProvider(self, didReceiveAssistantTranscriptDelta: d)
        case .assistantTranscriptDone(let full):
            let text = full.isEmpty ? assistantBuffer : full
            assistantBuffer = ""
            delegate?.voiceProvider(self, didFinishAssistantTurn: text)
        case .functionCall(let callID, let name, let args):
            if awaitingFirstAudio { awaitingFirstAudio = false; LatencyTracer.shared.end(.grokFirstAudio) }
            LatencyTracer.shared.record(.grokToolCall, milliseconds: 0)
            delegate?.voiceProvider(self, didRequestToolCall: ToolCallRequest(callID: callID, name: name, argumentsJSON: args))
        case .responseDone:
            responseInFlight = false
            delegate?.voiceProvider(self, didFinishResponse: ())
        case .error(let code, let message):
            Log.error("grok", "server error", ["code": code ?? "-", "message": message])
            handleServerError(code: code, message: message)
        case .other(let type):
            Log.debug("grok", "event", ["type": type])
        }
    }

    /// Automatic fallbacks for the two configuration points the public docs
    /// leave slightly ambiguous: manual turn detection and system-role context items.
    private func handleServerError(code: String?, message: String) {
        let lower = message.lowercased()
        if usingServerVAD, let cfg = config, cfg.silenceDurationMs > 0,
           lower.contains("silence_duration") || lower.contains("create_response") {
            var stripped = cfg
            stripped.silenceDurationMs = 0
            stripped.vadCreatesResponse = true
            config = stripped
            enqueue(RealtimeClientEvent.sessionUpdate(config: stripped))
            Log.warn("grok", "server rejected VAD tuning; using its default pause detection")
            return
        }
        if !usingServerVAD, lower.contains("turn_detection") {
            usingServerVAD = true
            if var cfg = config {
                cfg.serverVAD = true
                config = cfg
                enqueue(RealtimeClientEvent.sessionUpdate(config: cfg))
                Log.warn("grok", "manual turn detection rejected; falling back to server_vad")
                return
            }
        }
        if contextRole == "system", lower.contains("role") {
            contextRole = "user"
            Log.warn("grok", "system-role context rejected; falling back to user role")
            return
        }
        delegate?.voiceProvider(self, didFail: GrokVoiceError.server(code: code, message: message))
    }

    // MARK: Outbound

    /// Events are sent strictly in order: audio append → commit → response.create.
    private func enqueue(_ event: JSONValue) {
        guard let text = try? event.toString() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.outbox.append(text)
            self.pump()
        }
    }

    private func pump() {
        guard !sending, !outbox.isEmpty else { return }
        let next = outbox.removeFirst()
        sending = true
        transport.send(text: next) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sending = false
                if let error { Log.warn("grok", "send failed", ["error": error.localizedDescription]) }
                self.pump()
            }
        }
    }

    private func setState(_ s: VoiceConnectionState) {
        state = s
        delegate?.voiceProvider(self, didChangeState: s)
    }
}

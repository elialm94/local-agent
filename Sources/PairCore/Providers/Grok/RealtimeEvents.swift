import Foundation

/// Encoders/decoders for the xAI Grok Voice Agent realtime protocol
/// (OpenAI-Realtime-compatible JSON events over WebSocket). Pure functions so
/// they can be unit-tested without a network.
///
/// Verified against docs.x.ai (speech-to-speech + REST reference), Sept 2026.
public enum RealtimeClientEvent {
    public static func sessionUpdate(config: VoiceSessionConfig, includeTurnDetection: Bool = true) -> JSONValue {
        var session: [String: JSONValue] = [
            "voice": .string(config.voice),
            "instructions": .string(config.instructions),
            "audio": .object([
                "input": .object([
                    "format": .object(["type": .string("audio/pcm"), "rate": .number(Double(config.sampleRate))]),
                ]),
                "output": .object([
                    "format": .object(["type": .string("audio/pcm"), "rate": .number(Double(config.sampleRate))]),
                ]),
            ]),
        ]
        if includeTurnDetection {
            session["turn_detection"] = config.serverVAD ? .object(["type": .string("server_vad")]) : .null
        }
        if !config.tools.isEmpty {
            session["tools"] = .array(config.tools.map(\.realtimeFunctionSpec))
        }
        var transcription: [String: JSONValue] = [:]
        if let hint = config.languageHint { transcription["language_hint"] = .string(hint) }
        if !config.keyterms.isEmpty { transcription["keyterms"] = .array(config.keyterms.prefix(100).map { .string(String($0.prefix(50))) }) }
        if !transcription.isEmpty, case .object(var audio) = session["audio"]!, case .object(var input) = audio["input"]! {
            input["transcription"] = .object(transcription)
            audio["input"] = .object(input)
            session["audio"] = .object(audio)
        }
        return .object(["type": .string("session.update"), "session": .object(session)])
    }

    public static func audioAppend(pcm16: Data) -> JSONValue {
        .object(["type": .string("input_audio_buffer.append"), "audio": .string(pcm16.base64EncodedString())])
    }

    public static let audioCommit: JSONValue = .object(["type": .string("input_audio_buffer.commit")])
    public static let audioClear: JSONValue = .object(["type": .string("input_audio_buffer.clear")])
    public static let responseCreate: JSONValue = .object(["type": .string("response.create")])
    public static let responseCancel: JSONValue = .object(["type": .string("response.cancel")])

    public static func message(role: String, text: String) -> JSONValue {
        .object([
            "type": .string("conversation.item.create"),
            "item": .object([
                "type": .string("message"),
                "role": .string(role),
                "content": .array([.object(["type": .string("input_text"), "text": .string(text)])]),
            ]),
        ])
    }

    public static func functionCallOutput(callID: String, outputJSON: String) -> JSONValue {
        .object([
            "type": .string("conversation.item.create"),
            "item": .object([
                "type": .string("function_call_output"),
                "call_id": .string(callID),
                "output": .string(outputJSON),
            ]),
        ])
    }
}

public enum RealtimeServerEvent: Equatable {
    case sessionCreated
    case sessionUpdated
    case speechStarted
    case speechStopped
    case userTranscript(text: String, isFinal: Bool)
    case responseCreated
    case audioDelta(Data)
    case audioDone
    case assistantTranscriptDelta(String)
    case assistantTranscriptDone(String)
    case functionCall(callID: String, name: String, arguments: String)
    case responseDone
    case error(code: String?, message: String)
    case other(type: String)

    public static func parse(_ text: String) -> RealtimeServerEvent? {
        guard let json = try? JSONValue.parse(text) else { return nil }
        return parse(json)
    }

    public static func parse(_ json: JSONValue) -> RealtimeServerEvent? {
        guard let type = json["type"]?.stringValue else { return nil }
        switch type {
        case "session.created", "conversation.created": return .sessionCreated
        case "session.updated": return .sessionUpdated
        case "input_audio_buffer.speech_started": return .speechStarted
        case "input_audio_buffer.speech_stopped": return .speechStopped
        case "conversation.item.input_audio_transcription.completed":
            return .userTranscript(text: json["transcript"]?.stringValue ?? "", isFinal: true)
        case "conversation.item.input_audio_transcription.updated", "conversation.item.input_audio_transcription.delta":
            return .userTranscript(text: json["transcript"]?.stringValue ?? json["delta"]?.stringValue ?? "", isFinal: false)
        case "response.created": return .responseCreated
        case "response.output_audio.delta", "response.audio.delta":
            guard let b64 = json["delta"]?.stringValue, let data = Data(base64Encoded: b64) else { return .other(type: type) }
            return .audioDelta(data)
        case "response.output_audio.done", "response.audio.done": return .audioDone
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta", "response.text.delta", "response.output_text.delta":
            return .assistantTranscriptDelta(json["delta"]?.stringValue ?? "")
        case "response.output_audio_transcript.done", "response.audio_transcript.done", "response.text.done", "response.output_text.done":
            return .assistantTranscriptDone(json["transcript"]?.stringValue ?? json["text"]?.stringValue ?? "")
        case "response.function_call_arguments.done":
            return .functionCall(
                callID: json["call_id"]?.stringValue ?? "",
                name: json["name"]?.stringValue ?? "",
                arguments: json["arguments"]?.stringValue ?? "{}"
            )
        case "response.done": return .responseDone
        case "error":
            let err = json["error"]
            return .error(code: err?["code"]?.stringValue, message: err?["message"]?.stringValue ?? json["message"]?.stringValue ?? "unknown error")
        default:
            return .other(type: type)
        }
    }
}

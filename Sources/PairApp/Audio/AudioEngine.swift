import AVFoundation
import Foundation
import PairCore

/// Microphone capture → 24 kHz mono PCM16, and PCM16 playback for the
/// assistant's voice. One AVAudioEngine for both directions.
final class AudioEngine: @unchecked Sendable {
    let sampleRate: Double = 24000
    var onCapturedPCM16: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let playbackFormat: AVAudioFormat
    private var capturing = false
    private var installed = false
    private var tapInstalled = false
    private let lock = NSLock()
    private var firstPacketSent = false

    init() {
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default: completion(false)
        }
    }

    static var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Start the engine. With `capture: false` (no microphone permission yet)
    /// only playback is wired so the assistant can still be heard.
    func start(capture: Bool = true) throws {
        guard !installed else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        var inputDescription = "off"
        if capture {
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0 else { throw AudioError.noInputDevice }
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.handleInput(buffer)
            }
            tapInstalled = true
            inputDescription = "\(Int(inputFormat.sampleRate))Hz x\(inputFormat.channelCount)"
        }
        engine.prepare()
        try engine.start()
        player.play()
        installed = true
        Log.info("audio", "engine started", ["in": inputDescription])
    }

    func stop() {
        guard installed else { return }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        player.stop()
        engine.stop()
        engine.detach(player)
        installed = false
    }

    /// Begin forwarding microphone audio (called on hotkey down).
    func beginCapture() {
        lock.lock(); capturing = true; firstPacketSent = false; lock.unlock()
        LatencyTracer.shared.begin(.voiceFirstPacket)
    }

    func endCapture() {
        lock.lock(); capturing = false; lock.unlock()
    }

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let active = capturing; lock.unlock()
        guard active, let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        lock.lock()
        let first = !firstPacketSent
        firstPacketSent = true
        lock.unlock()
        if first { LatencyTracer.shared.end(.voiceFirstPacket) }
        onCapturedPCM16?(data)
    }

    // MARK: Playback

    /// Schedule assistant audio (PCM16 mono at `sampleRate`) for immediate playback.
    func play(pcm16: Data) {
        guard installed, engine.isRunning else { return }
        let frames = pcm16.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let dst = buffer.floatChannelData?[0] else { return }
        pcm16.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { dst[i] = Float(src[i]) / 32768 }
        }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer)
    }

    /// Drop queued audio (user interrupted).
    func flushPlayback() {
        guard installed, engine.isRunning else { return }
        player.stop()
        player.play()
    }

    enum AudioError: LocalizedError {
        case noInputDevice
        var errorDescription: String? { "No audio input device available." }
    }
}

import AVFoundation
import FluidAudio
import Foundation

/// Captures the default microphone and delivers 16 kHz mono Float32 samples,
/// in order, on an AsyncStream (the audio thread only converts and yields).
final class MicCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var configObserver: NSObjectProtocol?
    private(set) var isRunning = false

    /// Called when the input device changed and capture restarted.
    var onRestart: (() -> Void)?

    func start() throws -> AsyncStream<[Float]> {
        stop()
        let (stream, cont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(400))
        continuation = cont
        try startEngine()
        // headphones plugged in, AirPods connected, ...: the engine stops;
        // start it again on the new device
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            try? self.startEngine()
            self.onRestart?()
        }
        return stream
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "murmur", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone available"])
        }
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        isRunning = false
        continuation?.finish()
        continuation = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let continuation else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData, out.frameLength > 0 else { return }
        continuation.yield(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
    }
}

/// A stretch of speech, cut out of the stream by voice activity detection.
struct SpeechSegment {
    let samples: [Float]
    let startedAt: Date
    let endedAt: Date
}

/// Cuts continuous audio into utterances with Silero VAD (via FluidAudio):
/// speech start/end events with hysteresis, a little padding, and a forced
/// cut for very long monologues.
actor Segmenter {
    private let vad: VadManager
    private var state: VadStreamState
    private let config: VadSegmentationConfig
    private var pending: [Float] = [] // not yet a full VAD chunk
    private var buffer: [Float] = [] // audio since the last cut
    private var bufferStart = 0 // absolute sample index of buffer[0]
    private var processed = 0 // samples fed to the VAD
    private var speechStart: Int?
    private var streamStart = Date()
    private(set) var speaking = false

    static let rate = 16000

    init(vad: VadManager, threshold: Float) async {
        self.vad = vad
        state = await vad.makeStreamState()
        config = VadSegmentationConfig(
            minSpeechDuration: 0.3,
            minSilenceDuration: 0.9,
            maxSpeechDuration: 30,
            speechPadding: 0.25,
            negativeThreshold: max(0.05, threshold - 0.15)
        )
    }

    /// Starts over (a new capture session).
    func reset() async {
        state = await vad.makeStreamState()
        pending = []
        buffer = []
        bufferStart = 0
        processed = 0
        speechStart = nil
        speaking = false
        streamStart = Date()
    }

    /// Feeds audio; returns the utterances that ended in it.
    func feed(_ samples: [Float]) async -> [SpeechSegment] {
        if processed == 0 && buffer.isEmpty && pending.isEmpty {
            streamStart = Date().addingTimeInterval(-Double(samples.count) / Double(Self.rate))
        }
        pending += samples
        buffer += samples
        var out: [SpeechSegment] = []
        let size = VadManager.chunkSize
        while pending.count >= size {
            let chunk = Array(pending.prefix(size))
            pending.removeFirst(size)
            guard let result = try? await vad.processStreamingChunk(chunk, state: state, config: config) else {
                processed += size
                continue
            }
            state = result.state
            processed += size
            if let event = result.event {
                switch event.kind {
                case .speechStart:
                    speechStart = event.sampleIndex
                    speaking = true
                case .speechEnd:
                    if let start = speechStart, let seg = cut(from: start, to: event.sampleIndex) {
                        out.append(seg)
                    }
                    speechStart = nil
                    speaking = false
                }
            }
        }
        // not in speech: keep only a second of audio (the pre-roll)
        if speechStart == nil && buffer.count > Self.rate * 2 {
            let drop = buffer.count - Self.rate
            buffer.removeFirst(drop)
            bufferStart += drop
        }
        return out
    }

    /// Whatever is being said right now, cut off (switching modes, quitting).
    func flush() -> SpeechSegment? {
        defer { speechStart = nil; speaking = false }
        guard let start = speechStart else { return nil }
        return cut(from: start, to: bufferStart + buffer.count)
    }

    private func cut(from start: Int, to end: Int) -> SpeechSegment? {
        let lo = max(0, start - bufferStart)
        let hi = min(buffer.count, end - bufferStart)
        guard hi > lo else { return nil }
        let samples = Array(buffer[lo..<hi])
        buffer.removeFirst(hi)
        bufferStart += hi
        let t0 = streamStart.addingTimeInterval(Double(start) / Double(Self.rate))
        let t1 = streamStart.addingTimeInterval(Double(end) / Double(Self.rate))
        return SpeechSegment(samples: samples, startedAt: t0, endedAt: t1)
    }
}

/// Parakeet TDT v3 speech recognition on the Neural Engine (FluidAudio).
/// Multilingual (25 European languages, German and English among them) with
/// automatic language detection.
actor Transcriber {
    private var asr: AsrManager?
    private(set) var ready = false

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        if ready { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { p in
            progress(p.fractionCompleted)
        })
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
        ready = true
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let asr else { return "" }
        // Parakeet wants at least a second of audio: pad short utterances
        var audio = samples
        if audio.count < Segmenter.rate {
            audio += [Float](repeating: 0, count: Segmenter.rate - audio.count)
        }
        var decoder = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(audio, decoderState: &decoder)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

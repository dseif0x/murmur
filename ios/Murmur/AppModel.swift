import AVFoundation
import FluidAudio
import Foundation
import UIKit

/// The iPhone counterpart of the Mac app's model: the same capture →
/// segmentation → Parakeet → upload pipeline (Audio.swift and Uploader.swift
/// are shared with the Mac app), driven by an on-screen button, Siri / the
/// Action Button (App Intents) and the audio session instead of a hotkey.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Mode: String, CaseIterable, Identifiable {
        case ptt, toggle, always, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ptt: return "Hold"
            case .toggle: return "Tap"
            case .always: return "Always"
            case .off: return "Off"
            }
        }
        /// Modes where the button (or Siri) starts a recording.
        var usesButton: Bool { self == .ptt || self == .toggle }
    }

    enum Phase: Equatable {
        case starting
        case loadingModel(Double)
        case off
        case listening // always mode, quiet
        case hearing // always mode, someone speaks
        case idle // hold / tap mode, waiting for the button
        case recording
        case error(String)
    }

    // settings (UserDefaults; the token in the keychain)
    @Published var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "mode"); apply() } }
    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    @Published var token: String { didSet { Keychain.setToken(token) } }
    @Published var deviceName: String { didSet { defaults.set(deviceName, forKey: "deviceName") } }
    @Published var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: "sensitivity") } }
    @Published var speakerMode: SpeakerMode { didSet { defaults.set(speakerMode.rawValue, forKey: "speakerMode"); if speakerMode != .off { Task { await ensureSpeakers() } } } }
    @Published private(set) var voiceProfile: VoiceProfile? = VoiceProfile.load()
    @Published private(set) var enrollment: Enrollment = .idle

    enum Enrollment: Equatable {
        case idle
        case recording(Int) // seconds left
        case processing
        case failed(String)
    }

    // state
    @Published private(set) var phase: Phase = .starting
    @Published private(set) var recent: [Segment] = []
    @Published private(set) var upload = Uploader.Status()
    @Published private(set) var transcribing = 0
    @Published private(set) var micDenied = false
    /// Utterances recorded while the app couldn't transcribe (e.g. in the
    /// background without the Neural Engine): transcribed when it can again.
    @Published private(set) var deferred = 0

    private let defaults = UserDefaults.standard
    private let mic = MicCapture()
    private let transcriber = Transcriber()
    private let uploader = Uploader()
    private let tagger = SpeakerTagger()
    private var segmenter: Segmenter?
    private var captureTask: Task<Void, Never>?
    private var recSamples: [Float] = []
    private var recStart = Date()
    private var flushTimer: Timer?
    private var ready = false
    private var pendingStart = false // Siri asked to record before the model was ready
    private var backlog: [(SpeechSegment, String)] = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .ptt
        serverURL = defaults.string(forKey: "serverURL") ?? ""
        token = Keychain.token()
        deviceName = defaults.string(forKey: "deviceName") ?? "iPhone"
        sensitivity = defaults.object(forKey: "sensitivity") as? Double ?? 0.75
        speakerMode = SpeakerMode(rawValue: defaults.string(forKey: "speakerMode") ?? "") ?? .off
        recent = Self.loadRecent()
        observeAudioSession()
        Task { await start() }
    }

    var isConfigured: Bool { !serverURL.isEmpty && !token.isEmpty }
    var isRecording: Bool { phase == .recording }
    var isBusy: Bool {
        if case .loadingModel = phase { return true }
        return phase == .starting
    }

    var statusText: String {
        switch phase {
        case .starting: return "Starting…"
        case let .loadingModel(p): return p > 0 && p < 1 ? "Downloading the speech model… \(Int(p * 100))%" : "Loading the speech model…"
        case .off: return "Microphone off"
        case .listening: return transcribing > 0 ? "Transcribing…" : "Listening"
        case .hearing: return "Hearing speech…"
        case .idle: return transcribing > 0 ? "Transcribing…" : (mode == .toggle ? "Tap to record" : "Hold to talk")
        case .recording: return mode == .toggle ? "Recording… tap to send" : "Recording… release to send"
        case let .error(msg): return msg
        }
    }

    // MARK: - startup

    private func start() async {
        await uploader.setStatusHandler { [weak self] s in
            Task { @MainActor in self?.upload = s }
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        micDenied = AVAudioApplication.shared.recordPermission == .denied
        phase = .loadingModel(0)
        do {
            try await transcriber.load { [weak self] p in
                Task { @MainActor in
                    if case .loadingModel = self?.phase { self?.phase = .loadingModel(p) }
                }
            }
            let vad = try await VadManager(config: VadConfig(defaultThreshold: Float(sensitivity)))
            segmenter = await Segmenter(vad: vad, threshold: Float(sensitivity))
            await tagger.setProfile(voiceProfile?.embedding)
            if speakerMode != .off { await ensureSpeakers() }
            ready = true
            apply()
            if pendingStart {
                pendingStart = false
                startRecording()
            }
        } catch {
            phase = .error("Speech model failed to load: \(error.localizedDescription)")
        }
    }

    // MARK: - audio session

    /// Recording with other audio allowed to keep playing (and AirPods /
    /// Bluetooth headsets as input).
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func ensureMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            micDenied = false
            return true
        case .denied:
            micDenied = true
            return false
        default:
            let granted = await AVAudioApplication.requestRecordPermission()
            micDenied = !granted
            return granted
        }
    }

    private func observeAudioSession() {
        let nc = NotificationCenter.default
        // phone calls, Siri, alarms: capture stops; Always mode resumes after
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began:
                    if self.phase == .recording { self.stopRecording() } else { self.stopCapture() }
                case .ended:
                    if self.mode == .always { self.apply() }
                @unknown default:
                    break
                }
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.drainBacklog()
                self?.flush(force: true)
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            // send what's queued while iOS still gives us a moment
            Task { @MainActor in self?.flush(force: true) }
        })
    }

    // MARK: - modes

    func apply() {
        guard ready else { return }
        stopCapture()
        switch mode {
        case .off:
            phase = .off
            deactivateSession()
        case .always:
            Task { await startAlways() }
        case .ptt, .toggle:
            phase = .idle
            deactivateSession()
        }
    }

    private func stopCapture() {
        captureTask?.cancel()
        captureTask = nil
        if let segmenter {
            Task {
                if let seg = await segmenter.flush() { await self.process(seg, mode: "always") }
            }
        }
        mic.stop()
    }

    private func startAlways() async {
        guard let segmenter, await ensureMicPermission() else {
            phase = .error("Murmur may not use the microphone (Settings → Murmur)")
            return
        }
        do {
            try activateSession()
            let stream = try mic.start()
            phase = .listening
            captureTask = Task { [weak self] in
                await segmenter.reset()
                for await samples in stream {
                    if Task.isCancelled { break }
                    let done = await segmenter.feed(samples)
                    let speaking = await segmenter.speaking
                    await MainActor.run {
                        guard let self, self.mode == .always else { return }
                        self.phase = speaking ? .hearing : .listening
                    }
                    for seg in done {
                        Task { await self?.process(seg, mode: "always") }
                    }
                }
            }
        } catch {
            phase = .error("Microphone: \(error.localizedDescription)")
        }
    }

    // MARK: - button / Siri recordings

    /// Hold mode: finger down. Tap mode: start or stop.
    func buttonDown() {
        switch mode {
        case .ptt: startRecording()
        case .toggle:
            if phase == .recording { stopRecording() } else { startRecording() }
        default: break
        }
    }

    /// Hold mode: finger up.
    func buttonUp() {
        if mode == .ptt { stopRecording() }
    }

    /// Siri / Action Button / Shortcuts: start if idle, stop and send if recording.
    func toggleFromIntent() {
        if phase == .recording {
            stopRecording()
            return
        }
        // a voice command means "record now", whatever the mode
        if mode == .always || mode == .off { mode = .toggle }
        guard ready else {
            pendingStart = true
            return
        }
        startRecording()
    }

    func startRecording() {
        guard ready, phase != .recording else { return }
        Task {
            guard await ensureMicPermission() else {
                phase = .error("Murmur may not use the microphone (Settings → Murmur)")
                return
            }
            do {
                try activateSession()
                let stream = try mic.start()
                recSamples = []
                recStart = Date()
                phase = .recording
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                captureTask = Task { [weak self] in
                    for await samples in stream {
                        await MainActor.run { self?.recSamples += samples }
                    }
                }
            } catch {
                phase = .error("Microphone: \(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        guard phase == .recording else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // a short tail: the last syllable often ends after the finger lifts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.captureTask?.cancel()
            self.captureTask = nil
            self.mic.stop()
            self.deactivateSession()
            let samples = self.recSamples
            self.recSamples = []
            self.phase = self.mode.usesButton ? .idle : .off
            guard samples.count > Segmenter.rate / 3 else { return }
            let seg = SpeechSegment(samples: samples, startedAt: self.recStart,
                                    endedAt: self.recStart.addingTimeInterval(Double(samples.count) / Double(Segmenter.rate)))
            // the server knows "always" and "ptt"; button and Siri recordings are manual
            Task { await self.process(seg, mode: "ptt") }
        }
    }

    // MARK: - transcripts

    private func process(_ seg: SpeechSegment, mode: String) async {
        transcribing += 1
        defer { transcribing -= 1 }
        let text: String
        do {
            text = try await transcriber.transcribe(seg.samples)
        } catch {
            // e.g. in the background, where Core ML may refuse to run: keep the
            // audio and try again when the app comes back
            backlog.append((seg, mode))
            if backlog.count > 50 { backlog.removeFirst(backlog.count - 50) }
            deferred = backlog.count
            return
        }
        // noise comes back as nothing or a lone mark
        guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2 else { return }
        var speaker: String?
        if speakerMode != .off, await ensureSpeakers() {
            let who = await tagger.tag(seg.samples, at: seg.startedAt)
            // only my voice: everyone else is dropped here, never uploaded
            if speakerMode == .onlyMe, voiceProfile != nil, !who.isMe { return }
            speaker = who.speaker
        }
        let segment = Segment(id: UUID().uuidString.lowercased(), text: text, startedAt: seg.startedAt,
                              endedAt: seg.endedAt, mode: mode, language: nil, speaker: speaker)
        await uploader.enqueue(segment)
        recent.insert(segment, at: 0)
        if recent.count > 100 { recent.removeLast(recent.count - 100) }
        saveRecent()
        // send soon, but let a conversation's utterances travel together
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.flush() }
    }

    private func drainBacklog() {
        guard !backlog.isEmpty else { return }
        let items = backlog
        backlog = []
        deferred = 0
        for (seg, mode) in items {
            Task { await process(seg, mode: mode) }
        }
    }

    // MARK: - speakers

    /// Loads the speaker model (CAM++, ~30 MB, downloaded once). False if it
    /// can't be loaded; transcripts then go out without a speaker.
    @discardableResult
    func ensureSpeakers() async -> Bool {
        if await tagger.ready { return true }
        do {
            try await tagger.load { _ in }
            return true
        } catch {
            NSLog("speaker model: \(error)")
            return false
        }
    }

    /// Records the user's voice for 12 seconds and stores its embedding as
    /// "me". Listening pauses meanwhile.
    func enrollVoice() {
        switch enrollment {
        case .recording, .processing: return
        default: break
        }
        Task {
            guard await ensureMicPermission() else {
                enrollment = .failed("Murmur may not use the microphone (Settings → Murmur).")
                return
            }
            guard await ensureSpeakers() else {
                enrollment = .failed("The speaker model could not be loaded.")
                return
            }
            if phase == .recording { stopRecording() }
            stopCapture()
            var samples: [Float] = []
            do {
                try activateSession()
                let stream = try mic.start()
                let collect = Task { () -> [Float] in
                    var acc: [Float] = []
                    for await s in stream { acc += s }
                    return acc
                }
                for left in stride(from: 12, to: 0, by: -1) {
                    enrollment = .recording(left)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                mic.stop() // finishes the stream
                samples = await collect.value
            } catch {
                enrollment = .failed("Microphone: \(error.localizedDescription)")
                apply()
                return
            }
            enrollment = .processing
            do {
                guard samples.count > Segmenter.rate * 5 else {
                    throw NSError(domain: "murmur", code: 3, userInfo: [NSLocalizedDescriptionKey: "Too little audio"])
                }
                let e = try await tagger.enrollmentEmbedding(samples)
                let profile = VoiceProfile(embedding: e, createdAt: Date())
                VoiceProfile.save(profile)
                voiceProfile = profile
                await tagger.setProfile(e)
                enrollment = .idle
            } catch {
                enrollment = .failed(error.localizedDescription)
            }
            apply()
        }
    }

    func deleteVoiceProfile() {
        VoiceProfile.save(nil)
        voiceProfile = nil
        Task { await tagger.setProfile(nil) }
    }

    func flush(force: Bool = false) {
        let server = serverURL, token = token, device = deviceName
        Task { await uploader.flush(server: server, token: token, device: device, force: force) }
    }

    func testConnection() async -> String? {
        await Uploader.ping(server: serverURL, token: token)
    }

    var webURL: URL? { URL(string: serverURL) }

    func clearRecent() {
        recent = []
        saveRecent()
    }

    // the last transcripts survive restarts (for the list only)
    private static var recentFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/recent.json")
    }

    private static func loadRecent() -> [Segment] {
        guard let data = try? Data(contentsOf: recentFile) else { return [] }
        return (try? Uploader.decoder.decode([Segment].self, from: data)) ?? []
    }

    private func saveRecent() {
        if let data = try? Uploader.encoder.encode(recent) {
            try? data.write(to: Self.recentFile, options: .atomic)
        }
    }
}

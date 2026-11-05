import AppKit
import FluidAudio
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case always, ptt, toggle, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .always: return "Always"
            case .ptt: return "Push to talk"
            case .toggle: return "Toggle"
            case .off: return "Off"
            }
        }
        /// Modes driven by the hotkey (press to record), as opposed to ambient listening.
        var usesKey: Bool { self == .ptt || self == .toggle }
    }

    enum Phase: Equatable {
        case starting
        case loadingModel(Double)
        case off
        case listening // always mode, quiet
        case hearing // always mode, someone speaks
        case waitingForKey // push to talk / toggle, idle
        case recording // push to talk key held, or toggle armed
        case error(String)
    }

    // settings (UserDefaults; the token in the keychain)
    @Published var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "mode"); apply() } }
    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    @Published var token: String { didSet { Keychain.setToken(token) } }
    @Published var deviceName: String { didSet { defaults.set(deviceName, forKey: "deviceName") } }
    @Published var pttKey: HoldKey.Key { didSet { defaults.set(pttKey.rawValue, forKey: "pttKey"); if mode.usesKey { apply() } } }
    @Published var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: "sensitivity") } }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    // state
    @Published private(set) var phase: Phase = .starting
    @Published private(set) var recent: [Segment] = []
    @Published private(set) var upload = Uploader.Status()
    @Published private(set) var transcribing = 0

    private let defaults = UserDefaults.standard
    private let mic = MicCapture()
    private let transcriber = Transcriber()
    private let uploader = Uploader()
    private let hold = HoldKey()
    private var segmenter: Segmenter?
    private var captureTask: Task<Void, Never>?
    private var pttSamples: [Float] = []
    private var pttStart = Date()
    private var flushTimer: Timer?
    private var ready = false

    init() {
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .always
        serverURL = defaults.string(forKey: "serverURL") ?? ""
        token = Keychain.token()
        deviceName = defaults.string(forKey: "deviceName") ?? (Host.current().localizedName ?? "Mac")
        pttKey = HoldKey.Key(rawValue: defaults.string(forKey: "pttKey") ?? "") ?? .rightOption
        sensitivity = defaults.object(forKey: "sensitivity") as? Double ?? 0.75
        recent = Self.loadRecent()
        Task { await start() }
    }

    var isConfigured: Bool { !serverURL.isEmpty && !token.isEmpty }

    var menuIcon: String {
        switch phase {
        case .starting, .loadingModel: return "arrow.down.circle"
        case .off: return "mic.slash"
        case .listening: return "waveform"
        case .hearing: return "waveform.circle.fill"
        case .waitingForKey: return "mic"
        case .recording: return "mic.fill"
        case .error: return "exclamationmark.triangle"
        }
    }

    var statusText: String {
        switch phase {
        case .starting: return "Starting…"
        case let .loadingModel(p): return p > 0 && p < 1 ? "Downloading the speech model… \(Int(p * 100))%" : "Loading the speech model…"
        case .off: return "Microphone off"
        case .listening: return transcribing > 0 ? "Transcribing…" : "Listening"
        case .hearing: return "Hearing speech…"
        case .waitingForKey: return mode == .toggle ? "Press \(pttKey.label) to start" : "Hold \(pttKey.label) to talk"
        case .recording: return mode == .toggle ? "Recording… press \(pttKey.label) to stop" : "Recording… release to send"
        case let .error(msg): return msg
        }
    }

    // MARK: - startup

    private func start() async {
        await uploader.setStatusHandler { [weak self] s in
            Task { @MainActor in self?.upload = s }
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        phase = .loadingModel(0)
        do {
            try await transcriber.load { [weak self] p in
                Task { @MainActor in
                    if case .loadingModel = self?.phase { self?.phase = .loadingModel(p) }
                }
            }
            let vad = try await VadManager(config: VadConfig(defaultThreshold: Float(sensitivity)))
            segmenter = await Segmenter(vad: vad, threshold: Float(sensitivity))
            ready = true
            apply()
        } catch {
            phase = .error("Speech model failed to load: \(error.localizedDescription)")
        }
    }

    // MARK: - modes

    func apply() {
        guard ready else { return }
        stopCapture()
        hold.stop()
        switch mode {
        case .off:
            phase = .off
        case .always:
            startAlways()
        case .ptt:
            if !HoldKey.trusted { HoldKey.askForPermission() }
            hold.key = pttKey
            hold.onDown = { [weak self] in self?.pttDown() }
            hold.onUp = { [weak self] in self?.pttUp() }
            hold.start()
            phase = .waitingForKey
        case .toggle:
            if !HoldKey.trusted { HoldKey.askForPermission() }
            hold.key = pttKey
            // Toggle on each press of the key; the release is ignored.
            hold.onDown = { [weak self] in self?.toggleTap() }
            hold.onUp = nil
            hold.start()
            phase = .waitingForKey
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

    private func startAlways() {
        guard let segmenter else { return }
        do {
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

    private func pttDown() {
        guard mode == .ptt else { return }
        beginKeyRecording()
    }

    private func pttUp() {
        guard mode == .ptt else { return }
        endKeyRecording()
    }

    // Toggle mode: the first press arms recording, the next one stops and sends it.
    private func toggleTap() {
        guard mode == .toggle else { return }
        if phase == .recording {
            endKeyRecording()
        } else {
            beginKeyRecording()
        }
    }

    private func beginKeyRecording() {
        guard phase != .recording else { return }
        do {
            let stream = try mic.start()
            pttSamples = []
            pttStart = Date()
            phase = .recording
            captureTask = Task { [weak self] in
                for await samples in stream {
                    await MainActor.run { self?.pttSamples += samples }
                }
            }
        } catch {
            phase = .error("Microphone: \(error.localizedDescription)")
        }
    }

    private func endKeyRecording() {
        guard phase == .recording else { return }
        // a short tail: the last syllable often ends after the key comes up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.captureTask?.cancel()
            self.captureTask = nil
            self.mic.stop()
            let samples = self.pttSamples
            self.pttSamples = []
            if self.mode.usesKey { self.phase = .waitingForKey }
            guard samples.count > Segmenter.rate / 3 else { return }
            let seg = SpeechSegment(samples: samples, startedAt: self.pttStart,
                                    endedAt: self.pttStart.addingTimeInterval(Double(samples.count) / Double(Segmenter.rate)))
            // the server stores only "always" vs "ptt"; toggle is a manual capture too
            Task { await self.process(seg, mode: "ptt") }
        }
    }

    // MARK: - transcripts

    private func process(_ seg: SpeechSegment, mode: String) async {
        transcribing += 1
        defer { transcribing -= 1 }
        guard let text = try? await transcriber.transcribe(seg.samples) else { return }
        // noise comes back as nothing or a lone mark
        guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2 else { return }
        let segment = Segment(id: UUID().uuidString.lowercased(), text: text, startedAt: seg.startedAt,
                              endedAt: seg.endedAt, mode: mode, language: nil)
        await uploader.enqueue(segment)
        recent.insert(segment, at: 0)
        if recent.count > 40 { recent.removeLast(recent.count - 40) }
        saveRecent()
        // send soon, but let a conversation's utterances travel together
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.flush() }
    }

    func flush(force: Bool = false) {
        let server = serverURL, token = token, device = deviceName
        Task { await uploader.flush(server: server, token: token, device: device, force: force) }
    }

    func testConnection() async -> String? {
        await Uploader.ping(server: serverURL, token: token)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("launch at login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openWeb() {
        if let url = URL(string: serverURL) { NSWorkspace.shared.open(url) }
    }

    func clearRecent() {
        recent = []
        saveRecent()
    }

    // the last transcripts survive restarts (for the menu only)
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

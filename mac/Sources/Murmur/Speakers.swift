import FluidAudio
import Foundation

/// What the app does with voices (Settings → Speakers).
enum SpeakerMode: String, CaseIterable, Identifiable {
    /// No speaker detection; transcripts carry no speaker.
    case off
    /// Every transcript gets a speaker: "me" (the enrolled voice) or
    /// "speaker 2", "speaker 3", … within a conversation.
    case label
    /// Only what the enrolled voice says is kept; everything else is
    /// dropped on the device and never uploaded.
    case onlyMe

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .label: return "Label speakers"
        case .onlyMe: return "Only my voice"
        }
    }
    var explanation: String {
        switch self {
        case .off: return "Transcripts aren't attributed to anyone."
        case .label: return "Each transcript is marked as \"me\" (your recorded voice) or \"speaker 2\", \"speaker 3\" … per conversation."
        case .onlyMe: return "Only what you say is kept. Other voices are recognised on this device and dropped; nothing of theirs is uploaded."
        }
    }
    /// Modes that need the enrolled voice.
    var needsProfile: Bool { self == .onlyMe }
}

/// The enrolled voice: a CAM++ speaker embedding (192 numbers, no audio).
struct VoiceProfile: Codable, Equatable {
    var embedding: [Float]
    var createdAt: Date

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voice.json")
    }

    static func load() -> VoiceProfile? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(VoiceProfile.self, from: data)
    }

    static func save(_ profile: VoiceProfile?) {
        if let profile, let data = try? JSONEncoder().encode(profile) {
            try? data.write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Attributes utterances to speakers with CAM++ embeddings (FluidAudio):
/// cosine similarity to the enrolled voice decides "me"; other voices are
/// clustered on the fly into "speaker 2", "speaker 3", … and forgotten after
/// a silence (a new conversation starts the numbering again).
actor SpeakerTagger {
    struct Result {
        /// "me", "speaker N", or nil when the utterance was too short to tell.
        let speaker: String?
        let isMe: Bool
    }

    /// A stretch of an utterance spoken by one person.
    struct Turn {
        let range: Range<Int> // sample indices in the utterance
        let startedAt: Date
        let endedAt: Date
        let result: Result
    }

    private var embedder: CampPlusEmbedder?
    private var loading: Task<CampPlusEmbedder, Error>?
    private var profile: [Float]?
    private var others: [(centroid: [Float], count: Int, label: String)] = []
    private var nextNumber = 2
    private var lastHeard = Date.distantPast
    private var last: (speaker: String?, isMe: Bool, at: Date)?
    private(set) var ready = false

    /// Same speaker above this cosine similarity. CAM++ puts the same voice
    /// around 0.6-0.8 and different voices below ~0.4.
    static let sameVoice: Float = 0.55
    /// Shorter utterances give unreliable embeddings.
    static let minSeconds = 0.9
    /// Speaker changes inside an utterance: embeddings of overlapping windows,
    /// a turn ends where two windows in a row sound like someone else.
    static let window = 1.5
    static let hop = 0.75
    static let changeBelow: Float = 0.4
    static let minTurnSeconds = 1.0
    /// Silence after which "speaker 2" etc. start over.
    static let conversationGap: TimeInterval = 10 * 60

    /// Loads (downloads, the first time) the CAM++ model. Single-flight: the
    /// utterances processed in parallel all wait for the same download
    /// instead of starting their own (which made all but one fail).
    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        if ready { return }
        let task: Task<CampPlusEmbedder, Error>
        if let loading {
            task = loading
        } else {
            task = Task { try await CampPlusEmbedder.load(progressHandler: { p in progress(p.fractionCompleted) }) }
            loading = task
        }
        do {
            let e = try await task.value
            embedder = e
            ready = true
        } catch {
            loading = nil // let the next utterance retry
            throw error
        }
    }

    func setProfile(_ embedding: [Float]?) {
        profile = embedding
    }

    /// Embedding of a longer recording (enrollment): the mean of the
    /// embeddings of overlapping 3-second windows, normalized.
    func enrollmentEmbedding(_ samples: [Float]) async throws -> [Float] {
        guard let embedder else { throw NSError(domain: "murmur", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speaker model not loaded"]) }
        let rate = Segmenter.rate
        let window = rate * 3, hop = rate * 3 / 2
        var sum = [Float](repeating: 0, count: CampPlusEmbedder.embeddingDim)
        var n = 0
        var start = 0
        while start + window <= samples.count {
            let e = try await embedder.embed(audio: Array(samples[start..<start + window]))
            for i in 0..<min(sum.count, e.count) { sum[i] += e[i] }
            n += 1
            start += hop
        }
        if n == 0 { return try await embedder.embed(audio: samples) }
        return Self.normalized(sum)
    }

    /// Who said this utterance (spoken at `at`).
    func tag(_ samples: [Float], at: Date) async -> Result {
        if at.timeIntervalSince(lastHeard) > Self.conversationGap {
            others = []
            nextNumber = 2
        }
        lastHeard = at
        let seconds = Double(samples.count) / Double(Segmenter.rate)
        guard let embedder, seconds >= Self.minSeconds,
              let e = try? await embedder.embed(audio: samples) else {
            // too short to tell: a quick reply right after someone counts as them
            if let last, at.timeIntervalSince(last.at) < 4 {
                return Result(speaker: last.speaker, isMe: last.isMe)
            }
            return Result(speaker: nil, isMe: false)
        }
        let result: Result
        if let profile, Self.cosine(e, profile) >= Self.sameVoice {
            result = Result(speaker: "me", isMe: true)
        } else {
            result = Result(speaker: assign(e), isMe: false)
        }
        last = (result.speaker, result.isMe, at)
        return result
    }

    /// Splits an utterance where the speaker changes (the voice detector only
    /// cuts at pauses, so a quick back-and-forth arrives as one utterance) and
    /// says who spoke each part. Neighbouring parts with the same speaker are
    /// joined again.
    func turns(_ samples: [Float], startedAt: Date) async -> [Turn] {
        let rate = Double(Segmenter.rate)
        let edges = [0] + (await changePoints(samples)) + [samples.count]
        var out: [Turn] = []
        for i in 0..<(edges.count - 1) {
            let r = edges[i]..<edges[i + 1]
            guard !r.isEmpty else { continue }
            let t0 = startedAt.addingTimeInterval(Double(r.lowerBound) / rate)
            let t1 = startedAt.addingTimeInterval(Double(r.upperBound) / rate)
            let who = await tag(Array(samples[r]), at: t0)
            if let last = out.last, last.result.speaker != nil, last.result.speaker == who.speaker {
                out[out.count - 1] = Turn(range: last.range.lowerBound..<r.upperBound, startedAt: last.startedAt,
                                          endedAt: t1, result: last.result)
            } else {
                out.append(Turn(range: r, startedAt: t0, endedAt: t1, result: who))
            }
        }
        return out
    }

    /// Sample indices where another voice takes over.
    private func changePoints(_ samples: [Float]) async -> [Int] {
        guard let embedder else { return [] }
        let rate = Double(Segmenter.rate)
        let win = Int(Self.window * rate), hop = Int(Self.hop * rate), minTurn = Int(Self.minTurnSeconds * rate)
        guard samples.count >= win * 2 else { return [] } // under 3 s: one turn
        var starts: [Int] = []
        var embs: [[Float]] = []
        var s = 0
        while s + win <= samples.count {
            if let e = try? await embedder.embed(audio: Array(samples[s..<s + win])) {
                starts.append(s)
                embs.append(e)
            }
            s += hop
        }
        guard embs.count >= 3 else { return [] }
        var bounds: [Int] = []
        var centroid = embs[0]
        var count: Float = 1
        var low = 0
        var lastBound = 0
        for i in 1..<embs.count {
            if Self.cosine(embs[i], centroid) < Self.changeBelow {
                low += 1
                guard low >= 2 else { continue }
                // the new voice starts in the second half of the first window that differed
                let b = starts[i - 1] + hop
                if b - lastBound >= minTurn, samples.count - b >= minTurn {
                    bounds.append(b)
                    lastBound = b
                }
                centroid = embs[i]
                count = 1
                low = 0
            } else {
                low = 0
                centroid = Self.normalized(zip(centroid, embs[i]).map { ($0 * count + $1) / (count + 1) })
                count += 1
            }
        }
        return bounds
    }

    private func assign(_ e: [Float]) -> String {
        var best = -1
        var bestScore: Float = -1
        for (i, o) in others.enumerated() {
            let s = Self.cosine(e, o.centroid)
            if s > bestScore { best = i; bestScore = s }
        }
        if best >= 0, bestScore >= Self.sameVoice {
            // running mean, re-normalized
            let o = others[best]
            let w = Float(o.count)
            let c = zip(o.centroid, e).map { ($0 * w + $1) / (w + 1) }
            others[best] = (Self.normalized(c), o.count + 1, o.label)
            return o.label
        }
        let label = "speaker \(nextNumber)"
        nextNumber += 1
        others.append((e, 1, label))
        return label
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return dot / max(sqrt(na) * sqrt(nb), 1e-9)
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = max(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return v.map { $0 / n }
    }
}

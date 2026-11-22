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

    private var embedder: CampPlusEmbedder?
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
    /// Silence after which "speaker 2" etc. start over.
    static let conversationGap: TimeInterval = 10 * 60

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        if ready { return }
        embedder = try await CampPlusEmbedder.load(progressHandler: { p in progress(p.fractionCompleted) })
        ready = true
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

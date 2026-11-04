import Foundation
import Security

/// One transcript, as the server's /v1/transcripts takes it.
struct Segment: Codable, Identifiable, Equatable {
    let id: String
    let text: String
    let startedAt: Date
    let endedAt: Date
    let mode: String
    var language: String?

    enum CodingKeys: String, CodingKey {
        case id, text, mode, language
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

/// Persistent upload queue: transcripts are written to disk first and sent
/// in batches; anything the server didn't take stays and is retried with
/// backoff (offline, server down, wrong token).
actor Uploader {
    struct Status: Equatable {
        var queued = 0
        var lastSentAt: Date?
        var lastError: String?
    }

    private var queue: [Segment] = []
    private let file: URL
    private var flushing = false
    private var backoff: TimeInterval = 5
    private var nextTry = Date.distantPast
    private(set) var status = Status()
    var onStatus: (@Sendable (Status) -> Void)?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("queue.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? Self.decoder.decode([Segment].self, from: data) {
            queue = saved
        }
        status.queued = queue.count
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        onStatus = handler
        handler(status)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func enqueue(_ seg: Segment) {
        queue.append(seg)
        // a week offline at most; the oldest go first
        if queue.count > 20000 { queue.removeFirst(queue.count - 20000) }
        save()
        publish()
    }

    private func save() {
        if let data = try? Self.encoder.encode(queue) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func publish() {
        status.queued = queue.count
        onStatus?(status)
    }

    /// Sends what's queued, if the backoff allows. Called on a timer.
    func flush(server: String, token: String, device: String, force: Bool = false) async {
        guard !flushing, !queue.isEmpty, !server.isEmpty, !token.isEmpty else { return }
        guard force || Date() >= nextTry else { return }
        flushing = true
        defer { flushing = false }
        while !queue.isEmpty {
            let batch = Array(queue.prefix(100))
            do {
                try await send(batch, server: server, token: token, device: device)
                let sent = Set(batch.map(\.id))
                queue.removeAll { sent.contains($0.id) }
                save()
                status.lastSentAt = Date()
                status.lastError = nil
                backoff = 5
                nextTry = .distantPast
                publish()
            } catch {
                status.lastError = error.localizedDescription
                nextTry = Date().addingTimeInterval(backoff)
                backoff = min(backoff * 2, 300)
                publish()
                return
            }
        }
    }

    private func send(_ batch: [Segment], server: String, token: String, device: String) async throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces))?.appendingPathComponent("v1/transcripts") else {
            throw URLError(.badURL)
        }
        struct Body: Encodable {
            let device: String
            let segments: [Segment]
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try Self.encoder.encode(Body(device: device, segments: batch))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "murmur", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Server answered \(http.statusCode) \(msg.prefix(120))"])
        }
    }

    /// Checks the server and token.
    static func ping(server: String, token: String) async -> String? {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces))?.appendingPathComponent("v1/ping") else {
            return "Invalid server URL"
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return nil
            case 401: return "The server doesn't accept this token"
            default: return "Server answered \(code)"
            }
        } catch {
            return error.localizedDescription
        }
    }
}

/// The upload token lives in the login keychain.
enum Keychain {
    private static let service = "id.seifert.murmur"
    private static let account = "ingest-token"

    static func token() -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func setToken(_ token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

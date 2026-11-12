//
//  PlaySinks.swift
//  GTNW Chess
//
//  Where play history goes. Two writers, one contract (NovaGames `play` schema, game `gtnwchess`, client `mac`):
//  - `PGPlaySink`: direct to the Games DB as the LAN role `gtnwchess_mac` (Little Mister's Macs, IP allow-listed),
//    player 'default'. TLS verify-full against the bundled Games DB CA, SCRAM, bound parameters only.
//  - `SitePlaySink`: the games-saves HTTPS API (`/v1/play/gtnwchess/*`) as a signed-in site user (a roaming
//    MacBook), player = her username. Pinned to the bundled Nova Games root CA and host 192.168.1.5.
//

import Foundation

struct PlayEventRecord: Codable, Equatable, Sendable {
    var seq: Int
    var kind: String
    /// A JSON object (≤ 4 KB).
    var detail: Data
    var ts: Date
}

struct PlaySessionEnd: Codable, Equatable, Sendable {
    var outcome: String
    var score: Double?
    var actions: Int
    /// A JSON object (≤ 64 KB).
    var summary: Data
    var endedAt: Date
}

protocol PlaySink: Sendable {
    var label: String { get }
    func start(id: UUID, startedAt: Date) async throws
    func events(id: UUID, _ events: [PlayEventRecord], actions: Int) async throws
    func end(id: UUID, startedAt: Date, _ end: PlaySessionEnd) async throws
}

// MARK: - Direct Postgres (LAN role)

final class PGPlaySink: PlaySink, @unchecked Sendable {
    let config: PGConfig
    let password: @Sendable () throws -> String
    let player: String
    private var conn: PGConnection?
    private let lock = NSLock()
    var label: String { "Games DB (\(config.user))" }

    init(config: PGConfig, player: String = "default", password: @escaping @Sendable () throws -> String) {
        self.config = config
        self.player = player
        self.password = password
    }

    static func makeDefault(store: SecretStore = LoginKeychain()) -> PGPlaySink? {
        guard store.read(service: PlayCredentials.pgService, account: PlayCredentials.pgRole) != nil else { return nil }
        var cfg = PGConfig()
        cfg.caPEM = PGConfig.bundledCA()
        return PGPlaySink(config: cfg) {
            guard let pw = store.read(service: PlayCredentials.pgService, account: PlayCredentials.pgRole) else { throw PlayError.notConfigured }
            return pw
        }
    }

    private func connection() async throws -> PGConnection {
        if let c = lock.withLock({ conn }) { return c }
        let c = try await PGConnection.connect(config, password: try password())
        lock.withLock { conn = c }
        return c
    }

    private func run(_ sql: String, _ params: [String?]) async throws {
        do {
            try await connection().execute(sql, params)
        } catch let e as PGError {
            if e.isTransient { lock.withLock { conn = nil } }
            throw e.isTransient ? PlayError.network(e.localizedDescription) : PlayError.permanent(e.localizedDescription)
        }
    }

    static func iso(_ d: Date) -> String { d.ISO8601Format(.iso8601WithTimeZone(includingFractionalSeconds: true)) }

    func start(id: UUID, startedAt: Date) async throws {
        try await run("""
            INSERT INTO play.sessions (id, game, client, player, started_at, last_seen_at)
            VALUES ($1::uuid, 'gtnwchess', 'mac', $2, $3::timestamptz, $3::timestamptz)
            ON CONFLICT (id) DO UPDATE SET last_seen_at = GREATEST(play.sessions.last_seen_at, EXCLUDED.last_seen_at)
            WHERE play.sessions.ended_at IS NULL
            """, [id.uuidString, player, Self.iso(startedAt)])
    }

    func events(id: UUID, _ events: [PlayEventRecord], actions: Int) async throws {
        for e in events {
            try await run("""
                INSERT INTO play.events (session_id, seq, ts, kind, detail) VALUES ($1::uuid, $2::integer, $3::timestamptz, $4, $5::jsonb)
                ON CONFLICT (session_id, seq) DO NOTHING
                """, [id.uuidString, String(e.seq), Self.iso(e.ts), e.kind, String(decoding: e.detail, as: UTF8.self)])
        }
        try await run("""
            UPDATE play.sessions SET last_seen_at = GREATEST(last_seen_at, now()), actions = GREATEST(actions, $2::integer)
            WHERE id = $1::uuid AND ended_at IS NULL
            """, [id.uuidString, String(actions)])
    }

    func end(id: UUID, startedAt: Date, _ e: PlaySessionEnd) async throws {
        try await run("""
            INSERT INTO play.sessions (id, game, client, player, started_at, last_seen_at, ended_at, outcome, score, actions, summary)
            VALUES ($1::uuid, 'gtnwchess', 'mac', $2, $3::timestamptz, $4::timestamptz, $4::timestamptz, $5, $6::double precision, $7::integer, $8::jsonb)
            ON CONFLICT (id) DO UPDATE SET last_seen_at = GREATEST(play.sessions.last_seen_at, EXCLUDED.last_seen_at),
              actions = GREATEST(play.sessions.actions, EXCLUDED.actions), ended_at = EXCLUDED.ended_at,
              outcome = EXCLUDED.outcome, score = EXCLUDED.score, summary = EXCLUDED.summary
            WHERE play.sessions.ended_at IS NULL
            """, [id.uuidString, player, Self.iso(startedAt), Self.iso(max(e.endedAt, startedAt)), e.outcome,
                  e.score.map { String($0) }, String(e.actions), String(decoding: e.summary, as: UTF8.self)])
    }
}

// MARK: - games-saves HTTPS API (signed-in site user)

/// A small client for the Nova Games site API: CSRF/Origin dance, cookie session, root-CA pinning.
final class GamesSiteClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let origin = "https://192.168.1.5:8443"
    static let base = URL(string: "https://192.168.1.5:8443/api/saves")!
    static let pinnedHost = "192.168.1.5"

    let base: URL
    let origin: String
    let store: SecretStore
    private(set) var session: URLSession!
    private let cookies: HTTPCookieStorage
    private let anchor: SecCertificate?
    private let lock = NSLock()
    private var csrf: String?
    private var _username: String?
    /// Test hook: replaces URLSession transport.
    let protocolClasses: [AnyClass]?

    var username: String? { lock.withLock { _username ?? store.accounts(service: PlayCredentials.siteService).first } }
    var isConfigured: Bool { username.map { store.read(service: PlayCredentials.siteService, account: $0) != nil } ?? false }

    init(base: URL = GamesSiteClient.base, origin: String = GamesSiteClient.origin, store: SecretStore = LoginKeychain(),
         caPEM: [UInt8] = GamesSiteClient.bundledCA(), protocolClasses: [AnyClass]? = nil) {
        self.base = base
        self.origin = origin
        self.store = store
        self.protocolClasses = protocolClasses
        anchor = PGConnection.certificate(fromPEM: caPEM)
        cookies = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "com.jkoch.gtnwchess.site")
        cookies.cookieAcceptPolicy = .always
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = cookies
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { cfg.protocolClasses = protocolClasses }
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    static func bundledCA(_ bundle: Bundle = .main) -> [UInt8] {
        bundle.url(forResource: "nova-games-ca", withExtension: "crt").flatMap { try? Data(contentsOf: $0) }.map { [UInt8]($0) } ?? []
    }

    // Root-CA pinning: only the bundled Nova Games root, only the site host.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
        guard challenge.protectionSpace.host == base.host, let anchor else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString))
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    struct Response { var status: Int; var json: [String: Any] }

    func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Response {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            r.setValue(origin, forHTTPHeaderField: "Origin")
            if let t = currentCSRF() { r.setValue(t, forHTTPHeaderField: "X-CSRF-Token") }
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:], options: [.sortedKeys])
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw PlayError.network(String(describing: (error as? URLError)?.code.rawValue ?? -1)) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Response(status: status, json: json)
    }

    private func currentCSRF() -> String? {
        if let c = cookies.cookies(for: base)?.first(where: { $0.name == "__Host-gs_csrf" }) { return c.value }
        return lock.withLock { csrf }
    }

    func refreshCSRF() async throws {
        let r = try await request("GET", "auth/csrf")
        guard r.status == 200, let t = r.json["csrf"] as? String else { throw PlayError.http(r.status, "csrf") }
        lock.withLock { csrf = t }
    }

    /// Signs in and (on success) stores the password in the Keychain. Never logs it.
    @discardableResult
    func signIn(username raw: String, password: String, remember: Bool = true) async throws -> [String: Any] {
        let username = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard PlayCredentials.isValidUsername(username), (10...128).contains(password.count) else { throw PlayError.permanent("username or password format") }
        try await refreshCSRF()
        let r = try await request("POST", "auth/login", body: ["username": username, "password": password])
        guard r.status == 200 else { throw PlayError.http(r.status, (r.json["error"] as? String) ?? "login") }
        try await refreshCSRF()
        lock.withLock { _username = username }
        if remember {
            for old in store.accounts(service: PlayCredentials.siteService) where old != username { store.delete(service: PlayCredentials.siteService, account: old) }
            _ = store.write(password, service: PlayCredentials.siteService, account: username)
        }
        return r.json
    }

    func signOut() async {
        _ = try? await request("POST", "auth/logout")
        if let u = username { store.delete(service: PlayCredentials.siteService, account: u) }
        lock.withLock { _username = nil; csrf = nil }
        for c in cookies.cookies(for: base) ?? [] { cookies.deleteCookie(c) }
    }

    /// Calls `path`; on 401 signs in again with the stored password, on 403 csrf refreshes the token; retries once.
    func authed(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Response {
        var r = try await request(method, path, body: body)
        if r.status == 401, let u = username, let pw = store.read(service: PlayCredentials.siteService, account: u) {
            try await signIn(username: u, password: pw, remember: false)
            r = try await request(method, path, body: body)
        } else if r.status == 403, (r.json["error"] as? String) == "csrf" {
            try await refreshCSRF()
            r = try await request(method, path, body: body)
        }
        if (200...299).contains(r.status) { return r }
        if [404, 409, 413, 422, 400].contains(r.status) { throw PlayError.permanent("\(r.status) \((r.json["error"] as? String) ?? "")") }
        throw PlayError.http(r.status, (r.json["error"] as? String) ?? "")
    }

    // MARK: Consent ("Name me in Nova's reviews")

    struct Consent: Equatable, Sendable { var nameInReviews: Bool; var displayName: String? }

    func getConsent() async throws -> Consent {
        let r = try await authed("GET", "v1/play/gtnwchess/consent")
        return Consent(nameInReviews: r.json["name_in_reviews"] as? Bool ?? false, displayName: r.json["display_name"] as? String)
    }

    func setConsent(_ c: Consent) async throws -> Consent {
        let r = try await authed("PUT", "v1/play/gtnwchess/consent",
                                 body: ["name_in_reviews": c.nameInReviews, "display_name": c.displayName.map { $0 as Any } ?? NSNull()])
        return Consent(nameInReviews: r.json["name_in_reviews"] as? Bool ?? false, displayName: r.json["display_name"] as? String)
    }
}

final class SitePlaySink: PlaySink, @unchecked Sendable {
    let client: GamesSiteClient
    var label: String { "Nova Games (\(client.username ?? "signed out"))" }

    init(client: GamesSiteClient) { self.client = client }

    func start(id: UUID, startedAt: Date) async throws {
        guard client.isConfigured else { throw PlayError.notConfigured }
        _ = try await client.authed("POST", "v1/play/gtnwchess/sessions", body: ["id": id.uuidString.lowercased()])
    }

    func events(id: UUID, _ events: [PlayEventRecord], actions: Int) async throws {
        guard client.isConfigured else { throw PlayError.notConfigured }
        for chunk in stride(from: 0, to: events.count, by: 50) {
            let part = events[chunk..<min(events.count, chunk + 50)].map { e -> [String: Any] in
                ["seq": e.seq, "kind": e.kind, "detail": (try? JSONSerialization.jsonObject(with: e.detail)) ?? [:]]
            }
            _ = try await client.authed("POST", "v1/play/gtnwchess/sessions/\(id.uuidString.lowercased())/events",
                                        body: ["events": part, "actions": actions])
        }
    }

    func end(id: UUID, startedAt: Date, _ e: PlaySessionEnd) async throws {
        guard client.isConfigured else { throw PlayError.notConfigured }
        var body: [String: Any] = ["outcome": e.outcome, "actions": e.actions,
                                   "summary": (try? JSONSerialization.jsonObject(with: e.summary)) ?? [:]]
        body["score"] = e.score.map { $0 as Any } ?? NSNull()
        _ = try await client.authed("POST", "v1/play/gtnwchess/sessions/\(id.uuidString.lowercased())/end", body: body)
    }
}

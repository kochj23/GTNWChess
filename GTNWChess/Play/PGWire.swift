import CommonCrypto
import CryptoKit
import Foundation
import Network
import Security

/// A deliberately small Postgres client for the play-history writes, using Apple frameworks only (no PostgresNIO):
/// - TLS from the first byte (Postgres 17 "direct SSL", ALPN `postgresql`), TLS 1.2+, the bundled games-DB CA pinned
///   as the only anchor and the server name checked against it (verify-full);
/// - SCRAM-SHA-256 authentication only (cleartext/MD5 requests are refused);
/// - the extended query protocol with every value sent as a bound text parameter (never spliced into SQL).
/// Errors never include the password or the server's raw message text beyond the SQLSTATE and a short reason.
enum PGError: Error, Equatable, LocalizedError {
    case connect(String)
    case tls(String)
    case auth(String)
    case server(sqlstate: String, message: String)
    case protocolViolation(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .connect(let s): "games DB unreachable: \(s)"
        case .tls(let s): "games DB TLS failure: \(s)"
        case .auth(let s): "games DB authentication failed: \(s)"
        case .server(let code, let m): "games DB error \(code): \(m)"
        case .protocolViolation(let s): "games DB protocol error: \(s)"
        case .timeout: "games DB timed out"
        }
    }

    /// Network trouble worth retrying; authentication, TLS and SQL errors are permanent.
    var isTransient: Bool {
        switch self {
        case .connect, .timeout: true
        case .server(let code, _): code.hasPrefix("08") || code.hasPrefix("57") || code == "40001" || code == "53300"
        default: false
        }
    }
}

struct PGConfig: Sendable, Equatable {
    var host = "192.168.1.5"
    /// Name checked against the server certificate (its SANs are games-pg, nova-core3, localhost).
    var tlsServerName = "nova-core3"
    var port = 5433
    var database = "games"
    var user = "gtnwchess_mac"
    /// PEM of the only trusted CA (the bundled games-pg-ca.crt).
    var caPEM: [UInt8] = []
    var timeout: TimeInterval = 8

    static func bundledCA(_ bundle: Bundle = .main) -> [UInt8] {
        bundle.url(forResource: "games-pg-ca", withExtension: "crt").flatMap { try? Data(contentsOf: $0) }.map { [UInt8]($0) } ?? []
    }
}

final class PGConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "com.jkoch.gtnwchess.pg")
    private var buffer = [UInt8]()
    private let timeout: TimeInterval

    private init(_ c: NWConnection, timeout: TimeInterval) { conn = c; self.timeout = timeout }

    deinit { conn.cancel() }

    func close() {
        send(message("X", []))
        conn.cancel()
    }

    // MARK: connect + authenticate

    static func connect(_ cfg: PGConfig, password: String) async throws -> PGConnection {
        guard let anchor = Self.certificate(fromPEM: cfg.caPEM) else { throw PGError.tls("no CA certificate") }
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(sec, "postgresql")
        sec_protocol_options_set_tls_server_name(sec, cfg.tlsServerName)
        let name = cfg.tlsServerName
        sec_protocol_options_set_verify_block(sec, { _, trustRef, done in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, name as CFString))
            SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            done(SecTrustEvaluateWithError(trust, nil))
        }, DispatchQueue(label: "com.jkoch.gtnwchess.pg.verify"))
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(cfg.timeout))
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: cfg.port)) else { throw PGError.connect("bad port") }
        let c = PGConnection(NWConnection(host: NWEndpoint.Host(cfg.host), port: port, using: NWParameters(tls: tls, tcp: tcp)),
                             timeout: cfg.timeout)
        try await c.start()
        do {
            try await c.startup(user: cfg.user, database: cfg.database, password: password)
        } catch {
            c.conn.cancel()
            throw error
        }
        return c
    }

    private func start() async throws {
        let conn = self.conn
        let timeout = self.timeout
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let once = Once(k)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(()))
                case .failed(let e): once.resume(.failure(Self.classify(e)))
                case .waiting(let e):
                    if case .tls = e { once.resume(.failure(Self.classify(e))) }
                    else { once.resume(.failure(PGError.connect("waiting for network (\(e.debugDescription.prefix(60)))"))) }
                case .cancelled: once.resume(.failure(PGError.connect("cancelled")))
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.resume(.failure(PGError.timeout)) }
        }
        conn.stateUpdateHandler = nil
    }

    private static func classify(_ e: NWError) -> PGError {
        if case .tls(let st) = e { return .tls("certificate or handshake rejected (\(st))") }
        return .connect(String(e.debugDescription.prefix(80)))
    }

    private func startup(user: String, database: String, password: String) async throws {
        var body = [UInt8]()
        body += be32(196_608)
        for (k, v) in [("user", user), ("database", database), ("application_name", "GTNWChess"), ("client_encoding", "UTF8")] {
            body += cstr(k) + cstr(v)
        }
        body.append(0)
        send(be32(UInt32(body.count + 4)) + body)

        var scram: SCRAM?
        while true {
            let (type, payload) = try await readMessage()
            switch type {
            case UInt8(ascii: "R"):
                let code = try int32(payload, 0)
                switch code {
                case 0: break
                case 10:
                    let mechs = String(decoding: payload.dropFirst(4), as: UTF8.self).split(separator: "\0").map(String.init)
                    guard mechs.contains("SCRAM-SHA-256") else { throw PGError.auth("server offers no SCRAM-SHA-256") }
                    let s = SCRAM(password: password)
                    scram = s
                    let first = Array(s.clientFirst.utf8)
                    send(message("p", cstr("SCRAM-SHA-256") + be32(UInt32(first.count)) + first))
                case 11:
                    guard let s = scram, let final = s.clientFinal(serverFirst: String(decoding: payload.dropFirst(4), as: UTF8.self)) else {
                        throw PGError.auth("bad SCRAM challenge")
                    }
                    send(message("p", Array(final.utf8)))
                case 12:
                    guard let s = scram, s.verify(serverFinal: String(decoding: payload.dropFirst(4), as: UTF8.self)) else {
                        throw PGError.auth("server signature mismatch")
                    }
                default:
                    throw PGError.auth("unsupported authentication method \(code) (only SCRAM-SHA-256 is accepted)")
                }
            case UInt8(ascii: "E"):
                let e = Self.serverError(payload)
                if case .server(let code, _) = e, code.hasPrefix("28") { throw PGError.auth("password or role rejected") }
                throw e
            case UInt8(ascii: "Z"): return
            default: continue // ParameterStatus, BackendKeyData, NoticeResponse
            }
        }
    }

    // MARK: queries

    /// Runs one statement with bound text parameters (nil = NULL). Returns the rows as text (nil = NULL).
    @discardableResult
    func execute(_ sql: String, _ params: [String?] = []) async throws -> [[String?]] {
        var bind = [UInt8]()
        bind += cstr("") + cstr("")
        bind += be16(0)
        bind += be16(UInt16(params.count))
        for p in params {
            if let p { let b = Array(p.utf8); bind += be32(UInt32(b.count)) + b } else { bind += be32(0xFFFF_FFFF) }
        }
        bind += be16(0)
        send(message("P", cstr("") + cstr(sql) + be16(0)) + message("B", bind) + message("D", [UInt8(ascii: "P")] + cstr(""))
             + message("E", cstr("") + be32(0)) + message("S", []))
        var rows = [[String?]]()
        var failure: PGError?
        while true {
            let (type, payload) = try await readMessage()
            switch type {
            case UInt8(ascii: "D"):
                let n = Int(try int16(payload, 0))
                var p = 2, row = [String?]()
                for _ in 0..<n {
                    let len = try int32(payload, p); p += 4
                    if len < 0 { row.append(nil); continue }
                    guard p + Int(len) <= payload.count else { throw PGError.protocolViolation("short DataRow") }
                    row.append(String(decoding: payload[p..<p + Int(len)], as: UTF8.self)); p += Int(len)
                }
                rows.append(row)
            case UInt8(ascii: "E"): failure = Self.serverError(payload)
            case UInt8(ascii: "Z"):
                if let failure { throw failure }
                return rows
            default: continue
            }
        }
    }

    static func serverError(_ payload: [UInt8]) -> PGError {
        var fields = [UInt8: String](), p = 0
        while p < payload.count, payload[p] != 0 {
            let code = payload[p]; p += 1
            let end = payload[p...].firstIndex(of: 0) ?? payload.count
            fields[code] = String(decoding: payload[p..<end], as: UTF8.self); p = end + 1
        }
        return .server(sqlstate: fields[UInt8(ascii: "C")] ?? "XX000", message: String((fields[UInt8(ascii: "M")] ?? "error").prefix(160)))
    }

    // MARK: framing

    private func send(_ bytes: [UInt8]) {
        conn.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func readMessage() async throws -> (UInt8, [UInt8]) {
        while buffer.count < 5 { try await fill() }
        let len = Int(try int32(buffer, 1))
        guard len >= 4, len < 16 << 20 else { throw PGError.protocolViolation("message length \(len)") }
        while buffer.count < 1 + len { try await fill() }
        let type = buffer[0], payload = Array(buffer[5..<1 + len])
        buffer.removeFirst(1 + len)
        return (type, payload)
    }

    private func fill() async throws {
        let conn = self.conn, timeout = self.timeout, queue = self.queue
        let data: Data = try await withCheckedThrowingContinuation { k in
            let once = Once(k)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { d, _, done, err in
                if let err { once.resume(.failure(Self.classify(err))) }
                else if let d, !d.isEmpty { once.resume(.success(d)) }
                else if done { once.resume(.failure(PGError.connect("connection closed by server"))) }
                else { once.resume(.failure(PGError.protocolViolation("empty read"))) }
            }
            queue.asyncAfter(deadline: .now() + timeout) { once.resume(.failure(PGError.timeout)) }
        }
        buffer += data
    }

    private func message(_ type: Character, _ body: [UInt8]) -> [UInt8] {
        [type.asciiValue ?? 0] + be32(UInt32(body.count + 4)) + body
    }

    static func certificate(fromPEM pem: [UInt8]) -> SecCertificate? {
        let text = String(decoding: pem, as: UTF8.self)
        guard let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<text.endIndex) else { return nil }
        let b64 = text[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: String(b64)) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }
}

/// Resumes a continuation at most once (callbacks and the timeout race).
private final class Once<T: Sendable>: @unchecked Sendable {
    private var k: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    init(_ k: CheckedContinuation<T, Error>) { self.k = k }
    func resume(_ r: Result<T, Error>) {
        lock.lock(); let c = k; k = nil; lock.unlock()
        c?.resume(with: r)
    }
}

// MARK: - SCRAM-SHA-256 (RFC 5802 / 7677, no channel binding)

struct SCRAM {
    let password: String
    let nonce: String
    var clientFirstBare: String { "n=,r=\(nonce)" }
    var clientFirst: String { "n,," + clientFirstBare }
    private let box = Box()

    private final class Box { var authMessage = ""; var serverKey = [UInt8]() }

    init(password: String, nonce: String? = nil) {
        self.password = password
        var r = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, r.count, &r)
        self.nonce = nonce ?? Data(r).base64EncodedString()
    }

    /// The client-final message for the server-first message, or nil if the challenge is malformed or unsafe.
    func clientFinal(serverFirst: String) -> String? {
        var attrs = [Character: String]()
        for part in serverFirst.split(separator: ",") where part.count >= 2 && part.dropFirst().first == "=" {
            attrs[part.first!] = String(part.dropFirst(2))
        }
        guard let r = attrs["r"], r.hasPrefix(nonce), r.count > nonce.count, let s = attrs["s"],
              let salt = Data(base64Encoded: s), let iStr = attrs["i"], let iterations = Int(iStr),
              (4096...1_000_000).contains(iterations) else { return nil }
        let salted = Self.pbkdf2(password, salt: [UInt8](salt), iterations: iterations)
        let clientKey = Self.hmac(salted, "Client Key")
        let storedKey = [UInt8](SHA256.hash(data: clientKey))
        let withoutProof = "c=biws,r=\(r)"
        let auth = clientFirstBare + "," + serverFirst + "," + withoutProof
        let sig = Self.hmac(storedKey, auth)
        let proof = zip(clientKey, sig).map { $0 ^ $1 }
        box.authMessage = auth
        box.serverKey = Self.hmac(salted, "Server Key")
        return withoutProof + ",p=" + Data(proof).base64EncodedString()
    }

    func verify(serverFinal: String) -> Bool {
        guard serverFinal.hasPrefix("v="), let v = Data(base64Encoded: String(serverFinal.dropFirst(2))), !box.serverKey.isEmpty else {
            return false
        }
        return [UInt8](v) == Self.hmac(box.serverKey, box.authMessage)
    }

    static func hmac(_ key: [UInt8], _ msg: String) -> [UInt8] {
        [UInt8](HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
    }

    static func pbkdf2(_ password: String, salt: [UInt8], iterations: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        _ = pw.withUnsafeBufferPointer { p in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                 pw.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, out.count)
        }
        return out
    }
}

private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
private func cstr(_ s: String) -> [UInt8] { Array(s.utf8.filter { $0 != 0 }) + [0] }
private func int32(_ b: [UInt8], _ at: Int) throws -> Int32 {
    guard at >= 0, at + 4 <= b.count else { throw PGError.protocolViolation("short message") }
    return Int32(bitPattern: UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3]))
}
private func int16(_ b: [UInt8], _ at: Int) throws -> Int16 {
    guard at >= 0, at + 2 <= b.count else { throw PGError.protocolViolation("short message") }
    return Int16(bitPattern: UInt16(b[at]) << 8 | UInt16(b[at + 1]))
}

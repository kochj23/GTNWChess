//
//  TestSupport.swift
//  GTNWChessTests
//
//  Shared helpers: hermetic controllers (fallback engine, offline AI, no sink), a recording play sink with
//  failure injection, a URLProtocol stub, and an async wait.
//

import Foundation
import NovaAIKit
import XCTest
@testable import GTNWChess

enum Fixtures {
    static let kiwipete = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
    static let pos3 = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"
    static let pos4 = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1"
    static let pos5 = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8"
    static let pos6 = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10"

    /// The "Opera Game" (Morphy, Paris 1858), a public-domain classic.
    static let operaPGN = """
        [Event "Paris"]
        [Site "Paris FRA"]
        [Date "1858.??.??"]
        [White "Paul Morphy"]
        [Black "Duke Karl / Count Isouard"]
        [Result "1-0"]

        1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7
        8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7
        14. Rd1 Qe6 15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8# 1-0
        """

    static let foolsMate = ["f3", "e5", "g4", "Qh4#"]
    static let scholarsMate = ["e4", "e5", "Bc4", "Nc6", "Qh5", "Nf6", "Qxf7#"]

    static func game(_ sans: [String], fen: String? = nil) throws -> Game {
        var g = try fen.map { try Game(fen: $0) } ?? Game()
        for s in sans { try g.play(san: s) }
        return g
    }
}

/// Every play op the sink saw, in order. `failures` makes the next N calls throw `error`.
final class RecordingSink: PlaySink, @unchecked Sendable {
    let lock = NSLock()
    private var _ops: [String] = []
    private var _events: [PlayEventRecord] = []
    private var _ends: [PlaySessionEnd] = []
    var failures = 0
    var error: Error = PlayError.network("down")
    var label: String { "recording" }

    var ops: [String] { lock.withLock { _ops } }
    var events: [PlayEventRecord] { lock.withLock { _events } }
    var ends: [PlaySessionEnd] { lock.withLock { _ends } }

    private func gate(_ name: String) throws {
        try lock.withLock {
            if failures > 0 { failures -= 1; throw error }
            _ops.append(name)
        }
    }
    func start(id: UUID, startedAt: Date, player: String?) async throws { try gate("start") }
    func events(id: UUID, _ events: [PlayEventRecord], actions: Int) async throws {
        try gate("events")
        lock.withLock { _events += events }
    }
    func end(id: UUID, startedAt: Date, _ end: PlaySessionEnd) async throws {
        try gate("end")
        lock.withLock { _ends.append(end) }
    }
}

/// Canned HTTP replies for URLSession-based clients (games site, NovaAI). Records every request.
final class StubHTTP: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { var method: String; var url: URL; var headers: [String: String]; var body: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (Seen) -> (Int, Data))?
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func respond(_ h: @escaping @Sendable (Seen) -> (Int, Data)) { lock.withLock { handler = h; seen = [] } }
    static var requests: [Seen] { lock.withLock { seen } }
    static func reset() { lock.withLock { handler = nil; seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 65_536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            s.close()
        }
        let req = Seen(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)
        let h = Self.lock.withLock { Self.seen.append(req); return Self.handler }
        guard let (status, data) = h?(req) else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8) }
}

@MainActor
enum TestEnv {
    /// A controller that never touches the network, the real games DB or the real Keychain; 2D so moves apply at once.
    static func controller(sink: PlaySink? = nil, persist: Bool = false, ai: NovaAI? = nil, engine: EngineService? = nil) -> GameController {
        let site = GamesSiteClient(store: MemorySecretStore(), protocolClasses: [OfflineURLProtocol.self])
        let c = GameController(engine: engine ?? EngineService(primary: nil), ai: ai ?? AppAI.makeShared(), site: site,
                               outbox: PlayOutbox(fileURL: nil, sink: sink), persist: persist)
        c.is3D = false
        return c
    }

    /// Hermetic NovaAI whose transport is `StubHTTP`, set to Ollama.
    static func stubbedAI() -> NovaAI {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubHTTP.self]
        var s = AppAI.configuration.defaultSettings
        s.backend = .ollama
        s.extraOllamaEndpoints = []
        return NovaAI(configuration: AppAI.configuration, storage: NovaAIMemoryStorage(s), keyStore: NovaAIMemoryKeyStore(),
                      session: URLSession(configuration: cfg), sleep: { _ in })
    }

    nonisolated static func ollamaReply(_ text: String) -> Data {
        StubHTTP.json(["model": "qwen3:8b", "message": ["role": "assistant", "content": text], "done": true])
    }

    /// The first move of the "Legal moves:" line in a ModelPlayer prompt (a stub model that always plays legally).
    nonisolated static func firstLegal(_ body: Data) -> String {
        let s = String(decoding: body, as: UTF8.self)
        guard let r = s.range(of: "Legal moves: ") else { return "??" }
        return String(s[r.upperBound...].prefix { $0 != "," && $0 != "\\" && $0 != "\n" })
    }

    /// A Watch config whose sides are stub models (`white`/`black` true) on the stubbed Ollama, or the engine.
    static func watch(white: Bool, black: Bool, backend: NovaAIBackend = .ollama, model: String = "qwen3:8b") -> NewGameConfig {
        var cfg = NewGameConfig(); cfg.mode = .watch; cfg.level = .cadet; cfg.blackLevel = .cadet
        cfg.whiteSeat = WatchSeat(useModel: white, backend: backend, model: model)
        cfg.blackSeat = WatchSeat(useModel: black, backend: backend, model: model)
        return cfg
    }

    @discardableResult
    static func play(_ c: GameController, _ sans: [String]) -> Bool {
        for s in sans {
            guard let m = c.game.position.move(san: s), c.commit(m, source: .local) != nil else { return false }
        }
        return true
    }
}

/// Counts stub calls across threads.
final class StubCounter: @unchecked Sendable { let l = NSLock(); var n = 0; func next() -> Int { l.withLock { n += 1; return n } } }

/// Polls `cond` on the main actor until true or `timeout`.
@MainActor
func waitUntil(_ timeout: TimeInterval = 10, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return cond()
}

extension PlayOp {
    var kindName: String {
        switch self { case .start: return "start"; case .events: return "events"; case .end: return "end" }
    }
    var eventRecords: [PlayEventRecord] { if case .events(_, let e, _) = self { return e } else { return [] } }
}

func jsonObject(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

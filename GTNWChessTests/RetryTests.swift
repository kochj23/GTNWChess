//
//  RetryTests.swift
//  GTNWChessTests
//
//  Backoff policy, the play-history outbox (transient vs permanent, order, persistence, cap), engine failover,
//  AI retry/fallback and LAN reconnect giving up cleanly. No test really sleeps.
//

import XCTest
import NovaAIKit
@testable import GTNWChess

/// An engine that fails `failures` times, then answers e2e4 / +0.10.
final class FlakyEngine: ChessEngine, @unchecked Sendable {
    let lock = NSLock()
    var failures: Int
    var calls = 0
    init(failures: Int) { self.failures = failures }
    var name: String { "Flaky" }
    private func step() throws {
        try lock.withLock {
            calls += 1
            if failures > 0 { failures -= 1; throw EngineError.timeout("test") }
        }
    }
    func bestMove(fen: String, moves: [String], level: EngineLevel) async throws -> String { try step(); return "e2e4" }
    func evaluate(fen: String, depth: Int) async throws -> Evaluation { try step(); return Evaluation(cp: 10, mate: nil, bestMove: "e2e4", depth: depth) }
    func shutdown() async {}
}

final class Sleeps: @unchecked Sendable {
    let lock = NSLock()
    var delays: [TimeInterval] = []
    var sleeper: Retry.Sleeper { { d in self.lock.withLock { self.delays.append(d) } } }
}

@MainActor
final class RetryTests: XCTestCase {
    override func tearDown() { StubHTTP.reset() }

    func testBackoffDelaysAreExponential() {
        let p = Retry.Policy(attempts: 4, baseDelay: 0.5, multiplier: 2)
        XCTAssertEqual((1...3).map(p.delay(beforeRetry:)), [0.5, 1, 2])
    }

    func testRetryRunsUntilSuccess() async throws {
        let s = Sleeps()
        var n = 0
        let v = try await Retry.run(.init(attempts: 3, baseDelay: 0.1), sleep: s.sleeper) { () async throws -> Int in
            n += 1
            if n < 3 { throw PlayError.network("x") }
            return 42
        }
        XCTAssertEqual(v, 42)
        XCTAssertEqual(s.delays, [0.1, 0.2])
    }

    func testRetryStopsOnNonRetryable() async {
        var n = 0
        do {
            _ = try await Retry.run(.init(attempts: 5), sleep: { _ in }, when: { ($0 as? PlayError)?.isTransient ?? true }) { () async throws -> Int in
                n += 1; throw PlayError.permanent("bad")
            }
            XCTFail("should throw")
        } catch {}
        XCTAssertEqual(n, 1)
    }

    func testOutboxKeepsItemsAcrossTransientFailureThenDelivers() async {
        let sink = RecordingSink()
        sink.failures = 10
        let box = PlayOutbox(fileURL: nil, sink: sink)
        box.sleeper = { _ in }
        let id = UUID()
        box.enqueue(.start(id: id, startedAt: Date()))
        box.enqueue(.events(id: id, events: [], actions: 0))
        _ = await waitUntil(5) { !box.isFlushing }
        await box.flushNow()
        XCTAssertEqual(box.pending.count, 2, "transient failure keeps everything queued")
        XCTAssertNotNil(box.lastError)
        sink.failures = 0
        await box.flushNow()
        XCTAssertEqual(box.pending.count, 0)
        XCTAssertEqual(sink.ops, ["start", "events"], "order kept")
        XCTAssertNil(box.lastError)
    }

    func testOutboxDropsPermanentFailuresOnly() async {
        let sink = RecordingSink()
        sink.failures = 1
        sink.error = PlayError.permanent("422")
        let box = PlayOutbox(fileURL: nil, sink: nil)
        box.sleeper = { _ in }
        let id = UUID()
        box.enqueue(.start(id: id, startedAt: Date()))
        box.enqueue(.events(id: id, events: [], actions: 0))
        box.sink = sink
        await box.flushNow()
        XCTAssertEqual(box.dropped, 1)
        XCTAssertEqual(sink.ops, ["events"])
        XCTAssertTrue(box.pending.isEmpty)
    }

    func testOutboxPersistsAndReloads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let box = PlayOutbox(fileURL: url, sink: nil)
        let id = UUID()
        box.enqueue(.start(id: id, startedAt: Date(timeIntervalSince1970: 1_000)))
        let again = PlayOutbox(fileURL: url, sink: nil)
        XCTAssertEqual(again.pending, box.pending)
        XCTAssertEqual(again.pending.first?.sessionID, id)
    }

    func testOutboxIsCapped() {
        let box = PlayOutbox(fileURL: nil, sink: nil)
        let id = UUID()
        for _ in 0..<(PlayOutbox.maxItems + 5) { box.enqueue(.events(id: id, events: [], actions: 0)) }
        XCTAssertEqual(box.pending.count, PlayOutbox.maxItems)
    }

    func testEngineServiceRetriesPrimaryThenFallsBack() async throws {
        let once = FlakyEngine(failures: 1)
        let svc = EngineService(primary: once)
        let m = try await svc.bestMove(for: Game(), level: .pilot)
        XCTAssertEqual(m.uci, "e2e4")
        XCTAssertEqual(once.calls, 2, "one retry on the primary")
        XCTAssertEqual(svc.lastSource, "Flaky")

        let dead = FlakyEngine(failures: 99)
        let svc2 = EngineService(primary: dead)
        let m2 = try await svc2.bestMove(for: Game(), level: .cadet)
        XCTAssertNotNil(Position.start.legal(m2))
        XCTAssertEqual(svc2.lastSource, FallbackEngine().name)
    }

    func testEngineServiceRejectsIllegalEngineMove() async throws {
        final class Liar: ChessEngine, @unchecked Sendable {
            var name: String { "Liar" }
            func bestMove(fen: String, moves: [String], level: EngineLevel) async throws -> String { "e2e5" }
            func evaluate(fen: String, depth: Int) async throws -> Evaluation { Evaluation(cp: 0, mate: nil, bestMove: nil, depth: 1) }
            func shutdown() async {}
        }
        let svc = EngineService(primary: Liar())
        let m = try await svc.bestMove(for: Game(), level: .pilot)
        XCTAssertNotNil(Position.start.legal(m), "an illegal engine answer never reaches the board")
    }

    func testAIRetriesTransientThenSucceeds() async {
        let ai = TestEnv.stubbedAI()
        final class Count: @unchecked Sendable { let l = NSLock(); var n = 0; func next() -> Int { l.withLock { n += 1; return n } } }
        let count = Count()
        StubHTTP.respond { r in
            guard r.url.path.hasSuffix("/api/chat") else { return (200, StubHTTP.json(["models": []])) }
            return count.next() == 1 ? (503, StubHTTP.json(["error": "busy"])) : (200, TestEnv.ollamaReply("Develop your pieces and castle soon."))
        }
        let r = await NovaNarrator(ai: ai).coach(game: Game(), playerName: "Tester")
        XCTAssertTrue(r.isAI, "\(r.source)")
        XCTAssertGreaterThanOrEqual(StubHTTP.requests.filter { $0.url.path.hasSuffix("/api/chat") }.count, 2)
    }

    func testAIDownFallsBackToScript() async {
        let ai = TestEnv.stubbedAI()
        StubHTTP.respond { _ in (500, StubHTTP.json(["error": "down"])) }
        let g = try! Fixtures.game(["e4"])
        let r = await NovaNarrator(ai: ai).coach(game: g, playerName: "Tester")
        XCTAssertFalse(r.isAI)
        XCTAssertEqual(r.value, ScriptedCoach.explain(CoachFacts.make(game: g), playerName: "Tester"))
    }

    func testLANReconnectGivesUpAfterPolicy() async throws {
        let port = UInt16(LocalPostgres.freePort())   // nothing listens there
        let s = LANSession()
        s.reconnectPolicy = .init(attempts: 2, baseDelay: 0.01)
        let sleeps = Sleeps()
        s.sleeper = sleeps.sleeper
        try s.join(host: "127.0.0.1", port: port, code: "123456")
        _ = await waitUntil(10) { if case .failed = s.status { return true } else { return false } }
        if case .failed(let why) = s.status { XCTAssertTrue(why.contains("pairing code"), why) } else { XCTFail("\(s.status)") }
        XCTAssertTrue(sleeps.delays.isEmpty, "a first-time join never retries (wrong code fails fast)")
        await s.reconnect(reason: "test")
        if case .failed(let why) = s.status { XCTAssertTrue(why.contains("reconnect"), why) } else { XCTFail("\(s.status)") }
        XCTAssertEqual(sleeps.delays, [0.01, 0.02])
        s.stop()
    }

    // MARK: Model vs model: re-ask with the error, then the engine

    func testModelInvalidThenValidIsReaskedWithTheError() async {
        let ai = TestEnv.stubbedAI()
        let count = StubCounter()
        StubHTTP.respond { r in
            guard r.url.path.hasSuffix("/api/chat") else { return (200, StubHTTP.json(["models": []])) }
            return (200, TestEnv.ollamaReply(count.next() == 1 ? "Qh5, obviously" : "e4"))
        }
        let (m, replies) = await ModelPlayer(ai: ai).move(Game(), player: .model(.ollama, "qwen3:8b", fallback: .cadet))
        XCTAssertEqual(m?.uci, "e2e4")
        XCTAssertEqual(replies.map(\.valid), [false, true])
        XCTAssertEqual(replies.map(\.attempt), [1, 2])
        XCTAssertFalse(replies.contains { $0.fallback })
        let second = String(decoding: StubHTTP.requests.filter { $0.url.path.hasSuffix("/api/chat") }.last!.body, as: UTF8.self)
        XCTAssertTrue(second.contains("rejected"), "the retry tells the model what was wrong")
        XCTAssertTrue(second.contains("Qh5"))
    }

    func testThreeInvalidRepliesHandTheMoveToTheEngine() async {
        let ai = TestEnv.stubbedAI()
        StubHTTP.respond { r in
            r.url.path.hasSuffix("/api/chat") ? (200, TestEnv.ollamaReply("I think I'll resign.")) : (200, StubHTTP.json(["models": []]))
        }
        let (m, replies) = await ModelPlayer(ai: ai).move(Game(), player: .model(.ollama, "qwen3:8b", fallback: .cadet))
        XCTAssertNil(m)
        XCTAssertEqual(replies.count, ModelPlayer.maxAsks, "asked once plus 2 re-asks")
        XCTAssertEqual(replies.map(\.fallback), [false, false, true])
    }

    func testBackendDownCountsAsFailedAsksNotACrash() async {
        let ai = TestEnv.stubbedAI()
        StubHTTP.respond { _ in (500, StubHTTP.json(["error": "down"])) }
        let (m, replies) = await ModelPlayer(ai: ai).move(Game(), player: .model(.ollama, "qwen3:8b", fallback: .cadet))
        XCTAssertNil(m)
        XCTAssertEqual(replies.count, 3)
        XCTAssertTrue(replies.allSatisfy { $0.error != nil && $0.san == nil })
    }
}

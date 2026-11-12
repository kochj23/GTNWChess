//
//  IntegrationTests.swift
//  GTNWChessTests
//
//  Real Stockfish over UCI (skipped if absent), real TLS-PSK LAN sessions on loopback, and the play-history writer
//  against a throwaway TLS Postgres 17 with the vendored NovaGames play.sql (skipped if Postgres isn't installed).
//

import XCTest
import NovaAIKit
@testable import GTNWChess

final class StockfishIntegrationTests: XCTestCase {
    private func engine() throws -> UCIEngine {
        guard let url = UCIEngine.locate() else { throw XCTSkip("Stockfish not bundled or installed") }
        return UCIEngine(url: url, timeout: 20)
    }

    func testBestMoveIsLegalAndNameReported() async throws {
        let e = try engine()
        let uci = try await e.bestMove(fen: Position.startFEN, moves: ["e2e4", "e7e5"], level: .captain)
        var g = try Fixtures.game(["e4", "e5"])
        XCTAssertNoThrow(try g.play(uci: uci))
        let name = await e.name
        XCTAssertTrue(name.lowercased().contains("stockfish"), name)
        await e.shutdown()
        let running = await e.isRunning
        XCTAssertFalse(running, "process cleaned up")
    }

    func testFindsMateInOne() async throws {
        let e = try engine()
        let fen = try Fixtures.game(["e4", "e5", "Bc4", "Nc6", "Qh5", "Nf6"]).position.fen
        let ev = try await e.evaluate(fen: fen, depth: 10)
        XCTAssertEqual(ev.bestMove, "h5f7")
        XCTAssertEqual(ev.mate, 1)
        await e.shutdown()
    }

    func testEvaluationIsWhitePointOfView() async throws {
        let e = try engine()
        // Black to move, black is a queen down.
        let ev = try await e.evaluate(fen: "4k3/8/8/8/8/8/8/3QK3 b - - 0 1", depth: 8)
        XCTAssertGreaterThan(ev.pawns, 3)
        await e.shutdown()
    }

    func testServiceAnalysesAGame() async throws {
        guard let url = UCIEngine.locate() else { throw XCTSkip("Stockfish not available") }
        let svc = EngineService(primary: UCIEngine(url: url))
        let g = try Fixtures.game(Fixtures.foolsMate)
        let a = try await svc.analyze(g, depth: 8)
        XCTAssertEqual(a.moves.count, 4)
        XCTAssertEqual(a.moves[2].classification, .blunder, "g4 allows mate")
        XCTAssertEqual(a.decisiveMoment?.san, "g4")
        XCTAssertTrue(a.engine.lowercased().contains("stockfish"))
        await svc.shutdown()
    }
}

@MainActor
final class LANIntegrationTests: XCTestCase {
    private func hostAndPort(code: String) async throws -> (LANSession, UInt16) {
        let host = LANSession()
        try host.host(code: code, serviceName: "test", advertise: false)
        _ = await waitUntil(10) { host.listeningPort != nil && host.listeningPort != 0 }
        return (host, try XCTUnwrap(host.listeningPort))
    }

    func testTLSPSKSessionExchangesMessagesBothWays() async throws {
        let (host, port) = try await hostAndPort(code: "424242")
        defer { host.stop() }
        var hostGot: [LANMessage] = [], guestGot: [LANMessage] = []
        host.onMessage = { hostGot.append($0) }
        let guest = LANSession()
        defer { guest.stop() }
        guest.onMessage = { guestGot.append($0) }
        try guest.join(host: "127.0.0.1", port: port, code: "424242")
        let ok1 = await waitUntil(10) { guest.isConnected && host.isConnected }; XCTAssertTrue(ok1)
        guest.send(.move(ply: 1, uci: "e2e4", clockMs: nil))
        host.send(.drawOffer(ply: 1))
        let ok2 = await waitUntil(5) { !hostGot.isEmpty && !guestGot.isEmpty }; XCTAssertTrue(ok2)
        XCTAssertEqual(hostGot.first, .move(ply: 1, uci: "e2e4", clockMs: nil))
        XCTAssertEqual(guestGot.first, .drawOffer(ply: 1))
    }

    func testWrongPairingCodeNeverConnects() async throws {
        let (host, port) = try await hostAndPort(code: "111111")
        defer { host.stop() }
        var hostGot: [LANMessage] = []
        host.onMessage = { hostGot.append($0) }
        let guest = LANSession()
        defer { guest.stop() }
        try guest.join(host: "127.0.0.1", port: port, code: "222222")
        let ok3 = await waitUntil(15) { if case .failed = guest.status { return true } else { return false } }; XCTAssertTrue(ok3)
        guest.send(.move(ply: 1, uci: "e2e4", clockMs: nil))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(hostGot.isEmpty)
        XCTAssertFalse(host.isConnected)
    }

    func testGuestReconnectsAfterDrop() async throws {
        let (host, port) = try await hostAndPort(code: "333333")
        defer { host.stop() }
        let guest = LANSession()
        defer { guest.stop() }
        guest.sleeper = { _ in try? await Task.sleep(nanoseconds: 300_000_000) }
        try guest.join(host: "127.0.0.1", port: port, code: "333333")
        let ok4 = await waitUntil(10) { guest.isConnected }; XCTAssertTrue(ok4)
        // Host restarts its listener on the same port (drops the connection).
        host.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        try host.host(code: "333333", serviceName: "test", port: port, advertise: false)
        _ = await waitUntil(5) { if case .listening = host.status { return true } else { return false } }
        let ok5 = await waitUntil(20) { guest.isConnected && host.isConnected }; XCTAssertTrue(ok5, "\(guest.status)")
    }
}

final class PlayDBIntegrationTests: XCTestCase {
    func testPGSinkWritesSessionEventsAndEnd() async throws {
        let pg = try LocalPostgres.require()
        let sink = PGPlaySink(config: pg.config(), password: { pg.passwords["gtnwchess_mac"]! })
        let g = try Fixtures.game(Fixtures.scholarsMate)
        let id = UUID(), t = Date()
        let ctx = PlayContext(sessionID: id, mode: .vsNova, white: .human("Little Mister", local: true, account: "default"),
                              black: .nova(.pilot), you: "white", clock: nil, startedAt: t, startFEN: nil)
        try await sink.start(id: id, startedAt: t)
        var evs = [PlayReport.startEvent(ctx, at: t)]
        for (i, pm) in g.moves.enumerated() { evs.append(PlayReport.plyEvent(pm, ply: i + 1, moveNumber: i / 2 + 1, seq: i + 1, at: t)) }
        try await sink.events(id: id, evs, actions: 7)
        let fin = PlayReport.finalEvents(g, analysis: nil, firstSeq: evs.count, at: t, opening: Openings.classify(g.sanMoves))
        try await sink.events(id: id, fin, actions: 7)
        let summary = PlayReport.summary(g, ctx, analysis: nil, opening: Openings.classify(g.sanMoves), white: "Little Mister", black: "Nova",
                                         duration: 90, takebacks: 0)
        try await sink.end(id: id, startedAt: t, PlaySessionEnd(outcome: "win", score: nil, actions: 7, summary: summary, endedAt: t.addingTimeInterval(90)))
        // Idempotent: replaying the same writes (outbox retry after a lost ack) doesn't duplicate.
        try await sink.start(id: id, startedAt: t)
        try await sink.events(id: id, evs, actions: 7)

        let row = try pg.psql("SELECT game, client, writer, player, ended_at IS NOT NULL, outcome FROM play.sessions WHERE id='\(id.uuidString.lowercased())'", db: "games")
        XCTAssertEqual(row, "gtnwchess|mac|gtnwchess_mac|default|t|win")
        let n = try pg.psql("SELECT count(*), count(DISTINCT seq) FROM play.events WHERE session_id='\(id.uuidString.lowercased())'", db: "games")
        XCTAssertEqual(n, "\(evs.count + fin.count)|\(evs.count + fin.count)")
        let term = try pg.psql("SELECT summary->>'termination' FROM play.sessions WHERE id='\(id.uuidString.lowercased())'", db: "games")
        XCTAssertEqual(term, "checkmate")
    }

    func testRoleCannotDeleteOrTouchOthersRows() async throws {
        let pg = try LocalPostgres.require()
        let c = try await PGConnection.connect(pg.config(), password: pg.passwords["gtnwchess_mac"]!)
        defer { c.close() }
        do { _ = try await c.execute("DELETE FROM play.sessions"); XCTFail("DELETE allowed") } catch {}
        do { _ = try await c.execute("CREATE TABLE play.x (i int)"); XCTFail("DDL allowed") } catch {}
        let other = try await PGConnection.connect(pg.config(user: "other_writer"), password: pg.passwords["other_writer"]!)
        defer { other.close() }
        let seen = try await other.execute("SELECT count(*) FROM play.sessions WHERE writer = 'gtnwchess_mac'")
        XCTAssertEqual(seen.first?.first ?? nil, "0", "row-level security hides another writer's rows")
    }

    @MainActor
    func testControllerGameDrainsIntoRealDB() async throws {
        let pg = try LocalPostgres.require()
        let c = TestEnv.controller(sink: nil)
        var cfg = NewGameConfig(); cfg.mode = .hotseat; c.newGame(cfg)
        XCTAssertTrue(TestEnv.play(c, Fixtures.foolsMate))
        let ok6 = await waitUntil(30) { c.outbox.pending.last?.kindName == "end" }; XCTAssertTrue(ok6, "game finished and queued offline")
        let id = try XCTUnwrap(c.recorder.context?.sessionID).uuidString.lowercased()
        c.outbox.sink = PGPlaySink(config: pg.config(), password: { pg.passwords["gtnwchess_mac"]! })
        await c.outbox.flushNow()
        XCTAssertTrue(c.outbox.pending.isEmpty, c.outbox.lastError ?? "")
        XCTAssertEqual(try pg.psql("SELECT ended_at IS NOT NULL, outcome, summary->>'winner' FROM play.sessions WHERE id='\(id)'", db: "games"),
                       "t|hotseat|black")
        XCTAssertEqual(try pg.psql("SELECT count(*) FROM play.events WHERE session_id='\(id)' AND kind='ply'", db: "games"), "4")
        XCTAssertEqual(try pg.psql("SELECT count(*) FROM play.events WHERE session_id='\(id)' AND kind='game_over'", db: "games"), "1")
    }
}

/// Opt-in (GTNW_LIVE_AI=1): the real fleet backends answer a coach request, and the answer passes the validator.
@MainActor
final class LiveAIIntegrationTests: XCTestCase {
    func testFleetBackendsAnswerCoachRequests() async throws {
        guard ProcessInfo.processInfo.environment["GTNW_LIVE_AI"] == "1" else { throw XCTSkip("set GTNW_LIVE_AI=1 to call the LAN fleet") }
        let g = try Fixtures.game(["e4", "e5", "Nf3", "Nc6", "Bc4"])
        for backend in [NovaAIBackend.ollama, .novaGateway, .auto] {
            var s = AppAI.configuration.defaultSettings
            s.backend = backend
            let ai = NovaAI(configuration: AppAI.configuration, storage: NovaAIMemoryStorage(s), keyStore: NovaAIMemoryKeyStore())
            let r = await NovaNarrator(ai: ai).coach(game: g, playerName: "Tester")
            print("LIVEAI \(backend.rawValue): source=\(r.source) text=\(r.value.prefix(300))")
        }
    }
}

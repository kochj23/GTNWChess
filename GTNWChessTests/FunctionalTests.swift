//
//  FunctionalTests.swift
//  GTNWChessTests
//
//  Whole flows through GameController: hot-seat and vs-Nova games to the end with play history, takebacks,
//  draws, resignation, promotion, save/resume, PGN study mode, AI narration with fallback, and a full LAN game
//  between two controllers over TLS-PSK where only the host writes the session.
//

import XCTest
import NovaAIKit
@testable import GTNWChess

@MainActor
final class FunctionalTests: XCTestCase {
    override func tearDown() { StubHTTP.reset() }

    func testHotseatGameIsRecordedEndToEnd() async throws {
        let c = TestEnv.controller()
        var cfg = NewGameConfig(); cfg.mode = .hotseat; cfg.playerName = "Solar Player"; cfg.opponentName = "Void Player"
        c.newGame(cfg)
        XCTAssertTrue(TestEnv.play(c, Fixtures.scholarsMate))
        XCTAssertEqual(c.game.result, GameResult(winner: .white, termination: .checkmate))
        let ok7 = await waitUntil(30) { c.outbox.pending.last?.kindName == "end" }; XCTAssertTrue(ok7)
        let ops = c.outbox.pending
        XCTAssertEqual(ops.first?.kindName, "start")
        XCTAssertEqual(Set(ops.map(\.sessionID)).count, 1, "one game = one session")
        let events = ops.flatMap(\.eventRecords)
        XCTAssertEqual(events.map(\.seq), Array(0..<events.count), "contiguous seq")
        XCTAssertEqual(events.first?.kind, "game_start")
        XCTAssertEqual(events.filter { $0.kind == "ply" }.count, 7)
        XCTAssertEqual(events.filter { $0.kind == "move" }.count, 7)
        XCTAssertEqual(events.last?.kind, "game_over")
        guard case .end(_, _, let end) = ops.last! else { return XCTFail() }
        XCTAssertEqual(end.outcome, "hotseat")
        let s = jsonObject(end.summary)
        XCTAssertEqual(s["termination"] as? String, "checkmate")
        XCTAssertNotNil(s["analysis"] as? [String: Any], "post-game analysis attached")
        let okRecap = await waitUntil(30) { c.recap != nil }; XCTAssertTrue(okRecap, "recap lands after the end op (it waits on the narrator)")
    }

    func testVsNovaEngineRepliesAndTakebackReturnsToHumanTurn() async throws {
        let c = TestEnv.controller()
        var cfg = NewGameConfig(); cfg.mode = .vsNova; cfg.level = .cadet; cfg.side = "white"
        c.newGame(cfg)
        XCTAssertTrue(TestEnv.play(c, ["e4"]))
        XCTAssertFalse(c.canInteract, "Nova is thinking")
        let ok8 = await waitUntil(15) { c.game.ply == 2 }; XCTAssertTrue(ok8)
        XCTAssertTrue(c.canInteract)
        c.undo()
        XCTAssertEqual(c.game.ply, 0)
        XCTAssertEqual(c.game.sideToMove, .white)
        let kinds = c.outbox.pending.flatMap(\.eventRecords).map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == "takeback" }.count, 1)
    }

    func testWatchModeNovaPlaysBothSidesAndIsRecordedAsAIvsAI() async {
        UserDefaults.standard.set(0.2, forKey: Prefs.watchDelay)
        defer { UserDefaults.standard.removeObject(forKey: Prefs.watchDelay) }
        let c = TestEnv.controller()
        var cfg = NewGameConfig(); cfg.mode = .watch; cfg.level = .cadet; cfg.blackLevel = .scout
        c.newGame(cfg)
        XCTAssertEqual(c.you, "none")
        XCTAssertFalse(c.canInteract, "spectators can't move pieces")
        XCTAssertNil(c.resigningSide)
        XCTAssertEqual(c.player(.black).level, EngineLevel.scout.rawValue)
        let ok = await waitUntil(20) { c.game.ply >= 4 }; XCTAssertTrue(ok, "Nova plays both sides on her own")
        guard case .start(_, _, let player)? = c.outbox.pending.first else { return XCTFail("watch games are recorded") }
        XCTAssertEqual(player, "AI vs AI", "never a person's name")
    }

    func testWatchPauseHoldsAndTakeOverHandsTheSeatOver() async {
        UserDefaults.standard.set(0.2, forKey: Prefs.watchDelay)
        defer { UserDefaults.standard.removeObject(forKey: Prefs.watchDelay) }
        let c = TestEnv.controller()
        var cfg = NewGameConfig(); cfg.mode = .watch; cfg.level = .cadet; cfg.blackLevel = .cadet
        c.newGame(cfg)
        let started = await waitUntil(15) { c.game.ply >= 1 }; XCTAssertTrue(started)
        c.setWatchPaused(true)
        let settled = await waitUntil(5) { !c.engineThinking }; XCTAssertTrue(settled)
        let held = c.game.ply
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(c.game.ply, held, "paused: no further moves")
        let side = c.game.sideToMove
        c.takeOver()
        XCTAssertEqual(c.mode, .vsNova)
        XCTAssertTrue(c.isLocal(side))
        XCTAssertTrue(c.canInteract, "your move now")
        XCTAssertEqual(c.player(side).kind, "human")
        let ops = c.outbox.pending
        let watchID = ops.first!.sessionID
        guard case .end(let id, _, let end)? = ops.first(where: { $0.kindName == "end" }) else { return XCTFail("watch session closed") }
        XCTAssertEqual(id, watchID)
        XCTAssertEqual(end.outcome, "taken_over")
        XCTAssertEqual(end.player, "AI vs AI")
        XCTAssertEqual(jsonObject(end.summary)["spectator"] as? Bool, true)
        guard case .start(let humanID, _, let p)? = ops.last(where: { $0.kindName == "start" }) else { return XCTFail() }
        XCTAssertNotEqual(humanID, watchID, "your part is a new, normal session")
        XCTAssertNil(p, "recorded under your own name")
    }

    func testVsNovaAsBlackEngineOpens() async {
        let c = TestEnv.controller()
        var cfg = NewGameConfig(); cfg.mode = .vsNova; cfg.level = .scout; cfg.side = "black"
        c.newGame(cfg)
        XCTAssertTrue(c.flipped)
        let ok9 = await waitUntil(15) { c.game.ply == 1 }; XCTAssertTrue(ok9)
        XCTAssertEqual(c.game.moves.first?.side, .white)
    }

    func testResignRecordsLossForThePlayer() async {
        let c = TestEnv.controller()
        var cfg = NewGameConfig(); cfg.mode = .vsNova; cfg.side = "white"; c.newGame(cfg)
        c.resign()
        XCTAssertEqual(c.game.result, GameResult(winner: .black, termination: .resignation))
        XCTAssertFalse(c.canUndo, "no takebacks after resigning")
        let ok10 = await waitUntil(30) { c.outbox.pending.last?.kindName == "end" }; XCTAssertTrue(ok10)
        guard case .end(_, _, let e) = c.outbox.pending.last! else { return XCTFail() }
        XCTAssertEqual(e.outcome, "loss")
        XCTAssertTrue(c.outbox.pending.flatMap(\.eventRecords).contains { $0.kind == "resign" })
    }

    func testHotseatDrawOfferAcceptedAndDeclined() {
        let c = TestEnv.controller()
        var cfg = NewGameConfig(); cfg.mode = .hotseat; c.newGame(cfg)
        TestEnv.play(c, ["e4", "e5"])
        c.offerDraw()
        XCTAssertTrue(c.mustAnswerDraw)
        c.respondToDraw(false)
        XCTAssertNil(c.game.result)
        c.offerDraw()
        c.respondToDraw(true)
        XCTAssertEqual(c.game.result?.termination, .agreement)
        let offers = c.outbox.pending.flatMap(\.eventRecords).filter { $0.kind == "draw_offer" }.map { jsonObject($0.detail)["accepted"] as? Bool }
        XCTAssertEqual(offers, [false, true])
    }

    func testNovaDeclinesEarlyDraw() async {
        let c = TestEnv.controller()
        var cfg = NewGameConfig(); cfg.mode = .vsNova; cfg.side = "white"; c.newGame(cfg)
        c.offerDraw()
        let ok11 = await waitUntil(10) { c.feed.contains { $0.text.contains("declines") } }; XCTAssertTrue(ok11)
        XCTAssertNil(c.game.result)
    }

    func testPromotionPickerFlow() {
        let c = TestEnv.controller()
        try? c.loadFEN("7k/P7/8/8/8/8/8/K7 w - - 0 1")
        let a7 = Sq.parse("a7")!, a8 = Sq.parse("a8")!
        c.tap(a7)
        XCTAssertEqual(c.selected, a7)
        c.tap(a8)
        XCTAssertEqual(c.promotion, PendingPromotion(from: a7, to: a8, side: .white))
        XCTAssertEqual(c.game.ply, 0, "nothing moves until a piece is chosen")
        c.choosePromotion(.rook)
        XCTAssertNil(c.promotion)
        XCTAssertEqual(c.game.position.piece(at: a8)?.kind, .rook)
        XCTAssertEqual(c.game.lastMove?.san, "a8=R+")
    }

    func testSaveAndResume() throws {
        GameStore.clear()
        let a = TestEnv.controller(persist: true)
        var cfg = NewGameConfig(); cfg.mode = .hotseat; cfg.playerName = "Resumer"; a.newGame(cfg)
        TestEnv.play(a, ["d4", "d5", "c4"])
        let sid = a.recorder.context?.sessionID
        let b = TestEnv.controller(persist: true)
        XCTAssertTrue(b.resumeSaved())
        XCTAssertEqual(b.game.sanMoves, ["d4", "d5", "c4"])
        XCTAssertEqual(b.white.name, "Resumer")
        XCTAssertEqual(b.recorder.context?.sessionID, sid, "same session continues")
        XCTAssertEqual(b.recorder.seq, a.recorder.seq)
        GameStore.clear()
        XCTAssertFalse(TestEnv.controller(persist: true).resumeSaved())
    }

    func testPGNImportIsStudyOnlyAndNotRecorded() throws {
        let c = TestEnv.controller()
        try c.importPGN(Fixtures.operaPGN)
        XCTAssertEqual(c.game.moves.count, 33)
        XCTAssertEqual(c.white.name, "Paul Morphy")
        XCTAssertFalse(c.recorder.isEnabled)
        XCTAssertTrue(c.outbox.pending.isEmpty)
        XCTAssertTrue(c.exportPGN().contains("Rd8#"))
    }

    func testFallbackEnginePlaysAWholeGameLegally() async throws {
        let engine = EngineService(primary: nil)
        var g = Game()
        while !g.isOver && g.ply < 120 {
            let m = try await engine.bestMove(for: g, level: g.sideToMove == .white ? .captain : .cadet)
            try g.play(m)
        }
        XCTAssertTrue(g.isOver || g.ply == 120)
        XCTAssertEqual(try PGN.importGame(PGN.export(g, white: "S", black: "C")).game.uciMoves, g.uciMoves)
    }

    func testCoachUsesValidAIAndRejectsInventedMoves() async throws {
        let ai = TestEnv.stubbedAI()
        let g = try Fixtures.game(["e4", "e5", "Nf3"])
        StubHTTP.respond { _ in (200, TestEnv.ollamaReply("Nf3 eyes your pawn on e5. Defend it with Nc6.")) }
        let good = await NovaNarrator(ai: ai).coach(game: g, playerName: "Tester")
        XCTAssertTrue(good.isAI)
        XCTAssertTrue(good.value.contains("Nc6"))
        StubHTTP.respond { _ in (200, TestEnv.ollamaReply("Play Qxf7# right now, it's mate.")) }
        let bad = await NovaNarrator(ai: ai).coach(game: g, playerName: "Tester")
        XCTAssertFalse(bad.isAI, "an invented move is never shown")
        XCTAssertEqual(bad.value, ScriptedCoach.explain(CoachFacts.make(game: g), playerName: "Tester"))
    }

    func testOfflineAIUsesScriptForEverything() async throws {
        let ai = AppAI.makeShared()
        let g = try Fixtures.game(Fixtures.scholarsMate)
        let n = NovaNarrator(ai: ai)
        let talk = await n.battleTalk(attacker: .queen, victim: .pawn, attackerSide: .white, game: g)
        XCTAssertEqual(talk.source.label, "Built-in")
        let recap = await n.recap(game: g, white: "A", black: "B", analysis: nil, opening: Openings.classify(g.sanMoves))
        XCTAssertTrue(recap.value.contains("wins by checkmate"))
    }

    // MARK: LAN

    func testFullLANGameOnlyHostWrites() async throws {
        let host = TestEnv.controller(), guest = TestEnv.controller()
        defer { host.stopLAN(); guest.stopLAN() }
        let code = try host.hostLAN(name: "Hosty", side: "white", clock: ClockConfig(initialSeconds: 600, incrementSeconds: 0))
        let ok12 = await waitUntil(10) { (host.lan.listeningPort ?? 0) != 0 }; XCTAssertTrue(ok12)
        try guest.joinLAN(nil, address: "127.0.0.1:\(host.lan.listeningPort!)", code: code, name: "Guesty")
        let ok13 = await waitUntil(15) { guest.you == "black" && guest.lan.isConnected && !host.waitingForGuest }; XCTAssertTrue(ok13)
        XCTAssertEqual(host.black.name, "Guesty")
        XCTAssertEqual(guest.white.name, "Hosty")
        for (i, san) in Fixtures.scholarsMate.enumerated() {
            let mover = i % 2 == 0 ? host : guest
            let ok14 = await waitUntil(10) { mover.canInteract }; XCTAssertTrue(ok14, "ply \(i + 1)")
            XCTAssertTrue(TestEnv.play(mover, [san]))
            let ok15 = await waitUntil(10) { host.game.ply == i + 1 && guest.game.ply == i + 1 }; XCTAssertTrue(ok15)
        }
        XCTAssertEqual(host.game.result, GameResult(winner: .white, termination: .checkmate))
        XCTAssertEqual(guest.game.result, host.game.result)
        XCTAssertEqual(guest.game.uciMoves, host.game.uciMoves)
        let ok16 = await waitUntil(30) { host.outbox.pending.last?.kindName == "end" }; XCTAssertTrue(ok16)
        XCTAssertTrue(guest.outbox.pending.isEmpty, "the guest never writes: one game = one session")
        XCTAssertFalse(guest.recorder.isEnabled)
        guard case .end(_, _, let e) = host.outbox.pending.last! else { return XCTFail() }
        XCTAssertEqual(e.outcome, "win")
        XCTAssertNotNil(host.game.moves.last?.clockMs, "clock times travel with moves")
    }

    func testLANResignAndDrawTravel() async throws {
        let host = TestEnv.controller(), guest = TestEnv.controller()
        defer { host.stopLAN(); guest.stopLAN() }
        let code = try host.hostLAN(name: "H", side: "black", clock: nil)
        let ok17 = await waitUntil(10) { (host.lan.listeningPort ?? 0) != 0 }; XCTAssertTrue(ok17)
        try guest.joinLAN(nil, address: "127.0.0.1:\(host.lan.listeningPort!)", code: code, name: "G")
        let ok18 = await waitUntil(15) { guest.black.name == "H" && !host.waitingForGuest && guest.lan.isConnected }; XCTAssertTrue(ok18)
        guest.offerDraw()
        let ok19 = await waitUntil(10) { host.mustAnswerDraw }; XCTAssertTrue(ok19)
        host.respondToDraw(false)
        let ok20 = await waitUntil(10) { guest.drawOfferFrom == nil }; XCTAssertTrue(ok20)
        XCTAssertNil(guest.game.result)
        guest.resign()
        let ok21 = await waitUntil(10) { host.game.result != nil }; XCTAssertTrue(ok21)
        XCTAssertEqual(host.game.result, GameResult(winner: .black, termination: .resignation))
        let ok22 = await waitUntil(30) { host.outbox.pending.last?.kindName == "end" }; XCTAssertTrue(ok22)
        guard case .end(_, _, let e) = host.outbox.pending.last! else { return XCTFail() }
        XCTAssertEqual(e.outcome, "win", "host (black) wins by resignation")
        XCTAssertTrue(guest.outbox.pending.isEmpty)
        XCTAssertFalse(host.canUndo, "no takebacks in LAN games")
    }

    func testHostWithFixedCodeBindsOnce() async throws {
        let c = TestEnv.controller()
        defer { c.stopLAN() }
        XCTAssertThrowsError(try c.hostLAN(name: "H", side: "white", clock: nil, code: "12x456"))
        let code = try c.hostLAN(name: "H", side: "white", clock: nil, code: "482913")
        XCTAssertEqual(code, "482913")
        XCTAssertEqual(c.lanInfo?.code, "482913")
        let ok = await waitUntil(10) { if case .listening(let p) = c.lan.status { return p != 0 } else { return false } }
        XCTAssertTrue(ok, "\(c.lan.status)")
    }
}

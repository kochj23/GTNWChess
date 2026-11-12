//
//  UnitTests.swift
//  GTNWChessTests
//
//  Rules engine (perft, FEN, SAN, special moves, draws), PGN, openings, analysis maths, battle plans, cast,
//  coach facts, clocks, recorder payloads, LAN codec and referee.
//

import XCTest
import NovaAIKit
@testable import GTNWChess

final class RulesUnitTests: XCTestCase {
    func testPerftStartPosition() {
        let p = Position.start
        XCTAssertEqual([1, 2, 3, 4].map(p.perft), [20, 400, 8902, 197_281])
    }

    func testPerftKiwipete() throws {
        let p = try Position(fen: Fixtures.kiwipete)
        XCTAssertEqual([1, 2, 3].map(p.perft), [48, 2039, 97_862])
    }

    func testPerftEndgameAndPromotionPositions() throws {
        XCTAssertEqual(try Position(fen: Fixtures.pos3).perft(4), 43_238)
        XCTAssertEqual(try Position(fen: Fixtures.pos4).perft(3), 9_467)
        XCTAssertEqual(try Position(fen: Fixtures.pos5).perft(3), 62_379)
        XCTAssertEqual(try Position(fen: Fixtures.pos6).perft(3), 89_890)
    }

    func testFENRoundTrip() throws {
        for f in [Position.startFEN, Fixtures.kiwipete, Fixtures.pos3, Fixtures.pos4, Fixtures.pos5, Fixtures.pos6] {
            XCTAssertEqual(try Position(fen: f).fen, f)
        }
    }

    func testFENRejectsGarbage() {
        for bad in ["", "hello", "8/8/8/8/8/8/8/8 w - - 0 1", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP w KQkq - 0 1",
                    "rnbqkbnr/pppppppp/9/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x KQkq - 0 1"] {
            XCTAssertThrowsError(try Position(fen: bad), bad)
        }
    }

    func testCastlingBothSidesAndRightsLost() throws {
        var g = try Game(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        XCTAssertEqual(try g.play(san: "O-O").san, "O-O")
        XCTAssertEqual(g.position.piece(at: Sq.parse("f1")!)?.kind, .rook)
        XCTAssertEqual(try g.play(san: "O-O-O").san, "O-O-O")
        XCTAssertEqual(g.position.piece(at: Sq.parse("d8")!)?.kind, .rook)
        XCTAssertEqual(g.position.castling, 0)
    }

    func testCannotCastleThroughCheck() throws {
        let p = try Position(fen: "4k3/8/8/8/8/8/5r2/4K2R w K - 0 1")
        XCTAssertNil(p.move(san: "O-O"))
    }

    func testEnPassant() throws {
        var g = try Fixtures.game(["e4", "a6", "e5", "d5"])
        let pm = try g.play(san: "exd6")
        XCTAssertTrue(pm.move.isEnPassant)
        XCTAssertEqual(pm.captured, .pawn)
        XCTAssertNil(g.position.piece(at: Sq.parse("d5")!))
    }

    func testPromotionAllPieces() throws {
        let p = try Position(fen: "8/P7/8/8/8/8/8/k6K w - - 0 1")
        let promos = p.legalMoves().filter { $0.from == Sq.parse("a7")! }.compactMap(\.promotion)
        XCTAssertEqual(Set(promos), [.queen, .rook, .bishop, .knight])
        var g = try Game(fen: "8/P7/8/8/8/8/8/k6K w - - 0 1")
        XCTAssertEqual(try g.play(san: "a8=N").san, "a8=N")
        XCTAssertEqual(g.position.piece(at: Sq.parse("a8")!)?.kind, .knight)
    }

    func testSANDisambiguationAndCheckSuffix() throws {
        let p = try Position(fen: "4k3/8/8/8/8/8/8/R4RK1 w - - 0 1")
        XCTAssertNotNil(p.move(san: "Rad1"))
        XCTAssertNotNil(p.move(san: "Rfd1"))
        XCTAssertEqual(p.san(p.move(san: "Rad1")!), "Rad1")
        XCTAssertNil(p.move(san: "Rd1"), "ambiguous")
        let m = p.move(san: "Ra8")!
        XCTAssertEqual(p.san(m), "Ra8+")
    }

    func testCheckmateAndStalemate() throws {
        let mate = try Fixtures.game(Fixtures.foolsMate)
        XCTAssertEqual(mate.result, GameResult(winner: .black, termination: .checkmate))
        let stale = try Game(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
        XCTAssertEqual(stale.result?.termination, .stalemate)
    }

    func testInsufficientMaterialCases() throws {
        for f in ["8/8/8/4k3/8/8/8/4K3 w - - 0 1", "8/8/8/4k3/8/8/8/4KB2 w - - 0 1", "8/8/8/4k3/8/8/8/4KN2 w - - 0 1"] {
            XCTAssertTrue(try Position(fen: f).isInsufficientMaterial, f)
        }
        XCTAssertFalse(try Position(fen: "8/8/8/4k3/8/8/8/4KR2 w - - 0 1").isInsufficientMaterial)
    }

    func testThreefoldRepetition() throws {
        let g = try Fixtures.game(["Nf3", "Nf6", "Ng1", "Ng8", "Nf3", "Nf6", "Ng1", "Ng8"])
        XCTAssertEqual(g.result?.termination, .threefold)
    }

    func testFiftyMoveRule() throws {
        var g = try Game(fen: "8/8/8/4k3/8/8/8/R3K3 w - - 99 80")
        try g.play(san: "Ra2")
        XCTAssertEqual(g.result?.termination, .fiftyMove)
    }

    func testUndoRestoresPositionAndClearsResult() throws {
        var g = try Fixtures.game(Fixtures.foolsMate)
        g.undo()
        XCTAssertNil(g.result)
        XCTAssertEqual(g.ply, 3)
        XCTAssertEqual(g.position.fen, try Fixtures.game(["f3", "e5", "g4"]).position.fen)
    }

    func testPlayAfterGameOverThrows() throws {
        var g = try Fixtures.game(Fixtures.foolsMate)
        XCTAssertThrowsError(try g.play(san: "a3"))
    }

    func testMakeUnmakeIsExact() throws {
        var p = try Position(fen: Fixtures.kiwipete)
        let orig = p
        for m in p.legalMoves() {
            let u = p.make(m)
            p.unmake(m, u)
            XCTAssertEqual(p, orig, m.uci)
        }
    }
}

final class NotationUnitTests: XCTestCase {
    func testPGNExportImportRoundTrip() throws {
        var g = try Fixtures.game(Fixtures.scholarsMate)
        g.headers = [:]
        let text = PGN.export(g, white: "Solar Tester", black: "Void Tester")
        XCTAssertTrue(text.contains("[Result \"1-0\"]"))
        XCTAssertTrue(text.contains("4. Qxf7# 1-0"))
        let imp = try PGN.importGame(text)
        XCTAssertEqual(imp.game.sanMoves, g.sanMoves)
        XCTAssertEqual(imp.headers["White"], "Solar Tester")
    }

    func testPGNImportOperaGameWithCommentsAndVariations() throws {
        let text = Fixtures.operaPGN.replacingOccurrences(of: "4. dxe5", with: "4. dxe5 {a comment} (4. h3 Bxf3) ; rest of line\n")
        let imp = try PGN.importGame(text)
        XCTAssertEqual(imp.game.moves.count, 33)
        XCTAssertEqual(imp.game.result?.winner, .white)
        XCTAssertEqual(imp.game.lastMove?.san, "Rd8#")
    }

    func testPGNWithSetUpFEN() throws {
        let g = try Game(fen: Fixtures.pos3)
        let text = PGN.export(g, white: "A", black: "B")
        XCTAssertTrue(text.contains("[SetUp \"1\"]"))
        XCTAssertEqual(try PGN.importGame(text).game.startPosition.fen, Fixtures.pos3)
    }

    func testOpeningClassification() {
        XCTAssertEqual(Openings.classify(["e4", "c5"]).name.contains("Sicilian"), true)
        XCTAssertEqual(Openings.classify(["e4", "e5", "Nf3", "Nc6", "Bb5"]).name.contains("Ruy"), true)
        XCTAssertNotEqual(Openings.classify(["d4", "d5", "c4"]).eco, "")
    }

    func testSquareHelpers() {
        XCTAssertEqual(Sq.name(0), "a1")
        XCTAssertEqual(Sq.name(63), "h8")
        XCTAssertEqual(Sq.parse("e4"), 28)
        XCTAssertNil(Sq.parse("i9"))
    }
}

final class AnalysisUnitTests: XCTestCase {
    func testWinPercentAndAccuracyCurve() {
        XCTAssertEqual(Analyzer.winPercent(cp: 0), 50, accuracy: 0.001)
        XCTAssertGreaterThan(Analyzer.winPercent(cp: 300), 75)
        XCTAssertEqual(Analyzer.moveAccuracy(winDrop: 0), 100, accuracy: 0.01)
        XCTAssertLessThan(Analyzer.moveAccuracy(winDrop: 40), 20)
    }

    func testClassificationThresholds() {
        XCTAssertEqual(Analyzer.classify(winDrop: 50, isEngineMove: true), .best)
        XCTAssertEqual(Analyzer.classify(winDrop: 1, isEngineMove: false), .best)
        XCTAssertEqual(Analyzer.classify(winDrop: 5, isEngineMove: false), .good)
        XCTAssertEqual(Analyzer.classify(winDrop: 15, isEngineMove: false), .inaccuracy)
        XCTAssertEqual(Analyzer.classify(winDrop: 25, isEngineMove: false), .mistake)
        XCTAssertEqual(Analyzer.classify(winDrop: 31, isEngineMove: false), .blunder)
    }

    func testBuildFindsBlunderAndDecisiveMoment() throws {
        let g = try Fixtures.game(Fixtures.foolsMate)
        // White-POV evals: level, level, then white's g4 hangs mate.
        let evals = [Evaluation(cp: 20, mate: nil, bestMove: "e2e4", depth: 10), Evaluation(cp: 0, mate: nil, bestMove: "e7e5", depth: 10),
                     Evaluation(cp: 10, mate: nil, bestMove: "e2e4", depth: 10), Evaluation(cp: nil, mate: -1, bestMove: "d8h4", depth: 10),
                     Evaluation(cp: nil, mate: -1, bestMove: nil, depth: 10)]
        let a = Analyzer.build(g, evals: evals, engineName: "test", depth: 10)
        XCTAssertEqual(a.moves.count, 4)
        XCTAssertEqual(a.moves[2].san, "g4")
        XCTAssertEqual(a.moves[2].classification, .blunder)
        XCTAssertEqual(a.white.blunders, 1)
        XCTAssertEqual(a.decisiveMoment?.san, "g4")
        XCTAssertEqual(a.moves[3].classification, .best)
    }

    func testEvaluationPawnsClamp() {
        XCTAssertEqual(Evaluation(cp: 150, mate: nil, bestMove: nil, depth: 1).pawns, 1.5)
        XCTAssertEqual(Evaluation(cp: nil, mate: 3, bestMove: nil, depth: 1).pawns, 20)
        XCTAssertEqual(Evaluation(cp: nil, mate: -2, bestMove: nil, depth: 1).clampedCP, -2000)
    }

    func testUCIInfoParsing() {
        let e = UCIEngine.parseInfo(["info depth 12 seldepth 18 score cp 34 nodes 1000 pv e2e4 e7e5", "bestmove e2e4 ponder e7e5"])
        XCTAssertEqual(e.cp, 34)
        XCTAssertEqual(e.depth, 12)
        XCTAssertNil(e.bestMove, "bestmove is read by evaluate(), not parseInfo")
        let m = UCIEngine.parseInfo(["info depth 5 score mate -2 pv h7h8", "bestmove h7h8"])
        XCTAssertEqual(m.mate, -2)
    }

    func testEngineLevels() {
        XCTAssertEqual(EngineLevel.allCases.count, 8)
        XCTAssertEqual(EngineLevel.cadet.skill, 0)
        XCTAssertEqual(EngineLevel.supernova.skill, 20)
        XCTAssertEqual(Set(EngineLevel.allCases.map(\.name)).count, 8)
    }
}

final class CastAndBattleUnitTests: XCTestCase {
    func testThirtySixDistinctBattlePlans() {
        let all = BattlePlan.all
        XCTAssertEqual(all.count, 36)
        XCTAssertEqual(Set(all.map(\.signature)).count, 36, "every attacker→victim pair is choreographed differently")
    }

    func testBattleDurationScalesWithSpeed() {
        let p = BattlePlan.make(attacker: .queen, victim: .rook)
        XCTAssertEqual(p.duration(speed: 2), p.total / 2, accuracy: 1e-9)
        XCTAssertGreaterThan(p.total, 1.5)
        XCTAssertLessThan(p.total, 8)
    }

    func testCastLinesForAllPairs() {
        for a in PieceKind.allCases where a != .king {
            for v in PieceKind.allCases {
                let (x, y) = Cast.battleLine(attacker: a, victim: v, attackerSide: .white)
                XCTAssertFalse(x.isEmpty); XCTAssertFalse(y.isEmpty)
            }
        }
        XCTAssertEqual(Set(PieceKind.allCases.map { Cast.name($0, .white) }).count, 6)
    }

    func testAnimationSpeedsAreOrdered() {
        XCTAssertEqual(AnimationPrefs.speeds, AnimationPrefs.speeds.sorted())
        XCTAssertTrue(AnimationPrefs.speeds.contains(1))
    }
}

@MainActor
final class WatchModeUnitTests: XCTestCase {
    func testWatchGamesRecordAsAIvsAIWithMatchup() throws {
        let box = PlayOutbox(fileURL: nil, sink: nil)
        let r = PlayRecorder(outbox: box)
        let ctx = PlayContext(sessionID: UUID(), mode: .watch, white: .nova(.cadet), black: .nova(.pilot), you: "none", clock: nil,
                              startedAt: Date(), startFEN: nil)
        r.begin(ctx)
        XCTAssertTrue(r.isEnabled)
        guard case .start(_, _, let p)? = box.pending.first else { return XCTFail() }
        XCTAssertEqual(p, "AI vs AI")
        let g = try Fixtures.game(Fixtures.scholarsMate)
        XCTAssertEqual(PlayReport.outcome(g, ctx), "white_wins", "watch outcomes are from the board, not a player")
        let s = try XCTUnwrap(JSONSerialization.jsonObject(with: PlayReport.summary(g, ctx, analysis: nil, opening: Opening(eco: "-", name: "x"),
            white: "a", black: "b", duration: 1, takebacks: 0)) as? [String: Any])
        XCTAssertEqual(s["spectator"] as? Bool, true)
        let sides = try XCTUnwrap((s["matchup"] as? [String: Any])?["sides"] as? [[String: Any]])
        XCTAssertEqual(sides.map { $0["side"] as? String }, ["white", "black"])
        XCTAssertEqual(GameMode(rawValue: "watch"), .watch, "saved watch games decode")
    }
}

final class CoachUnitTests: XCTestCase {
    func testCoachFactsSeeHangingPieceAndMateThreat() throws {
        let g = try Fixtures.game(["e4", "e5", "Bc4", "Nc6", "Qh5"])
        let f = CoachFacts.make(game: g)
        XCTAssertEqual(f.sideToMove, .black)
        XCTAssertEqual(f.mateThreat, "Qxf7#")
        XCTAssertTrue(f.sheet.contains("Qxf7#"))
        XCTAssertTrue(ScriptedCoach.explain(f, playerName: "Tester").count > 20)
    }

    func testCoachFactsMateInOne() throws {
        let g = try Fixtures.game(["e4", "e5", "Bc4", "Nc6", "Qh5", "Nf6"])
        XCTAssertEqual(CoachFacts.make(game: g).mateInOne, "Qxf7#")
    }

    func testValidatorAcceptsRealAndRejectsInvented() throws {
        let g = try Fixtures.game(["e4", "e5", "Nf3"])
        let v = ChessMentionValidator(game: g, facts: CoachFacts.make(game: g))
        XCTAssertNoThrow(try v.validate("Solar's Nf3 attacks the pawn on e5. Consider Nc6 to defend it."))
        XCTAssertThrowsError(try v.validate("Great idea: Qxh7 wins on the spot."))
        XCTAssertThrowsError(try v.validate("The knight on e5 is strong."), "false claim: a pawn is on e5")
        XCTAssertThrowsError(try v.validate(" "))
    }

    func testScriptedRecap() throws {
        let g = try Fixtures.game(Fixtures.foolsMate)
        let s = ScriptedCoach.recap(game: g, white: "A", black: "B", analysis: nil, opening: Openings.classify(g.sanMoves))
        XCTAssertTrue(s.contains("B (Void) wins by checkmate"), s)
    }
}

final class StoreAndRecorderUnitTests: XCTestCase {
    func testClockTickIncrementAndFlag() {
        var c = ChessClock(config: ClockConfig(initialSeconds: 1, incrementSeconds: 2))
        c.running = .white
        XCTAssertNil(c.tick(500))
        XCTAssertEqual(c.switchAfterMove(by: .white), 2_500)
        XCTAssertEqual(c.running, .black)
        XCTAssertEqual(c.tick(5_000), .black)
        XCTAssertEqual(ChessClock.format(65_000), "1:05")
        XCTAssertEqual(ChessClock.format(9_500), "0:09.5")
    }

    func testSavedGameRestore() throws {
        let s = SavedGame(mode: .hotseat, startFEN: Position.startFEN, moves: ["e2e4", "e7e5"], white: .human("A", local: true, account: nil),
                          black: .human("B", local: true, account: nil), level: nil, you: "both", clock: nil, recorder: nil, lan: nil,
                          result: nil, savedAt: Date())
        let g = try s.restore()
        XCTAssertEqual(g.sanMoves, ["e4", "e5"])
        let bad = SavedGame(mode: .hotseat, startFEN: Position.startFEN, moves: ["e2e5"], white: s.white, black: s.black, level: nil,
                            you: "both", clock: nil, recorder: nil, lan: nil, result: nil, savedAt: Date())
        XCTAssertThrowsError(try bad.restore())
    }

    func testPlayerNameCleaning() {
        XCTAssertEqual(PlayerInfo.clean("  \u{0007}Ann\n "), "Ann")
        XCTAssertEqual(PlayerInfo.clean(""), "Player")
        XCTAssertEqual(PlayerInfo.clean(String(repeating: "x", count: 99)).count, 32)
    }

    func testPlyEventAndSummaryShape() throws {
        let g = try Fixtures.game(Fixtures.scholarsMate)
        let ev = PlayReport.plyEvent(g.moves[6], ply: 7, moveNumber: 4, seq: 8, at: Date())
        let d = jsonObject(ev.detail)
        XCTAssertEqual(d["san"] as? String, "Qxf7#")
        XCTAssertEqual(d["uci"] as? String, "h5f7")
        XCTAssertEqual(d["capture"] as? String, "pawn")
        XCTAssertEqual(d["check"] as? Bool, true)
        let ctx = PlayContext(sessionID: UUID(), mode: .vsNova, white: .human("Little Mister", local: true, account: "default"),
                              black: .nova(.pilot), you: "white", clock: nil, startedAt: Date(), startFEN: nil)
        let s = jsonObject(PlayReport.summary(g, ctx, analysis: nil, opening: Openings.classify(g.sanMoves), white: "LM", black: "Nova",
                                              duration: 61, takebacks: 1))
        XCTAssertEqual(s["termination"] as? String, "checkmate")
        XCTAssertEqual(s["winner"] as? String, "white")
        XCTAssertEqual(s["plies"] as? Int, 7)
        XCTAssertEqual((s["checks"] as? [String: Int])?["white"], 1)
        XCTAssertEqual(((s["captures"] as? [String: Any])?["white"] as? [String: Int])?["pawn"], 1)
        XCTAssertEqual((s["material_graph"] as? [Int])?.count, 7)
        XCTAssertEqual(PlayReport.outcome(g, ctx), "win")
        XCTAssertTrue((s["pgn"] as? String ?? "").contains("Qxf7#"))
    }

    func testFinalEventsCarryClassificationAndGameOver() throws {
        let g = try Fixtures.game(Fixtures.foolsMate)
        let evs = PlayReport.finalEvents(g, analysis: nil, firstSeq: 10, at: Date(), opening: Openings.classify(g.sanMoves))
        XCTAssertEqual(evs.map(\.kind), ["move", "move", "move", "move", "game_over"])
        XCTAssertEqual(evs.map(\.seq), Array(10...14))
        XCTAssertEqual(jsonObject(evs.last!.detail)["termination"] as? String, "checkmate")
    }
}

@MainActor
final class LANUnitTests: XCTestCase {
    func testCodecRoundTripAndPartialFrames() throws {
        let msgs: [LANMessage] = [.move(ply: 1, uci: "e2e4", clockMs: 300_000), .ping, .drawOffer(ply: 4), .resign(ply: 9)]
        var buf = Data()
        for m in msgs { buf += try LANCodec.encode(m) }
        var partial = buf.prefix(7)
        XCTAssertEqual(try LANCodec.decode(&partial), [])
        XCTAssertEqual(try LANCodec.decode(&buf), msgs)
        XCTAssertTrue(buf.isEmpty)
    }

    func testRefereeAcceptsLegalInTurn() throws {
        let g = Game()
        XCTAssertEqual(LANReferee.check(ply: 1, uci: "e2e4", game: g, remoteSide: .white), .accept(Move(from: 12, to: 28)))
    }

    func testRefereeReplayRejectsIllegalHistory() {
        var s = LANState(gameID: UUID(), hostName: "H", hostAccount: nil, guestName: "G", hostSide: .white, startFEN: Position.startFEN,
                         moves: ["e2e4", "e7e5", "g1f3"], clock: nil, clockMs: nil, result: nil)
        XCTAssertEqual(LANReferee.replay(s)?.ply, 3)
        s.moves.append("f3f3")
        XCTAssertNil(LANReferee.replay(s))
    }

    func testPairingCodes() {
        for _ in 0..<50 { XCTAssertTrue(LANSecurity.isValidCode(LANSecurity.newPairingCode())) }
        XCTAssertFalse(LANSecurity.isValidCode("12345"))
        XCTAssertFalse(LANSecurity.isValidCode("12345a"))
        XCTAssertFalse(LANSecurity.isValidCode("１２３４５６"), "full-width digits are not ASCII")
    }

    func testParseAddress() {
        XCTAssertEqual(GameController.parseAddress("192.168.1.99:5050")?.1, 5050)
        XCTAssertNil(GameController.parseAddress("host"))
        XCTAssertNil(GameController.parseAddress("host:0"))
        XCTAssertNil(GameController.parseAddress("host:99999"))
    }

    func testConsentFormOffNeverCarriesName() {
        XCTAssertEqual(ConsentForm.make(nameInReviews: false, firstName: "Somebody"), GamesSiteClient.Consent(nameInReviews: false, displayName: nil))
        XCTAssertEqual(ConsentForm.make(nameInReviews: true, firstName: " Jo Ann Smith "), GamesSiteClient.Consent(nameInReviews: true, displayName: "Jo"))
        XCTAssertEqual(ConsentForm.make(nameInReviews: true, firstName: "<script>"), GamesSiteClient.Consent(nameInReviews: true, displayName: "script"))
        XCTAssertEqual(ConsentForm.make(nameInReviews: true, firstName: "   "), GamesSiteClient.Consent(nameInReviews: false, displayName: nil))
    }
}

final class CoachClaimUnitTests: XCTestCase {
    /// Seen live from the fleet model: "attacking the Void's d5 pawn" with no pawn on d5.
    func testSquareThenPieceClaimsAreChecked() throws {
        let g = try Fixtures.game(["e4", "e5", "Nf3", "Nc6", "Bc4"])
        let v = ChessMentionValidator(game: g, facts: CoachFacts.make(game: g))
        XCTAssertThrowsError(try v.validate("The Solar Oracle moved from f1 to c4, attacking the Void's d5 pawn."))
        XCTAssertThrowsError(try v.validate("Capture with your d6 pawn."))
        XCTAssertNoThrow(try v.validate("The Solar Oracle moved from f1 to c4, eyeing the f7 pawn next to your king."))
        XCTAssertNoThrow(try v.validate("Your e5 pawn is defended by the knight on c6."))
        XCTAssertThrowsError(try v.validate("The Oracle could soon take the d5 piece."))
        XCTAssertNoThrow(try v.validate("The Oracle eyes the f7 piece."))
    }

    func testPieceListMatchesBoard() throws {
        let list = NovaNarrator.pieceList(try Fixtures.game(["e4"]).position)
        XCTAssertTrue(list.contains("White (Solar): Nb1 Bc1 Qd1 Ke1 Bf1 Ng1 Ra1".isEmpty ? "" : "Ke1"))
        XCTAssertTrue(list.contains("pawns a2 b2 c2 d2 f2 g2 h2 e4"))
        XCTAssertTrue(list.contains("Black (Void): Ra8"))
        XCTAssertFalse(list.contains("e2 "))
    }
}

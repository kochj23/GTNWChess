//
//  PerformanceTests.swift
//  GTNWChessTests
//
//  Hard time budgets (they fail when exceeded) plus XCTest measure blocks for trend tracking.
//

import XCTest
@testable import GTNWChess

@MainActor
final class PerformanceTests: XCTestCase {
    private func time(_ body: () throws -> Void) rethrows -> TimeInterval {
        let t = Date(); try body(); return Date().timeIntervalSince(t)
    }

    func testPerftDepth4Budget() throws {
        var n = 0
        let t = time { n = Position.start.perft(4) }
        XCTAssertEqual(n, 197_281)
        XCTAssertLessThan(t, 3.0, "perft(4) took \(t)s")
    }

    func testLegalMoveGenerationThroughput() throws {
        let p = try Position(fen: Fixtures.kiwipete)
        measure { for _ in 0..<2_000 { _ = p.legalMoves() } }
        let t = time { for _ in 0..<2_000 { _ = p.legalMoves() } }
        XCTAssertLessThan(t, 2.0)
    }

    func testPGNRoundTripOfLongGame() throws {
        // A long legal game: knights shuffle out and back, pawn moves in between dodge threefold and the 50-move rule.
        var g = Game()
        let pairs = [("a3", "a6"), ("b3", "b6"), ("d3", "d6"), ("e3", "e6"), ("g3", "g6"), ("h3", "h6"),
                     ("a4", "a5"), ("b4", "b5"), ("d4", "d5"), ("e4", "e5"), ("g4", "g5"), ("h4", "h5")]
        for (w, b) in pairs {
            for s in ["Nc3", "Nc6", "Nb1", "Nb8", w, b] { try g.play(san: s) }
        }
        XCTAssertEqual(g.ply, 72)
        XCTAssertFalse(g.isOver)
        let t = try time {
            let text = PGN.export(g, white: "A", black: "B")
            XCTAssertEqual(try PGN.importGame(text).game.uciMoves, g.uciMoves)
        }
        XCTAssertLessThan(t, 1.0)
    }

    func testCoachFactsAreCheapPerMove() throws {
        let g = try Fixtures.game(Array(Fixtures.operaGameSANs.prefix(20)))
        let t = time { for _ in 0..<200 { _ = CoachFacts.make(game: g) } }
        XCTAssertLessThan(t, 2.0, "coach facts must not stall the UI")
    }

    func testFallbackEngineAnswersQuickly() async throws {
        let e = FallbackEngine()
        let t0 = Date()
        let m = try await e.bestMove(fen: Fixtures.kiwipete, moves: [], level: .captain)
        XCTAssertNotNil(try Position(fen: Fixtures.kiwipete).move(uci: m))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10)
    }

    func testSynthRendersFast() {
        let t = time { for fx in SFX.allCases { _ = Synth.render(fx) } }
        XCTAssertLessThan(t, 2.0)
    }

    func testBoardSceneBuildAndSyncBudget() {
        let t = time {
            let s = BoardScene()
            for _ in 0..<20 { s.sync(Position.start); s.sync(try! Position(fen: Fixtures.kiwipete)) }
        }
        XCTAssertLessThan(t, 5.0)
    }

    func testSummaryStaysUnderPayloadLimit() throws {
        let g = try Fixtures.game(Fixtures.operaGameSANs)
        let ctx = PlayContext(sessionID: UUID(), mode: .hotseat, white: .human("A", local: true, account: nil),
                              black: .human("B", local: true, account: nil), you: "both", clock: nil, startedAt: Date(), startFEN: nil)
        let d = PlayReport.summary(g, ctx, analysis: nil, opening: Openings.classify(g.sanMoves), white: "A", black: "B", duration: 1, takebacks: 0)
        XCTAssertLessThan(d.count, 65_000)
    }
}

extension Fixtures {
    static var operaGameSANs: [String] { (try? PGN.importGame(operaPGN).game.sanMoves) ?? [] }
}

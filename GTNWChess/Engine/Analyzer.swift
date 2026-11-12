//
//  Analyzer.swift
//  GTNW Chess
//
//  Post-game analysis for play history and Nova's review: evaluates every position, classifies each move by the
//  mover's drop in win probability, and computes per-side accuracy (lichess-style), ACPL, blunders / mistakes /
//  inaccuracies, the biggest swing and the decisive moment. Runs off the main thread after the game; never blocks play.
//

import Foundation

enum MoveClass: String, Codable, Sendable, CaseIterable {
    case best, good, inaccuracy, mistake, blunder
}

struct MoveAnalysis: Codable, Equatable, Sendable {
    var ply: Int
    var moveNumber: Int
    var side: Side
    var san: String
    var uci: String
    /// Pawns, white POV, clamped ±20.
    var evalBefore: Double
    var evalAfter: Double
    var classification: MoveClass
    var bestSAN: String?
    var cpLoss: Int
    var winDrop: Double
    var accuracy: Double
}

struct SideStats: Codable, Equatable, Sendable {
    var accuracy: Double
    var acpl: Int
    var blunders: Int
    var mistakes: Int
    var inaccuracies: Int
}

struct Moment: Codable, Equatable, Sendable {
    var ply: Int
    var moveNumber: Int
    var side: Side
    var san: String
    var evalBefore: Double
    var evalAfter: Double
    var swing: Double
    var bestSAN: String?
    var note: String?
}

struct GameAnalysis: Codable, Equatable, Sendable {
    var engine: String
    var depth: Int
    var moves: [MoveAnalysis]
    var white: SideStats
    var black: SideStats
    var biggestSwing: Moment?
    var decisiveMoment: Moment?

    func stats(_ s: Side) -> SideStats { s == .white ? white : black }
}

enum Analyzer {
    static func winPercent(cp: Int) -> Double {
        50 + 50 * (2 / (1 + exp(-0.00368208 * Double(cp))) - 1)
    }

    static func moveAccuracy(winDrop: Double) -> Double {
        max(0, min(100, 103.1668 * exp(-0.04354 * max(0, winDrop)) - 3.1669))
    }

    static func classify(winDrop: Double, isEngineMove: Bool) -> MoveClass {
        if isEngineMove || winDrop < 2 { return .best }
        if winDrop < 10 { return .good }
        if winDrop < 20 { return .inaccuracy }
        if winDrop < 30 { return .mistake }
        return .blunder
    }

    /// Analyses a finished (or in-progress) game. `evaluate` returns a white-POV evaluation for a FEN.
    static func analyze(_ game: Game, engineName: String, depth: Int,
                        evaluate: (String) async throws -> Evaluation) async rethrows -> GameAnalysis {
        let positions = game.positions
        var evals: [Evaluation] = []
        evals.reserveCapacity(positions.count)
        for p in positions {
            if Task.isCancelled { break }
            evals.append(try await evaluate(p.fen))
        }
        return build(game, evals: evals, engineName: engineName, depth: depth)
    }

    /// Pure part: turns per-position evaluations (index 0 = start) into the analysis.
    static func build(_ game: Game, evals: [Evaluation], engineName: String, depth: Int) -> GameAnalysis {
        let positions = game.positions
        var out: [MoveAnalysis] = []
        for (i, pm) in game.moves.enumerated() where i + 1 < evals.count {
            let before = evals[i], after = evals[i + 1]
            let sign = pm.side == .white ? 1 : -1
            // A mating move: the "after" position has no legal moves and the mover won.
            let cpBefore = before.clampedCP * sign
            let cpAfter = (pm.isMate ? 2000 : after.clampedCP * sign)
            let wb = winPercent(cp: cpBefore), wa = winPercent(cp: cpAfter)
            let drop = max(0, wb - wa)
            let isBest = before.bestMove == pm.move.uci
            var bestSAN: String?
            if let b = before.bestMove, let m = positions[i].move(uci: b) { bestSAN = positions[i].san(m) }
            let moveNumber = positions[i].fullmoveNumber
            out.append(MoveAnalysis(ply: i + 1, moveNumber: moveNumber, side: pm.side, san: pm.san, uci: pm.move.uci,
                                    evalBefore: round2(before.pawns), evalAfter: round2(pm.isMate ? Double(20 * sign) : after.pawns),
                                    classification: classify(winDrop: drop, isEngineMove: isBest),
                                    bestSAN: isBest ? nil : bestSAN, cpLoss: min(1000, max(0, cpBefore - cpAfter)),
                                    winDrop: round2(drop), accuracy: round2(moveAccuracy(winDrop: drop))))
        }
        func stats(_ s: Side) -> SideStats {
            let ms = out.filter { $0.side == s }
            guard !ms.isEmpty else { return SideStats(accuracy: 0, acpl: 0, blunders: 0, mistakes: 0, inaccuracies: 0) }
            return SideStats(accuracy: round1(ms.map(\.accuracy).reduce(0, +) / Double(ms.count)),
                             acpl: ms.map(\.cpLoss).reduce(0, +) / ms.count,
                             blunders: ms.filter { $0.classification == .blunder }.count,
                             mistakes: ms.filter { $0.classification == .mistake }.count,
                             inaccuracies: ms.filter { $0.classification == .inaccuracy }.count)
        }
        func moment(_ m: MoveAnalysis, note: String?) -> Moment {
            Moment(ply: m.ply, moveNumber: m.moveNumber, side: m.side, san: m.san, evalBefore: m.evalBefore,
                   evalAfter: m.evalAfter, swing: round2(abs(m.evalAfter - m.evalBefore)), bestSAN: m.bestSAN, note: note)
        }
        let swing = out.max { abs($0.evalAfter - $0.evalBefore) < abs($1.evalAfter - $1.evalBefore) }
        var decisive: MoveAnalysis?
        if let winner = game.result?.winner {
            // The loser's costliest move.
            decisive = out.filter { $0.side == winner.opposite }.max { $0.winDrop < $1.winDrop }
            if let d = decisive, d.winDrop < 10 { decisive = out.filter { $0.side == winner }.last(where: { $0.classification == .best }) ?? d }
        } else {
            decisive = out.max { $0.winDrop < $1.winDrop }
        }
        return GameAnalysis(engine: engineName, depth: depth, moves: out, white: stats(.white), black: stats(.black),
                            biggestSwing: swing.map { moment($0, note: nil) },
                            decisiveMoment: decisive.map { moment($0, note: note(for: $0)) })
    }

    static func note(for m: MoveAnalysis) -> String {
        let who = m.side == .white ? "White" : "Black"
        let ev = { (x: Double) in String(format: "%+.1f", x) }
        var s = "\(who)'s \(m.san) on move \(m.moveNumber) moved the evaluation from \(ev(m.evalBefore)) to \(ev(m.evalAfter))"
        if let b = m.bestSAN, m.classification != .best { s += "; \(b) was stronger" }
        return s + "."
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

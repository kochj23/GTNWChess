//
//  FallbackEngine.swift
//  GTNW Chess
//
//  The built-in engine used when Stockfish isn't available (or fails): a small alpha-beta search with material,
//  piece-square tables and a capture-only quiescence search. It is weak by design but always plays legal moves,
//  so "vs Nova", hints and the coach keep working with no bundled binary.
//

import Foundation

/// Gameplay RNG: our own seeded SplitMix64, kept apart from the cosmetic RNG (battle effects, piece idles and chatter
/// use system random). After Doom's P_Random (gameplay) vs M_Random (menus/effects): the game's seed is stored in the
/// play summary, so the built-in engine's choices for a game can be reproduced. Stockfish's own skill randomness is
/// internal to Stockfish and not covered.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Stable across runs (Swift's Hasher is not): FNV-1a.
    static func hash(_ s: String) -> UInt64 {
        s.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }
}

final class FallbackEngine: ChessEngine, @unchecked Sendable {
    var name: String { "GTNW built-in engine" }
    /// The current game's gameplay seed (set by the controller per game).
    var seed: UInt64 = 0

    static let values: [Int] = [100, 320, 330, 500, 900, 0]
    /// Piece-square bonus: centralisation for N/B/Q, advancement for pawns, king safety (castled corners) for K.
    static func pst(_ kind: PieceKind, _ sq: Square, _ side: Side) -> Int {
        let f = Sq.file(sq), r = side == .white ? Sq.rank(sq) : 7 - Sq.rank(sq)
        let center = 3 - min(abs(3 - f), abs(4 - f)) + 3 - min(abs(3 - r), abs(4 - r)) // 0...6
        switch kind {
        case .pawn: return r * 6 + (f == 3 || f == 4 ? r * 3 : 0)
        case .knight: return center * 8 - 20
        case .bishop: return center * 5 - 8
        case .rook: return r == 6 ? 15 : 0
        case .queen: return center * 2
        case .king: return r == 0 && (f <= 2 || f >= 6) ? 20 : -r * 10
        }
    }

    /// Static evaluation, side-to-move POV.
    static func evaluate(_ p: Position) -> Int {
        var score = 0
        for s in 0..<64 {
            guard let pc = p.piece(at: s) else { continue }
            let v = values[pc.kind.rawValue] + pst(pc.kind, s, pc.side)
            score += pc.side == .white ? v : -v
        }
        return p.sideToMove == .white ? score : -score
    }

    func bestMove(fen: String, moves: [String], level: EngineLevel) async throws -> String {
        var pos = try Position(fen: fen)
        for m in moves {
            guard let mv = pos.move(uci: m) else { throw EngineError.badInput("move") }
            pos.make(mv)
        }
        let p = Personality.of(level)
        guard let m = Self.search(pos, depth: level.fallbackDepth, noise: p.noise, aggression: p.aggression, seed: seed) else {
            throw EngineError.noMove
        }
        return m.uci
    }

    func evaluate(fen: String, depth: Int) async throws -> Evaluation {
        let pos = try Position(fen: fen)
        let legal = pos.legalMoves()
        if legal.isEmpty {
            return pos.inCheck ? Evaluation(cp: nil, mate: pos.sideToMove == .white ? -1 : 1, bestMove: nil, depth: 0)
                               : Evaluation(cp: 0, mate: nil, bestMove: nil, depth: 0)
        }
        let d = max(1, min(3, depth))
        var best: Move?
        var bestScore = Int.min + 1
        var p = pos
        for m in Self.ordered(legal, pos) {
            let u = p.make(m)
            let s = -Self.negamax(&p, d - 1, -1_000_000, 1_000_000)
            p.unmake(m, u)
            if s > bestScore { bestScore = s; best = m }
        }
        let cp = pos.sideToMove == .white ? bestScore : -bestScore
        return Evaluation(cp: max(-3000, min(3000, cp)), mate: nil, bestMove: best?.uci, depth: d)
    }

    func shutdown() async {}

    static func search(_ pos: Position, depth: Int, noise: Int, aggression: Double = 0, seed: UInt64 = 0) -> Move? {
        let legal = pos.legalMoves()
        guard !legal.isEmpty else { return nil }
        var rng = SplitMix64(state: seed ^ SplitMix64.hash(pos.fen))   // same seed + position = same choice
        let bonus = Int(aggression * 25)
        var p = pos
        var scored: [(Move, Int)] = []
        for m in ordered(legal, pos) {
            let u = p.make(m)
            var s = -negamax(&p, depth - 1, -1_000_000, 1_000_000)
            p.unmake(m, u)
            if noise > 0 { s += Int.random(in: -noise...noise, using: &rng) }
            if bonus > 0, m.isCapture || p.applying(m).inCheck { s += bonus }
            scored.append((m, s))
        }
        return scored.max { $0.1 < $1.1 }?.0
    }

    static func ordered(_ moves: [Move], _ p: Position) -> [Move] {
        moves.sorted { a, b in
            func key(_ m: Move) -> Int {
                var k = 0
                if m.isCapture, let v = p.piece(at: m.to) { k += 10 * values[v.kind.rawValue] - values[p.piece(at: m.from)!.kind.rawValue] }
                if m.promotion == .queen { k += 800 }
                return k
            }
            return key(a) > key(b)
        }
    }

    static func negamax(_ p: inout Position, _ depth: Int, _ alphaIn: Int, _ beta: Int) -> Int {
        if depth <= 0 { return quiesce(&p, alphaIn, beta, 4) }
        let moves = p.legalMoves()
        if moves.isEmpty { return p.inCheck ? -100_000 - depth : 0 }
        if p.halfmoveClock >= 100 || p.isInsufficientMaterial { return 0 }
        var alpha = alphaIn
        for m in ordered(moves, p) {
            let u = p.make(m)
            let s = -negamax(&p, depth - 1, -beta, -alpha)
            p.unmake(m, u)
            if s >= beta { return s }
            if s > alpha { alpha = s }
        }
        return alpha
    }

    static func quiesce(_ p: inout Position, _ alphaIn: Int, _ beta: Int, _ budget: Int) -> Int {
        let stand = evaluate(p)
        if stand >= beta || budget == 0 { return stand }
        var alpha = max(alphaIn, stand)
        let captures = p.legalMoves().filter { $0.isCapture || $0.promotion != nil }
        for m in ordered(captures, p) {
            let u = p.make(m)
            let s = -quiesce(&p, -beta, -alpha, budget - 1)
            p.unmake(m, u)
            if s >= beta { return s }
            if s > alpha { alpha = s }
        }
        return alpha
    }
}

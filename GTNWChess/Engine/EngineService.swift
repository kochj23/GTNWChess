//
//  EngineService.swift
//  GTNW Chess
//
//  Chooses the engine: bundled Stockfish when present and healthy, otherwise the built-in fallback. A Stockfish
//  failure (crash, timeout, bad output) is retried once with a fresh process, then that request falls back, so
//  Nova always answers with a legal move. Stockfish decides moves; the LLM never does.
//

import Foundation

final class EngineService: @unchecked Sendable {
    let primary: ChessEngine?
    let fallback: ChessEngine
    private let lock = NSLock()
    private var _lastSource = "none"

    /// Which engine answered last ("Stockfish 19", "GTNW built-in engine").
    var lastSource: String { lock.withLock { _lastSource } }

    init(primary: ChessEngine?, fallback: ChessEngine = FallbackEngine()) {
        self.primary = primary
        self.fallback = fallback
    }

    static func makeDefault() -> EngineService {
        EngineService(primary: UCIEngine.locate().map { UCIEngine(url: $0) })
    }

    var hasStockfish: Bool { primary != nil }

    private func setSource(_ s: String) { lock.withLock { _lastSource = s } }

    private func withFailover<T>(_ body: (ChessEngine) async throws -> T) async throws -> T {
        if let primary {
            for attempt in 0..<2 {
                do {
                    let v = try await body(primary)
                    setSource(await primary.name)
                    return v
                } catch {
                    if case EngineError.badInput = error { throw error }
                    await primary.shutdown()   // next attempt starts a fresh process
                    if attempt == 1 { break }
                }
            }
        }
        let v = try await body(fallback)
        setSource(await fallback.name)
        return v
    }

    /// The engine's move for a game (validated legal before it's returned).
    func bestMove(for game: Game, level: EngineLevel) async throws -> Move {
        let fen = game.startPosition.fen, moves = game.uciMoves
        let uci = try await withFailover { try await $0.bestMove(fen: fen, moves: moves, level: level) }
        if let m = game.position.move(uci: uci) { return m }
        // Never trust an engine blindly: an illegal reply falls back.
        let alt = try await fallback.bestMove(fen: fen, moves: moves, level: level)
        guard let m = game.position.move(uci: alt) else { throw EngineError.noMove }
        return m
    }

    func evaluate(fen: String, depth: Int) async throws -> Evaluation {
        try await withFailover { try await $0.evaluate(fen: fen, depth: depth) }
    }

    /// A hint: the best move for the side to move (full strength, short search).
    func hint(for position: Position) async throws -> (Move, Evaluation) {
        let e = try await evaluate(fen: position.fen, depth: 12)
        if let b = e.bestMove, let m = position.move(uci: b) { return (m, e) }
        guard let m = FallbackEngine.search(position, depth: 2, noise: 0) else { throw EngineError.noMove }
        return (m, e)
    }

    func analyze(_ game: Game, depth: Int = 12) async throws -> GameAnalysis {
        let name = hasStockfish ? (await primary!.name) : await fallback.name
        return try await Analyzer.analyze(game, engineName: name, depth: depth) { fen in
            try await self.evaluate(fen: fen, depth: depth)
        }
    }

    func shutdown() async {
        await primary?.shutdown()
    }
}

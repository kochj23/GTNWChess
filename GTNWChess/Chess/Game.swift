//
//  Game.swift
//  GTNW Chess
//
//  A game record: start position, moves (with SAN), the position history for threefold repetition, and the
//  result. Draws by the 50-move rule, threefold repetition and insufficient material are applied automatically
//  (GTNW Chess is a teaching game: it never makes a learner "claim"). Resignation, agreed draws and timeouts are
//  set by the controller.
//

import Foundation

enum Termination: String, Codable, Sendable, CaseIterable {
    case checkmate, resignation, stalemate
    case fiftyMove = "fifty_move"
    case threefold
    case insufficientMaterial = "insufficient_material"
    case agreement, timeout, abandoned

    var label: String {
        switch self {
        case .checkmate: return "Checkmate"
        case .resignation: return "Resignation"
        case .stalemate: return "Stalemate"
        case .fiftyMove: return "50-move rule"
        case .threefold: return "Threefold repetition"
        case .insufficientMaterial: return "Insufficient material"
        case .agreement: return "Draw agreed"
        case .timeout: return "Time forfeit"
        case .abandoned: return "Abandoned"
        }
    }
}

struct GameResult: Codable, Equatable, Sendable {
    /// nil = draw.
    var winner: Side?
    var termination: Termination

    var pgn: String { winner.map(\.pgnResultWin) ?? "1/2-1/2" }
    var isDraw: Bool { winner == nil }
}

struct PlayedMove: Codable, Equatable, Sendable {
    var move: Move
    var san: String
    var side: Side
    var captured: PieceKind?
    var movedKind: PieceKind
    var isCheck: Bool
    var isMate: Bool
    /// Mover's remaining clock after the move, if a clock runs.
    var clockMs: Int?
}

struct Game: Sendable {
    private(set) var startPosition: Position
    private(set) var position: Position
    private(set) var moves: [PlayedMove] = []
    private(set) var history: [String]
    var result: GameResult?
    var headers: [String: String] = [:]

    init(start: Position = .start) {
        startPosition = start
        position = start
        history = [start.repetitionKey]
        updateAutomaticResult()
    }

    init(fen: String) throws { self.init(start: try Position(fen: fen)) }

    var isOver: Bool { result != nil }
    var sideToMove: Side { position.sideToMove }
    var ply: Int { moves.count }
    var startsFromStandard: Bool { startPosition.fen == Position.start.fen }
    var lastMove: PlayedMove? { moves.last }

    /// Plays a legal move. Throws for illegal moves or when the game is over.
    @discardableResult
    mutating func play(_ requested: Move, clockMs: Int? = nil) throws -> PlayedMove {
        guard result == nil else { throw ChessError.illegalMove("the game is over") }
        let legal = position.legalMoves()
        guard let m = legal.first(where: { $0 == requested }) else { throw ChessError.illegalMove(requested.uci) }
        let san = position.san(m, legal: legal)
        let mover = position.piece(at: m.from)!
        var captured: PieceKind?
        if m.isEnPassant { captured = .pawn } else if m.isCapture { captured = position.piece(at: m.to)?.kind }
        position.make(m)
        let played = PlayedMove(move: m, san: san, side: mover.side, captured: captured, movedKind: mover.kind,
                                isCheck: san.hasSuffix("+") || san.hasSuffix("#"), isMate: san.hasSuffix("#"), clockMs: clockMs)
        moves.append(played)
        history.append(position.repetitionKey)
        updateAutomaticResult()
        return played
    }

    @discardableResult
    mutating func play(san: String) throws -> PlayedMove {
        guard let m = position.move(san: san) else { throw ChessError.illegalMove(san) }
        return try play(m)
    }

    @discardableResult
    mutating func play(uci: String) throws -> PlayedMove {
        guard let m = position.move(uci: uci) else { throw ChessError.illegalMove(uci) }
        return try play(m)
    }

    /// Takes back the last move (clears any result).
    @discardableResult
    mutating func undo() -> PlayedMove? {
        guard let last = moves.popLast() else { return nil }
        history.removeLast()
        var p = startPosition
        for pm in moves { p.make(pm.move) }
        position = p
        result = nil
        updateAutomaticResult()
        return last
    }

    /// Positions before each ply (index 0 = start) and the final one.
    var positions: [Position] {
        var out = [startPosition]
        var p = startPosition
        for pm in moves { p.make(pm.move); out.append(p) }
        return out
    }

    func repetitions(of key: String) -> Int { history.filter { $0 == key }.count }

    private mutating func updateAutomaticResult() {
        guard result == nil || [.checkmate, .stalemate, .fiftyMove, .threefold, .insufficientMaterial].contains(result!.termination) else { return }
        result = Self.automaticResult(position: position, repetitions: repetitions(of: position.repetitionKey))
    }

    static func automaticResult(position: Position, repetitions: Int) -> GameResult? {
        if position.legalMoves().isEmpty {
            return position.inCheck ? GameResult(winner: position.sideToMove.opposite, termination: .checkmate)
                                    : GameResult(winner: nil, termination: .stalemate)
        }
        if position.isInsufficientMaterial { return GameResult(winner: nil, termination: .insufficientMaterial) }
        if repetitions >= 3 { return GameResult(winner: nil, termination: .threefold) }
        if position.halfmoveClock >= 100 { return GameResult(winner: nil, termination: .fiftyMove) }
        return nil
    }

    mutating func resign(_ side: Side) {
        guard result == nil else { return }
        result = GameResult(winner: side.opposite, termination: .resignation)
    }

    mutating func agreeDraw() {
        guard result == nil else { return }
        result = GameResult(winner: nil, termination: .agreement)
    }

    /// Flag fall: the side that ran out loses, unless the opponent can't possibly mate (then it's a draw).
    mutating func timeout(_ side: Side) {
        guard result == nil else { return }
        let opp = side.opposite
        let oppHasMatingMaterial = (0..<64).contains { s in
            guard let p = position.piece(at: s), p.side == opp else { return false }
            return p.kind != .king
        }
        result = oppHasMatingMaterial ? GameResult(winner: opp, termination: .timeout) : GameResult(winner: nil, termination: .timeout)
    }

    mutating func abandon() {
        guard result == nil else { return }
        result = GameResult(winner: nil, termination: .abandoned)
    }

    // MARK: - Stats

    /// Captures made by each side, by victim kind.
    func captures(by side: Side) -> [PieceKind: Int] {
        var out: [PieceKind: Int] = [:]
        for pm in moves where pm.side == side { if let c = pm.captured { out[c, default: 0] += 1 } }
        return out
    }

    func checks(by side: Side) -> Int { moves.filter { $0.side == side && $0.isCheck }.count }

    /// White-minus-black material after each ply.
    var materialGraph: [Int] { positions.dropFirst().map(\.materialBalance) }

    var uciMoves: [String] { moves.map(\.move.uci) }
    var sanMoves: [String] { moves.map(\.san) }
}

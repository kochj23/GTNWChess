//
//  Position.swift
//  GTNW Chess
//
//  A chess position (mailbox board) with a complete legal move generator: castling through/out of check, en
//  passant (including the discovered-check edge case, handled by make/test/unmake), promotion to Q/R/B/N, and
//  check / checkmate / stalemate. Validated with perft against the standard positions (see the tests).
//

import Foundation

struct Position: Hashable, Sendable {
    /// 64 cells: 0 empty, +1...+6 white P N B R Q K, -1...-6 black.
    var board: [Int8] = Array(repeating: 0, count: 64)
    var sideToMove: Side = .white
    /// Bits: 1 white O-O, 2 white O-O-O, 4 black O-O, 8 black O-O-O.
    var castling: UInt8 = 0
    /// The square a pawn may capture onto en passant, or -1.
    var epSquare: Int = -1
    var halfmoveClock = 0
    var fullmoveNumber = 1
    var kingSquare: [Square] = [4, 60]

    struct Undo: Sendable {
        var captured: Int8
        var castling: UInt8
        var epSquare: Int
        var halfmoveClock: Int
    }

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    static var start: Position { try! Position(fen: startFEN) }

    // MARK: - Lookup tables

    static let knightTargets: [[Square]] = (0..<64).map { s in
        [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)].compactMap { d in
            let f = Sq.file(s) + d.0, r = Sq.rank(s) + d.1
            return Sq.valid(f, r) ? Sq.make(f, r) : nil
        }
    }
    static let kingTargets: [[Square]] = (0..<64).map { s in
        [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)].compactMap { d in
            let f = Sq.file(s) + d.0, r = Sq.rank(s) + d.1
            return Sq.valid(f, r) ? Sq.make(f, r) : nil
        }
    }
    /// rays[s][d]: squares from s outward; d 0...3 orthogonal (N, S, E, W), 4...7 diagonal.
    static let rays: [[[Square]]] = (0..<64).map { s in
        [(0, 1), (0, -1), (1, 0), (-1, 0), (1, 1), (-1, 1), (1, -1), (-1, -1)].map { d in
            var out: [Square] = []
            var f = Sq.file(s) + d.0, r = Sq.rank(s) + d.1
            while Sq.valid(f, r) { out.append(Sq.make(f, r)); f += d.0; r += d.1 }
            return out
        }
    }
    /// Castling rights kept when a move touches the square (from or to).
    static let castleMask: [UInt8] = (0..<64).map { s in
        switch s {
        case 0: return 0b1111 & ~2
        case 7: return 0b1111 & ~1
        case 4: return 0b1111 & ~3
        case 56: return 0b1111 & ~8
        case 63: return 0b1111 & ~4
        case 60: return 0b1111 & ~12
        default: return 0b1111
        }
    }

    // MARK: - Access

    func piece(at s: Square) -> Piece? { Piece(code: board[s]) }

    mutating func set(_ p: Piece?, at s: Square) {
        board[s] = p?.code ?? 0
        if let p, p.kind == .king { kingSquare[p.side.rawValue] = s }
    }

    @inline(__always) private func isSide(_ code: Int8, _ side: Side) -> Bool {
        side == .white ? code > 0 : code < 0
    }

    // MARK: - Attacks

    /// True if `s` is attacked by any piece of `by`.
    func isAttacked(_ s: Square, by: Side) -> Bool {
        let sign: Int8 = by == .white ? 1 : -1
        let f = Sq.file(s)
        if by == .white {
            if f > 0, s - 9 >= 0, board[s - 9] == 1 { return true }
            if f < 7, s - 7 >= 0, board[s - 7] == 1 { return true }
        } else {
            if f > 0, s + 7 < 64, board[s + 7] == -1 { return true }
            if f < 7, s + 9 < 64, board[s + 9] == -1 { return true }
        }
        let knight = 2 * sign, king = 6 * sign, bishop = 3 * sign, rook = 4 * sign, queen = 5 * sign
        for t in Self.knightTargets[s] where board[t] == knight { return true }
        for t in Self.kingTargets[s] where board[t] == king { return true }
        let r = Self.rays[s]
        for d in 0..<8 {
            let slider = d < 4 ? rook : bishop
            for t in r[d] {
                let c = board[t]
                if c == 0 { continue }
                if c == slider || c == queen { return true }
                break
            }
        }
        return false
    }

    var inCheck: Bool { isAttacked(kingSquare[sideToMove.rawValue], by: sideToMove.opposite) }

    /// Squares attacked by `side` (for highlighting threats and the coach).
    func attackers(of s: Square, by side: Side) -> [Square] {
        var out: [Square] = []
        for from in 0..<64 where isSide(board[from], side) {
            if attacks(from: from, target: s) { out.append(from) }
        }
        return out
    }

    /// Does the piece on `from` attack `target` (pseudo-legally, ignoring pins)?
    func attacks(from: Square, target: Square) -> Bool {
        guard let p = piece(at: from), from != target else { return false }
        switch p.kind {
        case .pawn:
            let df = Sq.file(target) - Sq.file(from), dr = Sq.rank(target) - Sq.rank(from)
            return abs(df) == 1 && dr == (p.side == .white ? 1 : -1)
        case .knight: return Self.knightTargets[from].contains(target)
        case .king: return Self.kingTargets[from].contains(target)
        case .bishop, .rook, .queen:
            let dirs: Range<Int> = p.kind == .rook ? 0..<4 : p.kind == .bishop ? 4..<8 : 0..<8
            for d in dirs {
                for t in Self.rays[from][d] {
                    if t == target { return true }
                    if board[t] != 0 { break }
                }
            }
            return false
        }
    }

    // MARK: - Move generation

    /// All legal moves for the side to move.
    func legalMoves() -> [Move] {
        var pseudo: [Move] = []
        pseudo.reserveCapacity(64)
        generatePseudo(into: &pseudo)
        var copy = self
        let us = sideToMove
        var out: [Move] = []
        out.reserveCapacity(pseudo.count)
        for m in pseudo {
            let u = copy.make(m)
            if !copy.isAttacked(copy.kingSquare[us.rawValue], by: us.opposite) { out.append(m) }
            copy.unmake(m, u)
        }
        return out
    }

    func legalMoves(from s: Square) -> [Move] { legalMoves().filter { $0.from == s } }

    func generatePseudo(into moves: inout [Move]) {
        let us = sideToMove, them = us.opposite
        for from in 0..<64 {
            let c = board[from]
            guard c != 0, isSide(c, us) else { continue }
            let kind = PieceKind(rawValue: Int(abs(c)) - 1)!
            switch kind {
            case .pawn: genPawn(from, us, &moves)
            case .knight:
                for t in Self.knightTargets[from] {
                    let tc = board[t]
                    if tc == 0 { moves.append(Move(from: from, to: t)) }
                    else if isSide(tc, them) { moves.append(Move(from: from, to: t, flags: .capture)) }
                }
            case .king:
                for t in Self.kingTargets[from] {
                    let tc = board[t]
                    if tc == 0 { moves.append(Move(from: from, to: t)) }
                    else if isSide(tc, them) { moves.append(Move(from: from, to: t, flags: .capture)) }
                }
                genCastles(from, us, &moves)
            case .bishop, .rook, .queen:
                let dirs: Range<Int> = kind == .rook ? 0..<4 : kind == .bishop ? 4..<8 : 0..<8
                let r = Self.rays[from]
                for d in dirs {
                    for t in r[d] {
                        let tc = board[t]
                        if tc == 0 { moves.append(Move(from: from, to: t)); continue }
                        if isSide(tc, them) { moves.append(Move(from: from, to: t, flags: .capture)) }
                        break
                    }
                }
            }
        }
    }

    private func genPawn(_ from: Square, _ us: Side, _ moves: inout [Move]) {
        let dir = us == .white ? 8 : -8
        let startRank = us == .white ? 1 : 6, lastRank = us == .white ? 7 : 0
        let f = Sq.file(from)
        func add(_ to: Square, _ flags: Move.Flags) {
            if Sq.rank(to) == lastRank {
                for p in PieceKind.promotions { moves.append(Move(from: from, to: to, promotion: p, flags: flags)) }
            } else {
                moves.append(Move(from: from, to: to, flags: flags))
            }
        }
        let one = from + dir
        if one >= 0, one < 64, board[one] == 0 {
            add(one, [])
            let two = one + dir
            if Sq.rank(from) == startRank, board[two] == 0 { moves.append(Move(from: from, to: two, flags: .doublePush)) }
        }
        for df in [-1, 1] {
            let tf = f + df
            guard (0..<8).contains(tf) else { continue }
            let to = one + df
            guard to >= 0, to < 64 else { continue }
            let tc = board[to]
            if tc != 0, isSide(tc, us.opposite) { add(to, .capture) }
            else if to == epSquare { moves.append(Move(from: from, to: to, flags: [.capture, .enPassant])) }
        }
    }

    private func genCastles(_ from: Square, _ us: Side, _ moves: inout [Move]) {
        let them = us.opposite
        if us == .white, from == 4 {
            if castling & 1 != 0, board[5] == 0, board[6] == 0, board[7] == 4,
               !isAttacked(4, by: them), !isAttacked(5, by: them), !isAttacked(6, by: them) {
                moves.append(Move(from: 4, to: 6, flags: .castle))
            }
            if castling & 2 != 0, board[3] == 0, board[2] == 0, board[1] == 0, board[0] == 4,
               !isAttacked(4, by: them), !isAttacked(3, by: them), !isAttacked(2, by: them) {
                moves.append(Move(from: 4, to: 2, flags: .castle))
            }
        } else if us == .black, from == 60 {
            if castling & 4 != 0, board[61] == 0, board[62] == 0, board[63] == -4,
               !isAttacked(60, by: them), !isAttacked(61, by: them), !isAttacked(62, by: them) {
                moves.append(Move(from: 60, to: 62, flags: .castle))
            }
            if castling & 8 != 0, board[59] == 0, board[58] == 0, board[57] == 0, board[56] == -4,
               !isAttacked(60, by: them), !isAttacked(59, by: them), !isAttacked(58, by: them) {
                moves.append(Move(from: 60, to: 58, flags: .castle))
            }
        }
    }

    // MARK: - Make / unmake

    @discardableResult
    mutating func make(_ m: Move) -> Undo {
        let piece = board[m.from]
        let us = sideToMove
        var capSq = m.to
        if m.flags.contains(.enPassant) { capSq = m.to + (us == .white ? -8 : 8) }
        let undo = Undo(captured: board[capSq], castling: castling, epSquare: epSquare, halfmoveClock: halfmoveClock)
        if m.flags.contains(.enPassant) { board[capSq] = 0 }
        board[m.to] = m.promotion.map { Piece($0, us).code } ?? piece
        board[m.from] = 0
        let kind = abs(piece)
        if kind == 6 {
            kingSquare[us.rawValue] = m.to
            if m.flags.contains(.castle) {
                switch m.to {
                case 6: board[5] = board[7]; board[7] = 0
                case 2: board[3] = board[0]; board[0] = 0
                case 62: board[61] = board[63]; board[63] = 0
                case 58: board[59] = board[56]; board[56] = 0
                default: break
                }
            }
        }
        castling &= Self.castleMask[m.from] & Self.castleMask[m.to]
        epSquare = m.flags.contains(.doublePush) ? (m.from + m.to) / 2 : -1
        halfmoveClock = (kind == 1 || undo.captured != 0) ? 0 : halfmoveClock + 1
        if us == .black { fullmoveNumber += 1 }
        sideToMove = us.opposite
        return undo
    }

    mutating func unmake(_ m: Move, _ u: Undo) {
        let us = sideToMove.opposite
        sideToMove = us
        if us == .black { fullmoveNumber -= 1 }
        let moved = m.promotion != nil ? Piece(.pawn, us).code : board[m.to]
        board[m.from] = moved
        if m.flags.contains(.enPassant) {
            board[m.to] = 0
            board[m.to + (us == .white ? -8 : 8)] = u.captured
        } else {
            board[m.to] = u.captured
        }
        if abs(moved) == 6 {
            kingSquare[us.rawValue] = m.from
            if m.flags.contains(.castle) {
                switch m.to {
                case 6: board[7] = board[5]; board[5] = 0
                case 2: board[0] = board[3]; board[3] = 0
                case 62: board[63] = board[61]; board[61] = 0
                case 58: board[56] = board[59]; board[59] = 0
                default: break
                }
            }
        }
        castling = u.castling
        epSquare = u.epSquare
        halfmoveClock = u.halfmoveClock
    }

    /// The position after a legal move (copy).
    func applying(_ m: Move) -> Position {
        var p = self
        p.make(m)
        return p
    }

    /// The legal move matching `m` (from/to/promotion), with its flags filled in.
    func legal(_ m: Move) -> Move? { legalMoves().first { $0 == m } }

    func move(uci: String) -> Move? {
        let s = uci.trimmingCharacters(in: .whitespaces).lowercased()
        guard s.count == 4 || s.count == 5, let from = Sq.parse(s.prefix(2)), let to = Sq.parse(s.dropFirst(2).prefix(2)) else { return nil }
        var promo: PieceKind?
        if s.count == 5 {
            guard let p = PieceKind(fenLetter: s.last!), PieceKind.promotions.contains(p) else { return nil }
            promo = p
        }
        return legal(Move(from: from, to: to, promotion: promo))
    }

    // MARK: - Perft

    /// Leaf-node count to `depth` (the standard move-generator check).
    func perft(_ depth: Int) -> Int {
        var p = self
        return p.perftInPlace(depth)
    }

    private mutating func perftInPlace(_ depth: Int) -> Int {
        if depth == 0 { return 1 }
        var moves: [Move] = []
        moves.reserveCapacity(64)
        generatePseudo(into: &moves)
        let us = sideToMove
        var n = 0
        for m in moves {
            let u = make(m)
            if !isAttacked(kingSquare[us.rawValue], by: us.opposite) {
                n += depth == 1 ? 1 : perftInPlace(depth - 1)
            }
            unmake(m, u)
        }
        return n
    }

    /// Per-root-move counts (for debugging against reference tables).
    func divide(_ depth: Int) -> [String: Int] {
        var out: [String: Int] = [:]
        for m in legalMoves() { out[m.uci] = applying(m).perft(depth - 1) }
        return out
    }

    // MARK: - Material & draws

    func material(_ side: Side) -> Int {
        board.reduce(0) { acc, c in
            guard c != 0, isSide(c, side) else { return acc }
            return acc + PieceKind(rawValue: Int(abs(c)) - 1)!.value
        }
    }

    /// White material minus black material, in pawns.
    var materialBalance: Int { material(.white) - material(.black) }

    /// FIDE dead positions we detect: K v K, K+minor v K, and K+B v K+B with all bishops on one colour.
    var isInsufficientMaterial: Bool {
        var minors: [(PieceKind, Square)] = []
        for s in 0..<64 {
            let c = board[s]
            guard c != 0 else { continue }
            switch abs(c) {
            case 6: continue
            case 2, 3: minors.append((PieceKind(rawValue: Int(abs(c)) - 1)!, s))
            default: return false
            }
        }
        if minors.count <= 1 { return true }
        if minors.allSatisfy({ $0.0 == .bishop }) {
            let colours = Set(minors.map { Sq.isDark($0.1) })
            return colours.count == 1
        }
        return false
    }

    /// The en passant square only when a pawn could actually capture there (for FEN and repetition).
    var effectiveEPSquare: Int {
        guard epSquare >= 0 else { return -1 }
        let us = sideToMove
        let pawn = Piece(.pawn, us).code
        let behind = epSquare + (us == .white ? -8 : 8)
        for df in [-1, 1] {
            let f = Sq.file(behind) + df
            guard (0..<8).contains(f) else { continue }
            let s = Sq.make(f, Sq.rank(behind))
            if board[s] == pawn { return epSquare }
        }
        return -1
    }

    /// Key for threefold repetition: placement, side, castling rights, en passant (only when capturable).
    var repetitionKey: String {
        var s = String(board.map { Character(UnicodeScalar(UInt8(Int(65 + $0)))) })
        s += sideToMove == .white ? "w" : "b"
        s += String(castling) + ":" + String(effectiveEPSquare)
        return s
    }
}

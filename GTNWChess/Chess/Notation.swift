//
//  Notation.swift
//  GTNW Chess
//
//  FEN import/export (validated) and Standard Algebraic Notation (generation with minimal disambiguation, and a
//  forgiving parser: "0-0", "e8Q", "exd6 e.p.", trailing +/#/!/? are accepted).
//

import Foundation

extension Position {
    /// Parses and validates a FEN string. Rejects malformed fields, wrong king counts, pawns on the back ranks,
    /// impossible castling rights and en passant squares, and a side not to move being in check.
    init(fen: String) throws {
        let trimmed = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 120, !trimmed.contains(where: { $0.isNewline }) else { throw ChessError.badFEN("too long") }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4, parts.count <= 6 else { throw ChessError.badFEN("expected 4-6 fields") }
        var p = Position()
        let rows = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        guard rows.count == 8 else { throw ChessError.badFEN("expected 8 ranks") }
        var kings = [0, 0]
        for (i, row) in rows.enumerated() {
            let rank = 7 - i
            var file = 0
            for c in row {
                if let d = c.wholeNumberValue, (1...8).contains(d) {
                    file += d
                } else if let k = PieceKind(fenLetter: c), c.isASCII {
                    guard file < 8 else { throw ChessError.badFEN("rank \(rank + 1) too long") }
                    let side: Side = c.isUppercase ? .white : .black
                    if k == .pawn, rank == 0 || rank == 7 { throw ChessError.badFEN("pawn on back rank") }
                    if k == .king { kings[side.rawValue] += 1 }
                    p.set(Piece(k, side), at: Sq.make(file, rank))
                    file += 1
                } else {
                    throw ChessError.badFEN("bad character '\(c)'")
                }
                guard file <= 8 else { throw ChessError.badFEN("rank \(rank + 1) too long") }
            }
            guard file == 8 else { throw ChessError.badFEN("rank \(rank + 1) has \(file) files") }
        }
        guard kings == [1, 1] else { throw ChessError.badFEN("each side needs exactly one king") }
        switch parts[1] {
        case "w": p.sideToMove = .white
        case "b": p.sideToMove = .black
        default: throw ChessError.badFEN("side to move")
        }
        if parts[2] != "-" {
            for c in parts[2] {
                switch c {
                case "K": p.castling |= 1
                case "Q": p.castling |= 2
                case "k": p.castling |= 4
                case "q": p.castling |= 8
                default: throw ChessError.badFEN("castling '\(parts[2])'")
                }
            }
        }
        // Drop rights the placement can't support (king/rook not home) rather than reject: many FENs in the wild do this.
        if p.board[4] != 6 { p.castling &= ~3 }
        if p.board[7] != 4 { p.castling &= ~1 }
        if p.board[0] != 4 { p.castling &= ~2 }
        if p.board[60] != -6 { p.castling &= ~12 }
        if p.board[63] != -4 { p.castling &= ~4 }
        if p.board[56] != -4 { p.castling &= ~8 }
        if parts[3] != "-" {
            guard let ep = Sq.parse(parts[3]) else { throw ChessError.badFEN("en passant square") }
            let expectedRank = p.sideToMove == .white ? 5 : 2
            guard Sq.rank(ep) == expectedRank else { throw ChessError.badFEN("en passant rank") }
            let pawnSq = ep + (p.sideToMove == .white ? -8 : 8)
            guard p.board[pawnSq] == Piece(.pawn, p.sideToMove.opposite).code, p.board[ep] == 0 else {
                throw ChessError.badFEN("en passant without a pawn")
            }
            p.epSquare = ep
        }
        if parts.count >= 5 {
            guard let h = Int(parts[4]), (0...1000).contains(h) else { throw ChessError.badFEN("halfmove clock") }
            p.halfmoveClock = h
        }
        if parts.count == 6 {
            guard let f = Int(parts[5]), (1...10000).contains(f) else { throw ChessError.badFEN("fullmove number") }
            p.fullmoveNumber = f
        }
        if p.isAttacked(p.kingSquare[p.sideToMove.opposite.rawValue], by: p.sideToMove) {
            throw ChessError.badFEN("the side not to move is in check")
        }
        self = p
    }

    var fen: String {
        var rows: [String] = []
        for rank in stride(from: 7, through: 0, by: -1) {
            var row = "", empty = 0
            for file in 0..<8 {
                if let pc = piece(at: Sq.make(file, rank)) {
                    if empty > 0 { row += String(empty); empty = 0 }
                    row.append(pc.fenChar)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { row += String(empty) }
            rows.append(row)
        }
        var c = ""
        if castling & 1 != 0 { c += "K" }
        if castling & 2 != 0 { c += "Q" }
        if castling & 4 != 0 { c += "k" }
        if castling & 8 != 0 { c += "q" }
        let ep = effectiveEPSquare
        return [rows.joined(separator: "/"), sideToMove == .white ? "w" : "b", c.isEmpty ? "-" : c,
                ep >= 0 ? Sq.name(ep) : "-", String(halfmoveClock), String(fullmoveNumber)].joined(separator: " ")
    }

    // MARK: - SAN

    /// SAN for a legal move in this position, with + or #.
    func san(_ m: Move) -> String {
        san(m, legal: legalMoves())
    }

    func san(_ m: Move, legal: [Move]) -> String {
        var s: String
        guard let pc = piece(at: m.from) else { return m.uci }
        if m.isCastle {
            s = Sq.file(m.to) == 6 ? "O-O" : "O-O-O"
        } else if pc.kind == .pawn {
            s = m.isCapture ? String(Sq.name(m.from).first!) + "x" + Sq.name(m.to) : Sq.name(m.to)
            if let promo = m.promotion { s += "=" + promo.sanLetter }
        } else {
            s = pc.kind.sanLetter
            let rivals = legal.filter { $0.to == m.to && $0.from != m.from && board[$0.from] == board[m.from] }
            if !rivals.isEmpty {
                let sameFile = rivals.contains { Sq.file($0.from) == Sq.file(m.from) }
                let sameRank = rivals.contains { Sq.rank($0.from) == Sq.rank(m.from) }
                if !sameFile { s += String(Sq.name(m.from).first!) }
                else if !sameRank { s += String(Sq.name(m.from).last!) }
                else { s += Sq.name(m.from) }
            }
            if m.isCapture { s += "x" }
            s += Sq.name(m.to)
        }
        let after = applying(m)
        if after.inCheck { s += after.legalMoves().isEmpty ? "#" : "+" }
        return s
    }

    /// Parses SAN (or UCI as a fallback) against this position's legal moves.
    func move(san raw: String) -> Move? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 16 else { return nil }
        if t.hasSuffix("e.p.") { t = String(t.dropLast(4)).trimmingCharacters(in: .whitespaces) }
        while let l = t.last, "+#!?".contains(l) { t.removeLast() }
        t = t.replacingOccurrences(of: "0", with: "O")
        let legal = legalMoves()
        if t == "O-O" || t == "O-O-O" {
            return legal.first { $0.isCastle && (Sq.file($0.to) == 6) == (t == "O-O") }
        }
        // Exact match against generated SAN (ignoring check marks).
        func bare(_ s: String) -> String { s.filter { !"+#".contains($0) } }
        let normalized = t.replacingOccurrences(of: "=", with: "")
        for m in legal {
            let s = bare(san(m, legal: legal))
            if s == t || s.replacingOccurrences(of: "=", with: "") == normalized { return m }
        }
        // Over-disambiguated or missing 'x' forms ("Ng1f3", "Nf3xe5", "exd5" vs "ed5").
        let pieceLetter = t.first.flatMap { "NBRQK".contains($0) ? PieceKind(fenLetter: $0) : nil }
        var body = pieceLetter == nil ? Substring(t) : t.dropFirst()
        var promo: PieceKind?
        if let l = body.last, let k = PieceKind(fenLetter: l), l.isUppercase, PieceKind.promotions.contains(k) {
            promo = k
            body = body.dropLast()
            if body.last == "=" { body = body.dropLast() }
        }
        body = Substring(body.replacingOccurrences(of: "x", with: "").replacingOccurrences(of: "-", with: ""))
        guard body.count >= 2, let to = Sq.parse(body.suffix(2)) else { return move(uci: raw) }
        let hint = body.dropLast(2)
        let kind = pieceLetter ?? .pawn
        let candidates = legal.filter { m in
            guard m.to == to, m.promotion == promo, let p = piece(at: m.from), p.kind == kind else { return false }
            let name = Sq.name(m.from)
            for c in hint where !name.contains(c) { return false }
            return true
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}

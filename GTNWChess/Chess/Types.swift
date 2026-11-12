//
//  Types.swift
//  GTNW Chess
//
//  Core chess value types: sides, piece kinds, squares and moves. Squares are 0...63 with a1 = 0, h1 = 7, a8 = 56.
//

import Foundation

enum Side: Int, Codable, CaseIterable, Sendable {
    case white = 0, black = 1

    var opposite: Side { self == .white ? .black : .white }
    var name: String { self == .white ? "white" : "black" }
    /// The faction that plays this side: Solar is white, Void is black.
    var faction: String { self == .white ? "Solar" : "Void" }
    var pgnResultWin: String { self == .white ? "1-0" : "0-1" }
}

enum PieceKind: Int, Codable, CaseIterable, Sendable, Comparable {
    case pawn = 0, knight, bishop, rook, queen, king

    static func < (a: PieceKind, b: PieceKind) -> Bool { a.rawValue < b.rawValue }

    /// SAN letter ("" for pawns).
    var sanLetter: String { ["", "N", "B", "R", "Q", "K"][rawValue] }
    /// FEN letter for white (uppercase).
    var fenLetter: Character { ["P", "N", "B", "R", "Q", "K"][rawValue] }
    var name: String { ["pawn", "knight", "bishop", "rook", "queen", "king"][rawValue] }
    /// Material in pawns (king 0: it is never traded).
    var value: Int { [1, 3, 3, 5, 9, 0][rawValue] }

    init?(fenLetter c: Character) {
        switch c.lowercased() {
        case "p": self = .pawn
        case "n": self = .knight
        case "b": self = .bishop
        case "r": self = .rook
        case "q": self = .queen
        case "k": self = .king
        default: return nil
        }
    }

    static let promotions: [PieceKind] = [.queen, .rook, .bishop, .knight]
}

struct Piece: Hashable, Codable, Sendable {
    var kind: PieceKind
    var side: Side

    var fenChar: Character {
        side == .white ? kind.fenLetter : Character(kind.fenLetter.lowercased())
    }

    /// Board cell code: +1...+6 white, -1...-6 black.
    var code: Int8 { Int8(kind.rawValue + 1) * (side == .white ? 1 : -1) }

    init(_ kind: PieceKind, _ side: Side) { self.kind = kind; self.side = side }

    init?(code: Int8) {
        guard code != 0, let k = PieceKind(rawValue: Int(abs(code)) - 1) else { return nil }
        kind = k
        side = code > 0 ? .white : .black
    }
}

typealias Square = Int

enum Sq {
    static func file(_ s: Square) -> Int { s & 7 }
    static func rank(_ s: Square) -> Int { s >> 3 }
    static func make(_ file: Int, _ rank: Int) -> Square { rank * 8 + file }
    static func valid(_ file: Int, _ rank: Int) -> Bool { (0..<8).contains(file) && (0..<8).contains(rank) }
    static func name(_ s: Square) -> String {
        String(UnicodeScalar(UInt8(97 + file(s)))) + String(rank(s) + 1)
    }
    static func parse(_ text: some StringProtocol) -> Square? {
        let u = Array(text.utf8)
        guard u.count == 2, (97...104).contains(u[0]), (49...56).contains(u[1]) else { return nil }
        return make(Int(u[0]) - 97, Int(u[1]) - 49)
    }
    /// True for dark squares (a1 is dark).
    static func isDark(_ s: Square) -> Bool { (file(s) + rank(s)) % 2 == 0 }
}

struct Move: Hashable, Codable, Sendable, CustomStringConvertible {
    struct Flags: OptionSet, Hashable, Codable, Sendable {
        let rawValue: UInt8
        static let capture = Flags(rawValue: 1)
        static let enPassant = Flags(rawValue: 2)
        static let castle = Flags(rawValue: 4)
        static let doublePush = Flags(rawValue: 8)
    }

    var from: Square
    var to: Square
    var promotion: PieceKind?
    var flags: Flags = []

    init(from: Square, to: Square, promotion: PieceKind? = nil, flags: Flags = []) {
        self.from = from; self.to = to; self.promotion = promotion; self.flags = flags
    }

    var isCapture: Bool { flags.contains(.capture) }
    var isCastle: Bool { flags.contains(.castle) }
    var isEnPassant: Bool { flags.contains(.enPassant) }

    /// UCI long algebraic: e2e4, e7e8q.
    var uci: String {
        Sq.name(from) + Sq.name(to) + (promotion.map { String($0.fenLetter).lowercased() } ?? "")
    }

    var description: String { uci }

    static func == (a: Move, b: Move) -> Bool { a.from == b.from && a.to == b.to && a.promotion == b.promotion }
    func hash(into h: inout Hasher) { h.combine(from); h.combine(to); h.combine(promotion) }
}

enum ChessError: Error, Equatable, LocalizedError {
    case badFEN(String)
    case illegalMove(String)
    case badPGN(String)

    var errorDescription: String? {
        switch self {
        case .badFEN(let s): return "Invalid FEN: \(s)"
        case .illegalMove(let s): return "Illegal move: \(s)"
        case .badPGN(let s): return "Invalid PGN: \(s)"
        }
    }
}

//
//  Openings.swift
//  GTNW Chess
//
//  A small built-in ECO table (common openings by their main-line SAN prefix). The longest matching prefix wins.
//

import Foundation

struct Opening: Codable, Equatable, Sendable {
    var eco: String
    var name: String
}

enum Openings {
    static let table: [(eco: String, name: String, moves: [String])] = [
        ("A00", "Uncommon Opening", []),
        ("A00", "Grob's Attack", ["g4"]),
        ("A01", "Nimzo-Larsen Attack", ["b3"]),
        ("A02", "Bird's Opening", ["f4"]),
        ("A04", "Réti Opening", ["Nf3"]),
        ("A10", "English Opening", ["c4"]),
        ("A20", "English Opening: King's English", ["c4", "e5"]),
        ("A40", "Queen's Pawn Game", ["d4"]),
        ("A45", "Indian Defense", ["d4", "Nf6"]),
        ("A80", "Dutch Defense", ["d4", "f5"]),
        ("B00", "King's Pawn Opening", ["e4"]),
        ("B01", "Scandinavian Defense", ["e4", "d5"]),
        ("B02", "Alekhine's Defense", ["e4", "Nf6"]),
        ("B06", "Modern Defense", ["e4", "g6"]),
        ("B07", "Pirc Defense", ["e4", "d6", "d4", "Nf6"]),
        ("B10", "Caro-Kann Defense", ["e4", "c6"]),
        ("B20", "Sicilian Defense", ["e4", "c5"]),
        ("B22", "Sicilian Defense: Alapin Variation", ["e4", "c5", "c3"]),
        ("B23", "Sicilian Defense: Closed", ["e4", "c5", "Nc3"]),
        ("B27", "Sicilian Defense", ["e4", "c5", "Nf3"]),
        ("B50", "Sicilian Defense", ["e4", "c5", "Nf3", "d6"]),
        ("B54", "Sicilian Defense: Open", ["e4", "c5", "Nf3", "d6", "d4"]),
        ("B90", "Sicilian Defense: Najdorf Variation", ["e4", "c5", "Nf3", "d6", "d4", "cxd4", "Nxd4", "Nf6", "Nc3", "a6"]),
        ("C00", "French Defense", ["e4", "e6"]),
        ("C20", "King's Pawn Game", ["e4", "e5"]),
        ("C23", "Bishop's Opening", ["e4", "e5", "Bc4"]),
        ("C25", "Vienna Game", ["e4", "e5", "Nc3"]),
        ("C30", "King's Gambit", ["e4", "e5", "f4"]),
        ("C40", "King's Knight Opening", ["e4", "e5", "Nf3"]),
        ("C41", "Philidor Defense", ["e4", "e5", "Nf3", "d6"]),
        ("C42", "Petrov's Defense", ["e4", "e5", "Nf3", "Nf6"]),
        ("C44", "King's Pawn Game: Knight Opening", ["e4", "e5", "Nf3", "Nc6"]),
        ("C44", "Scotch Game", ["e4", "e5", "Nf3", "Nc6", "d4"]),
        ("C46", "Four Knights Game", ["e4", "e5", "Nf3", "Nc6", "Nc3", "Nf6"]),
        ("C50", "Italian Game", ["e4", "e5", "Nf3", "Nc6", "Bc4"]),
        ("C50", "Italian Game: Giuoco Piano", ["e4", "e5", "Nf3", "Nc6", "Bc4", "Bc5"]),
        ("C55", "Italian Game: Two Knights Defense", ["e4", "e5", "Nf3", "Nc6", "Bc4", "Nf6"]),
        ("C60", "Ruy Lopez", ["e4", "e5", "Nf3", "Nc6", "Bb5"]),
        ("C65", "Ruy Lopez: Berlin Defense", ["e4", "e5", "Nf3", "Nc6", "Bb5", "Nf6"]),
        ("C68", "Ruy Lopez: Exchange Variation", ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6", "Bxc6"]),
        ("C70", "Ruy Lopez: Morphy Defense", ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6", "Ba4"]),
        ("D00", "Queen's Pawn Game", ["d4", "d5"]),
        ("D02", "London System", ["d4", "d5", "Nf3", "Nf6", "Bf4"]),
        ("D02", "London System", ["d4", "Nf6", "Nf3", "d5", "Bf4"]),
        ("D06", "Queen's Gambit", ["d4", "d5", "c4"]),
        ("D10", "Slav Defense", ["d4", "d5", "c4", "c6"]),
        ("D20", "Queen's Gambit Accepted", ["d4", "d5", "c4", "dxc4"]),
        ("D30", "Queen's Gambit Declined", ["d4", "d5", "c4", "e6"]),
        ("E00", "Catalan / Indian Game", ["d4", "Nf6", "c4", "e6"]),
        ("E20", "Nimzo-Indian Defense", ["d4", "Nf6", "c4", "e6", "Nc3", "Bb4"]),
        ("E60", "King's Indian Defense", ["d4", "Nf6", "c4", "g6"]),
        ("D80", "Grünfeld Defense", ["d4", "Nf6", "c4", "g6", "Nc3", "d5"]),
    ]

    /// The opening for a game's SAN moves (standard start only).
    static func classify(_ sans: [String]) -> Opening {
        let bare = sans.map { $0.filter { !"+#".contains($0) } }
        var best = (eco: "A00", name: "Uncommon Opening", len: -1)
        for row in table where row.moves.count <= bare.count && row.moves.count > best.len {
            if Array(bare.prefix(row.moves.count)) == row.moves { best = (row.eco, row.name, row.moves.count) }
        }
        return Opening(eco: best.eco, name: best.name)
    }
}

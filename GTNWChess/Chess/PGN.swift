//
//  PGN.swift
//  GTNW Chess
//
//  PGN export (Seven Tag Roster + SetUp/FEN, 80-column movetext) and import (headers, comments, NAGs, variations
//  and move numbers are skipped; every move is replayed through the rules engine, so an illegal PGN is rejected).
//  Input is bounded (size, token count) so a hostile file can't stall the app.
//

import Foundation

enum PGN {
    static let maxBytes = 1_000_000
    static let maxPlies = 2_000

    static func export(_ game: Game, white: String, black: String, date: Date = Date(), event: String = "GTNW Chess",
                       site: String = "GTNW Chess, macOS", extra: [String: String] = [:]) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy.MM.dd"
        let result = game.result?.pgn ?? "*"
        var tags: [(String, String)] = [("Event", event), ("Site", site), ("Date", df.string(from: date)), ("Round", "-"),
                                        ("White", white), ("Black", black), ("Result", result)]
        if !game.startsFromStandard {
            tags.append(("SetUp", "1"))
            tags.append(("FEN", game.startPosition.fen))
        }
        if let r = game.result { tags.append(("Termination", r.termination.label)) }
        for k in extra.keys.sorted() where !tags.contains(where: { $0.0 == k }) { tags.append((k, extra[k]!)) }
        var out = tags.map { "[\($0.0) \"\(escape($0.1))\"]" }.joined(separator: "\n") + "\n\n"
        var tokens: [String] = []
        var number = game.startPosition.fullmoveNumber
        for (i, pm) in game.moves.enumerated() {
            if pm.side == .white { tokens.append("\(number).") }
            else if i == 0 { tokens.append("\(number)...") }
            tokens.append(pm.san)
            if pm.side == .black { number += 1 }
        }
        tokens.append(result)
        var line = ""
        for t in tokens {
            if line.count + t.count + 1 > 80 { out += line + "\n"; line = t }
            else { line += line.isEmpty ? t : " " + t }
        }
        out += line + "\n"
        return out
    }

    static func escape(_ s: String) -> String {
        String(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .filter { !$0.isNewline }.prefix(200))
    }

    struct Imported {
        var game: Game
        var headers: [String: String]
    }

    /// Imports the first game of a PGN text.
    static func importGame(_ text: String) throws -> Imported {
        guard text.utf8.count <= maxBytes else { throw ChessError.badPGN("file too large") }
        var headers: [String: String] = [:]
        var movetext = ""
        var inMoves = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("%") { continue }
            if !inMoves, line.hasPrefix("[") {
                if let (k, v) = parseTag(line) { headers[k] = v }
                continue
            }
            if line.isEmpty { continue }
            if inMoves, line.hasPrefix("[") { break } // next game
            inMoves = true
            movetext += line + "\n"
        }
        var game: Game
        if headers["SetUp"] == "1" || headers["FEN"] != nil, let fen = headers["FEN"] {
            game = try Game(fen: fen)
        } else {
            game = Game()
        }
        let tokens = tokenize(movetext)
        var declared: String?
        for t in tokens {
            if ["1-0", "0-1", "1/2-1/2", "*"].contains(t) { declared = t; break }
            guard game.ply < maxPlies else { throw ChessError.badPGN("too many moves") }
            if game.isOver { throw ChessError.badPGN("moves after the game ended: \(t)") }
            do { try game.play(san: t) } catch { throw ChessError.badPGN("illegal move \(t) at ply \(game.ply + 1)") }
        }
        if game.result == nil, let d = declared {
            let term = headers["Termination"]?.lowercased() ?? ""
            switch d {
            case "1-0": game.result = GameResult(winner: .white, termination: term.contains("time") ? .timeout : .resignation)
            case "0-1": game.result = GameResult(winner: .black, termination: term.contains("time") ? .timeout : .resignation)
            case "1/2-1/2": game.result = GameResult(winner: nil, termination: .agreement)
            default: break
            }
        }
        game.headers = headers
        return Imported(game: game, headers: headers)
    }

    static func parseTag(_ line: String) -> (String, String)? {
        guard line.hasPrefix("["), line.hasSuffix("]"), let space = line.firstIndex(of: " ") else { return nil }
        let key = String(line[line.index(after: line.startIndex)..<space])
        guard !key.isEmpty, key.count <= 40, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        var v = line[line.index(after: space)..<line.index(before: line.endIndex)].trimmingCharacters(in: .whitespaces)
        guard v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 else { return nil }
        v = String(v.dropFirst().dropLast())
        v = v.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        return (key, String(v.prefix(200)))
    }

    /// Movetext → SAN tokens: drops {comments}, ;comments, (variations), $NAGs, move numbers and annotations.
    static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        var depth = 0, inBrace = false, inSemi = false
        var cur = ""
        func flush() {
            defer { cur = "" }
            var t = cur.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, depth == 0 else { return }
            if t.hasPrefix("$") { return }
            // strip move numbers like "12." or "12..." possibly glued: "12.e4"
            while let f = t.first, f.isNumber, !t.hasPrefix("1-0"), !t.hasPrefix("0-1"), !t.hasPrefix("1/2") {
                t.removeFirst()
            }
            while t.hasPrefix(".") { t.removeFirst() }
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: "!?"))
            if !t.isEmpty { out.append(t) }
        }
        for c in text {
            if inSemi { if c.isNewline { inSemi = false }; continue }
            if inBrace { if c == "}" { inBrace = false }; continue }
            switch c {
            case "{": flush(); inBrace = true
            case ";": flush(); inSemi = true
            case "(": flush(); depth += 1
            case ")": flush(); depth = max(0, depth - 1)
            case " ", "\t", "\n", "\r": flush()
            default: cur.append(c)
            }
            if out.count > maxPlies * 2 { break }
        }
        flush()
        return out
    }
}

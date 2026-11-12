//
//  Coach.swift
//  GTNW Chess
//
//  Nova's coaching: deterministic facts about the last move and the threats in the position (`CoachFacts`), a
//  scripted explanation built from them (`ScriptedCoach`, the fallback), and the AI narration on top
//  (`NovaNarrator`). Every move and square the AI mentions is validated against the real position.
//

import Foundation
import NovaAIKit

struct Threat: Equatable, Sendable {
    var target: Square
    var targetKind: PieceKind
    var attacker: Square
    var attackerKind: PieceKind
    var defended: Bool
}

struct CoachFacts: Equatable, Sendable {
    var lastMoveSAN: String?
    var lastMoveSide: Side?
    var lastMoveDescription: String?
    var sideToMove: Side
    var inCheck: Bool
    /// Pieces of the side to move that are attacked and either undefended or attacked by something cheaper.
    var yourThreatened: [Threat]
    /// Enemy pieces the side to move can win (attacked and undefended / by a cheaper piece).
    var targets: [Threat]
    /// Mate the opponent threatens next move if ignored (SAN), if any.
    var mateThreat: String?
    /// Mate in one available now (SAN), if any.
    var mateInOne: String?
    var materialBalance: Int
    var legalCount: Int
    /// Every square and SAN these facts mention (for validation).
    var mentionedSquares: Set<String>
    var mentionedSANs: Set<String>

    static func make(game: Game) -> CoachFacts {
        let pos = game.position
        let us = pos.sideToMove
        var squares = Set<String>(), sans = Set<String>()
        var desc: String?
        if let last = game.lastMove {
            sans.insert(last.san)
            squares.insert(Sq.name(last.move.from)); squares.insert(Sq.name(last.move.to))
            var d = "\(Cast.fullName(last.movedKind, last.side)) (\(last.movedKind.name)) \(Sq.name(last.move.from))→\(Sq.name(last.move.to))"
            if last.move.isCastle { d = "\(last.side.faction) castled \(Sq.file(last.move.to) == 6 ? "kingside" : "queenside")" }
            if let c = last.captured { d += ", capturing a \(c.name)" }
            if let p = last.move.promotion { d += ", promoting to a \(p.name)" }
            if last.isMate { d += ", checkmate" } else if last.isCheck { d += ", giving check" }
            desc = d
        }
        func threats(against side: Side, in p: Position) -> [Threat] {
            var out: [Threat] = []
            for s in 0..<64 {
                guard let pc = p.piece(at: s), pc.side == side, pc.kind != .king else { continue }
                let attackers = p.attackers(of: s, by: side.opposite)
                guard !attackers.isEmpty else { continue }
                let defenders = p.attackers(of: s, by: side)
                let cheapest = attackers.compactMap { p.piece(at: $0) }.min { $0.kind.value < $1.kind.value }!
                let cheapestSq = attackers.first { p.piece(at: $0) == cheapest }!
                if defenders.isEmpty || cheapest.kind.value < pc.kind.value {
                    out.append(Threat(target: s, targetKind: pc.kind, attacker: cheapestSq, attackerKind: cheapest.kind,
                                      defended: !defenders.isEmpty))
                }
            }
            return out.sorted { $0.targetKind.value > $1.targetKind.value }
        }
        let mine = threats(against: us, in: pos)
        let theirs = threats(against: us.opposite, in: pos)
        for t in mine + theirs { squares.insert(Sq.name(t.target)); squares.insert(Sq.name(t.attacker)) }
        let legal = pos.legalMoves()
        var mateNow: String?
        for m in legal {
            let after = pos.applying(m)
            if after.inCheck && after.legalMoves().isEmpty { mateNow = pos.san(m, legal: legal); break }
        }
        var mateThreat: String?
        if !pos.inCheck {
            var nullPos = pos
            nullPos.sideToMove = us.opposite
            nullPos.epSquare = -1
            let theirLegal = nullPos.legalMoves()
            for m in theirLegal {
                let after = nullPos.applying(m)
                if after.inCheck && after.legalMoves().isEmpty { mateThreat = nullPos.san(m, legal: theirLegal); break }
            }
        }
        if let m = mateNow { sans.insert(m) }
        if let m = mateThreat { sans.insert(m) }
        return CoachFacts(lastMoveSAN: game.lastMove?.san, lastMoveSide: game.lastMove?.side, lastMoveDescription: desc,
                          sideToMove: us, inCheck: pos.inCheck, yourThreatened: Array(mine.prefix(3)),
                          targets: Array(theirs.prefix(3)), mateThreat: mateThreat, mateInOne: mateNow,
                          materialBalance: pos.materialBalance, legalCount: legal.count,
                          mentionedSquares: squares, mentionedSANs: sans)
    }

    /// Plain-text fact sheet for the LLM prompt.
    var sheet: String {
        var lines: [String] = []
        if let d = lastMoveDescription, let s = lastMoveSAN { lines.append("Last move: \(s) — \(d).") }
        lines.append("\(sideToMove.faction) (\(sideToMove.name)) to move\(inCheck ? ", in check" : "").")
        let bal = materialBalance
        lines.append(bal == 0 ? "Material is level." : "Material: \(bal > 0 ? "white" : "black") is up \(abs(bal)).")
        for t in yourThreatened {
            lines.append("Threat to \(sideToMove.name): the \(t.targetKind.name) on \(Sq.name(t.target)) is attacked by the \(t.attackerKind.name) on \(Sq.name(t.attacker))\(t.defended ? " (defended, but the attacker is cheaper)" : " and is undefended").")
        }
        for t in targets {
            lines.append("Chance for \(sideToMove.name): the enemy \(t.targetKind.name) on \(Sq.name(t.target)) can be taken by the \(t.attackerKind.name) on \(Sq.name(t.attacker))\(t.defended ? " (it is defended)" : " (undefended)").")
        }
        if let m = mateThreat { lines.append("Danger: the opponent threatens \(m) mate next move.") }
        if let m = mateInOne { lines.append("\(m) is checkmate right now.") }
        return lines.joined(separator: "\n")
    }
}

/// The deterministic coach (AI off, unavailable, or a reply that failed validation).
enum ScriptedCoach {
    static func explain(_ f: CoachFacts, playerName: String) -> String {
        var parts: [String] = []
        if let d = f.lastMoveDescription, let s = f.lastMoveSAN { parts.append("\(s): \(d).") }
        if let m = f.mateInOne {
            parts.append("\(playerName), \(m) is checkmate. Take it!")
        } else if f.inCheck {
            parts.append("You're in check: move the Regent, block, or capture the checker.")
        }
        if let m = f.mateThreat, f.mateInOne == nil {
            parts.append("Careful: if you ignore it, \(m) is mate next move. Defend that first.")
        }
        if let t = f.yourThreatened.first {
            parts.append("Your \(t.targetKind.name) on \(Sq.name(t.target)) is under attack from the \(t.attackerKind.name) on \(Sq.name(t.attacker))\(t.defended ? " and the trade loses material" : " and nothing defends it").")
        }
        if let t = f.targets.first, f.mateInOne == nil {
            parts.append("Opportunity: the \(t.targetKind.name) on \(Sq.name(t.target)) is \(t.defended ? "worth more than your attacker" : "hanging") — your \(t.attackerKind.name) on \(Sq.name(t.attacker)) can take it.")
        }
        if parts.count <= 1 {
            parts.append(f.materialBalance == 0 ? "Material is level. Develop, castle, and fight for the centre."
                         : "Keep improving your worst-placed piece; no tactics are hanging right now.")
        }
        return parts.joined(separator: " ")
    }

    static func hint(move: Move, san: String, eval: Evaluation, side: Side) -> String {
        let e = eval.mate.map { "mate in \(abs($0))" } ?? String(format: "%+.1f", eval.pawns * (side == .white ? 1 : -1))
        return "Nova suggests \(san) (\(Sq.name(move.from))→\(Sq.name(move.to))). Engine view for you: \(e)."
    }

    static func recap(game: Game, white: String, black: String, analysis: GameAnalysis?, opening: Opening) -> String {
        guard let r = game.result else { return "The game is still going." }
        let who = r.winner.map { $0 == .white ? "\(white) (Solar)" : "\(black) (Void)" }
        var s = who.map { "\($0) wins by \(r.termination.label.lowercased())" } ?? "Drawn by \(r.termination.label.lowercased())"
        s += " after \(game.moves.count) plies, out of the \(opening.name)."
        if let a = analysis {
            s += String(format: " Accuracy: Solar %.0f%%, Void %.0f%%.", a.white.accuracy, a.black.accuracy)
            if let d = a.decisiveMoment { s += " Turning point: " + (d.note ?? "\(d.san) on move \(d.moveNumber).") }
        }
        return s
    }
}

/// Rejects AI text that mentions a move or square the game doesn't support.
struct ChessMentionValidator: Sendable {
    let allowedSANs: Set<String>
    let allowedSquares: Set<String>
    /// Square → piece kind names that may be claimed to stand there (current or previous position).
    let occupants: [String: Set<String>]

    static let sanRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(O-O-O|O-O|[KQRBN][a-h]?[1-8]?x?[a-h][1-8](?:=[QRBN])?|[a-h]x[a-h][1-8](?:=[QRBN])?|[a-h][1-8]=[QRBN])[+#]?"#)
    static let squareRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([a-h][1-8])(?![0-9A-Za-z])"#)
    static let claimRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(king|queen|rook|bishop|knight|pawn|piece|regent|corona|eclipse|bastion|vaulter|oracle|drone)s?\s+(?:on|at|from)\s+([a-h][1-8])\b"#)

    static let squarePieceRegex = try! NSRegularExpression(
        pattern: #"(?i)\b([a-h][1-8])[-\s]+(king|queen|rook|bishop|knight|pawn|piece|regent|corona|eclipse|bastion|vaulter|oracle|drone)s?\b"#)

    static let aliases: [String: String] = ["regent": "king", "corona": "queen", "eclipse": "queen", "bastion": "rook",
                                            "vaulter": "knight", "oracle": "bishop", "drone": "pawn"]

    init(game: Game, facts: CoachFacts, extraSANs: Set<String> = [], extraSquares: Set<String> = []) {
        var sans = facts.mentionedSANs.union(extraSANs)
        var squares = facts.mentionedSquares.union(extraSquares)
        let pos = game.position
        let legal = pos.legalMoves()
        for m in legal { sans.insert(pos.san(m, legal: legal)); squares.insert(Sq.name(m.to)); squares.insert(Sq.name(m.from)) }
        for pm in game.moves.suffix(12) { sans.insert(pm.san); squares.insert(Sq.name(pm.move.from)); squares.insert(Sq.name(pm.move.to)) }
        var occ: [String: Set<String>] = [:]
        let positions = game.positions
        for p in positions.suffix(2) {
            for s in 0..<64 { if let pc = p.piece(at: s) { occ[Sq.name(s), default: []].insert(pc.kind.name); squares.insert(Sq.name(s)) } }
        }
        allowedSANs = Set(sans.map(Self.bare))
        allowedSquares = squares
        occupants = occ
    }

    init(allowedSANs: Set<String>, allowedSquares: Set<String>, occupants: [String: Set<String>] = [:]) {
        self.allowedSANs = Set(allowedSANs.map(Self.bare))
        self.allowedSquares = allowedSquares
        self.occupants = occupants
    }

    static func bare(_ s: String) -> String { s.filter { !"+#!?".contains($0) } }

    static func matches(_ re: NSRegularExpression, _ s: String, group: Int = 1) -> [String] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range(at: group), in: s).map { String(s[$0]) }
        }
    }

    /// Error/apology boilerplate that some backends return as a normal reply ("I'm having some trouble right now…").
    static let boilerplateRegex = try! NSRegularExpression(pattern:
        #"(?i)(having (some )?trouble|try again (later|in)|give me a (few|minute|moment)|something went wrong|I can(no|')t (help|assist|do that)|as an AI\b|language model|\berror\b|unavailable|rate limit)"#)
    static let pieceWords = try! NSRegularExpression(pattern:
        #"(?i)\b(king|queen|rook|bishop|knight|pawn|regent|corona|eclipse|bastion|vaulter|oracle|drone|check(mate)?|castl\w*|solar|void)\b"#)

    /// Returns the cleaned text or throws the reason it was rejected. `requireAnchor`: the text must mention at least
    /// one real move, square or piece, so an off-topic or error reply never stands in for the coach.
    func validate(_ raw: String, requireAnchor: Bool = false) throws -> String {
        guard let cleaned = NovaAIText.clean(raw) else { throw NovaAIValidationError("empty reply") }
        let text = NovaAIText.plain(cleaned, max: 700)
        guard text.count >= 8 else { throw NovaAIValidationError("too short") }
        let all = NSRange(text.startIndex..., in: text)
        if Self.boilerplateRegex.firstMatch(in: text, range: all) != nil { throw NovaAIValidationError("error or apology text") }
        if requireAnchor, Self.matches(Self.sanRegex, text).isEmpty, Self.matches(Self.squareRegex, text).isEmpty,
           Self.pieceWords.firstMatch(in: text, range: all) == nil {
            throw NovaAIValidationError("doesn't talk about the game")
        }
        for san in Self.matches(Self.sanRegex, text) where !allowedSANs.contains(Self.bare(san)) {
            throw NovaAIValidationError("mentions \(san), which isn't a move in this game or position")
        }
        for sq in Self.matches(Self.squareRegex, text) where !allowedSquares.contains(sq) {
            throw NovaAIValidationError("mentions square \(sq), which isn't part of the position facts")
        }
        // "knight on f6" (piece, square) and "the d5 pawn" (square, piece): both are claims about the board.
        let claims = Self.claimRegex.matches(in: text, range: all).map { ($0, 1, 2) }
            + Self.squarePieceRegex.matches(in: text, range: all).map { ($0, 2, 1) }
        for (m, ki, si) in claims {
            guard let kr = Range(m.range(at: ki), in: text), let sr = Range(m.range(at: si), in: text) else { continue }
            var kind = text[kr].lowercased()
            kind = Self.aliases[kind] ?? kind
            let sq = String(text[sr])
            let there = occupants[sq] ?? []
            if !occupants.isEmpty, kind == "piece" ? there.isEmpty : !there.contains(kind) {
                throw NovaAIValidationError("says a \(kind) is on \(sq), which is false")
            }
        }
        return text
    }
}

/// Nova's AI narration. Every call returns text (AI when available and valid, else the script) and its source.
@MainActor
struct NovaNarrator {
    var ai: NovaAI

    /// "White (Solar): Ke1 Qd1 … pawns a2 b2 …" so the model never has to guess where pieces stand.
    nonisolated static func pieceList(_ p: Position) -> String {
        Side.allCases.map { side in
            var pieces: [String] = [], pawns: [String] = []
            for s in 0..<64 {
                guard let pc = p.piece(at: s), pc.side == side else { continue }
                if pc.kind == .pawn { pawns.append(Sq.name(s)) } else { pieces.append(pc.kind.sanLetter + Sq.name(s)) }
            }
            return "\(side.name.capitalized) (\(side.faction)): " + (pieces + (pawns.isEmpty ? [] : ["pawns " + pawns.joined(separator: " ")])).joined(separator: " ")
        }.joined(separator: "\n") + "\nEvery other square is empty."
    }

    func coach(game: Game, playerName: String) async -> NovaAIResult<String> {
        let facts = CoachFacts.make(game: game)
        let scripted = ScriptedCoach.explain(facts, playerName: playerName)
        let validator = ChessMentionValidator(game: game, facts: facts)
        let prompt = """
            Facts about the position:
            \(facts.sheet)
            \(Self.pieceList(game.position))

            Explain the last move and the main threat to \(playerName) (playing \(facts.sideToMove.faction)) in two or three \
            short sentences, like a friendly coach. Mention only moves, squares and pieces from the facts; never place a piece on a square the piece list does not give it.
            """
        let req = NovaAIRequest(prompt: prompt, system: NovaPersona.system("You are coaching a learner. Be encouraging and concrete."),
                                temperature: 0.4, maxTokens: 220)
        return await ai.text(req, validate: { try validator.validate($0, requireAnchor: true) }, fallback: { scripted })
    }

    func battleTalk(attacker: PieceKind, victim: PieceKind, attackerSide: Side, game: Game) async -> NovaAIResult<String> {
        let (a, v) = Cast.battleLine(attacker: attacker, victim: victim, attackerSide: attackerSide)
        let scripted = a + " — " + v
        let facts = CoachFacts.make(game: game)
        let validator = ChessMentionValidator(game: game, facts: facts)
        let prompt = """
            The \(Cast.fullName(attacker, attackerSide)) (\(Cast.personality(attacker))) just captured the \
            \(Cast.fullName(victim, attackerSide.opposite)) (\(Cast.personality(victim))) with \(game.lastMove?.san ?? "a capture").
            Write one line of trash talk from the attacker and one short last word from the victim, on a single line \
            separated by " — ". At most 30 words total. Playful, no gore.
            """
        let req = NovaAIRequest(prompt: prompt, system: NovaPersona.system("You voice the robot pieces' battle banter."),
                                temperature: 0.9, maxTokens: 90)
        return await ai.text(req, validate: { try validator.validate($0, requireAnchor: true) }, fallback: { scripted })
    }

    func recap(game: Game, white: String, black: String, analysis: GameAnalysis?, opening: Opening) async -> NovaAIResult<String> {
        let scripted = ScriptedCoach.recap(game: game, white: white, black: black, analysis: analysis, opening: opening)
        var sans = Set(game.sanMoves)
        var facts = "Result: \(game.result?.pgn ?? "*") (\(game.result?.termination.label ?? "in progress")). Opening: \(opening.eco) \(opening.name).\n"
        facts += "Moves: " + game.sanMoves.joined(separator: " ") + "\n"
        if let a = analysis {
            facts += String(format: "Accuracy: Solar %.0f%%, Void %.0f%%. Blunders: Solar %d, Void %d.\n",
                            a.white.accuracy, a.black.accuracy, a.white.blunders, a.black.blunders)
            if let d = a.decisiveMoment {
                facts += "Decisive moment: \(d.note ?? d.san)\n"
                if let b = d.bestSAN { sans.insert(b) }
            }
        }
        let validator = ChessMentionValidator(allowedSANs: sans, allowedSquares: Set((0..<64).map(Sq.name)))
        let prompt = facts + "\nWrite a 3-4 sentence recap of this game for the players, \(white) (Solar) and \(black) (Void). Cite at most three moves, only from the list."
        let req = NovaAIRequest(prompt: prompt, system: NovaPersona.system("You are recapping a finished game. Roast the moves, never the people."),
                                temperature: 0.6, maxTokens: 260)
        return await ai.text(req, validate: { try validator.validate($0, requireAnchor: true) }, fallback: { scripted })
    }
}

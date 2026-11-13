//
//  PlayRecorder.swift
//  GTNW Chess
//
//  Turns a game into play history (contract: NovaGames play schema, game `gtnwchess`): a session per game, live
//  `game_start` / `ply` / `takeback` / `draw_offer` / `resign` events, and at the end the analysed `move` events,
//  `game_over` and the summary (players, result, opening, captures, checks, material graph, PGN, Stockfish analysis).
//
//  ONE GAME = ONE SESSION. In LAN play only the host records (the session id is the shared LAN game UUID); the
//  guest's recorder is disabled, enforced here (`isEnabled`) and tested.
//

import Foundation

/// `watch` = AI vs AI spectator games: recorded as player "AI vs AI" with summary.spectator = true (kept out of human stats).
enum GameMode: String, Codable, Sendable { case vsNova = "vs_nova", hotseat, lan, watch }

struct PlayerInfo: Codable, Equatable, Sendable {
    var name: String
    var kind: String          // "human" | "nova" | "model" (a language model; `level` is its engine fallback)
    var level: Int?
    var levelName: String?
    var local: Bool
    var account: String?
    /// kind "model": NovaAIBackend rawValue ("auto" = the AI settings) and model id (nil = the backend's model).
    var backend: String? = nil
    var model: String? = nil

    static func human(_ name: String, local: Bool, account: String?) -> PlayerInfo {
        PlayerInfo(name: PlayerInfo.clean(name), kind: "human", level: nil, levelName: nil, local: local, account: account)
    }
    static func nova(_ level: EngineLevel) -> PlayerInfo {
        PlayerInfo(name: "Nova", kind: "nova", level: level.rawValue, levelName: level.name, local: true, account: nil)
    }

    /// Display names: printable, ≤ 32 chars, never empty.
    static func clean(_ s: String) -> String {
        let t = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Player" : String(t.prefix(32))
    }

    /// The macOS user's first name (default display name).
    static var defaultName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return clean(full.split(separator: " ").first.map(String.init) ?? NSUserName())
    }
}

struct ClockConfig: Codable, Equatable, Sendable {
    var initialSeconds: Int
    var incrementSeconds: Int

    static let presets: [ClockConfig] = [ClockConfig(initialSeconds: 300, incrementSeconds: 0), ClockConfig(initialSeconds: 300, incrementSeconds: 3),
                                         ClockConfig(initialSeconds: 600, incrementSeconds: 5), ClockConfig(initialSeconds: 900, incrementSeconds: 10),
                                         ClockConfig(initialSeconds: 1800, incrementSeconds: 0)]
    var label: String { "\(initialSeconds / 60)+\(incrementSeconds)" }
}

struct PlayContext: Codable, Equatable, Sendable {
    var sessionID: UUID
    var mode: GameMode
    var white: PlayerInfo
    var black: PlayerInfo
    /// "white" | "black" | "both" — the side(s) played on this Mac.
    var you: String
    var clock: ClockConfig?
    var startedAt: Date
    var startFEN: String?
    /// The game's gameplay RNG seed (SplitMix64; nil for games recorded before 1.1).
    var seed: UInt64? = nil

    static func seedString(_ s: UInt64?) -> Any { s.map { String(format: "%016llx", $0) as Any } ?? NSNull() }

    func player(_ s: Side) -> PlayerInfo { s == .white ? white : black }
}

/// One language-model answer for a move (Watch model-vs-model). Recorded as a `model_reply` event so replays and
/// journals read the record and never re-call a model (after Quake III Com_InitJournaling: the journal of external
/// inputs is the source of truth). `fallback`: this was the last failed ask and the engine played.
struct ModelReply: Equatable, Sendable {
    var side: Side
    var backend: String
    var model: String?
    var reply: String
    var latencyMs: Int
    var attempt: Int
    var san: String?
    var error: String?
    var fallback = false
    var valid: Bool { san != nil }
}

struct LiveEvent: Codable, Equatable, Sendable {
    var kind: String
    var ply: Int
    var by: Side?
    var accepted: Bool?
}

enum PlayReport {
    static func json(_ o: [String: Any], max: Int = 4096) -> Data {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]),
              d.count <= max else { return Data("{\"truncated\":true}".utf8) }
        return d
    }

    static func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    static func playerJSON(_ p: PlayerInfo) -> [String: Any] {
        var d: [String: Any] = ["name": p.name, "kind": p.kind, "level": p.level.map { $0 as Any } ?? NSNull(),
                                "level_name": p.levelName.map { $0 as Any } ?? NSNull(), "local": p.local,
                                "account": p.account.map { $0 as Any } ?? NSNull()]
        if p.kind == "model" { d["backend"] = p.backend ?? NSNull(); d["model"] = p.model ?? NSNull() }
        return d
    }

    /// Printable, one line, ≤ 80 chars: what a model said, never the whole reply.
    static func excerpt(_ s: String) -> String {
        let t = s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(t.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    static func modelReplyEvent(_ r: ModelReply, ply: Int, seq: Int, at: Date) -> PlayEventRecord {
        PlayEventRecord(seq: seq, kind: "model_reply", detail: json([
            "ply": ply, "side": r.side.name, "backend": r.backend, "model": r.model.map { $0 as Any } ?? NSNull(),
            "excerpt": excerpt(r.reply), "latency_ms": r.latencyMs, "attempt": r.attempt, "valid": r.valid,
            "san": r.san.map { $0 as Any } ?? NSNull(), "error": r.error.map { excerpt($0) as Any } ?? NSNull(), "fallback": r.fallback,
        ]), ts: at)
    }

    static func clockJSON(_ c: ClockConfig?) -> Any {
        c.map { ["initial_seconds": $0.initialSeconds, "increment_seconds": $0.incrementSeconds] as [String: Any] } ?? NSNull()
    }

    static func startEvent(_ ctx: PlayContext, at: Date) -> PlayEventRecord {
        let level = ctx.white.level ?? ctx.black.level
        return PlayEventRecord(seq: 0, kind: "game_start", detail: json([
            "mode": ctx.mode.rawValue, "white": ctx.white.name, "black": ctx.black.name, "white_kind": ctx.white.kind,
            "black_kind": ctx.black.kind, "level": level.map { $0 as Any } ?? NSNull(), "clock": clockJSON(ctx.clock),
            "start_fen": ctx.startFEN.map { $0 as Any } ?? NSNull(), "seed": PlayContext.seedString(ctx.seed),
        ]), ts: at)
    }

    static func plyEvent(_ pm: PlayedMove, ply: Int, moveNumber: Int, seq: Int, at: Date) -> PlayEventRecord {
        PlayEventRecord(seq: seq, kind: "ply", detail: json([
            "ply": ply, "move_number": moveNumber, "side": pm.side.name, "san": pm.san, "uci": pm.move.uci,
            "capture": pm.captured.map { $0.name as Any } ?? NSNull(), "check": pm.isCheck,
            "clock_ms": pm.clockMs.map { $0 as Any } ?? NSNull(),
        ]), ts: at)
    }

    static func liveEvent(_ e: LiveEvent, seq: Int, at: Date, fromPly: Int? = nil) -> PlayEventRecord {
        var d: [String: Any] = ["ply": e.ply]
        if let by = e.by { d["by"] = by.name }
        if let a = e.accepted { d["accepted"] = a }
        if e.kind == "takeback", let f = fromPly { d = ["from_ply": f, "to_ply": e.ply] }
        return PlayEventRecord(seq: seq, kind: e.kind, detail: json(d), ts: at)
    }

    /// Outcome from this Mac's player's point of view.
    static func outcome(_ game: Game, _ ctx: PlayContext) -> String {
        guard let r = game.result else { return "abandoned" }
        if r.termination == .abandoned { return "abandoned" }
        if ctx.mode == .watch { return r.winner.map { "\($0.name)_wins" } ?? "draw" }
        if ctx.you == "both" { return "hotseat" }
        guard let w = r.winner else { return "draw" }
        return w.name == ctx.you ? "win" : "loss"
    }

    static func score(_ ctx: PlayContext, _ a: GameAnalysis?) -> Double? {
        guard let a else { return nil }
        return ctx.you == "black" ? a.black.accuracy : a.white.accuracy
    }

    static func capturesJSON(_ game: Game) -> [String: Any] {
        var out: [String: Any] = [:]
        for s in Side.allCases {
            let c = game.captures(by: s)
            out[s.name] = Dictionary(uniqueKeysWithValues: [PieceKind.pawn, .knight, .bishop, .rook, .queen].map { ($0.name, c[$0] ?? 0) })
        }
        return out
    }

    static func notable(_ game: Game, takebacks: Int) -> [String] {
        var out: [String] = []
        for (i, pm) in game.moves.enumerated() {
            let n = i / 2 + game.startPosition.fullmoveNumber
            if pm.move.isCastle { out.append("Castled \(Sq.file(pm.move.to) == 6 ? "kingside" : "queenside") on move \(n) (\(pm.side.name))") }
            if let p = pm.move.promotion { out.append("Promoted to a \(p.name) with \(pm.san) on move \(n) (\(pm.side.name))") }
            if pm.captured == .queen { out.append("Won the queen with \(pm.san) on move \(n) (\(pm.side.name))") }
        }
        if takebacks > 0 { out.append("\(takebacks) takeback\(takebacks == 1 ? "" : "s")") }
        return Array(out.prefix(40))
    }

    static let watchPlayer = "AI vs AI"

    static func summary(_ game: Game, _ ctx: PlayContext, analysis: GameAnalysis?, opening: Opening, white: String, black: String,
                        duration: TimeInterval, takebacks: Int, fallbacks: [String: Int] = [:]) -> Data {
        let r = game.result
        var s: [String: Any] = [
            "mode": ctx.mode.rawValue,
            "players": ["white": playerJSON(ctx.white), "black": playerJSON(ctx.black)],
            "you": ctx.you,
            "result": r?.pgn ?? "*",
            "winner": r?.winner.map { $0.name as Any } ?? NSNull(),
            "termination": (r?.termination ?? .abandoned).rawValue,
            "opening": ["eco": opening.eco, "name": opening.name],
            "plies": game.moves.count,
            "moves": (game.moves.count + 1) / 2,
            "duration_seconds": Int(max(0, duration)),
            "clock": clockJSON(ctx.clock),
            "captures": capturesJSON(game),
            "checks": ["white": game.checks(by: .white), "black": game.checks(by: .black)],
            "material_graph": Array(game.materialGraph.prefix(400)),
            "notable": notable(game, takebacks: takebacks),
            "takebacks": takebacks,
            "seed": PlayContext.seedString(ctx.seed),
        ]
        s["pgn"] = String(PGN.export(game, white: white, black: black, date: ctx.startedAt).prefix(40_000))
        if ctx.mode == .watch {
            s["spectator"] = true
            s["matchup"] = ["sides": [Side.white, .black].map { side -> [String: Any] in
                let p = ctx.player(side)
                if p.kind == "model" {
                    return ["side": side.name, "kind": "model", "backend": p.backend ?? NSNull(), "model": p.model ?? NSNull(), "label": p.name]
                }
                return ["side": side.name, "kind": "engine", "backend": NSNull(), "model": NSNull(),
                        "label": "Nova engine" + (p.levelName.map { " (\($0))" } ?? "")]
            }]
            let models = [Side.white, .black].filter { ctx.player($0).kind == "model" }
            if !models.isEmpty { s["fallbacks"] = Dictionary(uniqueKeysWithValues: models.map { ($0.name, fallbacks[$0.name] ?? 0) }) }
        }
        if let a = analysis {
            func st(_ x: SideStats) -> [String: Any] {
                ["accuracy": x.accuracy, "acpl": x.acpl, "blunders": x.blunders, "mistakes": x.mistakes, "inaccuracies": x.inaccuracies]
            }
            func mo(_ m: Moment?) -> Any {
                guard let m else { return NSNull() }
                var d: [String: Any] = ["ply": m.ply, "move_number": m.moveNumber, "side": m.side.name, "san": m.san,
                                        "eval_before": m.evalBefore, "eval_after": m.evalAfter, "swing": m.swing]
                d["best_san"] = m.bestSAN.map { $0 as Any } ?? NSNull()
                if let n = m.note { d["note"] = n }
                return d
            }
            s["analysis"] = ["engine": a.engine, "depth": a.depth, "white": st(a.white), "black": st(a.black),
                             "biggest_swing": mo(a.biggestSwing), "decisive_moment": mo(a.decisiveMoment)]
        } else {
            s["analysis"] = NSNull()
        }
        var d = json(s, max: 65_000)
        if d.count > 60_000 || String(decoding: d, as: UTF8.self).contains("\"truncated\"") {
            s["pgn"] = String((s["pgn"] as? String ?? "").prefix(8_000))
            s["material_graph"] = Array(game.materialGraph.prefix(150))
            d = json(s, max: 65_000)
        }
        return d
    }

    static func finalEvents(_ game: Game, analysis: GameAnalysis?, firstSeq: Int, at: Date, opening: Opening) -> [PlayEventRecord] {
        var out: [PlayEventRecord] = []
        var seq = firstSeq
        let byPly = Dictionary(uniqueKeysWithValues: (analysis?.moves ?? []).map { ($0.ply, $0) })
        let positions = game.positions
        for (i, pm) in game.moves.enumerated() {
            let a = byPly[i + 1]
            var d: [String: Any] = ["ply": i + 1, "move_number": positions[i].fullmoveNumber, "side": pm.side.name, "san": pm.san,
                                    "uci": pm.move.uci, "capture": pm.captured.map { $0.name as Any } ?? NSNull(),
                                    "check": pm.isCheck, "mate": pm.isMate, "clock_ms": pm.clockMs.map { $0 as Any } ?? NSNull()]
            d["eval_before"] = a.map { $0.evalBefore as Any } ?? NSNull()
            d["eval_after"] = a.map { $0.evalAfter as Any } ?? NSNull()
            d["classification"] = a.map { $0.classification.rawValue as Any } ?? NSNull()
            d["best_san"] = a?.bestSAN.map { $0 as Any } ?? NSNull()
            out.append(PlayEventRecord(seq: seq, kind: "move", detail: json(d), ts: at))
            seq += 1
        }
        let r = game.result
        out.append(PlayEventRecord(seq: seq, kind: "game_over", detail: json([
            "result": r?.pgn ?? "*", "winner": r?.winner.map { $0.name as Any } ?? NSNull(),
            "termination": (r?.termination ?? .abandoned).rawValue, "plies": game.moves.count,
            "opening": ["eco": opening.eco, "name": opening.name],
            "white_accuracy": analysis.map { $0.white.accuracy as Any } ?? NSNull(),
            "black_accuracy": analysis.map { $0.black.accuracy as Any } ?? NSNull(),
        ]), ts: at))
        return out
    }
}

/// Records one game at a time into the outbox.
@MainActor
final class PlayRecorder {
    let outbox: PlayOutbox
    private(set) var context: PlayContext?
    private(set) var seq = 0
    private(set) var takebacks = 0
    private(set) var ended = false
    /// Watch: per side, how often the engine played because a model gave no legal move.
    private(set) var fallbacks: [String: Int] = [:]
    var now: () -> Date = Date.init

    /// False for a LAN guest (the host writes the one session for the game).
    var isEnabled: Bool { context.map { !($0.mode == .lan && $0.you != hostSide) } ?? false }
    /// For LAN games: the side the host plays ("white"/"black"); the recorder only runs on the host.
    var hostSide: String?

    init(outbox: PlayOutbox) { self.outbox = outbox }

    struct State: Codable, Equatable { var context: PlayContext; var seq: Int; var takebacks: Int; var hostSide: String?; var fallbacks: [String: Int]? }
    var state: State? { context.map { State(context: $0, seq: seq, takebacks: takebacks, hostSide: hostSide, fallbacks: fallbacks) } }

    func begin(_ ctx: PlayContext, hostSide: String? = nil) {
        context = ctx
        self.hostSide = hostSide
        seq = 0
        takebacks = 0
        fallbacks = [:]
        ended = false
        guard isEnabled else { return }
        outbox.enqueue(.start(id: ctx.sessionID, startedAt: ctx.startedAt, player: ctx.mode == .watch ? PlayReport.watchPlayer : nil))
        outbox.enqueue(.events(id: ctx.sessionID, events: [PlayReport.startEvent(ctx, at: ctx.startedAt)], actions: 0))
        seq = 1
    }

    /// Resumes a saved game's recording (same session id; seq continues).
    func resume(_ s: State) {
        context = s.context
        seq = s.seq
        takebacks = s.takebacks
        hostSide = s.hostSide
        fallbacks = s.fallbacks ?? [:]
        ended = false
    }

    /// A model's answer for the move at `ply` (and the fallback count when the engine had to play it).
    func modelReply(_ r: ModelReply, ply: Int) {
        guard isEnabled, !ended, let ctx = context else { return }
        if r.fallback { fallbacks[r.side.name, default: 0] += 1 }
        outbox.enqueue(.events(id: ctx.sessionID, events: [PlayReport.modelReplyEvent(r, ply: ply, seq: seq, at: now())], actions: ply - 1))
        seq += 1
    }

    func played(_ pm: PlayedMove, game: Game) {
        guard isEnabled, !ended, let ctx = context else { return }
        let ply = game.moves.count
        let moveNumber = game.positions[ply - 1].fullmoveNumber
        outbox.enqueue(.events(id: ctx.sessionID, events: [PlayReport.plyEvent(pm, ply: ply, moveNumber: moveNumber, seq: seq, at: now())], actions: ply))
        seq += 1
    }

    func live(_ e: LiveEvent, fromPly: Int? = nil, actions: Int) {
        guard isEnabled, !ended, let ctx = context else { return }
        if e.kind == "takeback" { takebacks += 1 }
        outbox.enqueue(.events(id: ctx.sessionID, events: [PlayReport.liveEvent(e, seq: seq, at: now(), fromPly: fromPly)], actions: actions))
        seq += 1
    }

    /// Final write: analysed moves, game_over, ended session with summary.
    func finish(game: Game, analysis: GameAnalysis?, white: String, black: String) {
        guard isEnabled, !ended, let ctx = context else { return }
        ended = true
        let t = now()
        let opening = game.startsFromStandard ? Openings.classify(game.sanMoves) : Opening(eco: "-", name: "Custom position")
        let evs = PlayReport.finalEvents(game, analysis: analysis, firstSeq: seq, at: t, opening: opening)
        seq += evs.count
        for chunk in stride(from: 0, to: evs.count, by: 50) {
            outbox.enqueue(.events(id: ctx.sessionID, events: Array(evs[chunk..<min(evs.count, chunk + 50)]), actions: game.moves.count))
        }
        let summary = PlayReport.summary(game, ctx, analysis: analysis, opening: opening, white: white, black: black,
                                         duration: t.timeIntervalSince(ctx.startedAt), takebacks: takebacks, fallbacks: fallbacks)
        outbox.enqueue(.end(id: ctx.sessionID, startedAt: ctx.startedAt,
                            end: PlaySessionEnd(outcome: PlayReport.outcome(game, ctx), score: PlayReport.score(ctx, analysis),
                                                actions: game.moves.count, summary: summary, endedAt: t,
                                                player: ctx.mode == .watch ? PlayReport.watchPlayer : nil)))
    }

    /// Watch game handed to a human: the AI-vs-AI session ends here as "taken_over"; the caller starts a normal one.
    func endTakenOver(game: Game, white: String, black: String) {
        guard isEnabled, !ended, let ctx = context, ctx.mode == .watch else { return }
        ended = true
        let t = now()
        let summary = PlayReport.summary(game, ctx, analysis: nil, opening: Opening(eco: "-", name: "Taken over"), white: white, black: black,
                                         duration: t.timeIntervalSince(ctx.startedAt), takebacks: takebacks, fallbacks: fallbacks)
        outbox.enqueue(.end(id: ctx.sessionID, startedAt: ctx.startedAt,
                            end: PlaySessionEnd(outcome: "taken_over", score: nil, actions: game.moves.count, summary: summary,
                                                endedAt: t, player: PlayReport.watchPlayer)))
    }
}

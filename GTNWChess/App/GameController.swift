//
//  GameController.swift
//  GTNW Chess
//
//  The game's brain on the main actor: modes (vs Nova, hot-seat, LAN), input and promotion, Stockfish moves,
//  battles, clocks, draw offers / resignation, takebacks, hints, Nova's coach and commentary, autosave/resume and
//  play history. Every move from anywhere (click, engine, the other Mac, a PGN) goes through the rules engine.
//

import Foundation
import NovaAIKit
import SwiftUI

struct FeedItem: Identifiable, Equatable {
    enum Kind: String { case coach, battle, system, recap, hint }
    let id = UUID()
    var kind: Kind
    var text: String
    var source: String
}

struct PendingPromotion: Identifiable, Equatable {
    var id: String { "\(from)-\(to)" }
    var from: Square
    var to: Square
    var side: Side
}

struct NewGameConfig: Equatable {
    var mode: GameMode = .vsNova
    var level: EngineLevel = .pilot
    /// Void's level in a Watch game (`level` is Solar's).
    var blackLevel: EngineLevel = .captain
    /// "white", "black" or "random" (vs Nova / LAN host).
    var side = "white"
    var playerName = PlayerInfo.defaultName
    var opponentName = "Challenger"
    var clock: ClockConfig?
    var startFEN: String?
}

enum Prefs {
    static let battles = "anim.battles", speed = "anim.speed", camera = "anim.camera", carnage = "anim.carnage"
    static let sound = "sound.enabled", volume = "sound.volume"
    static let coachAuto = "coach.auto", showThreats = "coach.threats", legalHints = "coach.legal"
    static let playerName = "player.name", antialias = "gfx.antialias", shadows = "gfx.shadows"
    static let siteSkipped = "site.signInSkipped", watchDelay = "watch.delay"

    static func register() {
        UserDefaults.standard.register(defaults: [battles: true, speed: 1.0, camera: true, carnage: 2, sound: true, volume: 0.8,
                                                  coachAuto: true, showThreats: true, legalHints: true, antialias: true, shadows: true, watchDelay: 1.2])
    }

    static var animation: AnimationPrefs {
        let d = UserDefaults.standard
        return AnimationPrefs(battlesEnabled: d.bool(forKey: battles), speed: min(3, max(0.5, d.double(forKey: speed))),
                              cinematicCamera: d.bool(forKey: camera), carnage: min(2, max(0, d.integer(forKey: carnage))))
    }

    static var playerDisplayName: String {
        let s = UserDefaults.standard.string(forKey: playerName) ?? ""
        return s.trimmingCharacters(in: .whitespaces).isEmpty ? PlayerInfo.defaultName : PlayerInfo.clean(s)
    }
}

@MainActor
final class GameController: ObservableObject {
    @Published private(set) var game = Game()
    @Published private(set) var mode: GameMode = .vsNova
    @Published private(set) var white = PlayerInfo.human(PlayerInfo.defaultName, local: true, account: nil)
    @Published private(set) var black = PlayerInfo.nova(.pilot)
    @Published private(set) var level: EngineLevel = .pilot
    /// "white" | "black" | "both" | "none" (watching).
    @Published private(set) var you = "white"
    /// Watch mode: hold the next engine move.
    @Published private(set) var watchPaused = false
    private var lastWatchConfig: NewGameConfig?
    @Published var selected: Square?
    @Published var promotion: PendingPromotion?
    @Published private(set) var animating = false
    @Published private(set) var battleBanner: String?
    @Published private(set) var engineThinking = false
    @Published private(set) var coachText = "Welcome to GTNW Chess. Solar moves first."
    @Published private(set) var coachSource = "Built-in"
    @Published private(set) var feed: [FeedItem] = []
    @Published private(set) var hintMove: Move?
    @Published private(set) var clock: ChessClock?
    @Published var drawOfferFrom: Side?
    @Published private(set) var analysis: GameAnalysis?
    @Published private(set) var analyzing = false
    @Published private(set) var recap: String?
    @Published var is3D = true { didSet { if !is3D { scene.skipBattle() } } }
    @Published var flipped = false { didSet { scene.setFlipped(flipped, animated: true) } }
    @Published private(set) var lanInfo: SavedGame.LANInfo?
    @Published private(set) var waitingForGuest = false
    @Published private(set) var lanNote: String?
    @Published private(set) var gameToken = UUID()

    let scene: BoardScene
    let engine: EngineService
    let lan: LANSession
    let outbox: PlayOutbox
    let recorder: PlayRecorder
    let site: GamesSiteClient
    var ai: NovaAI
    var persist = true
    private var clockTimer: Timer?
    private var lastTick = Date()
    private var startedAt = Date()

    init(engine: EngineService = .makeDefault(), ai: NovaAI? = nil, site: GamesSiteClient = GamesSiteClient(),
         outbox: PlayOutbox? = nil, persist: Bool = !RuntimeEnv.underXCTest && !RuntimeEnv.demo) {
        Prefs.register()
        scene = BoardScene()
        self.engine = engine
        self.ai = ai ?? AppAI.shared
        self.site = site
        self.persist = persist
        lan = LANSession()
        let box = outbox ?? PlayOutbox(fileURL: persist ? PlayOutbox.defaultURL() : nil, sink: nil)
        self.outbox = box
        recorder = PlayRecorder(outbox: box)
        if outbox == nil { box.sink = Self.chooseSink(site: site) }
        lan.onMessage = { [weak self] m in self?.handleLAN(m) }
        lan.onConnected = { [weak self] in self?.lanConnected() }
        lan.onDisconnected = { [weak self] in self?.lanNote = "The other Mac disconnected. Waiting for it to come back…" }
        scene.sync(game.position)
        refreshHighlights()
    }

    /// PG direct on Little Mister's Macs (role password in the login keychain), else the site API when signed in.
    static func chooseSink(site: GamesSiteClient) -> PlaySink? {
        if RuntimeEnv.underXCTest || RuntimeEnv.demo { return nil }
        if let pg = PGPlaySink.makeDefault() { return pg }
        return SitePlaySink(client: site)
    }

    /// Which Nova Games identity sits on this Mac's side.
    var localAccount: String? {
        if outbox.sink is PGPlaySink { return "default" }
        return site.isConfigured ? site.username : nil
    }

    var playSinkLabel: String { outbox.sink?.label ?? "Not set up (local queue only)" }

    // MARK: - Derived state

    func player(_ s: Side) -> PlayerInfo { s == .white ? white : black }
    var whiteName: String { white.kind == "nova" ? "Nova (\(white.levelName ?? ""))" : white.name }
    var blackName: String { black.kind == "nova" ? "Nova (\(black.levelName ?? ""))" : black.name }
    func displayName(_ s: Side) -> String { s == .white ? whiteName : blackName }

    func isLocal(_ s: Side) -> Bool {
        switch mode {
        case .hotseat: return true
        case .vsNova, .lan: return you == s.name
        case .watch: return false
        }
    }

    var canInteract: Bool {
        !animating && !game.isOver && !engineThinking && isLocal(game.sideToMove) && !waitingForGuest
            && (mode != .lan || lan.isConnected)
    }

    var legalTargets: [Square] {
        guard let s = selected else { return [] }
        return game.position.legalMoves(from: s).map(\.to)
    }

    var statusLine: String {
        if waitingForGuest { return "Waiting for a challenger to join…" }
        if let r = game.result {
            if let w = r.winner { return "\(displayName(w)) (\(w.faction)) wins — \(r.termination.label)" }
            return "Draw — \(r.termination.label)"
        }
        var s = "\(displayName(game.sideToMove)) (\(game.sideToMove.faction)) to move"
        if game.position.inCheck { s += " — check!" }
        if engineThinking { s = "Nova is thinking…" }
        return s
    }

    var playerName: String {
        switch mode {
        case .hotseat: return displayName(game.sideToMove)
        default: return you == "black" ? black.name : white.name
        }
    }

    // MARK: - New game / resume

    func newGame(_ c: NewGameConfig) {
        stopLAN()
        scene.skipBattle()
        var g: Game
        if let fen = c.startFEN, let fg = try? Game(fen: fen) { g = fg } else { g = Game() }
        let side: Side = c.side == "random" ? (Bool.random() ? .white : .black) : (c.side == "black" ? .black : .white)
        mode = c.mode
        level = c.level
        let me = PlayerInfo.human(c.playerName, local: true, account: localAccount)
        switch c.mode {
        case .vsNova:
            you = side.name
            white = side == .white ? me : .nova(c.level)
            black = side == .black ? me : .nova(c.level)
        case .hotseat:
            you = "both"
            white = me
            black = .human(c.opponentName, local: true, account: nil)
        case .lan:
            you = side.name
            white = side == .white ? me : .human("Challenger", local: false, account: nil)
            black = side == .black ? me : .human("Challenger", local: false, account: nil)
        case .watch:
            you = "none"
            white = .nova(c.level)
            black = .nova(c.blackLevel)
            lastWatchConfig = c
        }
        watchPaused = false
        install(g, clock: c.clock.map(ChessClock.init(config:)))
        g = game
        flipped = side == .black && c.mode != .hotseat && c.mode != .watch
        feed.removeAll()
        if c.mode == .lan { return }   // starts when the guest arrives
        beginRecording(sessionID: UUID(), hostSide: nil)
        say("New game: \(whiteName) (Solar) vs \(blackName) (Void).", kind: .system, source: "GTNW Chess")
        afterPositionChange()
        maybeEngineMove()
    }

    private func install(_ g: Game, clock: ChessClock?) {
        game = g
        gameToken = UUID()
        selected = nil
        promotion = nil
        hintMove = nil
        drawOfferFrom = nil
        analysis = nil
        recap = nil
        engineThinking = false
        animating = false
        battleBanner = nil
        self.clock = clock
        startedAt = Date()
        scene.sync(game.position)
        refreshHighlights()
        startClockTimer()
    }

    private func beginRecording(sessionID: UUID, hostSide: String?) {
        let ctx = PlayContext(sessionID: sessionID, mode: mode, white: white, black: black, you: you, clock: clock?.config,
                              startedAt: startedAt, startFEN: game.startsFromStandard ? nil : game.startPosition.fen)
        recorder.begin(ctx, hostSide: hostSide)
        autosave()
    }

    func resumeSaved() -> Bool {
        guard persist, let s = GameStore.load(), let g = try? s.restore() else { return false }
        mode = s.mode
        white = s.white
        black = s.black
        level = s.level ?? .pilot
        you = s.you
        install(g, clock: s.clock)
        if let r = s.recorder { recorder.resume(r); startedAt = r.context.startedAt }
        flipped = you == "black"
        lanInfo = s.lan
        say(g.isOver ? "Last game restored (finished)." : "Game resumed where you left off.", kind: .system, source: "GTNW Chess")
        if let info = s.lan, !g.isOver { resumeLAN(info) }
        afterPositionChange()
        maybeEngineMove()
        return true
    }

    func autosave() {
        guard persist else { return }
        let s = SavedGame(mode: mode, startFEN: game.startPosition.fen, moves: game.uciMoves, white: white, black: black,
                          level: level, you: you, clock: clock, recorder: recorder.state, lan: lanInfo, result: game.result,
                          savedAt: Date())
        GameStore.save(s)
    }

    // MARK: - Input

    func tap(_ s: Square) {
        guard canInteract else { return }
        if let sel = selected, legalTargets.contains(s) {
            attemptMove(from: sel, to: s)
            return
        }
        if let p = game.position.piece(at: s), p.side == game.sideToMove {
            selected = selected == s ? nil : s
            SoundPlayer.shared.play(.select)
        } else {
            selected = nil
        }
        refreshHighlights()
    }

    func attemptMove(from: Square, to: Square) {
        let candidates = game.position.legalMoves(from: from).filter { $0.to == to }
        guard !candidates.isEmpty else { selected = nil; refreshHighlights(); return }
        if candidates.count > 1, candidates.allSatisfy({ $0.promotion != nil }) {
            promotion = PendingPromotion(from: from, to: to, side: game.sideToMove)
            return
        }
        commit(candidates[0], source: .local)
    }

    func choosePromotion(_ kind: PieceKind?) {
        guard let p = promotion else { return }
        promotion = nil
        guard let kind, let m = game.position.legal(Move(from: p.from, to: p.to, promotion: kind)) else {
            selected = nil; refreshHighlights(); return
        }
        commit(m, source: .local)
    }

    enum MoveSource { case local, engine, remote, replay }

    /// Plays a legal move and runs everything that follows it.
    @discardableResult
    func commit(_ requested: Move, source: MoveSource, remoteClockMs: Int? = nil) -> PlayedMove? {
        guard !game.isOver else { return nil }
        let before = game.position
        let mover = game.sideToMove
        var clockMs: Int?
        if var c = clock {
            if let r = remoteClockMs { c.remaining[mover.rawValue] = max(0, r) ; c.running = mover.opposite; clockMs = r }
            else { clockMs = c.switchAfterMove(by: mover) }
            clock = c
        }
        guard let pm = try? game.play(requested, clockMs: clockMs) else { return nil }
        selected = nil
        hintMove = nil
        if drawOfferFrom != nil, drawOfferFrom != mover { recorder.live(LiveEvent(kind: "draw_offer", ply: game.ply - 1, by: drawOfferFrom, accepted: false), actions: game.ply) }
        drawOfferFrom = nil
        recorder.played(pm, game: game)
        if mode == .lan, source == .local { lan.send(.move(ply: game.ply, uci: pm.move.uci, clockMs: clockMs)) }
        autosave()
        let token = gameToken
        let prefs = Prefs.animation
        if pm.captured != nil {
            if is3D && prefs.battlesEnabled && source != .replay {
                battleBanner = BattlePlan.make(attacker: pm.movedKind, victim: pm.captured!).title(attackerSide: pm.side)
            }
            requestBattleTalk(pm)
        }
        if is3D && source != .replay {
            animating = true
            scene.animate(pm, before: before, after: game.position, prefs: prefs) { [weak self] in
                guard let self, self.gameToken == token else { return }
                self.animating = false
                self.battleBanner = nil
                self.afterMove(pm)
            }
        } else {
            SoundPlayer.shared.play(pm.captured != nil ? .capture : .move)
            scene.sync(game.position)
            afterMove(pm)
        }
        return pm
    }

    func skipAnimation() { scene.skipBattle() }

    private func afterMove(_ pm: PlayedMove) {
        refreshHighlights()
        if game.isOver { handleGameOver(lastMove: pm); return }
        if pm.isCheck { SoundPlayer.shared.play(.check) }
        afterPositionChange()
        maybeEngineMove()
    }

    private func afterPositionChange() {
        refreshHighlights()
        if UserDefaults.standard.bool(forKey: Prefs.coachAuto), !game.isOver, isLocal(game.sideToMove) || mode == .hotseat {
            refreshCoach()
        }
    }

    func refreshHighlights() {
        var h = BoardScene.Highlights()
        h.selected = selected
        h.targets = UserDefaults.standard.bool(forKey: Prefs.legalHints) ? legalTargets : []
        h.lastMove = game.lastMove?.move
        if game.position.inCheck { h.check = game.position.kingSquare[game.sideToMove.rawValue] }
        h.hint = hintMove
        if UserDefaults.standard.bool(forKey: Prefs.showThreats), isLocal(game.sideToMove), !game.isOver {
            h.threatened = CoachFacts.make(game: game).yourThreatened.map(\.target)
        }
        scene.setHighlights(h)
        objectWillChange.send()
    }

    // MARK: - Engine

    func maybeEngineMove() {
        guard mode == .vsNova || (mode == .watch && !watchPaused), !game.isOver, !isLocal(game.sideToMove), !engineThinking else { return }
        engineThinking = true
        let token = gameToken, snapshot = game
        // Watch: each side plays at its own level (stored on the player); vs Nova: the chosen level.
        let lvl = mode == .watch ? (player(game.sideToMove).level.flatMap(EngineLevel.init(rawValue:)) ?? level) : level
        let pace = mode == .watch ? min(5, max(0.2, UserDefaults.standard.double(forKey: Prefs.watchDelay))) : 0.45
        Task {
            let started = Date()
            let m = try? await engine.bestMove(for: snapshot, level: lvl)
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < pace { try? await Task.sleep(nanoseconds: UInt64((pace - elapsed) * 1e9)) }
            guard self.gameToken == token, self.game.ply == snapshot.ply else { return }
            self.engineThinking = false
            if let m { self.commit(m, source: .engine) }
            else { self.say("Nova's engine failed to answer; it's your move.", kind: .system, source: "Engine") }
        }
    }

    // MARK: - Watch (Nova vs Nova)

    func setWatchPaused(_ paused: Bool) {
        guard mode == .watch else { return }
        watchPaused = paused
        if paused { return }
        if game.isOver, let c = lastWatchConfig { newGame(c) } else { maybeEngineMove() }
    }

    /// Takes the seat of the side to move; the other side stays Nova. The watch session ends as "taken_over" and a normal one starts.
    func takeOver() {
        guard mode == .watch, !game.isOver, !animating else { return }
        let side = game.sideToMove
        gameToken = UUID()          // drop a pending engine reply for this side
        engineThinking = false
        let opponentLevel = player(side.opposite).level.flatMap(EngineLevel.init(rawValue:)) ?? level
        recorder.endTakenOver(game: game, white: whiteName, black: blackName)
        let me = PlayerInfo.human(Prefs.playerDisplayName, local: true, account: localAccount)
        if side == .white { white = me } else { black = me }
        mode = .vsNova
        you = side.name
        level = opponentLevel
        watchPaused = false
        flipped = side == .black
        beginRecording(sessionID: UUID(), hostSide: nil)   // from here on it's your game
        say("You take over \(side.faction). Nova keeps \(side.opposite.faction).", kind: .system, source: "GTNW Chess")
        afterPositionChange()
    }

    func requestHint() {
        guard !game.isOver, isLocal(game.sideToMove) else { return }
        let pos = game.position, token = gameToken, side = game.sideToMove
        Task {
            guard let (m, e) = try? await engine.hint(for: pos), self.gameToken == token, self.game.position == pos else { return }
            self.hintMove = m
            self.refreshHighlights()
            let text = ScriptedCoach.hint(move: m, san: pos.san(m), eval: e, side: side)
            self.say(text, kind: .hint, source: self.engine.lastSource)
        }
    }

    // MARK: - Coach & commentary

    func refreshCoach() {
        let token = gameToken, snapshot = game, name = playerName
        let facts = CoachFacts.make(game: snapshot)
        coachText = ScriptedCoach.explain(facts, playerName: name)
        coachSource = "Built-in"
        let narrator = NovaNarrator(ai: ai)
        Task {
            let r = await narrator.coach(game: snapshot, playerName: name)
            guard self.gameToken == token, self.game.ply == snapshot.ply else { return }
            self.coachText = r.value
            self.coachSource = r.source.label
        }
    }

    private func requestBattleTalk(_ pm: PlayedMove) {
        let token = gameToken, snapshot = game
        let narrator = NovaNarrator(ai: ai)
        Task {
            let r = await narrator.battleTalk(attacker: pm.movedKind, victim: pm.captured!, attackerSide: pm.side, game: snapshot)
            guard self.gameToken == token else { return }
            self.say(r.value, kind: .battle, source: r.source.label)
        }
    }

    func say(_ text: String, kind: FeedItem.Kind, source: String) {
        feed.append(FeedItem(kind: kind, text: text, source: source))
        if feed.count > 80 { feed.removeFirst(feed.count - 80) }
    }

    // MARK: - Takeback, resign, draw

    var canUndo: Bool { mode != .lan && mode != .watch && !game.moves.isEmpty && !animating && !(game.isOver && game.result?.termination == .resignation) }

    func undo() {
        guard canUndo else { return }
        scene.skipBattle()
        let from = game.ply
        gameToken = UUID()
        engineThinking = false
        if mode == .vsNova {
            game.undo()
            while !game.moves.isEmpty, !isLocal(game.sideToMove) { game.undo() }
            if !isLocal(game.sideToMove) && game.moves.isEmpty { /* engine plays first again */ }
        } else {
            game.undo()
        }
        recorder.live(LiveEvent(kind: "takeback", ply: game.ply), fromPly: from, actions: game.ply)
        analysis = nil
        recap = nil
        selected = nil
        hintMove = nil
        animating = false
        battleBanner = nil
        scene.sync(game.position)
        clock?.running = game.ply == 0 ? nil : game.sideToMove
        autosave()
        say("Takeback: back to move \(game.position.fullmoveNumber).", kind: .system, source: "GTNW Chess")
        afterPositionChange()
        maybeEngineMove()
    }

    var resigningSide: Side? {
        guard !game.isOver else { return nil }
        if mode == .hotseat { return game.sideToMove }
        if mode == .watch { return nil }
        return you == "black" ? .black : .white
    }

    func resign() {
        guard let s = resigningSide else { return }
        scene.skipBattle()
        game.resign(s)
        recorder.live(LiveEvent(kind: "resign", ply: game.ply, by: s), actions: game.ply)
        if mode == .lan { lan.send(.resign(ply: game.ply)) }
        handleGameOver(lastMove: nil)
    }

    func offerDraw() {
        guard !game.isOver, drawOfferFrom == nil, let s = resigningSide else { return }
        switch mode {
        case .vsNova:
            let token = gameToken, fen = game.position.fen, plies = game.ply
            say("You offer a draw…", kind: .system, source: "GTNW Chess")
            Task {
                let e = try? await engine.evaluate(fen: fen, depth: 10)
                guard self.gameToken == token else { return }
                let novaSide: Side = self.you == "white" ? .black : .white
                let novaView = (e?.pawns ?? 0) * (novaSide == .white ? 1 : -1)
                let accept = plies >= 20 && novaView <= 0.3 || self.game.position.isInsufficientMaterial
                self.recorder.live(LiveEvent(kind: "draw_offer", ply: plies, by: s, accepted: accept), actions: plies)
                if accept { self.game.agreeDraw(); self.say("Nova accepts the draw.", kind: .system, source: "Nova"); self.handleGameOver(lastMove: nil) }
                else { self.say(plies < 20 ? "Nova declines: it's too early to split the point." : "Nova declines: she likes her position.", kind: .system, source: "Nova") }
            }
        case .hotseat:
            drawOfferFrom = s
        case .lan:
            drawOfferFrom = s
            lan.send(.drawOffer(ply: game.ply))
            say("Draw offered. Waiting for an answer…", kind: .system, source: "GTNW Chess")
        case .watch:
            return
        }
    }

    /// The opponent of the offering side answers (hot-seat sheet, or the LAN peer).
    func respondToDraw(_ accept: Bool) {
        guard let by = drawOfferFrom else { return }
        drawOfferFrom = nil
        recorder.live(LiveEvent(kind: "draw_offer", ply: game.ply, by: by, accepted: accept), actions: game.ply)
        if mode == .lan { lan.send(.drawReply(accept: accept)) }
        if accept { game.agreeDraw(); handleGameOver(lastMove: nil) } else { say("Draw declined.", kind: .system, source: "GTNW Chess") }
    }

    /// True when this Mac must answer a pending offer.
    var mustAnswerDraw: Bool {
        guard let by = drawOfferFrom else { return false }
        switch mode {
        case .hotseat: return true
        case .lan: return by.name != you
        case .vsNova, .watch: return false
        }
    }

    // MARK: - Clock

    private func startClockTimer() {
        clockTimer?.invalidate()
        guard clock != nil else { return }
        lastTick = Date()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickClock() }
        }
    }

    func tickClock(now: Date = Date()) {
        let dt = Int(now.timeIntervalSince(lastTick) * 1000)
        lastTick = now
        guard var c = clock, !game.isOver, !animating, !waitingForGuest, game.ply > 0 || c.running != nil else { return }
        if c.running == nil { c.running = game.sideToMove }
        if let flagged = c.tick(dt) {
            clock = c
            // Only the flagged side's own Mac (or a shared Mac) calls it, so LAN games agree.
            guard mode != .lan || isLocal(flagged) else { return }
            game.timeout(flagged)
            if mode == .lan { lan.send(.flag(side: flagged)) }
            handleGameOver(lastMove: nil)
        } else {
            clock = c
        }
    }

    // MARK: - Game over

    private func handleGameOver(lastMove: PlayedMove?) {
        clock?.running = nil
        engineThinking = false
        refreshHighlights()
        autosave()
        guard let r = game.result else { return }
        if let w = r.winner {
            SoundPlayer.shared.play(mode == .hotseat || mode == .watch || isLocal(w) ? .victory : .defeat)
        } else {
            SoundPlayer.shared.play(.draw)
        }
        say(statusLine, kind: .system, source: "GTNW Chess")
        coachText = statusLine + ". Nova's recap follows once the analysis is done."
        coachSource = "GTNW Chess"
        let token = gameToken
        if r.termination == .checkmate, let pm = lastMove, is3D {
            animating = true
            scene.checkmateFinale(attackerSquare: pm.move.to, kingSquare: game.position.kingSquare[game.sideToMove.rawValue],
                                  attackerKind: pm.move.promotion ?? pm.movedKind, attackerSide: pm.side, prefs: Prefs.animation) { [weak self] in
                guard let self, self.gameToken == token else { return }
                self.animating = false
                self.finalize(token)
            }
        } else {
            finalize(token)
        }
    }

    private func finalize(_ token: UUID) {
        analyzing = true
        let snapshot = game
        let wn = whiteName, bn = blackName
        Task {
            let a = try? await engine.analyze(snapshot, depth: 12)
            guard self.gameToken == token else { return }
            self.analysis = a
            self.analyzing = false
            self.recorder.finish(game: snapshot, analysis: a, white: wn, black: bn)
            self.autosave()
            let opening = snapshot.startsFromStandard ? Openings.classify(snapshot.sanMoves) : Opening(eco: "-", name: "Custom position")
            let r = await NovaNarrator(ai: self.ai).recap(game: snapshot, white: wn, black: bn, analysis: a, opening: opening)
            guard self.gameToken == token else { return }
            self.recap = r.value
            self.coachText = r.value
            self.coachSource = r.source.label
            self.say(r.value, kind: .recap, source: r.source.label)
            // Watch: the next game starts on its own after a short break, unless paused or the viewer moved on.
            if self.mode == .watch, let c = self.lastWatchConfig {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard self.gameToken == token, self.mode == .watch, !self.watchPaused else { return }
                self.newGame(c)
            }
        }
    }

    // MARK: - PGN / FEN

    func exportPGN() -> String {
        PGN.export(game, white: whiteName, black: blackName, date: startedAt)
    }

    func importPGN(_ text: String) throws {
        let imp = try PGN.importGame(text)
        stopLAN()
        mode = .hotseat
        you = "both"
        white = .human(imp.headers["White"].map(PlayerInfo.clean) ?? "White", local: true, account: nil)
        black = .human(imp.headers["Black"].map(PlayerInfo.clean) ?? "Black", local: true, account: nil)
        install(imp.game, clock: nil)
        recorder.begin(PlayContext(sessionID: UUID(), mode: .lan, white: white, black: black, you: "none", clock: nil,
                                   startedAt: Date(), startFEN: nil))   // imported games are study only: never recorded
        flipped = false
        say("Imported \(imp.game.moves.count) plies (\(whiteName) vs \(blackName)). Study mode: either side can move.",
            kind: .system, source: "GTNW Chess")
        afterPositionChange()
    }

    func loadFEN(_ fen: String) throws {
        let g = try Game(fen: fen)
        var c = NewGameConfig()
        c.mode = .hotseat
        c.playerName = Prefs.playerDisplayName
        c.startFEN = g.startPosition.fen
        newGame(c)
    }

    // MARK: - LAN

    /// Hosts a LAN game. `code`: a fixed pairing code (launch flag for automated runs); otherwise a fresh random one.
    func hostLAN(name: String, side: String, clock: ClockConfig?, code fixed: String? = nil) throws -> String {
        var c = NewGameConfig()
        c.mode = .lan
        c.side = side
        c.playerName = name
        c.clock = clock
        newGame(c)
        let code = fixed ?? LANSecurity.newPairingCode()
        guard LANSecurity.isValidCode(code) else { throw LANError.badCode }
        let hostSide: Side = you == "black" ? .black : .white
        lanInfo = SavedGame.LANInfo(role: "host", gameID: UUID(), code: code, hostSide: hostSide, hostAddress: nil)
        try lan.host(code: code, serviceName: "\(PlayerInfo.clean(name))'s GTNW Chess",
                     port: UInt16(RuntimeEnv.argument(after: "--lan-port") ?? "") ?? 0)
        waitingForGuest = true
        say("Hosting a LAN game. Pairing code: \(code)", kind: .system, source: "LAN")
        return code
    }

    func joinLAN(_ found: LANSession.Found?, address: String?, code: String, name: String) throws {
        stopLAN()
        mode = .lan
        waitingForGuest = false
        lanInfo = SavedGame.LANInfo(role: "guest", gameID: UUID(), code: code, hostSide: .white, hostAddress: address)
        pendingGuestName = PlayerInfo.clean(name)
        if let f = found { try lan.join(f.endpoint, code: code) }
        else if let a = address, let (h, p) = Self.parseAddress(a) { try lan.join(host: h, port: p, code: code) }
        else { throw LANError.rejected("no host selected") }
        say("Joining…", kind: .system, source: "LAN")
    }

    private var pendingGuestName = ""
    private var guestJoinedGame: UUID?

    static func parseAddress(_ s: String) -> (String, UInt16)? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let p = UInt16(parts[1]), p > 0, !parts[0].isEmpty, parts[0].count < 100 else { return nil }
        return (String(parts[0]), p)
    }

    private func resumeLAN(_ info: SavedGame.LANInfo) {
        if info.role == "host" {
            try? lan.host(code: info.code, serviceName: "\(Prefs.playerDisplayName)'s GTNW Chess",
                          port: UInt16(RuntimeEnv.argument(after: "--lan-port") ?? "") ?? 0)
            say("Waiting for the other Mac to rejoin (code \(info.code)).", kind: .system, source: "LAN")
        } else if let a = info.hostAddress, let (h, p) = Self.parseAddress(a) {
            pendingGuestName = you == "black" ? black.name : white.name
            try? lan.join(host: h, port: p, code: info.code)
        } else {
            lanNote = "Rejoin from the LAN menu (Game › Join LAN Game) with the same code."
        }
    }


    func stopLAN() {
        lan.stop()
        waitingForGuest = false
        lanNote = nil
        guestJoinedGame = nil
    }

    var remoteSide: Side? { mode == .lan ? (you == "white" ? .black : .white) : nil }

    private func lanConnected() {
        lanNote = nil
        if lan.role == .guest, let info = lanInfo {
            let known = guestJoinedGame ?? (game.ply > 0 ? info.gameID : nil)
            lan.send(.hello(proto: LANCodec.protocolVersion, name: pendingGuestName, account: localAccount, gameID: known, haveplies: game.ply))
        }
    }

    func lanState() -> LANState? {
        guard let info = lanInfo, info.role == "host" else { return nil }
        let guest = remoteSide.map(player)?.name ?? "Challenger"
        return LANState(gameID: info.gameID, hostName: player(info.hostSide).name, hostAccount: localAccount, guestName: guest,
                        hostSide: info.hostSide, startFEN: game.startPosition.fen, moves: game.uciMoves, clock: clock?.config,
                        clockMs: clock?.remaining, result: game.result)
    }

    func handleLAN(_ m: LANMessage) {
        switch m {
        case .hello(let proto, let name, let account, let gameID, _):
            guard lan.role == .host, let info = lanInfo else { return }
            guard proto == LANCodec.protocolVersion else { lan.send(.reject(reason: "protocol", ply: 0)); return }
            if gameID != nil && gameID != info.gameID { lan.send(.reject(reason: "different game", ply: game.ply)); return }
            if waitingForGuest {
                let guest = PlayerInfo.human(name, local: false, account: account.flatMap { PlayCredentials.isValidUsername($0) || $0 == "default" ? $0 : nil })
                if info.hostSide == .white { black = guest } else { white = guest }
                waitingForGuest = false
                startedAt = Date()
                beginRecording(sessionID: info.gameID, hostSide: info.hostSide.name)
                say("\(guest.name) joined. \(whiteName) (Solar) vs \(blackName) (Void).", kind: .system, source: "LAN")
                afterPositionChange()
            }
            if let s = lanState() { lan.send(.welcome(s)) }
        case .welcome(let s):
            guard lan.role == .guest, var info = lanInfo else { return }
            guard let g = LANReferee.replay(s) else { lan.send(.reject(reason: "invalid state", ply: 0)); return }
            let mySide = s.hostSide.opposite
            let me = PlayerInfo.human(pendingGuestName.isEmpty ? Prefs.playerDisplayName : pendingGuestName, local: true, account: localAccount)
            let host = PlayerInfo.human(s.hostName, local: false, account: s.hostAccount)
            info.gameID = s.gameID
            info.hostSide = s.hostSide
            lanInfo = info
            let fresh = guestJoinedGame != s.gameID
            guestJoinedGame = s.gameID
            you = mySide.name
            white = mySide == .white ? me : host
            black = mySide == .black ? me : host
            var c = s.clock.map(ChessClock.init(config:))
            if let ms = s.clockMs, ms.count == 2 { c?.remaining = ms }
            if g.ply > 0 { c?.running = g.sideToMove }
            if fresh || g.uciMoves != game.uciMoves {
                install(g, clock: c)
                if fresh {
                    // The guest never writes play history: the host's session is the one record of this game.
                    recorder.begin(PlayContext(sessionID: s.gameID, mode: .lan, white: white, black: black, you: you,
                                               clock: s.clock, startedAt: Date(), startFEN: nil), hostSide: s.hostSide.name)
                }
            }
            flipped = mySide == .black
            autosave()
            say(fresh ? "Joined \(host.name)'s game. You play \(mySide.faction)." : "Back in sync with \(host.name).", kind: .system, source: "LAN")
            if g.isOver { handleGameOver(lastMove: nil) } else { afterPositionChange() }
        case .move(let ply, let uci, let clockMs):
            guard let rs = remoteSide else { return }
            switch LANReferee.check(ply: ply, uci: uci, game: game, remoteSide: rs) {
            case .accept(let mv):
                guard !animating else { scene.skipBattle(); _ = commit(mv, source: .remote, remoteClockMs: clockMs); return }
                commit(mv, source: .remote, remoteClockMs: clockMs)
            case .reject(let why):
                lan.send(.reject(reason: why, ply: game.ply))
                if lan.role == .host, let s = lanState() { lan.send(.welcome(s)) }
                say("Rejected a move from the other Mac (\(why)); resyncing.", kind: .system, source: "LAN")
            }
        case .reject(let reason, _):
            say("The other Mac rejected that (\(reason)); resyncing.", kind: .system, source: "LAN")
            if lan.role == .guest {
                lan.send(.hello(proto: LANCodec.protocolVersion, name: pendingGuestName, account: localAccount,
                                gameID: lanInfo?.gameID, haveplies: game.ply))
            } else if let s = lanState() {
                lan.send(.welcome(s))
            }
        case .drawOffer:
            guard let rs = remoteSide, !game.isOver else { return }
            drawOfferFrom = rs
            say("\(displayName(rs)) offers a draw.", kind: .system, source: "LAN")
        case .drawReply(let accept):
            guard let by = drawOfferFrom, by.name == you else { return }
            drawOfferFrom = nil
            recorder.live(LiveEvent(kind: "draw_offer", ply: game.ply, by: by, accepted: accept), actions: game.ply)
            if accept { game.agreeDraw(); handleGameOver(lastMove: nil) } else { say("Draw declined.", kind: .system, source: "LAN") }
        case .resign:
            guard let rs = remoteSide, !game.isOver else { return }
            game.resign(rs)
            recorder.live(LiveEvent(kind: "resign", ply: game.ply, by: rs), actions: game.ply)
            handleGameOver(lastMove: nil)
        case .flag(let side):
            guard let rs = remoteSide, side == rs, !game.isOver else { return }
            game.timeout(side)
            handleGameOver(lastMove: nil)
        case .bye:
            lanNote = "The other player left."
        case .ping, .pong:
            break
        }
    }
}

//
//  GameStore.swift
//  GTNW Chess
//
//  Save / resume: the game in progress is autosaved after every move to the app's container
//  (Application Support/GTNW Chess/current-game.json) and restored at launch. No state outside the container.
//

import Foundation

struct ChessClock: Codable, Equatable, Sendable {
    var config: ClockConfig
    /// Remaining ms [white, black].
    var remaining: [Int]
    var running: Side?

    init(config: ClockConfig) {
        self.config = config
        remaining = [config.initialSeconds * 1000, config.initialSeconds * 1000]
    }

    mutating func tick(_ ms: Int) -> Side? {
        guard let s = running else { return nil }
        remaining[s.rawValue] = max(0, remaining[s.rawValue] - ms)
        return remaining[s.rawValue] == 0 ? s : nil
    }

    /// The mover finished: add the increment, start the other clock. Returns the mover's remaining ms.
    @discardableResult
    mutating func switchAfterMove(by mover: Side) -> Int {
        remaining[mover.rawValue] += config.incrementSeconds * 1000
        running = mover.opposite
        return remaining[mover.rawValue]
    }

    static func format(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        if s < 20 && ms > 0 { return String(format: "%d:%02d.%d", s / 60, s % 60, (ms % 1000) / 100) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct SavedGame: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct LANInfo: Codable, Equatable, Sendable {
        var role: String          // host | guest
        var gameID: UUID
        var code: String
        var hostSide: Side
        var hostAddress: String?  // guest: host:port for reconnect
    }

    var version = SavedGame.currentVersion
    var mode: GameMode
    var startFEN: String
    var moves: [String]
    var white: PlayerInfo
    var black: PlayerInfo
    var level: EngineLevel?
    var you: String
    var clock: ChessClock?
    var recorder: PlayRecorder.State?
    var lan: LANInfo?
    var result: GameResult?
    var savedAt: Date

    func restore() throws -> Game {
        var g = try Game(fen: startFEN)
        for u in moves { try g.play(uci: u) }
        if g.result == nil, let r = result { g.result = r }
        return g
    }
}

enum GameStore {
    static var url: URL { AppContainer.directory.appendingPathComponent("current-game.json") }

    static func save(_ s: SavedGame, to url: URL = GameStore.url) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: url, options: [.atomic])
    }

    static func load(from url: URL = GameStore.url) -> SavedGame? {
        guard let d = try? Data(contentsOf: url), d.count < 2_000_000,
              let s = try? JSONDecoder().decode(SavedGame.self, from: d), s.version == SavedGame.currentVersion,
              (try? s.restore()) != nil else { return nil }
        return s
    }

    static func clear(_ url: URL = GameStore.url) { try? FileManager.default.removeItem(at: url) }
}

//
//  GameStore.swift
//  GTNW Chess
//
//  Save / resume: the game in progress is autosaved after every move to the app's container
//  (Application Support/GTNW Chess/current-game.json) and restored at launch. No state outside the container.
//  Older save versions are migrated forward. A save from a newer build, or one that cannot be read, is moved aside
//  to `current-game.unreadable-<date>.json` (never deleted) and the player is told.
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
    /// 1: GTNW Chess 1.0–1.1. 2: adds `writtenBy`. Bump when the JSON changes and add a step to `GameStore.migrations`.
    static let currentVersion = 2
    static var appVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

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
    /// The app version that wrote this save (v2+), named when a newer build's save is refused.
    var writtenBy: String? = SavedGame.appVersion

    func restore() throws -> Game {
        var g = try Game(fen: startFEN)
        for u in moves { try g.play(uci: u) }
        if g.result == nil, let r = result { g.result = r }
        return g
    }
}

/// Why a save could not be resumed. The file itself is kept (moved aside).
enum SaveLoadError: LocalizedError, Equatable {
    case newer(version: Int, writtenBy: String?)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case let .newer(v, by):
            return "Your saved game was made by a newer GTNW Chess (\(by.map { "version \($0), " } ?? "")save format \(v)). "
                + "This version reads up to format \(SavedGame.currentVersion)."
        case let .unreadable(why): return "Your saved game could not be read (\(why))."
        }
    }
}

/// A save that could not be resumed, and where it was kept.
struct SaveSetAside: LocalizedError {
    var reason: SaveLoadError
    var keptAt: URL?

    var errorDescription: String? {
        let kept = keptAt.map { " It was kept as \($0.lastPathComponent) in \($0.deletingLastPathComponent().path)." }
            ?? " It could not be moved aside, so it was left in place."
        return (reason.errorDescription ?? "") + kept + " A new game was started."
    }
}

enum GameStore {
    static var url: URL { AppContainer.directory.appendingPathComponent("current-game.json") }
    static let maxBytes = 2_000_000

    /// One step per older version: the save's JSON object at version N → version N + 1.
    static let migrations: [Int: ([String: Any]) -> [String: Any]] = [
        // 1 → 2: `writtenBy` is new and optional. 1.0 and 1.1 field additions already decode with defaults.
        1: { var o = $0; o["version"] = 2; return o },
    ]

    static func save(_ s: SavedGame, to url: URL = GameStore.url) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: url, options: [.atomic])
    }

    /// Size cap → version (refuse newer, migrate older) → JSON → the moves replay legally.
    static func decode(_ data: Data) throws -> SavedGame {
        guard data.count < maxBytes else { throw SaveLoadError.unreadable("\(data.count) bytes is too large") }
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], var v = obj["version"] as? Int, v >= 1 else {
            throw SaveLoadError.unreadable("not a GTNW Chess save")
        }
        guard v <= SavedGame.currentVersion else { throw SaveLoadError.newer(version: v, writtenBy: obj["writtenBy"] as? String) }
        var json = data
        if v < SavedGame.currentVersion {
            while v < SavedGame.currentVersion {
                guard let step = migrations[v] else { throw SaveLoadError.unreadable("no migration from format \(v)") }
                obj = step(obj)
                v += 1
            }
            json = try JSONSerialization.data(withJSONObject: obj)
        }
        let s: SavedGame
        do { s = try JSONDecoder().decode(SavedGame.self, from: json) } catch { throw SaveLoadError.unreadable("damaged save data") }
        do { _ = try s.restore() } catch { throw SaveLoadError.unreadable("the moves are not a legal game") }
        return s
    }

    /// nil when there is no save. A save that cannot be used is moved aside, never deleted, and `SaveSetAside` says where.
    static func load(from url: URL = GameStore.url, now: Date = Date()) throws -> SavedGame? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        do { return try decode(d) } catch let reason as SaveLoadError {
            throw SaveSetAside(reason: reason, keptAt: moveAside(url, now: now))
        }
    }

    /// `<name>.unreadable-<yyyyMMdd-HHmmss>.json` next to the original.
    static func asideURL(for url: URL, now: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base).unreadable-\(f.string(from: now)).json")
    }

    static func moveAside(_ url: URL, now: Date) -> URL? {
        let fm = FileManager.default
        let first = asideURL(for: url, now: now)
        var dest = first, n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = first.deletingPathExtension().appendingPathExtension("\(n)").appendingPathExtension("json"); n += 1
        }
        do { try fm.moveItem(at: url, to: dest); return dest } catch { return nil }
    }

    static func clear(_ url: URL = GameStore.url) { try? FileManager.default.removeItem(at: url) }
}

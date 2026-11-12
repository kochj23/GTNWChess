//
//  UCIEngine.swift
//  GTNW Chess
//
//  A UCI client for the bundled Stockfish (a separate GPLv3 program; we only exchange UCI text over pipes).
//  Every value sent to the engine is validated first (FEN through the rules engine, moves against a strict UCI
//  pattern), so nothing from a PGN or the network can inject engine commands. Reads have timeouts; a dead engine
//  surfaces as an error and the caller falls back to the built-in engine.
//

import Foundation

/// An engine evaluation, from WHITE's point of view.
struct Evaluation: Equatable, Sendable {
    /// Centipawns (white POV) when not a mate score.
    var cp: Int?
    /// Mate in N (positive: white mates), when found.
    var mate: Int?
    var bestMove: String?
    var depth: Int = 0

    /// Pawns, clamped to ±20 (mate = ±20).
    var pawns: Double {
        if let m = mate { return m > 0 ? 20 : -20 }
        return max(-20, min(20, Double(cp ?? 0) / 100))
    }

    /// Centipawns clamped to ±2000 (mate = ±2000).
    var clampedCP: Int {
        if let m = mate { return m > 0 ? 2000 : -2000 }
        return max(-2000, min(2000, cp ?? 0))
    }
}

/// Difficulty levels, beginner to strong. Names fit the Solar/Void fleet theme.
enum EngineLevel: Int, CaseIterable, Codable, Sendable, Identifiable {
    case cadet = 1, scout, pilot, captain, commander, admiral, nova, supernova

    var id: Int { rawValue }
    var name: String {
        ["Cadet", "Scout", "Pilot", "Captain", "Commander", "Admiral", "Nova", "Supernova"][rawValue - 1]
    }
    var blurb: String {
        ["First flight: hangs pieces", "Learning the ropes", "Club beginner", "Casual player", "Solid club player",
         "Strong club player", "Expert", "Full strength"][rawValue - 1]
    }
    /// Stockfish "Skill Level" 0...20.
    var skill: Int { [0, 2, 5, 8, 11, 15, 20, 20][rawValue - 1] }
    /// Search limit: depth for the weak levels, time for the strong ones.
    var goCommand: String {
        switch self {
        case .cadet: return "go depth 1"
        case .scout: return "go depth 2"
        case .pilot: return "go depth 4"
        case .captain: return "go depth 6"
        case .commander: return "go depth 9"
        case .admiral: return "go movetime 300"
        case .nova: return "go movetime 800"
        case .supernova: return "go movetime 2000"
        }
    }
    /// Depth the built-in fallback engine searches at this level.
    var fallbackDepth: Int { [1, 1, 2, 2, 3, 3, 3, 4][rawValue - 1] }
}

enum EngineError: Error, Equatable, LocalizedError {
    case notFound
    case launchFailed(String)
    case timeout(String)
    case died
    case badInput(String)
    case noMove

    var errorDescription: String? {
        switch self {
        case .notFound: return "Stockfish isn't bundled with this build"
        case .launchFailed(let s): return "Stockfish didn't start: \(s)"
        case .timeout(let s): return "Stockfish timed out waiting for \(s)"
        case .died: return "Stockfish stopped unexpectedly"
        case .badInput(let s): return "Refused to send unsafe engine input: \(s)"
        case .noMove: return "Stockfish returned no move"
        }
    }
}

/// Anything that can choose a move and evaluate a position (Stockfish or the built-in fallback; tests use stubs).
protocol ChessEngine: AnyObject, Sendable {
    var name: String { get async }
    func bestMove(fen: String, moves: [String], level: EngineLevel) async throws -> String
    func evaluate(fen: String, depth: Int) async throws -> Evaluation
    func shutdown() async
}

actor UCIEngine: ChessEngine {
    nonisolated static let uciMovePattern = try! NSRegularExpression(pattern: "^[a-h][1-8][a-h][1-8][qrbn]?$")

    /// The bundled binary (Contents/MacOS/stockfish), else a developer install (tests, debug runs).
    nonisolated static func locate(bundle: Bundle = .main) -> URL? {
        var candidates: [URL] = []
        if let u = bundle.url(forAuxiliaryExecutable: "stockfish") { candidates.append(u) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/stockfish"))
        candidates += ["/opt/homebrew/bin/stockfish", "/usr/local/bin/stockfish"].map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    let url: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var lines: LineQueue?
    private(set) var engineName = "Stockfish"
    private var currentSkill: Int?
    let timeout: TimeInterval

    var name: String { engineName }

    init(url: URL, timeout: TimeInterval = 15) {
        self.url = url
        self.timeout = timeout
    }

    static func validate(fen: String) throws -> String {
        guard !fen.contains(where: { $0.isNewline || $0 == "\0" }), let p = try? Position(fen: fen) else {
            throw EngineError.badInput("FEN")
        }
        return p.fen
    }

    static func validate(moves: [String]) throws -> [String] {
        guard moves.count <= 2000 else { throw EngineError.badInput("too many moves") }
        for m in moves {
            let r = NSRange(m.startIndex..., in: m)
            guard uciMovePattern.firstMatch(in: m, range: r) != nil else { throw EngineError.badInput("move") }
        }
        return moves
    }

    func start() async throws {
        if process?.isRunning == true { return }
        let p = Process()
        p.executableURL = url
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        let queue = LineQueue()
        let buffer = LineBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; queue.finish(); return }
            for line in buffer.append(d) { queue.push(line) }
        }
        p.terminationHandler = { _ in queue.finish() }
        do { try p.run() } catch { throw EngineError.launchFailed(error.localizedDescription) }
        process = p
        stdin = inPipe.fileHandleForWriting
        lines = queue
        try send("uci")
        for line in try await readUntil(prefix: "uciok", what: "uciok") where line.hasPrefix("id name ") {
            engineName = String(line.dropFirst(8))
        }
        try send("setoption name Threads value 1")
        try send("setoption name Hash value 32")
        try await ready()
    }

    func ready() async throws {
        try send("isready")
        _ = try await readUntil(prefix: "readyok", what: "readyok")
    }

    private func send(_ cmd: String) throws {
        guard let stdin, process?.isRunning == true else { throw EngineError.died }
        guard !cmd.contains(where: { $0.isNewline }) else { throw EngineError.badInput("newline") }
        do { try stdin.write(contentsOf: Data((cmd + "\n").utf8)) } catch { throw EngineError.died }
    }

    /// Collects lines until one starts with `prefix` (inclusive), or times out.
    private func readUntil(prefix: String, what: String) async throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var collected: [String] = []
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw EngineError.timeout(what) }
            let line = try await nextLine(timeout: remaining, what: what)
            collected.append(line)
            if line.hasPrefix(prefix) { return collected }
        }
    }

    private func nextLine(timeout: TimeInterval, what: String) async throws -> String {
        guard let lines else { throw EngineError.died }
        guard let line = try await lines.next(timeout: timeout) else {
            if lines.isFinished { throw EngineError.died }
            throw EngineError.timeout(what)
        }
        return line
    }

    private func setSkill(_ s: Int) async throws {
        guard currentSkill != s else { return }
        try send("setoption name Skill Level value \(s)")
        currentSkill = s
        try await ready()
    }

    func bestMove(fen: String, moves: [String], level: EngineLevel) async throws -> String {
        try await start()
        let f = try Self.validate(fen: fen), ms = try Self.validate(moves: moves)
        try await setSkill(level.skill)
        try send("position fen \(f)" + (ms.isEmpty ? "" : " moves " + ms.joined(separator: " ")))
        try send(level.goCommand)
        let out = try await readUntil(prefix: "bestmove", what: "bestmove")
        guard let last = out.last, let mv = last.split(separator: " ").dropFirst().first.map(String.init),
              mv != "(none)", (try? Self.validate(moves: [mv])) != nil else { throw EngineError.noMove }
        return mv
    }

    func evaluate(fen: String, depth: Int) async throws -> Evaluation {
        try await start()
        let f = try Self.validate(fen: fen)
        try await setSkill(20)
        try send("position fen \(f)")
        try send("go depth \(max(1, min(30, depth)))")
        let out = try await readUntil(prefix: "bestmove", what: "evaluation")
        var e = Self.parseInfo(out)
        if let last = out.last { e.bestMove = last.split(separator: " ").dropFirst().first.map(String.init).flatMap { $0 == "(none)" ? nil : $0 } }
        // UCI scores are from the side to move; convert to white's view.
        if f.split(separator: " ")[1] == "b" {
            e.cp = e.cp.map { -$0 }
            e.mate = e.mate.map { -$0 }
        }
        if e.cp == nil, e.mate == nil, let p = try? Position(fen: f), p.legalMoves().isEmpty {
            // Mate or stalemate on the board: Stockfish reports "mate 0" / "cp 0".
            if p.inCheck { e.mate = p.sideToMove == .white ? -1 : 1 } else { e.cp = 0 }
        }
        return e
    }

    /// Parses the deepest "info ... score" line (cp or mate) from UCI output, side-to-move POV.
    static func parseInfo(_ lines: [String]) -> Evaluation {
        var e = Evaluation()
        for line in lines where line.hasPrefix("info ") && line.contains(" score ") && !line.contains(" lowerbound") && !line.contains(" upperbound") {
            let t = line.split(separator: " ").map(String.init)
            guard let si = t.firstIndex(of: "score"), si + 2 < t.count, let v = Int(t[si + 2]) else { continue }
            if let di = t.firstIndex(of: "depth"), di + 1 < t.count, let d = Int(t[di + 1]) { e.depth = d }
            if t[si + 1] == "cp" { e.cp = v; e.mate = nil } else if t[si + 1] == "mate" {
                if v == 0 { e.mate = nil; e.cp = nil } else { e.mate = v; e.cp = nil }
            }
        }
        return e
    }

    func shutdown() async {
        if process?.isRunning == true { try? send("quit") }
        try? stdin?.close()
        if let p = process, p.isRunning {
            let deadline = Date().addingTimeInterval(1)
            while p.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            if p.isRunning { p.terminate() }
        }
        lines?.finish()
        process = nil
        stdin = nil
        lines = nil
        currentSkill = nil
    }

    var isRunning: Bool { process?.isRunning == true }
}

/// Splits pipe output into lines (thread-safe; the readability handler runs on a background queue).
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(d)
        var out: [String] = []
        while let i = pending.firstIndex(of: 10) {
            let lineData = pending[pending.startIndex..<i]
            out.append(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            pending.removeSubrange(pending.startIndex...i)
        }
        if pending.count > 1_000_000 { pending.removeAll() }
        return out
    }
}

/// Lines from the engine, waited on with a timeout (nil = timed out or finished).
final class LineQueue: @unchecked Sendable {
    private var items: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var waiterID = 0
    private(set) var isFinished = false
    private let lock = NSLock()

    func push(_ line: String) {
        lock.lock()
        if let w = waiter { waiter = nil; lock.unlock(); w.resume(returning: line); return }
        if items.count < 10_000 { items.append(line) }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        isFinished = true
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume(returning: nil)
    }

    func next(timeout: TimeInterval) async throws -> String? {
        try Task.checkCancellation()
        return await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
            lock.lock()
            if !items.isEmpty { let l = items.removeFirst(); lock.unlock(); k.resume(returning: l); return }
            if isFinished { lock.unlock(); k.resume(returning: nil); return }
            waiterID += 1
            let id = waiterID
            waiter = k
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if self.waiterID == id, let w = self.waiter { self.waiter = nil; self.lock.unlock(); w.resume(returning: nil); return }
                self.lock.unlock()
            }
        }
    }
}

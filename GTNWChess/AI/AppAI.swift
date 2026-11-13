//
//  AppAI.swift
//  GTNW Chess
//
//  GTNW Chess's one AI object, built on NovaAIKit (https://github.com/kochj23/NovaAIKit, 1.0.0+).
//
//  - Toggle, backends (auto, ollama, mlx, tinyllm, tinychat, openwebui, novagateway, openrouter, openai), model and
//    URL pickers, Auto failover, retries, timeouts, https-only keys and the status indicator come from the kit.
//  - Keys live only in the Keychain: com.jkoch.gtnwchess.<backend> (account apiKey). No key ships in the app.
//  - The LLM only narrates (coach, battle trash talk, recap). Stockfish decides every move. Every move or square a
//    reply mentions is checked against the real position (`ChessMentionValidator`); a reply that fails twice is
//    replaced by the scripted text (`ScriptedCoach`, `BattleLines`).
//  - Defaults: Auto tries Ollama on the LAN fleet host (nova-core8, reachable from any Mac on the network), then the
//    core3 Ollama, then local servers, then Nova Gateway (loopback; Nova's "chat" agent on Little Mister's Mac), then
//    OpenRouter/OpenAI only if the player stored a key. Away from the LAN everything falls back to the script.
//

import Foundation
import NovaAIKit

@MainActor
enum AppAI {
    nonisolated static let appID = "gtnwchess"
    nonisolated static let appName = "GTNW Chess"
    /// LAN fleet Ollama (bound beyond loopback; checked from office-2 on 2026-11-11).
    nonisolated static let fleetOllama = "http://nova-core8.digitalnoise.net:11434"
    nonisolated static let fleetOllamaBackup = "http://nova-core3.digitalnoise.net:11434"
    nonisolated static let fleetModel = "qwen3:8b"

    nonisolated static var configuration: NovaAIConfiguration {
        var d = NovaAISettings()
        d.timeout = 25
        d.setURL(fleetOllama, for: .ollama)
        d.setModel(fleetModel, for: .ollama)
        d.extraOllamaEndpoints = [NovaAIEndpoint(url: fleetOllamaBackup, model: fleetModel)]
        d.setModel("chat", for: .novaGateway)
        return NovaAIConfiguration(appID: appID, appName: appName, appURL: "https://github.com/kochj23/GTNWChess",
                                   defaultSettings: d, retry: NovaAIRetryPolicy(maxAttempts: 2))
    }

    /// The shared instance. Under XCTest it is hermetic: settings and keys in memory, every request refused.
    static var shared: NovaAI = makeShared()

    static func makeShared() -> NovaAI {
        if RuntimeEnv.underXCTest || RuntimeEnv.noAI {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [OfflineURLProtocol.self]
            var s = configuration.defaultSettings
            if RuntimeEnv.noAI { s.enabled = false }
            return NovaAI(configuration: configuration, storage: NovaAIMemoryStorage(s), keyStore: NovaAIMemoryKeyStore(),
                          session: URLSession(configuration: cfg))
        }
        return NovaAI(configuration: configuration)
    }
}

/// Refuses every request (tests, `--no-ai`), so nothing can reach a server.
final class OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() {}
}

enum RuntimeEnv {
    static let underXCTest = NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static var noAI: Bool { CommandLine.arguments.contains("--no-ai") }
    /// Screenshots/QA: no play history, no saved game (nothing leaves the app or outlives the run).
    static var demo: Bool { CommandLine.arguments.contains("--demo") }
    static func argument(after flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), a.indices.contains(i + 1) else { return nil }
        return a[i + 1]
    }
}

/// Nova's persona, per the NovaAIKit apps' convention: one system preamble shared by every prompt, the feature's
/// rules appended. She's Little Mister's AI advisor: warm, direct, curious, opinionated (she/her).
enum NovaPersona {
    static let preamble = """
        You are Nova, an AI advisor with a warm, direct, curious and opinionated voice (she/her). In GTNW Chess you \
        coach and commentate a game between the Solar faction (white) and the Void faction (black). Their pieces are \
        robots: Drones (pawns), Vaulters (knights), Oracles (bishops), Bastions (rooks), Corona or Eclipse (queens) and \
        Regents (kings).
        Hard rules: use only the facts given. Never invent a move, square or piece. Write moves in SAN (e.g. Nf3, exd5, \
        O-O) and squares as a1-h8 exactly as they appear in the facts. No lists, no markdown, no emoji.
        """

    static func system(_ rules: String) -> String { preamble + "\n" + rules }
}

// MARK: - Model vs model (Watch)

/// The ONE check that turns a driver's move text into a legal move. Clicks, Stockfish and LAN peers produce `Move`
/// values that `Game.play` checks; any text (a language model's reply) comes through here first, then the same path.
/// A failed model is replaced by swapping the move's source to the engine, nothing else changes (after Quake III
/// BotInputToUserCommand: every driver produces the same command type).
enum MoveValidator {
    struct Rejection: Error, Equatable { var reason: String }

    /// The first token of `reply` that is a legal move here (SAN, or UCI like e2e4). Move numbers and punctuation are ignored.
    static func move(in reply: String, position: Position) throws -> Move {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Rejection(reason: "the reply was empty") }
        for raw in text.split(whereSeparator: { $0.isWhitespace || ",;:\"'`*()[]{}<>/".contains($0) }).prefix(80) {
            var t = String(raw)
            if let r = t.range(of: #"^\d+\.+"#, options: .regularExpression) { t.removeSubrange(r) }
            while let l = t.last, ".!?".contains(l) { t.removeLast() }
            // Every move has a digit (a square) except castling; skipping plain words keeps rambling replies cheap.
            guard t.count >= 2, t.contains(where: \.isNumber) || t.hasPrefix("O-O") else { continue }
            if let m = position.move(san: t) ?? position.move(uci: t) { return m }
        }
        throw Rejection(reason: "\"\(PlayReport.excerpt(text))\" is not one of the legal moves")
    }
}

extension PlayerInfo {
    /// A language-model side: `backend` .auto = the AI settings; `fallback` is the engine level that plays when it fails.
    static func model(_ backend: NovaAIBackend, _ model: String, fallback: EngineLevel) -> PlayerInfo {
        let label = model.isEmpty ? (backend == .auto ? "AI (settings)" : backend.displayName) : model
        return PlayerInfo(name: clean(label), kind: "model", level: fallback.rawValue, levelName: fallback.name, local: true,
                          account: nil, backend: backend.rawValue, model: model.isEmpty ? nil : model)
    }
}

/// Asks a side's language model for one move: FEN, legal moves (SAN) and recent moves in; one move out. An invalid
/// answer is re-asked with the error (up to `maxAsks` in all); after that the caller's engine plays the move.
@MainActor
struct ModelPlayer {
    static let maxAsks = 3
    let ai: NovaAI

    static let system = """
        You are playing a game of chess. Reply with exactly one move for your side, chosen from the legal moves list, \
        in SAN exactly as listed (for example Nf3, exd5, O-O, e8=Q). No explanation, no move number, nothing else.
        """

    static func prompt(_ g: Game, rejected: String? = nil) -> String {
        let pos = g.position
        let legal = pos.legalMoves()
        let recent = g.moves.suffix(12).map(\.san).joined(separator: " ")
        var s = """
            You play \(pos.sideToMove.name) (\(pos.sideToMove.faction)).
            Position (FEN): \(pos.fen)
            Recent moves: \(recent.isEmpty ? "none, this is the first move" : recent)
            Legal moves: \(legal.map { pos.san($0, legal: legal) }.joined(separator: ", "))
            Your move:
            """
        if let rejected { s += "\nYour previous answer was rejected: \(rejected). Answer with one move from the legal moves list." }
        return s
    }

    /// The model's legal move (nil: every ask failed; the last reply is marked `fallback`) and every reply, in order.
    func move(_ g: Game, player p: PlayerInfo) async -> (Move?, [ModelReply]) {
        let backend = NovaAIBackend(rawValue: p.backend ?? "") ?? .auto
        let side = g.sideToMove
        var replies: [ModelReply] = []
        var rejected: String?
        for attempt in 1...Self.maxAsks {
            let req = NovaAIRequest(prompt: Self.prompt(g, rejected: rejected), system: Self.system, temperature: 0.2, maxTokens: 64,
                                    backend: backend == .auto ? nil : backend, model: p.model)
            let t0 = Date()
            var r = ModelReply(side: side, backend: backend.rawValue, model: p.model, reply: "", latencyMs: 0, attempt: attempt)
            do {
                let resp = try await ai.complete(req)
                r.reply = resp.text
                r.backend = resp.backend.rawValue
                r.model = resp.model
                let m = try MoveValidator.move(in: resp.text, position: g.position)
                r.san = g.position.san(m)
                r.latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
                replies.append(r)
                return (m, replies)
            } catch let e as MoveValidator.Rejection {
                r.error = e.reason
            } catch {
                r.error = (error as? LocalizedError)?.errorDescription ?? "the backend failed"
            }
            r.latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
            rejected = r.error
            replies.append(r)
        }
        replies[replies.count - 1].fallback = true
        return (nil, replies)
    }
}

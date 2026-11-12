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

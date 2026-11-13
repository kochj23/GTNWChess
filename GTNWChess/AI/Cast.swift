//
//  Cast.swift
//  GTNW Chess
//
//  The two factions and their six robot characters (original GTNW Chess designs), plus the scripted battle
//  trash talk for every attacker → victim pair. These lines are the fallback whenever AI is off or unavailable.
//

import Foundation

enum Cast {
    static func name(_ kind: PieceKind, _ side: Side) -> String {
        switch kind {
        case .pawn: return "Drone"
        case .knight: return "Vaulter"
        case .bishop: return "Oracle"
        case .rook: return "Bastion"
        case .queen: return side == .white ? "Corona" : "Eclipse"
        case .king: return "Regent"
        }
    }

    static func fullName(_ kind: PieceKind, _ side: Side) -> String { "\(side.faction) \(name(kind, side))" }

    static func personality(_ kind: PieceKind) -> String {
        switch kind {
        case .pawn: return "an eager little hover-drone with one big eye and a spark tip; chirpy, brave beyond its size"
        case .knight: return "a spring-legged acrobat that vaults over anything; reckless and showy"
        case .bishop: return "a tall floating seer with a halo ring and a prism crystal; cryptic, speaks in angles"
        case .rook: return "a slab-sided walking fortress with a twin cannon battery; stoic, few words, heavy"
        case .queen: return "a tall commander ringed by three orbiting satellites; regal, fast, ruthless"
        case .king: return "a broad-shouldered regent with a crown of antennas who bends gravity; pompous, slow"
        }
    }

    /// Scripted trash talk for a capture: attacker's line, then the victim's last word. Every pair differs.
    static func battleLine(attacker: PieceKind, victim: PieceKind, attackerSide: Side) -> (String, String) {
        let a = fullName(attacker, attackerSide), v = fullName(victim, attackerSide.opposite)
        let taunt: [PieceKind: String] = [
            .pawn: "Small chassis, big spark!",
            .knight: "Didn't see that angle coming, did you?",
            .bishop: "The diagonal foretold your end.",
            .rook: "Battery armed. Firing for effect.",
            .queen: "Satellites, take it apart.",
            .king: "Kneel before the Regent's gravity.",
        ]
        let lastWord: [PieceKind: [PieceKind: String]] = [
            .pawn: [.pawn: "Drone down... tell my hover-pad I…", .knight: "A drone? Beaten by a DRONE?",
                    .bishop: "My prism... saw everything but this.", .rook: "Walls breached by a bottle rocket!",
                    .queen: "Outshone by a spark plug. Humiliating.", .king: "The crown flickers…"],
            .knight: [.pawn: "Boing— no!", .knight: "Spring for spring... you landed first.",
                      .bishop: "Prophecy didn't cover hooves of steel.", .rook: "It jumped OVER my walls!",
                      .queen: "My orbit… folded.", .king: "Out-vaulted. The Regent yields."],
            .bishop: [.pawn: "Zapped from across the board!", .knight: "Can't vault away from light.",
                      .bishop: "Two seers, one future. Not mine.", .rook: "Beam through the gun port. Clever.",
                      .queen: "Blinded by a sliver of light.", .king: "The halo's light… goes dark."],
            .rook: [.pawn: "Overkill! Total overkill!", .knight: "Shelled mid-jump!",
                    .bishop: "My crystal can't stop artillery.", .rook: "Bastion against bastion. You fired first.",
                    .queen: "Brought down by a brick with cannons.", .king: "Siege complete. The gate falls."],
            .queen: [.pawn: "Even her satellites outrank me.", .knight: "Caught in orbit.",
                     .bishop: "I saw her coming. Didn't help.", .rook: "Orbital strike on the keep!",
                     .queen: "Corona and Eclipse. Only one shines.", .king: "Surrounded by stars. Checkmate."],
            .king: [.pawn: "The Regent himself? For me?", .knight: "Pulled out of the air!",
                    .bishop: "Gravity, my one blind spot.", .rook: "Crushed into a cube.",
                    .queen: "Dragged down by the crown.", .king: "Regent to Regent… the end."],
        ]
        return ("\(a): \(taunt[attacker]!)", "\(v): \(lastWord[attacker]![victim]!)")
    }
}

// MARK: - Level personalities (data) and the chat gate

/// Nova's character per engine level, as data (after Quake III's bot characteristic files, chars.h /
/// BotLoadCachedCharacter: one table per skill with a default block for anything missing). The same row feeds the
/// built-in engine (`noise`, `aggression`) and the language-model prompts (`voice`), and gates chatter (`chatRate`,
/// `chatCooldown`). Bundled as JSON in the binary so it is edited as data, not code.
struct Personality: Codable, Equatable, Sendable {
    /// 0...1: bonus the built-in engine gives captures and checks at the root.
    var aggression: Double
    /// Centipawns of random noise the built-in engine adds per root move (gameplay RNG, seeded per game).
    var noise: Int
    /// 0...1: chance that an ordinary event gets AI banter (notable events always do).
    var chatRate: Double
    /// Plies to wait after AI banter before the next ordinary one.
    var chatCooldown: Int
    /// How Nova sounds at this level, for the LLM prompts.
    var voice: String

    static let json = """
        {"default": {"aggression": 0.2, "noise": 0, "chatRate": 0.5, "chatCooldown": 2, "voice": "calm, dry and precise"},
         "levels": {
          "1": {"aggression": 0.8, "noise": 60, "chatRate": 0.9, "chatCooldown": 0, "voice": "an over-excited cadet who charges at everything"},
          "2": {"aggression": 0.6, "noise": 60, "chatRate": 0.8, "chatCooldown": 1, "voice": "a keen scout, chatty and a bit nervous"},
          "3": {"aggression": 0.4, "noise": 20, "chatRate": 0.7, "chatCooldown": 1, "voice": "a cheerful pilot who loves a trade"},
          "4": {"aggression": 0.3, "noise": 20, "chatRate": 0.6, "chatCooldown": 2, "voice": "a confident captain, teasing but fair"},
          "5": {"aggression": 0.2, "noise": 0, "chatRate": 0.5, "chatCooldown": 2, "voice": "a cool commander who plays the long game"},
          "6": {"aggression": 0.2, "noise": 0, "chatRate": 0.4, "chatCooldown": 3, "voice": "a stern admiral, few words, all of them sharp"},
          "7": {"aggression": 0.1, "noise": 0, "chatRate": 0.35, "chatCooldown": 3, "voice": "Nova at full focus, wry and quietly smug"},
          "8": {"aggression": 0.1, "noise": 0, "chatRate": 0.3, "chatCooldown": 4, "voice": "Nova unleashed, icy and theatrical"}}}
        """

    private struct Table: Codable { var `default`: Personality; var levels: [String: Personality] }
    private static let table: Table? = try? JSONDecoder().decode(Table.self, from: Data(json.utf8))
    static let fallback = Personality(aggression: 0.2, noise: 0, chatRate: 0.5, chatCooldown: 2, voice: "calm, dry and precise")

    /// The level's row, else the table's default block, else the built-in default.
    static func of(_ level: EngineLevel?) -> Personality {
        guard let t = table else { return fallback }
        return level.flatMap { t.levels[String($0.rawValue)] } ?? t.default
    }
}

/// Gates AI chatter: event + probability + cooldown + situation (after Quake III BotChat_Kill / BotChat_*), so banter
/// stays cheap and never spams. A gated-out event uses the scripted line instead of calling a model. Narration is
/// cosmetic, so its dice are the cosmetic RNG (system random), never the game's seeded RNG.
struct ChatGate {
    private(set) var lastPly: [String: Int] = [:]
    var roll: () -> Double = { Double.random(in: 0..<1) }

    /// True: call the model for this event. `notable` (a queen falls, check, a threat on the board) always passes.
    mutating func allow(_ event: String, ply: Int, personality p: Personality, notable: Bool) -> Bool {
        if !notable {
            if let last = lastPly[event], ply - last <= p.chatCooldown { return false }
            if roll() >= p.chatRate { return false }
        }
        lastPly[event] = ply
        return true
    }
}

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

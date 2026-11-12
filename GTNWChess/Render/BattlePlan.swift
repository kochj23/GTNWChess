//
//  BattlePlan.swift
//  GTNW Chess
//
//  The capture-battle choreography as data. Every attacker → victim pair (6 × 6, the king-victim row plays as the
//  checkmate finale) gets its own plan: the attacker's signature strike, the victim's pair-specific reaction, the
//  victim's defeat, and the attacker's victory flourish, each with its own timing. Shared building blocks, but no
//  two pairs share the same combination. Pure value type: the scene executes it, tests inspect it.
//

import Foundation

enum AttackStyle: String, CaseIterable, Codable, Sendable {
    /// Drone: zips in low and rams with a spark-charged headbutt.
    case sparkRam
    /// Vaulter: coils, vaults in a high arc and slams down with a shockwave ring.
    case vaultSlam
    /// Oracle: raises its prism and fires a focused light beam.
    case prismBeam
    /// Bastion: braces on its treads and fires a twin-cannon salvo in arcs.
    case cannonSalvo
    /// Corona/Eclipse: launches its three satellites, which strike from three sides.
    case satelliteStrike
    /// Regent: a gravity well pulls the victim off its feet and compresses it.
    case gravityCrush

    static func of(_ k: PieceKind) -> AttackStyle { allCases[k.rawValue] }
    var isRanged: Bool { self == .prismBeam || self == .cannonSalvo || self == .satelliteStrike || self == .gravityCrush }
}

enum DefeatStyle: String, CaseIterable, Codable, Sendable {
    /// Drone: pops into sparks; its eye bounces away.
    case popSparks
    /// Vaulter: spring overloads and it pinwheels off the board.
    case springLaunch
    /// Oracle: crystal shatters, halo drops and rolls away.
    case prismShatter
    /// Bastion: breaks apart into falling blocks.
    case blockCollapse
    /// Corona/Eclipse: dissolves into a rising spiral of stardust.
    case stardustSpiral
    /// Regent: crown topples, lights flicker out, it powers down and kneels (checkmate finale).
    case crownFall

    static func of(_ k: PieceKind) -> DefeatStyle { allCases[k.rawValue] }
}

enum Reaction: String, CaseIterable, Codable, Sendable {
    case brace, sidestep, shieldUp, taunt, flinch, counterSpark
}

enum Flourish: String, CaseIterable, Codable, Sendable {
    case spin, hop, salute, glowPulse, orbitLap, stomp
}

struct BattlePlan: Equatable, Sendable {
    var attacker: PieceKind
    var victim: PieceKind
    var attack: AttackStyle
    var reaction: Reaction
    var defeat: DefeatStyle
    var flourish: Flourish
    /// Seconds at 1× speed.
    var approach: Double
    var react: Double
    var strike: Double
    var fall: Double
    var settle: Double
    /// A pair-specific accent hue shift (0...1) for the effects.
    var hueShift: Double
    var cameraSide: Double

    var total: Double { approach + react + strike + fall + settle }

    /// Unique per pair: the signature tests check for 36 distinct battles.
    var signature: String { "\(attack.rawValue)/\(reaction.rawValue)/\(defeat.rawValue)/\(flourish.rawValue)" }

    func duration(speed: Double) -> Double { total / max(0.1, speed) }

    static func make(attacker: PieceKind, victim: PieceKind) -> BattlePlan {
        let a = attacker.rawValue, v = victim.rawValue
        // Latin squares: every row and column uses each reaction / flourish once.
        let reaction = Reaction.allCases[(a + v) % 6]
        let flourish = Flourish.allCases[(a + 2 * v + 1) % 6]
        let attack = AttackStyle.of(attacker)
        let approach = attack.isRanged ? 0.35 : [0.55, 0.75][min(a, 1)]
        let strike = [0.55, 0.8, 0.85, 0.95, 1.0, 1.1][a]
        let fall = [0.7, 0.95, 0.9, 1.05, 1.15, 1.4][v]
        return BattlePlan(attacker: attacker, victim: victim, attack: attack, reaction: reaction,
                          defeat: DefeatStyle.of(victim), flourish: flourish,
                          approach: approach, react: 0.35 + 0.05 * Double((a * 3 + v) % 4), strike: strike, fall: fall,
                          settle: 0.45, hueShift: Double((a * 6 + v) * 7 % 36) / 36, cameraSide: (a + v) % 2 == 0 ? 1 : -1)
    }

    static var all: [BattlePlan] {
        PieceKind.allCases.flatMap { a in PieceKind.allCases.map { v in make(attacker: a, victim: v) } }
    }

    /// Short title shown on the battle banner.
    func title(attackerSide: Side) -> String {
        "\(Cast.fullName(attacker, attackerSide)) vs \(Cast.fullName(victim, attackerSide.opposite))"
    }
}

/// Animation preferences (Settings › Animation).
struct AnimationPrefs: Equatable, Sendable {
    var battlesEnabled = true
    /// 0.5...3×.
    var speed = 1.0
    var cinematicCamera = true
    /// Kill-moment violence: 0 Tame (original effects), 1 Brutal, 2 Maximum (default).
    var carnage = 2

    static let carnageLevels = ["Tame", "Brutal", "Maximum"]
    static let speeds: [Double] = [0.5, 0.75, 1, 1.5, 2, 3]
}

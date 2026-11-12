//
//  PieceFactory.swift
//  GTNW Chess
//
//  The twelve robot models (6 characters × Solar/Void), built in code from SceneKit primitives with
//  physically-based materials. Original designs:
//    Drone (pawn)    – hover-orb with one big eye, antenna spark and a glowing thruster ring
//    Vaulter (knight) – spring-legged hopper with a long sensor snout and swept fins
//    Oracle (bishop) – tall tapered seer with a floating halo ring and a prism crystal
//    Bastion (rook)  – slab-sided walking fortress on treads with a twin cannon battery and visor slit
//    Corona/Eclipse (queen) – slender commander with a fin crest and three orbiting satellites
//    Regent (king)   – broad capsule body with pauldrons, a crown of antennas and a gravity core
//  Models face +Z; the board turns Solar pieces to face the Void side. Named child nodes ("eye", "core", "weapon",
//  "halo", "sats", "spring", "crown", "glow") are what the battle choreography animates.
//

import SceneKit
import AppKit

struct FactionPalette {
    var body: NSColor
    var trim: NSColor
    var accent: NSColor
    var glow: NSColor
    var bodyMetal: CGFloat
    var bodyRough: CGFloat

    static let solar = FactionPalette(body: NSColor(red: 0.96, green: 0.86, blue: 0.62, alpha: 1),
                                      trim: NSColor(red: 0.85, green: 0.62, blue: 0.22, alpha: 1),
                                      accent: NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1),
                                      glow: NSColor(red: 1.0, green: 0.78, blue: 0.25, alpha: 1),
                                      bodyMetal: 0.65, bodyRough: 0.28)
    static let void = FactionPalette(body: NSColor(red: 0.16, green: 0.14, blue: 0.24, alpha: 1),
                                     trim: NSColor(red: 0.38, green: 0.30, blue: 0.62, alpha: 1),
                                     accent: NSColor(red: 0.62, green: 0.25, blue: 1.0, alpha: 1),
                                     glow: NSColor(red: 0.30, green: 0.92, blue: 1.0, alpha: 1),
                                     bodyMetal: 0.75, bodyRough: 0.32)

    static func of(_ side: Side) -> FactionPalette { side == .white ? solar : void }
}

enum PieceFactory {
    static func material(_ color: NSColor, metal: CGFloat = 0.5, rough: CGFloat = 0.4, emission: NSColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metal
        m.roughness.contents = rough
        if let e = emission { m.emission.contents = e; m.emission.intensity = 1.0 }
        return m
    }

    static func node(_ g: SCNGeometry, _ m: SCNMaterial, name: String? = nil, at p: SCNVector3 = SCNVector3Zero) -> SCNNode {
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.position = p
        n.name = name
        return n
    }

    /// A complete piece node (root name "piece:<kind>:<side>").
    static func make(_ kind: PieceKind, _ side: Side) -> SCNNode {
        let pal = FactionPalette.of(side)
        let body = material(pal.body, metal: pal.bodyMetal, rough: pal.bodyRough)
        let trim = material(pal.trim, metal: 0.9, rough: 0.2)
        let accent = material(pal.accent, metal: 0.3, rough: 0.35, emission: pal.accent.withAlphaComponent(0.35))
        let glow = material(pal.glow, metal: 0, rough: 1, emission: pal.glow)
        let root = SCNNode()
        root.name = "piece:\(kind.name):\(side.name)"
        let model = SCNNode()
        model.name = "model"
        root.addChildNode(model)
        // Shared base plinth (every robot stands on its faction disc).
        let base = node(SCNCylinder(radius: 0.36, height: 0.06), trim, name: "base", at: SCNVector3(0, 0.03, 0))
        model.addChildNode(base)
        let ring = node(SCNTorus(ringRadius: 0.33, pipeRadius: 0.012), glow, name: "glow", at: SCNVector3(0, 0.065, 0))
        model.addChildNode(ring)

        switch kind {
        case .pawn: buildDrone(model, body, trim, accent, glow)
        case .knight: buildVaulter(model, body, trim, accent, glow)
        case .bishop: buildOracle(model, body, trim, accent, glow)
        case .rook: buildBastion(model, body, trim, accent, glow)
        case .queen: buildQueen(model, body, trim, accent, glow, side: side)
        case .king: buildRegent(model, body, trim, accent, glow)
        }
        model.enumerateHierarchy { n, _ in n.castsShadow = true }
        addIdle(kind, model)
        return root
    }

    static func height(_ kind: PieceKind) -> CGFloat { [0.75, 1.05, 1.3, 1.0, 1.45, 1.55][kind.rawValue] }

    // MARK: - Characters

    static func buildDrone(_ m: SCNNode, _ body: SCNMaterial, _ trim: SCNMaterial, _ accent: SCNMaterial, _ glow: SCNMaterial) {
        let core = SCNNode(); core.name = "core"; core.position = SCNVector3(0, 0.42, 0); m.addChildNode(core)
        core.addChildNode(node(SCNSphere(radius: 0.21), body, name: "shell"))
        core.addChildNode(node(SCNTorus(ringRadius: 0.215, pipeRadius: 0.025), trim, name: "belt"))
        let eye = node(SCNSphere(radius: 0.085), glow, name: "eye", at: SCNVector3(0, 0.03, 0.17))
        core.addChildNode(eye)
        core.addChildNode(node(SCNTorus(ringRadius: 0.09, pipeRadius: 0.018), trim, at: SCNVector3(0, 0.03, 0.165)).rotatedX(.pi / 2))
        let antenna = node(SCNCylinder(radius: 0.012, height: 0.18), trim, at: SCNVector3(0.06, 0.27, -0.02))
        core.addChildNode(antenna)
        core.addChildNode(node(SCNSphere(radius: 0.03), accent, name: "weapon", at: SCNVector3(0.06, 0.37, -0.02)))
        // Thruster under the orb.
        m.addChildNode(node(SCNCone(topRadius: 0.1, bottomRadius: 0.04, height: 0.14), trim, at: SCNVector3(0, 0.17, 0)))
        m.addChildNode(node(SCNTorus(ringRadius: 0.12, pipeRadius: 0.015), glow, at: SCNVector3(0, 0.12, 0)))
    }

    static func buildVaulter(_ m: SCNNode, _ body: SCNMaterial, _ trim: SCNMaterial, _ accent: SCNMaterial, _ glow: SCNMaterial) {
        let spring = SCNNode(); spring.name = "spring"; m.addChildNode(spring)
        for i in 0..<5 {
            spring.addChildNode(node(SCNTorus(ringRadius: 0.11, pipeRadius: 0.022), trim, at: SCNVector3(0, 0.12 + CGFloat(i) * 0.06, 0)))
        }
        let core = SCNNode(); core.name = "core"; core.position = SCNVector3(0, 0.55, 0); m.addChildNode(core)
        let torso = node(SCNCapsule(capRadius: 0.16, height: 0.42), body, name: "shell")
        torso.eulerAngles = SCNVector3(0.5, 0, 0)
        core.addChildNode(torso)
        // Long sensor snout reaching forward and up: the Vaulter's silhouette.
        let snout = node(SCNCone(topRadius: 0.035, bottomRadius: 0.11, height: 0.38), body, at: SCNVector3(0, 0.26, 0.17))
        snout.eulerAngles = SCNVector3(1.1, 0, 0)
        core.addChildNode(snout)
        core.addChildNode(node(SCNSphere(radius: 0.05), glow, name: "eye", at: SCNVector3(0, 0.36, 0.32)))
        for x in [-1.0, 1.0] {
            let fin = node(SCNBox(width: 0.02, height: 0.28, length: 0.18, chamferRadius: 0.01), accent, at: SCNVector3(CGFloat(x) * 0.15, 0.18, -0.12))
            fin.eulerAngles = SCNVector3(-0.5, 0, CGFloat(x) * 0.35)
            core.addChildNode(fin)
        }
        core.addChildNode(node(SCNBox(width: 0.06, height: 0.06, length: 0.2, chamferRadius: 0.02), trim, name: "weapon", at: SCNVector3(0, -0.05, 0.16)))
    }

    static func buildOracle(_ m: SCNNode, _ body: SCNMaterial, _ trim: SCNMaterial, _ accent: SCNMaterial, _ glow: SCNMaterial) {
        let core = SCNNode(); core.name = "core"; m.addChildNode(core)
        core.addChildNode(node(SCNCone(topRadius: 0.07, bottomRadius: 0.24, height: 0.8), body, name: "shell", at: SCNVector3(0, 0.46, 0)))
        core.addChildNode(node(SCNTorus(ringRadius: 0.17, pipeRadius: 0.02), trim, at: SCNVector3(0, 0.3, 0)))
        core.addChildNode(node(SCNSphere(radius: 0.11), body, at: SCNVector3(0, 0.92, 0)))
        core.addChildNode(node(SCNBox(width: 0.16, height: 0.035, length: 0.04, chamferRadius: 0.015), glow, name: "eye", at: SCNVector3(0, 0.94, 0.09)))
        let halo = node(SCNTorus(ringRadius: 0.2, pipeRadius: 0.014), glow, name: "halo", at: SCNVector3(0, 1.1, 0))
        halo.eulerAngles = SCNVector3(0.25, 0, 0)
        core.addChildNode(halo)
        let crystal = node(SCNPyramid(width: 0.12, height: 0.18, length: 0.12), accent, name: "weapon", at: SCNVector3(0, 1.16, 0))
        let lower = node(SCNPyramid(width: 0.12, height: 0.12, length: 0.12), accent, at: SCNVector3(0, 0, 0))
        lower.eulerAngles = SCNVector3(CGFloat.pi, 0, 0)
        crystal.addChildNode(lower)
        core.addChildNode(crystal)
    }

    static func buildBastion(_ m: SCNNode, _ body: SCNMaterial, _ trim: SCNMaterial, _ accent: SCNMaterial, _ glow: SCNMaterial) {
        for x in [-1.0, 1.0] {
            m.addChildNode(node(SCNBox(width: 0.12, height: 0.12, length: 0.5, chamferRadius: 0.05), trim, at: SCNVector3(CGFloat(x) * 0.2, 0.12, 0)))
        }
        let core = SCNNode(); core.name = "core"; core.position = SCNVector3(0, 0.46, 0); m.addChildNode(core)
        core.addChildNode(node(SCNBox(width: 0.5, height: 0.5, length: 0.46, chamferRadius: 0.06), body, name: "shell"))
        core.addChildNode(node(SCNBox(width: 0.36, height: 0.05, length: 0.02, chamferRadius: 0.01), glow, name: "eye", at: SCNVector3(0, 0.1, 0.235)))
        core.addChildNode(node(SCNBox(width: 0.54, height: 0.06, length: 0.5, chamferRadius: 0.02), trim, at: SCNVector3(0, 0.26, 0)))
        let battery = SCNNode(); battery.name = "weapon"; battery.position = SCNVector3(0, 0.36, 0); core.addChildNode(battery)
        for x in [-1.0, 1.0] {
            let barrel = node(SCNCylinder(radius: 0.05, height: 0.36), trim, at: SCNVector3(CGFloat(x) * 0.11, 0, 0.1))
            barrel.eulerAngles = SCNVector3(CGFloat.pi / 2 - 0.25, 0, 0)
            battery.addChildNode(barrel)
            battery.addChildNode(node(SCNCylinder(radius: 0.035, height: 0.02), accent, at: SCNVector3(CGFloat(x) * 0.11, 0.04, 0.28)).rotatedX(CGFloat.pi / 2 - 0.25))
        }
        battery.addChildNode(node(SCNBox(width: 0.32, height: 0.1, length: 0.2, chamferRadius: 0.03), body, at: SCNVector3(0, -0.02, -0.04)))
    }

    static func buildQueen(_ m: SCNNode, _ body: SCNMaterial, _ trim: SCNMaterial, _ accent: SCNMaterial, _ glow: SCNMaterial, side: Side) {
        let core = SCNNode(); core.name = "core"; m.addChildNode(core)
        core.addChildNode(node(SCNCone(topRadius: 0.1, bottomRadius: 0.22, height: 0.7), body, name: "shell", at: SCNVector3(0, 0.42, 0)))
        core.addChildNode(node(SCNCapsule(capRadius: 0.11, height: 0.42), body, at: SCNVector3(0, 0.92, 0)))
        core.addChildNode(node(SCNTorus(ringRadius: 0.13, pipeRadius: 0.02), trim, at: SCNVector3(0, 0.8, 0)))
        core.addChildNode(node(SCNBox(width: 0.14, height: 0.03, length: 0.03, chamferRadius: 0.012), glow, name: "eye", at: SCNVector3(0, 1.0, 0.105)))
        // Fin crest: Solar's flares outward like a corona, Void's sweeps back like an eclipse shadow.
        let crest = SCNNode(); crest.name = "crown"; crest.position = SCNVector3(0, 1.18, 0); core.addChildNode(crest)
        for i in 0..<5 {
            let a = (CGFloat(i) - 2) * 0.32
            let fin = node(SCNBox(width: 0.025, height: 0.22, length: 0.08, chamferRadius: 0.01), accent)
            fin.position = SCNVector3(sin(a) * 0.08, 0.06, side == .white ? 0 : -0.04)
            fin.eulerAngles = SCNVector3(side == .white ? 0 : -0.5, 0, -a)
            crest.addChildNode(fin)
        }
        let sats = SCNNode(); sats.name = "sats"; sats.position = SCNVector3(0, 0.75, 0); core.addChildNode(sats)
        for i in 0..<3 {
            let a = CGFloat(i) * 2 * .pi / 3
            sats.addChildNode(node(SCNSphere(radius: 0.045), glow, name: "sat\(i)", at: SCNVector3(cos(a) * 0.32, 0, sin(a) * 0.32)))
        }
        sats.addChildNode(node(SCNTorus(ringRadius: 0.32, pipeRadius: 0.004), trim))
        core.addChildNode(node(SCNSphere(radius: 0.04), accent, name: "weapon", at: SCNVector3(0, 0.62, 0.2)))
    }

    static func buildRegent(_ m: SCNNode, _ body: SCNMaterial, _ trim: SCNMaterial, _ accent: SCNMaterial, _ glow: SCNMaterial) {
        let core = SCNNode(); core.name = "core"; m.addChildNode(core)
        core.addChildNode(node(SCNCapsule(capRadius: 0.24, height: 0.95), body, name: "shell", at: SCNVector3(0, 0.6, 0)))
        for x in [-1.0, 1.0] {
            core.addChildNode(node(SCNSphere(radius: 0.12), trim, at: SCNVector3(CGFloat(x) * 0.25, 0.86, 0)))
        }
        core.addChildNode(node(SCNBox(width: 0.24, height: 0.05, length: 0.03, chamferRadius: 0.015), glow, name: "eye", at: SCNVector3(0, 0.92, 0.225)))
        core.addChildNode(node(SCNSphere(radius: 0.08), accent, name: "weapon", at: SCNVector3(0, 0.58, 0.22)))
        core.addChildNode(node(SCNBox(width: 0.42, height: 0.6, length: 0.04, chamferRadius: 0.02), trim, at: SCNVector3(0, 0.55, -0.24)))
        let crown = SCNNode(); crown.name = "crown"; crown.position = SCNVector3(0, 1.1, 0); core.addChildNode(crown)
        crown.addChildNode(node(SCNTorus(ringRadius: 0.15, pipeRadius: 0.025), trim))
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3
            crown.addChildNode(node(SCNCylinder(radius: 0.012, height: 0.18), trim, at: SCNVector3(cos(a) * 0.15, 0.09, sin(a) * 0.15)))
            crown.addChildNode(node(SCNSphere(radius: 0.03), glow, at: SCNVector3(cos(a) * 0.15, 0.19, sin(a) * 0.15)))
        }
    }

    // MARK: - Idle life

    static func addIdle(_ kind: PieceKind, _ model: SCNNode) {
        let phase = Double.random(in: 0...1)
        switch kind {
        case .pawn:
            if let core = model.childNode(withName: "core", recursively: false) {
                let bob = SCNAction.sequence([.moveBy(x: 0, y: 0.035, z: 0, duration: 0.9), .moveBy(x: 0, y: -0.035, z: 0, duration: 0.9)])
                bob.timingMode = .easeInEaseOut
                core.runAction(.sequence([.wait(duration: phase), .repeatForever(bob)]), forKey: "idle")
            }
        case .queen:
            model.childNode(withName: "sats", recursively: true)?.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 4)), forKey: "idle")
        case .bishop:
            model.childNode(withName: "halo", recursively: true)?.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 6)), forKey: "idle")
            model.childNode(withName: "weapon", recursively: true)?.runAction(.repeatForever(.rotateBy(x: 0, y: -2 * .pi, z: 0, duration: 3)), forKey: "idle")
        case .king:
            model.childNode(withName: "crown", recursively: true)?.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 12)), forKey: "idle")
        default:
            break
        }
    }
}

extension SCNNode {
    func rotatedX(_ a: CGFloat) -> SCNNode { eulerAngles.x = a; return self }
}

//
//  Effects.swift
//  GTNW Chess
//
//  Reusable battle building blocks made from SceneKit primitives and particle systems: spark bursts, beams,
//  projectiles, shockwave rings, debris and stardust. All generated in code.
//

import SceneKit
import AppKit

enum Effects {
    /// A soft round particle sprite, generated once.
    static let sprite: NSImage = {
        let size = 32
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let g = NSGradient(colors: [NSColor.white, NSColor.white.withAlphaComponent(0)])
        g?.draw(in: NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)), relativeCenterPosition: .zero)
        img.unlockFocus()
        return img
    }()

    static func color(_ base: NSColor, hueShift: Double) -> NSColor {
        guard let c = base.usingColorSpace(.deviceRGB) else { return base }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: (h + CGFloat(hueShift) * 0.12).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: a)
    }

    static func burst(color: NSColor, count: CGFloat = 160, speed: CGFloat = 2.2, size: CGFloat = 0.06, life: CGFloat = 0.6,
                      gravity: Bool = true) -> SCNParticleSystem {
        let p = SCNParticleSystem()
        p.particleImage = sprite
        p.birthRate = count
        p.emissionDuration = 0.08
        p.loops = false
        p.particleLifeSpan = life
        p.particleLifeSpanVariation = life * 0.4
        p.particleVelocity = speed
        p.particleVelocityVariation = speed * 0.6
        p.spreadingAngle = 180
        p.particleSize = size
        p.particleSizeVariation = size * 0.5
        p.particleColor = color
        p.particleColorVariation = SCNVector4(0.05, 0.1, 0.2, 0)
        p.blendMode = .additive
        p.isAffectedByGravity = gravity
        p.acceleration = gravity ? SCNVector3(0, -2.5, 0) : SCNVector3Zero
        let fade = CAKeyframeAnimation()
        fade.values = [1.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.6, 1]
        p.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        return p
    }

    static func stardust(color: NSColor) -> SCNParticleSystem {
        let p = burst(color: color, count: 260, speed: 0.4, size: 0.04, life: 1.4, gravity: false)
        p.emissionDuration = 0.9
        p.acceleration = SCNVector3(0, 1.4, 0)
        p.emitterShape = SCNCylinder(radius: 0.2, height: 1.0)
        p.birthLocation = .volume
        return p
    }

    static func glowMaterial(_ c: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = c
        m.emission.contents = c
        m.blendMode = .add
        m.writesToDepthBuffer = false
        return m
    }

    static func beam(from a: SCNVector3, to b: SCNVector3, color: NSColor, radius: CGFloat = 0.05) -> SCNNode {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let len = sqrt(dx * dx + dy * dy + dz * dz)
        let cyl = SCNCylinder(radius: radius, height: len)
        cyl.materials = [glowMaterial(color)]
        let n = SCNNode(geometry: cyl)
        n.name = "fx:beam"
        n.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        n.look(at: b, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
        let core = SCNCylinder(radius: radius * 0.4, height: len)
        core.materials = [glowMaterial(.white)]
        n.addChildNode(SCNNode(geometry: core))
        return n
    }

    static func orb(_ color: NSColor, radius: CGFloat = 0.07) -> SCNNode {
        let s = SCNSphere(radius: radius)
        s.materials = [glowMaterial(color)]
        let n = SCNNode(geometry: s)
        n.name = "fx:orb"
        return n
    }

    static func ring(_ color: NSColor) -> SCNNode {
        let t = SCNTorus(ringRadius: 0.3, pipeRadius: 0.025)
        t.materials = [glowMaterial(color)]
        let n = SCNNode(geometry: t)
        n.name = "fx:ring"
        return n
    }

    static func block(_ material: SCNMaterial?, size: CGFloat) -> SCNNode {
        let b = SCNBox(width: size, height: size, length: size, chamferRadius: size * 0.1)
        if let material { b.materials = [material] }
        let n = SCNNode(geometry: b)
        n.name = "fx:block"
        return n
    }

    /// An arc from a to b peaking `height` above the higher end.
    static func arc(from a: SCNVector3, to b: SCNVector3, height: CGFloat, duration: Double) -> SCNAction {
        SCNAction.customAction(duration: duration) { node, t in
            let k = CGFloat(t) / CGFloat(max(duration, 0.0001))
            let x = a.x + (b.x - a.x) * k, z = a.z + (b.z - a.z) * k
            let y = a.y + (b.y - a.y) * k + height * 4 * k * (1 - k)
            node.position = SCNVector3(x, y, z)
        }
    }
}

//
//  BoardScene.swift
//  GTNW Chess
//
//  The 3D board (SceneKit): a deep-space board with lunar-silver and indigo tiles, faction rim lights, the robot
//  pieces, square highlights, an orbiting camera, ordinary move animation and the capture battles (executing a
//  `BattlePlan`). Battles are skippable at any moment and scale with the speed setting.
//

@preconcurrency import SceneKit
import AppKit

@MainActor
final class BoardScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let boardNode = SCNNode()
    let piecesNode = SCNNode()
    private(set) var pieces: [Square: SCNNode] = [:]
    private var overlays: [SCNNode] = []
    private var dots: [SCNNode] = []
    private(set) var flipped = false
    var cameraYaw: CGFloat = 0
    var cameraPitch: CGFloat = 0.92
    var cameraDistance: CGFloat = 11.5
    var playSound: (SFX) -> Void = { SoundPlayer.shared.play($0) }

    /// The battle in progress, if any.
    private(set) var battle: ActiveBattle?
    var battleActive: Bool { battle != nil }

    // ponytail: only touched on the main thread (SceneKit callbacks hop to main before use).
    final class ActiveBattle: @unchecked Sendable {
        let plan: BattlePlan
        let attacker: SCNNode
        let victim: SCNNode
        let victimKeeps: Bool
        let target: SCNVector3
        let attackerYaw: CGFloat
        var fx: [SCNNode] = []
        var completion: (() -> Void)?
        let driver = SCNNode()
        init(plan: BattlePlan, attacker: SCNNode, victim: SCNNode, victimKeeps: Bool, target: SCNVector3, attackerYaw: CGFloat) {
            self.plan = plan; self.attacker = attacker; self.victim = victim; self.victimKeeps = victimKeeps
            self.target = target; self.attackerYaw = attackerYaw
        }
    }

    init() {
        build()
    }

    // MARK: - Geometry helpers

    static func point(_ s: Square, y: CGFloat = 0) -> SCNVector3 {
        SCNVector3(CGFloat(Sq.file(s)) - 3.5, y, 3.5 - CGFloat(Sq.rank(s)))
    }

    static func baseYaw(_ side: Side) -> CGFloat { side == .white ? .pi : 0 }

    // MARK: - Build

    private func build() {
        scene.background.contents = Self.starfield()
        scene.lightingEnvironment.contents = NSColor(red: 0.18, green: 0.16, blue: 0.26, alpha: 1)
        scene.lightingEnvironment.intensity = 1.2
        scene.rootNode.addChildNode(boardNode)
        scene.rootNode.addChildNode(piecesNode)

        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 0.1
        camera.zFar = 200
        camera.wantsHDR = true
        camera.bloomIntensity = 0.6
        camera.bloomThreshold = 0.8
        camera.bloomBlurRadius = 6
        camera.wantsExposureAdaptation = false
        camera.vignettingIntensity = 0.4
        cameraNode.camera = camera
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)
        placeCamera(animated: false)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 1400
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowSampleCount = 8
        key.shadowRadius = 3
        key.shadowColor = NSColor.black.withAlphaComponent(0.55)
        key.orthographicScale = 7
        let keyNode = SCNNode(); keyNode.light = key; keyNode.name = "key"
        keyNode.eulerAngles = SCNVector3(-1.0, 0.5, 0)
        scene.rootNode.addChildNode(keyNode)
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 260; amb.color = NSColor(red: 0.55, green: 0.55, blue: 0.75, alpha: 1)
        let ambNode = SCNNode(); ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)
        for (side, pos) in [(Side.white, SCNVector3(0, 3, 7)), (.black, SCNVector3(0, 3, -7))] {
            let l = SCNLight(); l.type = .omni; l.intensity = 900
            l.color = FactionPalette.of(side).glow
            l.attenuationStartDistance = 2; l.attenuationEndDistance = 14
            let n = SCNNode(); n.light = l; n.position = pos
            scene.rootNode.addChildNode(n)
        }

        let light = PieceFactory.material(NSColor(red: 0.70, green: 0.74, blue: 0.84, alpha: 1), metal: 0.55, rough: 0.25)
        let dark = PieceFactory.material(NSColor(red: 0.10, green: 0.10, blue: 0.22, alpha: 1), metal: 0.6, rough: 0.22)
        for s in 0..<64 {
            let tile = SCNBox(width: 0.98, height: 0.12, length: 0.98, chamferRadius: 0.02)
            tile.materials = [Sq.isDark(s) ? dark : light]
            let n = SCNNode(geometry: tile)
            n.name = "tile:\(s)"
            n.position = Self.point(s, y: -0.06)
            boardNode.addChildNode(n)

            let ov = SCNPlane(width: 0.96, height: 0.96)
            ov.materials = [Effects.glowMaterial(.clear)]
            let o = SCNNode(geometry: ov)
            o.eulerAngles.x = -.pi / 2
            o.position = Self.point(s, y: 0.004)
            o.isHidden = true
            o.name = "overlay:\(s)"
            boardNode.addChildNode(o)
            overlays.append(o)

            let d = SCNCylinder(radius: 0.13, height: 0.01)
            d.materials = [Effects.glowMaterial(NSColor(red: 0.35, green: 0.95, blue: 1, alpha: 0.85))]
            let dn = SCNNode(geometry: d)
            dn.position = Self.point(s, y: 0.01)
            dn.isHidden = true
            dn.name = "dot:\(s)"
            boardNode.addChildNode(dn)
            dots.append(dn)
        }
        // Frame with an emissive inner rim and coordinates.
        let frameMat = PieceFactory.material(NSColor(red: 0.07, green: 0.06, blue: 0.12, alpha: 1), metal: 0.8, rough: 0.3)
        let frame = SCNBox(width: 8.9, height: 0.16, length: 8.9, chamferRadius: 0.08)
        frame.materials = [frameMat]
        let fn = SCNNode(geometry: frame); fn.position = SCNVector3(0, -0.1, 0); fn.name = "frame"
        boardNode.addChildNode(fn)
        for (i, edge) in [(8.1, 0.03), (0.03, 8.1)].enumerated() {
            for sign in [-1.0, 1.0] {
                let b = SCNBox(width: edge.0, height: 0.02, length: edge.1, chamferRadius: 0)
                b.materials = [Effects.glowMaterial(i == 0 ? FactionPalette.of(sign > 0 ? .white : .black).glow
                                                           : NSColor(red: 0.5, green: 0.4, blue: 1, alpha: 1))]
                let n = SCNNode(geometry: b)
                n.position = i == 0 ? SCNVector3(0, 0.01, CGFloat(sign) * 4.04) : SCNVector3(CGFloat(sign) * 4.04, 0.01, 0)
                boardNode.addChildNode(n)
            }
        }
        let labelMat = Effects.glowMaterial(NSColor(red: 0.7, green: 0.75, blue: 0.95, alpha: 0.9))
        for i in 0..<8 {
            for (text, pos) in [(String(UnicodeScalar(UInt8(97 + i))), SCNVector3(CGFloat(i) - 3.5, 0.0, 4.28)),
                                (String(i + 1), SCNVector3(-4.28, 0.0, 3.5 - CGFloat(i)))] {
                let t = SCNText(string: text, extrusionDepth: 0.01)
                t.font = NSFont.systemFont(ofSize: 0.24, weight: .semibold)
                t.flatness = 0.02
                t.materials = [labelMat]
                let n = SCNNode(geometry: t)
                let (minB, maxB) = n.boundingBox
                n.pivot = SCNMatrix4MakeTranslation((maxB.x + minB.x) / 2, (maxB.y + minB.y) / 2, 0)
                n.eulerAngles.x = -.pi / 2
                n.position = pos
                n.name = "label"
                boardNode.addChildNode(n)
            }
        }
    }

    static func starfield() -> NSImage {
        let w = 1024, h = 512
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSGradient(colors: [NSColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 1), NSColor(red: 0.07, green: 0.03, blue: 0.14, alpha: 1),
                            NSColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1)])?.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 90)
        var rng = Synth.Noise(state: 0xC0FFEE)
        for _ in 0..<700 {
            let x = CGFloat((rng.next() + 1) / 2) * CGFloat(w), y = CGFloat((rng.next() + 1) / 2) * CGFloat(h)
            let r = CGFloat(abs(rng.next())) * 1.3 + 0.3
            NSColor(white: 1, alpha: CGFloat(abs(rng.next())) * 0.8 + 0.2).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r, height: r)).fill()
        }
        // A distant nova bloom.
        NSGradient(colors: [NSColor(red: 1, green: 0.75, blue: 0.4, alpha: 0.35), NSColor(red: 0.5, green: 0.2, blue: 0.9, alpha: 0.12), .clear])?
            .draw(in: NSBezierPath(ovalIn: NSRect(x: 620, y: 300, width: 260, height: 160)), relativeCenterPosition: .zero)
        img.unlockFocus()
        return img
    }

    // MARK: - Camera

    func placeCamera(animated: Bool, duration: Double = 0.6) {
        let yaw = cameraYaw + (flipped ? .pi : 0)
        let d = cameraDistance
        let pos = SCNVector3(sin(yaw) * cos(cameraPitch) * d, sin(cameraPitch) * d, cos(yaw) * cos(cameraPitch) * d)
        moveCamera(to: pos, lookAt: SCNVector3(0, -0.3, 0), duration: animated ? duration : 0)
    }

    /// Moves the camera with an explicit action (eased position, slerped orientation). Implicit SCNTransaction
    /// animations on the camera could leave its presentation stuck at the battle pose.
    func moveCamera(to pos: SCNVector3, lookAt target: SCNVector3, duration: Double) {
        let goal = SCNNode()
        goal.position = pos
        goal.look(at: target)
        let p1 = goal.simdPosition, q1 = goal.simdOrientation
        cameraNode.removeAction(forKey: "camera")
        guard duration > 0 else { cameraNode.simdPosition = p1; cameraNode.simdOrientation = q1; return }
        let p0 = cameraNode.presentation.simdPosition, q0 = cameraNode.presentation.simdOrientation
        cameraNode.simdPosition = p0
        cameraNode.simdOrientation = q0
        let move = SCNAction.customAction(duration: duration) { n, t in
            let x = Float(min(1, max(0, t / CGFloat(duration))))
            let e = x * x * (3 - 2 * x)
            n.simdPosition = simd_mix(p0, p1, SIMD3<Float>(repeating: e))
            n.simdOrientation = simd_slerp(q0, q1, e)
        }
        cameraNode.runAction(.sequence([move, .run { n in n.simdPosition = p1; n.simdOrientation = q1 }]), forKey: "camera")
    }

    func setFlipped(_ f: Bool, animated: Bool) {
        flipped = f
        placeCamera(animated: animated, duration: 0.9)
    }

    func orbit(dx: CGFloat, dy: CGFloat) {
        cameraYaw -= dx * 0.008
        cameraPitch = min(1.45, max(0.35, cameraPitch + dy * 0.006))
        placeCamera(animated: false)
    }

    func zoom(_ delta: CGFloat) {
        cameraDistance = min(17, max(7, cameraDistance - delta * 0.08))
        placeCamera(animated: false)
    }

    func resetCamera() {
        cameraYaw = 0; cameraPitch = 0.92; cameraDistance = 11.5
        placeCamera(animated: true)
    }

    // MARK: - Pieces

    /// Makes the scene match `position` (used at load, undo, and after every move as a safety net).
    func sync(_ position: Position) {
        guard battle == nil else { return }
        for s in 0..<64 {
            let want = position.piece(at: s)
            if let node = pieces[s] {
                if node.name != want.map(Self.nodeName) {
                    node.removeFromParentNode()
                    pieces[s] = nil
                } else {
                    node.position = Self.point(s)
                    node.eulerAngles.y = Self.baseYaw(want!.side)
                    node.opacity = 1
                    node.scale = SCNVector3(1, 1, 1)
                    continue
                }
            }
            if let p = want {
                let n = PieceFactory.make(p.kind, p.side)
                n.position = Self.point(s)
                n.eulerAngles.y = Self.baseYaw(p.side)
                piecesNode.addChildNode(n)
                pieces[s] = n
            }
        }
        // Any orphan nodes (e.g. after a skipped battle) go.
        let live = Set(pieces.values.map { ObjectIdentifier($0) })
        for n in piecesNode.childNodes where !live.contains(ObjectIdentifier(n)) { n.removeFromParentNode() }
    }

    static func nodeName(_ p: Piece) -> String { "piece:\(p.kind.name):\(p.side.name)" }

    func square(of node: SCNNode) -> Square? {
        var n: SCNNode? = node
        while let cur = n {
            if let name = cur.name {
                if name.hasPrefix("tile:") || name.hasPrefix("overlay:") || name.hasPrefix("dot:") {
                    return Int(name.split(separator: ":")[1])
                }
                if name.hasPrefix("piece:") { return pieces.first { $0.value === cur }?.key }
            }
            n = cur.parent
        }
        return nil
    }

    // MARK: - Highlights

    struct Highlights: Equatable {
        var selected: Square?
        var targets: [Square] = []
        var lastMove: Move?
        var check: Square?
        var hint: Move?
        var threatened: [Square] = []
    }

    private(set) var highlights = Highlights()

    func setHighlights(_ h: Highlights) {
        highlights = h
        var colors: [Square: NSColor] = [:]
        for s in h.threatened { colors[s] = NSColor(red: 1, green: 0.35, blue: 0.2, alpha: 0.28) }
        if let m = h.lastMove {
            colors[m.from] = NSColor(red: 1, green: 0.72, blue: 0.25, alpha: 0.22)
            colors[m.to] = NSColor(red: 1, green: 0.72, blue: 0.25, alpha: 0.35)
        }
        if let m = h.hint {
            colors[m.from] = NSColor(red: 0.3, green: 1, blue: 0.5, alpha: 0.35)
            colors[m.to] = NSColor(red: 0.3, green: 1, blue: 0.5, alpha: 0.55)
        }
        if let s = h.selected { colors[s] = NSColor(red: 1, green: 0.85, blue: 0.3, alpha: 0.55) }
        if let c = h.check { colors[c] = NSColor(red: 1, green: 0.1, blue: 0.2, alpha: 0.6) }
        for s in 0..<64 {
            if let c = colors[s] {
                overlays[s].geometry?.firstMaterial?.diffuse.contents = c
                overlays[s].geometry?.firstMaterial?.emission.contents = c
                overlays[s].isHidden = false
            } else {
                overlays[s].isHidden = true
            }
            dots[s].isHidden = !h.targets.contains(s)
        }
    }

    var visibleOverlayCount: Int { overlays.filter { !$0.isHidden }.count }
    var visibleDotCount: Int { dots.filter { !$0.isHidden }.count }

    // MARK: - Moves

    /// Animates a played move from `before` to `after`. Captures run a battle unless disabled.
    func animate(_ pm: PlayedMove, before: Position, after: Position, prefs: AnimationPrefs, completion: @escaping () -> Void) {
        let m = pm.move
        guard let mover = pieces[m.from] else { sync(after); completion(); return }
        let speed = max(0.1, prefs.speed)
        if pm.captured != nil, prefs.battlesEnabled {
            let victimSq = m.isEnPassant ? m.to + (pm.side == .white ? -8 : 8) : m.to
            if let victim = pieces[victimSq] {
                let plan = BattlePlan.make(attacker: pm.movedKind, victim: pm.captured!)
                runBattle(plan, attacker: mover, victim: victim, from: m.from, to: m.to, attackerSide: pm.side,
                          victimKeeps: false, prefs: prefs) { [weak self] in
                    guard let self else { return }
                    self.pieces[victimSq] = nil
                    self.pieces[m.from] = nil
                    self.pieces[m.to] = mover
                    self.finishMove(pm, after: after, speed: speed, completion: completion)
                }
                return
            }
        }
        if pm.captured != nil {
            let victimSq = m.isEnPassant ? m.to + (pm.side == .white ? -8 : 8) : m.to
            if let v = pieces[victimSq] {
                v.runAction(.sequence([.group([.scale(to: 0.01, duration: 0.18 / speed), .fadeOut(duration: 0.18 / speed)]), .removeFromParentNode()]))
                pieces[victimSq] = nil
            }
            playSound(.capture)
        } else {
            playSound(.move)
        }
        let dest = Self.point(m.to)
        let dur = 0.32 / speed
        let travel: SCNAction = pm.movedKind == .knight ? Effects.arc(from: mover.position, to: dest, height: 0.8, duration: dur)
                                                        : .move(to: dest, duration: dur)
        travel.timingMode = .easeInEaseOut
        pieces[m.from] = nil
        pieces[m.to] = mover
        if m.isCastle {
            let (rf, rt) = Self.castleRook(m.to)
            if let rook = pieces[rf] {
                pieces[rf] = nil
                pieces[rt] = rook
                rook.runAction(.sequence([.wait(duration: dur * 0.3), .move(to: Self.point(rt), duration: dur)]))
            }
        }
        mover.runAction(travel) { [weak self] in
            DispatchQueue.main.async { self?.finishMove(pm, after: after, speed: speed, completion: completion) }
        }
    }

    static func castleRook(_ kingTo: Square) -> (Square, Square) {
        switch kingTo {
        case 6: return (7, 5)
        case 2: return (0, 3)
        case 62: return (63, 61)
        default: return (56, 59)
        }
    }

    private func finishMove(_ pm: PlayedMove, after: Position, speed: Double, completion: @escaping () -> Void) {
        if let promo = pm.move.promotion, let old = pieces[pm.move.to] {
            let n = PieceFactory.make(promo, pm.side)
            n.position = old.position
            n.eulerAngles.y = Self.baseYaw(pm.side)
            n.scale = SCNVector3(0.01, 0.01, 0.01)
            old.removeFromParentNode()
            piecesNode.addChildNode(n)
            pieces[pm.move.to] = n
            let fx = SCNNode()
            fx.position = SCNVector3(n.position.x, 0.5, n.position.z)
            fx.addParticleSystem(Effects.burst(color: FactionPalette.of(pm.side).glow, count: 220, speed: 1.5, gravity: false))
            piecesNode.addChildNode(fx)
            fx.runAction(.sequence([.wait(duration: 1.2), .removeFromParentNode()]))
            n.runAction(.scale(to: 1, duration: 0.35 / speed))
            playSound(.orbital)
        }
        if pm.isCheck { playSound(.check) }
        sync(after)
        completion()
    }

    // MARK: - Battles

    /// Runs the checkmate finale: the mating piece "defeats" the Regent, who kneels and stays on the board.
    func checkmateFinale(attackerSquare: Square, kingSquare: Square, attackerKind: PieceKind, attackerSide: Side,
                         prefs: AnimationPrefs, completion: @escaping () -> Void) {
        guard prefs.battlesEnabled, let a = pieces[attackerSquare], let k = pieces[kingSquare] else { completion(); return }
        let plan = BattlePlan.make(attacker: attackerKind, victim: .king)
        runBattle(plan, attacker: a, victim: k, from: attackerSquare, to: kingSquare, attackerSide: attackerSide,
                  victimKeeps: true, prefs: prefs, returnHome: true, completion: completion)
    }

    func runBattle(_ plan: BattlePlan, attacker: SCNNode, victim: SCNNode, from: Square, to: Square, attackerSide: Side,
                   victimKeeps: Bool, prefs: AnimationPrefs, returnHome: Bool = false, completion: @escaping () -> Void) {
        let k = 1 / max(0.1, prefs.speed)
        let A0 = attacker.position, V = Self.point(to)
        let dx = V.x - A0.x, dz = V.z - A0.z
        let dist = max(0.001, sqrt(dx * dx + dz * dz))
        let dir = SCNVector3(dx / dist, 0, dz / dist)
        let yaw = atan2(dir.x, dir.z)
        let home = returnHome ? A0 : V
        let b = ActiveBattle(plan: plan, attacker: attacker, victim: victim, victimKeeps: victimKeeps, target: home,
                             attackerYaw: Self.baseYaw(attackerSide))
        b.completion = completion
        battle = b
        scene.rootNode.addChildNode(b.driver)
        let pal = FactionPalette.of(attackerSide), vpal = FactionPalette.of(attackerSide.opposite)
        let fxColor = Effects.color(pal.glow, hueShift: plan.hueShift)

        // Camera.
        if prefs.cinematicCamera {
            let mid = SCNVector3((A0.x + V.x) / 2, 0.4, (A0.z + V.z) / 2)
            let side = SCNVector3(-dir.z * CGFloat(plan.cameraSide), 0, dir.x * CGFloat(plan.cameraSide))
            let span = max(3.2, dist * 0.9 + 2.2)
            moveCamera(to: SCNVector3(mid.x + side.x * span - dir.x * 1.2, 2.3 + dist * 0.15, mid.z + side.z * span - dir.z * 1.2),
                       lookAt: mid, duration: 0.5 * k)
        }

        // Face off.
        attacker.runAction(.rotateTo(x: 0, y: yaw, z: 0, duration: 0.25 * k, usesShortestUnitArc: true), forKey: "battle-turn")
        victim.runAction(.rotateTo(x: 0, y: yaw + .pi, z: 0, duration: 0.25 * k, usesShortestUnitArc: true), forKey: "battle-turn")

        let melee = !plan.attack.isRanged
        let standOff = melee ? SCNVector3(V.x - dir.x * 0.62, 0, V.z - dir.z * 0.62)
                             : (dist > 3 ? SCNVector3(A0.x + dir.x * (dist - 3), 0, A0.z + dir.z * (dist - 3)) : A0)
        let tApproach = plan.approach * k, tReact = plan.react * k, tStrike = plan.strike * k
        let tFall = plan.fall * k, tSettle = plan.settle * k

        // 1. Approach.
        let approach = SCNAction.move(to: standOff, duration: tApproach)
        approach.timingMode = .easeInEaseOut
        attacker.runAction(approach, forKey: "battle")
        playSound(.whoosh)

        // 2. Reaction (pair-specific).
        victim.runAction(.sequence([.wait(duration: tApproach), reactionAction(plan.reaction, victim: victim, dir: dir, duration: tReact,
                                                                                 color: vpal.glow, battle: b, attacker: attacker)]), forKey: "battle")

        // 3. Strike, 4. defeat, 5. settle — driven by the timeline node.
        let t1 = tApproach + tReact
        b.driver.runAction(.sequence([
            .wait(duration: t1),
            .run { [weak self] _ in DispatchQueue.main.async { self?.strike(b, from: standOff, to: V, dir: dir, color: fxColor, duration: tStrike) } },
            .wait(duration: tStrike),
            .run { [weak self] _ in DispatchQueue.main.async { self?.defeat(b, at: V, dir: dir, color: Effects.color(vpal.glow, hueShift: plan.hueShift), duration: tFall) } },
            .wait(duration: tFall),
            .run { [weak self] _ in DispatchQueue.main.async { self?.settle(b, duration: tSettle) } },
            .wait(duration: tSettle + 0.05),
            .run { [weak self] _ in DispatchQueue.main.async { self?.endBattle() } },
        ]), forKey: "battle")
    }

    private func reactionAction(_ r: Reaction, victim: SCNNode, dir: SCNVector3, duration d: Double, color: NSColor,
                                battle b: ActiveBattle, attacker: SCNNode) -> SCNAction {
        let model = victim.childNode(withName: "model", recursively: false) ?? victim
        switch r {
        case .brace:
            return .run { _ in model.runAction(.sequence([.scale(to: 0.9, duration: d * 0.4), .scale(to: 1.0, duration: d * 0.6)]), forKey: "battle") }
        case .sidestep:
            let side = SCNVector3(-dir.z * 0.25, 0, dir.x * 0.25)
            return .sequence([.moveBy(x: side.x, y: 0, z: side.z, duration: d * 0.5), .moveBy(x: -side.x, y: 0, z: -side.z, duration: d * 0.5)])
        case .shieldUp:
            return .run { [weak self] _ in
                DispatchQueue.main.async {
                    let disc = SCNNode(geometry: SCNCylinder(radius: 0.42, height: 0.01))
                    disc.geometry?.materials = [Effects.glowMaterial(color.withAlphaComponent(0.4))]
                    disc.eulerAngles.x = .pi / 2
                    disc.name = "fx:shield"
                    let holder = SCNNode()
                    holder.position = SCNVector3(victim.position.x - dir.x * 0.38, 0.55, victim.position.z - dir.z * 0.38)
                    holder.eulerAngles.y = atan2(dir.x, dir.z)
                    holder.addChildNode(disc)
                    holder.name = "fx:shieldHolder"
                    disc.opacity = 0
                    disc.runAction(.sequence([.fadeIn(duration: d * 0.5), .wait(duration: d * 0.6), .fadeOut(duration: 0.2), .removeFromParentNode()]))
                    self?.addFX(holder, to: b)
                }
            }
        case .taunt:
            let hop = SCNAction.sequence([.moveBy(x: 0, y: 0.18, z: 0, duration: d * 0.25), .moveBy(x: 0, y: -0.18, z: 0, duration: d * 0.25)])
            return .repeat(hop, count: 2)
        case .flinch:
            return .run { _ in model.runAction(.sequence([.rotateBy(x: -0.25, y: 0, z: 0, duration: d * 0.4), .rotateBy(x: 0.25, y: 0, z: 0, duration: d * 0.6)]), forKey: "battle") }
        case .counterSpark:
            return .run { [weak self] _ in
                DispatchQueue.main.async {
                    let s = SCNNode()
                    s.position = SCNVector3(attacker.position.x, 0.6, attacker.position.z)
                    s.addParticleSystem(Effects.burst(color: color, count: 60, speed: 1.2, size: 0.04, life: 0.4))
                    self?.addFX(s, to: b)
                    self?.playSound(.click)
                }
            }
        }
    }

    private func addFX(_ n: SCNNode, to b: ActiveBattle) {
        guard battle === b else { return }
        scene.rootNode.addChildNode(n)
        b.fx.append(n)
    }

    private func spark(_ b: ActiveBattle, at p: SCNVector3, color: NSColor, count: CGFloat = 160, speed: CGFloat = 2.2) {
        let n = SCNNode()
        n.position = p
        n.addParticleSystem(Effects.burst(color: color, count: count, speed: speed))
        addFX(n, to: b)
    }

    private func strike(_ b: ActiveBattle, from S: SCNVector3, to V: SCNVector3, dir: SCNVector3, color: NSColor, duration d: Double) {
        guard battle === b else { return }
        let a = b.attacker, victim = b.victim
        let hit = SCNVector3(V.x, 0.55, V.z)
        let weaponWorld = a.childNode(withName: "weapon", recursively: true)?.worldPosition ?? SCNVector3(S.x, 0.8, S.z)
        switch b.plan.attack {
        case .sparkRam:
            let lunge = SCNAction.sequence([.moveBy(x: -dir.x * 0.15, y: 0, z: -dir.z * 0.15, duration: d * 0.3),
                                            .move(to: SCNVector3(V.x - dir.x * 0.3, 0, V.z - dir.z * 0.3), duration: d * 0.2),
                                            .moveBy(x: -dir.x * 0.1, y: 0, z: -dir.z * 0.1, duration: d * 0.3)])
            a.runAction(lunge, forKey: "battle")
            b.driver.runAction(.sequence([.wait(duration: d * 0.5), .run { [weak self] _ in
                DispatchQueue.main.async { self?.spark(b, at: hit, color: color); self?.playSound(.pop) } }]), forKey: "battle-fx")
        case .vaultSlam:
            let land = SCNVector3(V.x - dir.x * 0.32, 0, V.z - dir.z * 0.32)
            a.runAction(.group([Effects.arc(from: S, to: land, height: 1.6, duration: d * 0.7),
                                .rotateBy(x: 0, y: 2 * .pi, z: 0, duration: d * 0.7)]), forKey: "battle")
            playSound(.boing)
            b.driver.runAction(.sequence([.wait(duration: d * 0.7), .run { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.battle === b else { return }
                    let r = Effects.ring(color)
                    r.position = SCNVector3(V.x, 0.05, V.z)
                    r.scale = SCNVector3(0.3, 0.3, 0.3)
                    r.runAction(.group([.scale(to: 3.2, duration: d * 0.3), .fadeOut(duration: d * 0.3)]))
                    self.addFX(r, to: b)
                    self.spark(b, at: hit, color: color, count: 120)
                    self.playSound(.capture)
                } }]), forKey: "battle-fx")
        case .prismBeam:
            a.childNode(withName: "weapon", recursively: true)?.runAction(.sequence([.scale(to: 1.6, duration: d * 0.25), .scale(to: 1, duration: d * 0.5)]))
            let beam = Effects.beam(from: weaponWorld, to: hit, color: color, radius: 0.045)
            beam.opacity = 0
            beam.runAction(.sequence([.wait(duration: d * 0.2), .fadeIn(duration: d * 0.1), .wait(duration: d * 0.45), .fadeOut(duration: d * 0.25)]))
            addFX(beam, to: b)
            playSound(.beam)
            b.driver.runAction(.sequence([.wait(duration: d * 0.35), .run { [weak self] _ in
                DispatchQueue.main.async { self?.spark(b, at: hit, color: color, count: 200, speed: 1.6) } }]), forKey: "battle-fx")
        case .cannonSalvo:
            a.runAction(.sequence([.moveBy(x: -dir.x * 0.12, y: 0, z: -dir.z * 0.12, duration: d * 0.1),
                                   .moveBy(x: dir.x * 0.12, y: 0, z: dir.z * 0.12, duration: d * 0.3)]), forKey: "battle")
            for i in 0..<4 {
                let delay = d * 0.12 * Double(i)
                let target = SCNVector3(hit.x + CGFloat(i % 2 == 0 ? 0.12 : -0.12), hit.y, hit.z + CGFloat(i < 2 ? 0.1 : -0.1))
                b.driver.runAction(.sequence([.wait(duration: delay), .run { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.battle === b else { return }
                        let shell = Effects.orb(color, radius: 0.06)
                        shell.position = weaponWorld
                        let fly = Effects.arc(from: weaponWorld, to: target, height: 0.9, duration: d * 0.45)
                        shell.runAction(.sequence([fly, .run { [weak self] _ in
                            DispatchQueue.main.async { self?.spark(b, at: target, color: color, count: 90, speed: 1.8) } },
                                                   .fadeOut(duration: 0.05)]))
                        self.addFX(shell, to: b)
                        self.playSound(.cannon)
                    } }]), forKey: "battle-fx\(i)")
            }
        case .satelliteStrike:
            for i in 0..<3 {
                let ang = CGFloat(i) * 2 * .pi / 3
                let start = SCNVector3(S.x + cos(ang) * 0.32, 0.75, S.z + sin(ang) * 0.32)
                let flank = SCNVector3(V.x + cos(ang) * 0.7, 0.9, V.z + sin(ang) * 0.7)
                let orb = Effects.orb(color, radius: 0.06)
                orb.position = start
                orb.runAction(.sequence([.move(to: flank, duration: d * 0.45), .move(to: hit, duration: d * 0.2), .fadeOut(duration: 0.05)]))
                addFX(orb, to: b)
            }
            a.childNode(withName: "sats", recursively: true)?.runAction(.sequence([.fadeOut(duration: d * 0.1), .wait(duration: d * 0.8), .fadeIn(duration: d * 0.1)]))
            playSound(.orbital)
            b.driver.runAction(.sequence([.wait(duration: d * 0.65), .run { [weak self] _ in
                DispatchQueue.main.async { self?.spark(b, at: hit, color: color, count: 240, speed: 2.4); self?.playSound(.capture) } }]), forKey: "battle-fx")
        case .gravityCrush:
            let well = Effects.ring(NSColor(red: 0.5, green: 0.2, blue: 1, alpha: 1))
            well.position = SCNVector3(V.x, 0.03, V.z)
            well.scale = SCNVector3(2.5, 2.5, 2.5)
            well.runAction(.sequence([.scale(to: 0.6, duration: d * 0.8), .fadeOut(duration: d * 0.2)]))
            addFX(well, to: b)
            victim.runAction(.group([.moveBy(x: 0, y: 0.5, z: 0, duration: d * 0.6), .rotateBy(x: 0, y: 3 * .pi, z: 0, duration: d * 0.9),
                                     .sequence([.wait(duration: d * 0.5), .scale(to: 0.7, duration: d * 0.4)])]), forKey: "battle")
            playSound(.gravity)
        }
    }

    private func defeat(_ b: ActiveBattle, at V: SCNVector3, dir: SCNVector3, color: NSColor, duration d: Double) {
        guard battle === b else { return }
        let v = b.victim
        let center = SCNVector3(V.x, 0.55, V.z)
        let vanish = SCNAction.sequence([.fadeOut(duration: d * 0.3), .run { n in n.isHidden = true }])
        switch b.plan.defeat {
        case .popSparks:
            v.runAction(.sequence([.scale(to: 1.25, duration: d * 0.15), .group([.scale(to: 0.01, duration: d * 0.15), .fadeOut(duration: d * 0.15)]),
                                   .run { n in n.isHidden = true }]), forKey: "battle")
            spark(b, at: center, color: color, count: 220, speed: 2.6)
            let eye = Effects.orb(color, radius: 0.07)
            eye.position = center
            let away = SCNVector3(V.x + dir.x * 1.3 + dir.z * 0.4, 0.08, V.z + dir.z * 1.3 - dir.x * 0.4)
            eye.runAction(.sequence([Effects.arc(from: center, to: away, height: 0.7, duration: d * 0.5),
                                     Effects.arc(from: away, to: SCNVector3(away.x + dir.x * 0.4, 0.07, away.z + dir.z * 0.4), height: 0.2, duration: d * 0.25),
                                     .fadeOut(duration: d * 0.25)]))
            addFX(eye, to: b)
            playSound(.pop)
        case .springLaunch:
            let off = SCNVector3(V.x + dir.x * 4.5, 3.2, V.z + dir.z * 4.5)
            v.runAction(.group([Effects.arc(from: v.position, to: off, height: 1.5, duration: d * 0.85),
                                .rotateBy(x: 4 * .pi, y: 0, z: 2 * .pi, duration: d * 0.85),
                                .sequence([.wait(duration: d * 0.6), vanish])]), forKey: "battle")
            playSound(.boing)
        case .prismShatter:
            let mat = v.childNode(withName: "weapon", recursively: true)?.geometry?.firstMaterial
            for i in 0..<14 {
                let shard = Effects.block(mat, size: 0.05)
                shard.position = SCNVector3(V.x, 1.1, V.z)
                let a = CGFloat(i) / 14 * 2 * .pi
                let to = SCNVector3(V.x + cos(a) * 0.9, 0.03, V.z + sin(a) * 0.9)
                shard.runAction(.sequence([.group([Effects.arc(from: shard.position, to: to, height: 0.4, duration: d * 0.6),
                                                   .rotateBy(x: 6, y: 4, z: 2, duration: d * 0.6)]), .fadeOut(duration: d * 0.3)]))
                addFX(shard, to: b)
            }
            if let halo = v.childNode(withName: "halo", recursively: true) {
                let ring = Effects.ring(color)
                ring.scale = SCNVector3(0.65, 0.65, 0.65)
                ring.position = halo.worldPosition
                let rest = SCNVector3(V.x - dir.z * 0.8, 0.2, V.z + dir.x * 0.8)
                ring.runAction(.sequence([.group([.move(to: SCNVector3(halo.worldPosition.x, 0.2, halo.worldPosition.z), duration: d * 0.3),
                                                  .rotateTo(x: .pi / 2, y: 0, z: 0, duration: d * 0.3)]),
                                          .move(to: rest, duration: d * 0.45), .fadeOut(duration: d * 0.2)]))
                addFX(ring, to: b)
                halo.isHidden = true
            }
            v.runAction(.sequence([.wait(duration: d * 0.2), vanish]), forKey: "battle")
            playSound(.shatter)
        case .blockCollapse:
            let mat = v.childNode(withName: "shell", recursively: true)?.geometry?.firstMaterial
            v.runAction(.sequence([.wait(duration: d * 0.08), .run { n in n.isHidden = true }]), forKey: "battle")
            for i in 0..<12 {
                let blk = Effects.block(mat, size: 0.16)
                let gx = CGFloat(i % 3) - 1, gy = CGFloat(i / 3) * 0.17 + 0.25, gz = CGFloat((i / 3) % 2) * 0.2 - 0.1
                blk.position = SCNVector3(V.x + gx * 0.17, gy, V.z + gz)
                let to = SCNVector3(V.x + gx * 0.7 + CGFloat(i % 2) * 0.2 - 0.1, 0.08, V.z + gz * 3 + dir.z * 0.3)
                blk.runAction(.sequence([.wait(duration: Double(i) * 0.02 * d),
                                         .group([Effects.arc(from: blk.position, to: to, height: 0.25, duration: d * 0.55),
                                                 .rotateBy(x: CGFloat(i % 3), y: 1, z: CGFloat(i % 2), duration: d * 0.55)]),
                                         .fadeOut(duration: d * 0.3)]))
                addFX(blk, to: b)
            }
            playSound(.crumble)
        case .stardustSpiral:
            let dust = SCNNode()
            dust.position = SCNVector3(V.x, 0.6, V.z)
            dust.addParticleSystem(Effects.stardust(color: color))
            addFX(dust, to: b)
            v.runAction(.group([.rotateBy(x: 0, y: 6 * .pi, z: 0, duration: d * 0.9), .moveBy(x: 0, y: 0.6, z: 0, duration: d * 0.9),
                                .sequence([.wait(duration: d * 0.4), vanish])]), forKey: "battle")
            playSound(.dissolve)
        case .crownFall:
            if let crown = v.childNode(withName: "crown", recursively: true) {
                let c = crown.clone()
                c.position = crown.worldPosition
                let to = SCNVector3(V.x - dir.x * 0.6 + dir.z * 0.3, 0.05, V.z - dir.z * 0.6 - dir.x * 0.3)
                c.runAction(.group([Effects.arc(from: c.position, to: to, height: 0.4, duration: d * 0.5), .rotateBy(x: 1.4, y: 0, z: 0.6, duration: d * 0.5)]))
                c.name = "fx:crown"
                addFX(c, to: b)
                crown.isHidden = true
            }
            v.enumerateHierarchy { n, _ in
                if n.name == "eye" || n.name == "glow" { n.runAction(.sequence([.fadeOpacity(to: 0.15, duration: d * 0.3), .fadeOpacity(to: 0.7, duration: 0.08), .fadeOpacity(to: 0.05, duration: d * 0.3)])) }
            }
            let model = v.childNode(withName: "model", recursively: false) ?? v
            model.runAction(.sequence([.wait(duration: d * 0.35), .group([.rotateBy(x: 0.35, y: 0, z: 0, duration: d * 0.5),
                                                                         .moveBy(x: 0, y: -0.12, z: 0, duration: d * 0.5)])]), forKey: "battle")
            playSound(.powerDown)
        }
    }

    private func settle(_ b: ActiveBattle, duration d: Double) {
        guard battle === b else { return }
        let a = b.attacker
        let move = SCNAction.move(to: b.target, duration: d * 0.6)
        move.timingMode = .easeInEaseOut
        let flourish: SCNAction
        let model = a.childNode(withName: "model", recursively: false) ?? a
        switch b.plan.flourish {
        case .spin: flourish = .run { _ in model.runAction(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: d * 0.4)) }
        case .hop: flourish = .sequence([.moveBy(x: 0, y: 0.25, z: 0, duration: d * 0.2), .moveBy(x: 0, y: -0.25, z: 0, duration: d * 0.2)])
        case .salute: flourish = .run { _ in model.runAction(.sequence([.rotateBy(x: 0.3, y: 0, z: 0, duration: d * 0.2), .rotateBy(x: -0.3, y: 0, z: 0, duration: d * 0.2)])) }
        case .glowPulse: flourish = .run { _ in model.runAction(.sequence([.scale(to: 1.15, duration: d * 0.2), .scale(to: 1, duration: d * 0.2)])) }
        case .orbitLap: flourish = .run { _ in model.runAction(.rotateBy(x: 0, y: -2 * .pi, z: 0, duration: d * 0.4)) }
        case .stomp: flourish = .run { _ in model.runAction(.sequence([.scale(to: 0.88, duration: d * 0.1), .scale(to: 1, duration: d * 0.1),
                                                                       .scale(to: 0.88, duration: d * 0.1), .scale(to: 1, duration: d * 0.1)])) }
        }
        a.runAction(.sequence([move, flourish, .rotateTo(x: 0, y: b.attackerYaw, z: 0, duration: 0.01)]), forKey: "battle")
        playSound(b.plan.victim == .king ? .victory : .select)
    }

    /// Skips the running battle: final state immediately, completion called once.
    func skipBattle() {
        guard battle != nil else { return }
        endBattle()
    }

    private func endBattle() {
        guard let b = battle else { return }
        battle = nil
        b.driver.removeAllActions()
        b.driver.removeFromParentNode()
        for n in b.fx { n.removeAllActions(); n.removeFromParentNode() }
        for n in [b.attacker, b.victim] {
            for key in ["battle", "battle-turn"] { n.removeAction(forKey: key) }
            n.enumerateChildNodes { c, _ in c.removeAction(forKey: "battle") }
        }
        if let m = b.attacker.childNode(withName: "model", recursively: false) {
            m.removeAllActions(); m.scale = SCNVector3(1, 1, 1); m.eulerAngles = SCNVector3Zero; m.position = SCNVector3Zero
            PieceFactory.addIdle(b.plan.attacker, m)
        }
        b.attacker.childNode(withName: "sats", recursively: true)?.opacity = 1
        b.attacker.position = b.target
        b.attacker.eulerAngles = SCNVector3(0, b.attackerYaw, 0)
        b.attacker.opacity = 1
        if b.victimKeeps {
            b.victim.removeAllActions()
            b.victim.scale = SCNVector3(1, 1, 1)
            b.victim.opacity = 1
            b.victim.isHidden = false
            b.victim.position = SCNVector3(b.victim.position.x, 0, b.victim.position.z)
            if let model = b.victim.childNode(withName: "model", recursively: false) {
                model.removeAllActions()
                model.eulerAngles = SCNVector3(0.35, 0, 0)
                model.position = SCNVector3(0, -0.12, 0)
            }
            b.victim.childNode(withName: "crown", recursively: true)?.isHidden = true
        } else {
            b.victim.removeAllActions()
            b.victim.removeFromParentNode()
        }
        placeCamera(animated: true, duration: 0.45)
        let c = b.completion
        b.completion = nil
        c?()
    }
}

//
//  FrameTests.swift
//  GTNWChessTests
//
//  Scene graph and UI state: piece nodes per position, highlights, camera flip/orbit limits, battles (start,
//  skip completes exactly once, run to completion under an offscreen renderer), and real offscreen frames that
//  must not be blank.
//

import XCTest
import SceneKit
import Metal
@testable import GTNWChess

@MainActor
final class FrameTests: XCTestCase {
    private func renderer(_ s: BoardScene) throws -> SCNRenderer {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let r = SCNRenderer(device: dev, options: nil)
        r.scene = s.scene
        r.pointOfView = s.cameraNode
        r.isPlaying = true
        return r
    }

    /// Fraction of sampled pixels that differ noticeably from the first one.
    private func variety(_ img: NSImage) -> Double {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
        let bpp = cg.bitsPerPixel / 8, row = cg.bytesPerRow
        var differ = 0, total = 0
        let first = (Int(p[0]), Int(p[1]), Int(p[2]))
        for y in stride(from: 0, to: cg.height, by: 7) {
            for x in stride(from: 0, to: cg.width, by: 7) {
                let o = y * row + x * bpp
                let d = abs(Int(p[o]) - first.0) + abs(Int(p[o + 1]) - first.1) + abs(Int(p[o + 2]) - first.2)
                if d > 30 { differ += 1 }
                total += 1
            }
        }
        return Double(differ) / Double(max(1, total))
    }

    func testStartPositionHas32NamedPieces() {
        let s = BoardScene()
        s.sync(Position.start)
        XCTAssertEqual(s.pieces.count, 32)
        XCTAssertEqual(s.piecesNode.childNodes.count, 32)
        XCTAssertEqual(s.pieces[4]?.name, "piece:king:white")
        XCTAssertEqual(s.pieces[59]?.name, "piece:queen:black")
        XCTAssertEqual(s.square(of: s.pieces[12]!), 12)
        XCTAssertEqual(s.scene.rootNode.childNode(withName: "tile:0", recursively: true) != nil, true)
    }

    func testSyncReusesNodesAndRemovesCaptured() throws {
        let s = BoardScene()
        s.sync(Position.start)
        let rook = s.pieces[0]
        let g = try Fixtures.game(["e4", "d5", "exd5"])
        s.sync(g.position)
        XCTAssertEqual(s.pieces.count, 31)
        XCTAssertEqual(s.piecesNode.childNodes.count, 31)
        XCTAssertTrue(s.pieces[0] === rook, "unchanged squares keep their node")
        XCTAssertEqual(s.pieces[Sq.parse("d5")!]?.name, "piece:pawn:white")
    }

    func testHighlightsFollowSelectionAndCheck() throws {
        let c = TestEnv.controller()
        var cfg = NewGameConfig(); cfg.mode = .hotseat; c.newGame(cfg)
        c.tap(Sq.parse("e2")!)
        XCTAssertEqual(c.scene.visibleDotCount, 2, "e3 and e4")
        XCTAssertEqual(c.scene.highlights.selected, Sq.parse("e2"))
        c.tap(Sq.parse("e4")!)
        XCTAssertEqual(c.scene.visibleDotCount, 0)
        XCTAssertEqual(c.scene.highlights.lastMove?.uci, "e2e4")
        XCTAssertGreaterThanOrEqual(c.scene.visibleOverlayCount, 2)
        TestEnv.play(c, ["f5", "Qh5+"])
        XCTAssertEqual(c.scene.highlights.check, Sq.parse("e8"))
    }

    func testCameraFlipAndOrbitLimits() {
        let s = BoardScene()
        let z0 = s.cameraNode.position.z
        s.setFlipped(true, animated: false)
        XCTAssertEqual(s.cameraNode.position.z, -z0, accuracy: 0.01)
        for _ in 0..<100 { s.orbit(dx: 0, dy: 500) }
        XCTAssertLessThanOrEqual(s.cameraPitch, 1.45)
        for _ in 0..<100 { s.zoom(1_000) }
        XCTAssertGreaterThanOrEqual(s.cameraDistance, 7)
        s.resetCamera()
        XCTAssertEqual(s.cameraDistance, 11.5)
    }

    func testBattleStartsAndSkipCompletesExactlyOnce() throws {
        let s = BoardScene()
        s.playSound = { _ in }
        let g0 = try Fixtures.game(["e4", "d5"])
        var g = g0
        s.sync(g.position)
        let pm = try g.play(san: "exd5")
        var done = 0
        s.animate(pm, before: g0.position, after: g.position, prefs: AnimationPrefs()) { done += 1 }
        XCTAssertTrue(s.battleActive)
        XCTAssertGreaterThan(s.scene.rootNode.childNodes.count, 0)
        s.skipBattle()
        s.skipBattle()
        XCTAssertFalse(s.battleActive)
        XCTAssertEqual(done, 1)
        s.sync(g.position)
        XCTAssertEqual(s.pieces.count, 31)
        XCTAssertEqual(s.piecesNode.childNodes.count, 31, "no orphan nodes after a skip")
    }

    func testMaximumCarnageScarsTheBoardThenANewGameWipesIt() async throws {
        let s = BoardScene()
        s.playSound = { _ in }
        let r = try renderer(s)
        let g0 = try Fixtures.game(["e4", "d5"])
        var g = g0
        s.sync(g.position)
        let pm = try g.play(san: "exd5")
        var prefs = AnimationPrefs(); prefs.speed = 3
        XCTAssertEqual(prefs.carnage, 2, "Maximum is the default")
        var done = 0
        s.animate(pm, before: g0.position, after: g.position, prefs: prefs) { done += 1 }
        let start = CACurrentMediaTime()
        let ok = await waitUntil(15) {
            r.render(atTime: CACurrentMediaTime() - start + 0.001)
            return done == 1
        }
        XCTAssertTrue(ok)
        XCTAssertGreaterThan(s.scarsNode.childNodes.count, 0, "a kill leaves a mark")
        for n in [s.boardNode, s.piecesNode, s.scarsNode] { XCTAssertEqual(n.position.x, 0); XCTAssertEqual(n.position.y, 0) }
        s.sync(g.position)
        XCTAssertGreaterThan(s.scarsNode.childNodes.count, 0, "marks survive ordinary syncs")
        s.sync(Game().position)
        XCTAssertEqual(s.scarsNode.childNodes.count, 0, "a fresh board is clean")
    }

    func testBattlesDisabledResolveWithoutABattle() throws {
        let s = BoardScene()
        s.playSound = { _ in }
        let g0 = try Fixtures.game(["e4", "d5"])
        var g = g0
        s.sync(g.position)
        let pm = try g.play(san: "exd5")
        var prefs = AnimationPrefs(); prefs.battlesEnabled = false
        s.animate(pm, before: g0.position, after: g.position, prefs: prefs) {}
        XCTAssertFalse(s.battleActive)
    }

    func testBattleRunsToCompletionUnderRenderer() async throws {
        let s = BoardScene()
        s.playSound = { _ in }
        let r = try renderer(s)
        let g0 = try Fixtures.game(["e4", "d5"])
        var g = g0
        s.sync(g.position)
        let pm = try g.play(san: "exd5")
        var prefs = AnimationPrefs(); prefs.speed = 3
        var done = 0
        s.animate(pm, before: g0.position, after: g.position, prefs: prefs) { done += 1 }
        let start = CACurrentMediaTime()
        let ok = await waitUntil(15) {
            r.render(atTime: CACurrentMediaTime() - start + 0.001)
            return done == 1
        }
        XCTAssertTrue(ok, "battle finished by itself (\(BattlePlan.make(attacker: .pawn, victim: .pawn).duration(speed: 3))s)")
        XCTAssertFalse(s.battleActive)
        XCTAssertEqual(done, 1)
    }

    func testOffscreenFramesAreNotBlank() throws {
        let s = BoardScene()
        s.sync(Position.start)
        let r = try renderer(s)
        let img = r.snapshot(atTime: 0, with: CGSize(width: 320, height: 200), antialiasingMode: .none)
        XCTAssertGreaterThan(variety(img), 0.2, "board and pieces visible")
        s.setFlipped(true, animated: false)
        let img2 = r.snapshot(atTime: 0.1, with: CGSize(width: 320, height: 200), antialiasingMode: .none)
        XCTAssertGreaterThan(variety(img2), 0.2)
    }

    func testControllerUIState() throws {
        let c = TestEnv.controller()
        var cfg = NewGameConfig(); cfg.mode = .vsNova; cfg.side = "black"; c.newGame(cfg)
        XCTAssertTrue(c.flipped)
        XCTAssertTrue(c.scene.flipped)
        c.is3D = true
        c.is3D = false
        XCTAssertFalse(c.scene.battleActive)
        XCTAssertTrue(c.statusLine.contains("thinking") || c.statusLine.contains("to move"), c.statusLine)
        cfg.mode = .hotseat; c.newGame(cfg)
        XCTAssertFalse(c.flipped, "hot-seat board stays Solar-side")
        XCTAssertTrue(c.canInteract)
        XCTAssertEqual(c.statusLine, "\(c.whiteName) (Solar) to move")
    }

    func testTwoDBoardTogglesWithoutAnimating() throws {
        let c = TestEnv.controller()
        var cfg = NewGameConfig(); cfg.mode = .hotseat; c.newGame(cfg)
        TestEnv.play(c, ["e4", "d5", "exd5"])
        XCTAssertFalse(c.animating, "2D applies captures immediately")
        XCTAssertNil(c.battleBanner)
        XCTAssertEqual(c.scene.pieces.count, 31)
    }

    func testCameraReturnsToPlayerViewAfterBattle() async throws {
        for (fen, san) in [("r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 1", "Bxc6"),
                           ("3rk3/ppp2ppp/8/8/8/8/PPP2PPP/3QK3 w - - 0 1", "Qxd8+")] {
            let s = BoardScene()
            s.playSound = { _ in }
            let r = try renderer(s)
            let home = s.cameraNode.position, homeQ = s.cameraNode.orientation
            let g0 = try Game(fen: fen)
            var g = g0
            s.sync(g.position)
            let pm = try g.play(san: san)
            var prefs = AnimationPrefs(); prefs.speed = 3
            var done = false
            s.animate(pm, before: g0.position, after: g.position, prefs: prefs) { done = true }
            let start = CACurrentMediaTime()
            let ok = await waitUntil(15) { r.render(atTime: CACurrentMediaTime() - start); return done }
            XCTAssertTrue(ok)
            // Let the return move finish.
            let t1 = CACurrentMediaTime()
            while CACurrentMediaTime() - t1 < 1.2 { r.render(atTime: CACurrentMediaTime() - start); try await Task.sleep(nanoseconds: 16_000_000) }
            let p = s.cameraNode.presentation.position, q = s.cameraNode.presentation.orientation
            XCTAssertEqual(p.x, home.x, accuracy: 0.05, san); XCTAssertEqual(p.y, home.y, accuracy: 0.05, san); XCTAssertEqual(p.z, home.z, accuracy: 0.05, san)
            XCTAssertEqual(abs(q.x * homeQ.x + q.y * homeQ.y + q.z * homeQ.z + q.w * homeQ.w), 1, accuracy: 0.01, "\(san): camera orientation restored")
        }
    }
}

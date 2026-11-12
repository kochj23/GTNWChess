//
//  BoardViews.swift
//  GTNW Chess
//
//  The 3D board (SCNView: click to select/move, drag to orbit, scroll to zoom, Esc/click skips a battle) and the
//  flat 2D study board (SwiftUI). Both drive the same GameController.
//

import SceneKit
import SwiftUI

final class ChessSCNView: SCNView {
    var onSquare: (Square) -> Void = { _ in }
    var onSkip: () -> Void = {}
    var isBattling: () -> Bool = { false }
    weak var board: BoardScene?
    private var dragStart: NSPoint?
    private var dragged = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        if abs(p.x - start.x) + abs(p.y - start.y) > 4 { dragged = true }
        if dragged { board?.orbit(dx: event.deltaX, dy: event.deltaY) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard !dragged else { return }
        if isBattling() { onSkip(); return }
        let p = convert(event.locationInWindow, from: nil)
        let hits = hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: false])
        for h in hits {
            if let s = board?.square(of: h.node) { onSquare(s); return }
        }
    }

    override func rightMouseDragged(with event: NSEvent) { board?.orbit(dx: event.deltaX, dy: event.deltaY) }

    override func scrollWheel(with event: NSEvent) { board?.zoom(event.scrollingDeltaY) }

    override func magnify(with event: NSEvent) { board?.zoom(event.magnification * 60) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.charactersIgnoringModifiers == " " { onSkip(); return }
        super.keyDown(with: event)
    }
}

struct Board3DView: NSViewRepresentable {
    @ObservedObject var controller: GameController
    @AppStorage(Prefs.antialias) private var antialias = true
    @AppStorage(Prefs.shadows) private var shadows = true

    func makeNSView(context: Context) -> ChessSCNView {
        let v = ChessSCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        v.scene = controller.scene.scene
        v.pointOfView = controller.scene.cameraNode
        v.board = controller.scene
        v.backgroundColor = .black
        v.rendersContinuously = true
        v.preferredFramesPerSecond = 60
        v.isJitteringEnabled = false
        v.onSquare = { [weak controller] s in controller?.tap(s) }
        v.onSkip = { [weak controller] in controller?.skipAnimation() }
        v.isBattling = { [weak controller] in controller?.scene.battleActive ?? false }
        v.setAccessibilityLabel("3D chess board")
        apply(v)
        return v
    }

    func updateNSView(_ v: ChessSCNView, context: Context) { apply(v) }

    private func apply(_ v: ChessSCNView) {
        v.antialiasingMode = antialias ? .multisampling4X : .none
        v.scene?.rootNode.childNode(withName: "key", recursively: false)?.light?.castsShadow = shadows
    }
}

struct Board2DView: View {
    @ObservedObject var controller: GameController

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height) * 0.94
            let cell = size / 8
            let game = controller.game
            let targets = Set(controller.legalTargets)
            let last = game.lastMove?.move
            let check = game.position.inCheck ? game.position.kingSquare[game.sideToMove.rawValue] : nil
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { col in
                            let file = controller.flipped ? 7 - col : col
                            let rank = controller.flipped ? row : 7 - row
                            let s = Sq.make(file, rank)
                            cellView(s, size: cell, targets: targets, last: last, check: check, game: game)
                                .onTapGesture { controller.tap(s) }
                        }
                    }
                }
            }
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.rim, lineWidth: 2))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("2D chess board")
        }
        .background(Theme.space)
    }

    @ViewBuilder
    private func cellView(_ s: Square, size: CGFloat, targets: Set<Square>, last: Move?, check: Square?, game: Game) -> some View {
        let dark = Sq.isDark(s)
        ZStack {
            Rectangle().fill(dark ? Theme.darkTile : Theme.lightTile)
            if last?.from == s || last?.to == s { Rectangle().fill(Color.orange.opacity(0.28)) }
            if controller.hintMove?.from == s || controller.hintMove?.to == s { Rectangle().fill(Color.green.opacity(0.35)) }
            if controller.selected == s { Rectangle().fill(Color.yellow.opacity(0.45)) }
            if check == s { Rectangle().fill(Color.red.opacity(0.5)) }
            if let p = game.position.piece(at: s) {
                Text(Self.glyph(p))
                    .font(.system(size: size * 0.74))
                    .foregroundStyle(p.side == .white ? Theme.solar : Theme.void)
                    .shadow(color: p.side == .white ? .black.opacity(0.6) : Theme.voidGlow.opacity(0.9), radius: 1.5)
            }
            if targets.contains(s) {
                Circle().fill(Theme.voidGlow.opacity(0.75)).frame(width: size * 0.24, height: size * 0.24)
            }
            if Sq.rank(s) == (controller.flipped ? 7 : 0) {
                Text(String(Sq.name(s).first!)).font(.system(size: size * 0.16, weight: .semibold))
                    .foregroundStyle(dark ? Theme.lightTile : Theme.darkTile)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(3)
            }
            if Sq.file(s) == (controller.flipped ? 7 : 0) {
                Text(String(Sq.rank(s) + 1)).font(.system(size: size * 0.16, weight: .semibold))
                    .foregroundStyle(dark ? Theme.lightTile : Theme.darkTile)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(3)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .accessibilityLabel("\(Sq.name(s)) \(game.position.piece(at: s).map { "\($0.side.faction) \($0.kind.name)" } ?? "empty")")
    }

    static func glyph(_ p: Piece) -> String {
        ["♟", "♞", "♝", "♜", "♛", "♚"][p.kind.rawValue]
    }
}

enum Theme {
    static let space = Color(red: 0.04, green: 0.035, blue: 0.08)
    static let panel = Color(red: 0.08, green: 0.07, blue: 0.14)
    static let lightTile = Color(red: 0.70, green: 0.74, blue: 0.84)
    static let darkTile = Color(red: 0.16, green: 0.16, blue: 0.32)
    static let solar = Color(red: 1.0, green: 0.84, blue: 0.45)
    static let void = Color(red: 0.12, green: 0.06, blue: 0.22)
    static let voidGlow = Color(red: 0.30, green: 0.92, blue: 1.0)
    static let rim = Color(red: 0.55, green: 0.45, blue: 1.0)
    static let accent = Color(red: 1.0, green: 0.55, blue: 0.2)
}

//
//  ContentView.swift
//  GTNW Chess
//
//  Main window: the board (3D or 2D) with the battle banner, and a side panel with players and clocks, Nova's
//  coach, the move list, the battle log and the game actions.
//

import NovaAIKit
import SwiftUI
import UniformTypeIdentifiers

enum ActiveSheet: String, Identifiable {
    case newGame, hostLAN, joinLAN, signIn, fen
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var controller: GameController
    @ObservedObject var ai: NovaAI
    @SceneStorage("view.is3D") private var is3D = true
    @State private var sheet: ActiveSheet?
    @State private var errorText: String?
    @State private var confirmResign = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                if controller.is3D { Board3DView(controller: controller) } else { Board2DView(controller: controller) }
                if let b = controller.battleBanner { BattleBanner(title: b) { controller.skipAnimation() } }
                if controller.waitingForGuest, let code = controller.lanInfo?.code { PairingCodeView(code: code, lan: controller.lan) }
            }
            .frame(minWidth: 560, minHeight: 520)
            SidePanel(controller: controller, ai: ai, sheet: $sheet, confirmResign: $confirmResign)
                .frame(width: 340)
        }
        .background(Theme.space)
        .preferredColorScheme(.dark)
        .onAppear {
            // Restored view mode, unless a launch flag chose one. Board orientation follows the game (your side at the bottom).
            if !CommandLine.arguments.contains("--2d") { controller.is3D = is3D }
        }
        .onChange(of: controller.is3D) { _, v in is3D = v }
        .sheet(item: $sheet) { s in
            switch s {
            case .newGame: NewGameSheet(controller: controller) { sheet = nil }
            case .hostLAN: HostLANSheet(controller: controller) { sheet = nil }
            case .joinLAN: JoinLANSheet(controller: controller) { sheet = nil }
            case .signIn: SignInSheet(client: controller.site) { sheet = nil; controller.outbox.flush() }
            case .fen: FENSheet(controller: controller) { sheet = nil }
            }
        }
        .sheet(item: $controller.promotion) { p in PromotionPicker(side: p.side) { controller.choosePromotion($0) } }
        .alert("Resign this game?", isPresented: $confirmResign) {
            Button("Resign", role: .destructive) { controller.resign() }
            Button("Keep playing", role: .cancel) {}
        }
        .alert(drawQuestion, isPresented: Binding(get: { controller.mustAnswerDraw }, set: { _ in })) {
            Button("Accept draw") { controller.respondToDraw(true) }
            Button("Decline", role: .cancel) { controller.respondToDraw(false) }
        }
        .alert("GTNW Chess", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .gtnwCommand)) { n in handle(n.object as? String ?? "") }
        .onAppear { if AppLaunch.shouldOfferSignIn(controller) { sheet = .signIn } }
    }

    private var drawQuestion: String {
        controller.drawOfferFrom.map { "\(controller.displayName($0)) offers a draw" } ?? "Draw offer"
    }

    private func handle(_ cmd: String) {
        switch cmd {
        case "new": sheet = .newGame
        case "host": sheet = .hostLAN
        case "join": sheet = .joinLAN
        case "signin": sheet = .signIn
        case "fen": sheet = .fen
        case "open": openPGN()
        case "save": savePGN()
        case "undo": controller.undo()
        case "flip": controller.flipped.toggle()
        case "toggle3d": controller.is3D.toggle()
        case "hint": controller.requestHint()
        case "resign": confirmResign = true
        case "draw": controller.offerDraw()
        case "copyfen": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(controller.game.position.fen, forType: .string)
        case "copypgn": NSPasteboard.general.clearContents(); NSPasteboard.general.setString(controller.exportPGN(), forType: .string)
        case "skip": controller.skipAnimation()
        case "resetcam": controller.scene.resetCamera()
        default: break
        }
    }

    private func openPGN() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "pgn") ?? .plainText, .plainText]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attrs[.size] as? Int ?? 0) <= PGN.maxBytes else { throw ChessError.badPGN("file too large") }
            try controller.importPGN(String(contentsOf: url, encoding: .utf8))
        } catch { errorText = error.localizedDescription }
    }

    private func savePGN() {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: "pgn") ?? .plainText]
        p.nameFieldStringValue = "GTNW Chess \(controller.whiteName) vs \(controller.blackName).pgn"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try controller.exportPGN().write(to: url, atomically: true, encoding: .utf8) } catch { errorText = error.localizedDescription }
    }
}

struct BattleBanner: View {
    var title: String
    var skip: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill").foregroundStyle(Theme.accent)
            Text(title).font(.system(.headline, design: .rounded)).foregroundStyle(.white)
            Button("Skip ⎋", action: skip).buttonStyle(.borderless).foregroundStyle(Theme.voidGlow)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.rim.opacity(0.7)))
        .padding(.top, 14)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityIdentifier("battleBanner")
    }
}

struct PairingCodeView: View {
    var code: String
    @ObservedObject var lan: LANSession
    private var port: UInt16? { if case .listening(let p) = lan.status, p != 0 { return p } else { return nil } }
    var body: some View {
        VStack(spacing: 6) {
            Text("Pairing code").font(.caption).foregroundStyle(.secondary)
            Text(code).font(.system(size: 44, weight: .bold, design: .monospaced)).foregroundStyle(Theme.solar)
            Text("On the other Mac: Game › Join LAN Game, pick this Mac, enter the code.").font(.caption).foregroundStyle(.secondary)
            if let port { Text("Port \(String(port))").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 60)
    }
}

struct SidePanel: View {
    @ObservedObject var controller: GameController
    @ObservedObject var ai: NovaAI
    @Binding var sheet: ActiveSheet?
    @Binding var confirmResign: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("GTNW CHESS").font(.system(.title3, design: .rounded).weight(.heavy)).foregroundStyle(Theme.solar)
                Spacer()
                NovaAIStatusIndicator(ai: ai)
            }
            PlayerRow(controller: controller, side: .black)
            PlayerRow(controller: controller, side: .white)
            Text(controller.statusLine).font(.callout.weight(.semibold)).foregroundStyle(controller.game.isOver ? Theme.accent : .white)
                .accessibilityIdentifier("status")
            if controller.mode == .watch { WatchControls(controller: controller) }
            if let note = controller.lanNote ?? (controller.mode == .lan ? controller.lan.status.label : nil) {
                Label(note, systemImage: "network").font(.caption).foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.coachText).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("coach")
                    Text(controller.coachSource).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: { Label("Nova · Coach", systemImage: "sparkles").foregroundStyle(Theme.voidGlow) }
            HStack {
                Button { controller.requestHint() } label: { Label("Hint", systemImage: "lightbulb") }
                    .disabled(!controller.canInteract)
                Button { controller.refreshCoach() } label: { Label("Explain", systemImage: "text.bubble") }
                Button { controller.undo() } label: { Label("Takeback", systemImage: "arrow.uturn.backward") }
                    .disabled(!controller.canUndo)
            }
            .controlSize(.small)
            MoveList(game: controller.game)
            Feed(items: controller.feed)
            if let a = controller.analysis {
                Text(String(format: "Accuracy — Solar %.0f%% · Void %.0f%%", a.white.accuracy, a.black.accuracy))
                    .font(.caption).foregroundStyle(Theme.solar)
            } else if controller.analyzing {
                ProgressView("Analysing with \(controller.engine.hasStockfish ? "Stockfish" : "the built-in engine")…").controlSize(.small)
            }
            HStack {
                Button("New Game…") { sheet = .newGame }.keyboardShortcut("n", modifiers: .command)
                Spacer()
                Button("Draw") { controller.offerDraw() }.disabled(controller.game.isOver || controller.drawOfferFrom != nil)
                Button("Resign") { confirmResign = true }.disabled(controller.game.isOver || controller.resigningSide == nil)
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(Theme.panel)
    }
}

struct PlayerRow: View {
    @ObservedObject var controller: GameController
    var side: Side
    var body: some View {
        let toMove = controller.game.sideToMove == side && !controller.game.isOver
        HStack {
            Circle().fill(side == .white ? Theme.solar : Theme.rim).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if controller.player(side).kind == "model" { Image(systemName: "cpu").foregroundStyle(Theme.voidGlow) }
                    Text(controller.displayName(side)).font(.headline).lineLimit(1)
                }.accessibilityIdentifier("name-\(side.name)")
                Text("\(side.faction) · \(captured)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let c = controller.clock {
                Text(ChessClock.format(c.remaining[side.rawValue]))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(c.remaining[side.rawValue] < 20_000 ? .red : .white)
                    .accessibilityIdentifier("clock-\(side.name)")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(toMove ? Theme.rim.opacity(0.25) : Color.white.opacity(0.04)))
    }

    private var captured: String {
        let c = controller.game.captures(by: side)
        let s = [PieceKind.queen, .rook, .bishop, .knight, .pawn].compactMap { k in c[k].map { "\(Board2DView.glyph(Piece(k, side.opposite)))×\($0)" } }
        return s.isEmpty ? "no captures" : s.joined(separator: " ")
    }
}

struct MoveList: View {
    var game: Game
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.fixed(30)), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.0) { row in
                        Text("\(row.0).").foregroundStyle(.secondary)
                        Text(row.1).id("w\(row.0)")
                        Text(row.2).id("b\(row.0)")
                    }
                }
                .font(.system(.callout, design: .monospaced))
            }
            .frame(minHeight: 90, maxHeight: 170)
            .onChange(of: game.ply) { _, _ in if let last = rows.last { proxy.scrollTo("w\(last.0)") } }
        }
        .accessibilityIdentifier("moves")
    }

    private var rows: [(Int, String, String)] {
        var out: [(Int, String, String)] = []
        var n = game.startPosition.fullmoveNumber
        var i = 0
        let ms = game.moves
        if let first = ms.first, first.side == .black { out.append((n, "…", first.san)); i = 1; n += 1 }
        while i < ms.count {
            out.append((n, ms[i].san, i + 1 < ms.count ? ms[i + 1].san : ""))
            i += 2; n += 1
        }
        return out
    }
}

struct Feed: View {
    var items: [FeedItem]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                            Text(item.source).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .id(item.id)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(color(item.kind).opacity(0.12)))
                    }
                }
            }
            .onChange(of: items.count) { _, _ in if let l = items.last { proxy.scrollTo(l.id) } }
        }
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("feed")
    }

    private func color(_ k: FeedItem.Kind) -> Color {
        switch k {
        case .battle: return Theme.accent
        case .coach, .hint: return Theme.voidGlow
        case .recap: return Theme.solar
        case .system: return .gray
        }
    }
}

struct PromotionPicker: View {
    var side: Side
    var choose: (PieceKind?) -> Void
    var body: some View {
        VStack(spacing: 14) {
            Text("Promote your Drone").font(.headline)
            HStack(spacing: 14) {
                ForEach(PieceKind.promotions, id: \.self) { k in
                    Button { choose(k) } label: {
                        VStack {
                            Text(Board2DView.glyph(Piece(k, side))).font(.system(size: 40))
                                .foregroundStyle(side == .white ? Theme.solar : Theme.rim)
                            Text(Cast.name(k, side)).font(.caption)
                        }.frame(width: 76, height: 86)
                    }
                    .accessibilityIdentifier("promote-\(k.name)")
                }
            }
            Button("Cancel", role: .cancel) { choose(nil) }
        }
        .padding(24)
    }
}

/// Spectator bar for Watch (AI vs AI): badge with the matchup, pause/resume, pace, take over.
struct WatchControls: View {
    @ObservedObject var controller: GameController
    @AppStorage(Prefs.watchDelay) private var delay = 1.2
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("SPECTATING", systemImage: "eye.fill").font(.caption.weight(.heavy))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.voidGlow.opacity(0.35)))
                    .accessibilityIdentifier("spectating")
                Text(controller.matchupLabel).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("matchup")
                Spacer()
                Button { controller.setWatchPaused(!controller.watchPaused) } label: {
                    Label(controller.watchPaused ? "Resume" : "Pause", systemImage: controller.watchPaused ? "play.fill" : "pause.fill")
                }.accessibilityIdentifier("watchPause")
                Button { controller.takeOver() } label: { Label("Take over", systemImage: "hand.raised.fill") }
                    .disabled(controller.game.isOver || controller.animating)
                    .help("Play the side to move from here; the other side keeps its engine or model.")
            }
            Picker("Pace", selection: $delay) {
                Text("Blitz").tag(0.3); Text("Normal").tag(1.2); Text("Savour").tag(3.0)
            }.pickerStyle(.segmented)
        }
        .controlSize(.small)
    }
}

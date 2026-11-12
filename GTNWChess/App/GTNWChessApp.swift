//
//  GTNWChessApp.swift
//  GTNW Chess
//
//  App entry: one restorable main window, the Settings window, and the native menus (New Game, Open/Save PGN,
//  Undo, Flip Board, 2D/3D, Full Screen, LAN, hints). Headless flags: --setup-credentials, --selftest.
//

import NovaAIKit
import SwiftUI

extension Notification.Name {
    static let gtnwCommand = Notification.Name("GTNWChess.command")
}

func post(_ cmd: String) { NotificationCenter.default.post(name: .gtnwCommand, object: cmd) }

@MainActor
enum AppLaunch {
    static var controller: GameController?

    static func shouldOfferSignIn(_ c: GameController) -> Bool {
        guard !RuntimeEnv.underXCTest, !RuntimeEnv.demo, !CommandLine.arguments.contains("--no-signin") else { return false }
        if c.outbox.sink is PGPlaySink { return false }
        return !c.site.isConfigured && !UserDefaults.standard.bool(forKey: Prefs.siteSkipped)
    }

    /// Launch arguments used for screenshots, QA and the two-instance LAN test.
    static func applyLaunchArguments(_ c: GameController) {
        let a = CommandLine.arguments
        if let fen = RuntimeEnv.argument(after: "--fen") { try? c.loadFEN(fen) }
        if let pgnPath = RuntimeEnv.argument(after: "--pgn"), let text = try? String(contentsOfFile: pgnPath, encoding: .utf8) { try? c.importPGN(text) }
        if a.contains("--2d") { c.is3D = false }
        if let lvl = RuntimeEnv.argument(after: "--vs-nova").flatMap(Int.init).flatMap(EngineLevel.init(rawValue:)) {
            var cfg = NewGameConfig(); cfg.level = lvl; cfg.playerName = Prefs.playerDisplayName; c.newGame(cfg)
        }
        if let code = RuntimeEnv.argument(after: "--lan-host") {
            _ = try? c.hostLAN(name: RuntimeEnv.argument(after: "--name") ?? Prefs.playerDisplayName, side: "white", clock: nil,
                               code: LANSecurity.isValidCode(code) ? code : nil)
        }
        if let addr = RuntimeEnv.argument(after: "--lan-join"), let code = RuntimeEnv.argument(after: "--code") {
            try? c.joinLAN(nil, address: addr, code: code, name: RuntimeEnv.argument(after: "--name") ?? Prefs.playerDisplayName)
        }
        if let script = RuntimeEnv.argument(after: "--auto-moves") {
            AutoPlayer.shared.run(script.split(separator: ",").map(String.init), controller: c)
        }
    }
}

/// Plays a scripted list of SAN moves for this Mac's side (two-instance LAN test, demos).
@MainActor
final class AutoPlayer {
    static let shared = AutoPlayer()
    private var timer: Timer?

    func run(_ sans: [String], controller c: GameController) {
        var queue = sans
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard !queue.isEmpty else { self?.timer?.invalidate(); return }
                guard c.canInteract, let m = c.game.position.move(san: queue[0]) else { return }
                queue.removeFirst()
                c.commit(m, source: .local)
            }
        }
    }
}

@main
struct GTNWChessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller: GameController
    @StateObject private var ai: NovaAI

    init() {
        CLI.runIfRequested()
        Prefs.register()
        let c = GameController()
        _controller = StateObject(wrappedValue: c)
        _ai = StateObject(wrappedValue: AppAI.shared)
        AppLaunch.controller = c
        SoundPlayer.shared.enabled = UserDefaults.standard.bool(forKey: Prefs.sound)
        SoundPlayer.shared.volume = Float(UserDefaults.standard.double(forKey: Prefs.volume))
        if !RuntimeEnv.underXCTest {
            if CommandLine.arguments.contains("--fresh") || !c.resumeSaved() {
                var cfg = NewGameConfig()
                cfg.playerName = Prefs.playerDisplayName
                c.newGame(cfg)
            }
            AppLaunch.applyLaunchArguments(c)
            c.outbox.flush()
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in c.outbox.flush() } }
        }
    }

    var body: some Scene {
        Window("GTNW Chess", id: "main") {
            ContentView(controller: controller, ai: ai)
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Game…") { post("new") }.keyboardShortcut("n")
                Button("Open PGN…") { post("open") }.keyboardShortcut("o")
                Button("Save PGN…") { post("save") }.keyboardShortcut("s")
                Divider()
                Button("Host LAN Game…") { post("host") }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Join LAN Game…") { post("join") }.keyboardShortcut("j", modifiers: [.command, .shift])
                Divider()
                Button("Set Up Position (FEN)…") { post("fen") }
                Button("Copy FEN") { post("copyfen") }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Copy PGN") { post("copypgn") }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Move (Takeback)") { post("undo") }.keyboardShortcut("z")
            }
            CommandGroup(after: .toolbar) {
                Button("Flip Board") { post("flip") }.keyboardShortcut("f", modifiers: [.command, .option])
                Button("Toggle 2D / 3D") { post("toggle3d") }.keyboardShortcut("d", modifiers: [.command, .option])
                Button("Reset Camera") { post("resetcam") }.keyboardShortcut("0")
                Button("Skip Battle") { post("skip") }.keyboardShortcut(.escape, modifiers: [])
                Divider()
                Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.keyboardShortcut("f", modifiers: [.command, .control])
            }
            CommandMenu("Game") {
                Button("Hint") { post("hint") }.keyboardShortcut("h")
                Button("Offer Draw") { post("draw") }
                Button("Resign…") { post("resign") }
                Divider()
                Button("Sign In to Nova Games…") { post("signin") }
            }
        }
        Settings {
            SettingsView(controller: controller, ai: ai)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppLaunch.controller?.autosave()
            AppLaunch.controller?.lan.stop()
        }
        let engine = MainActor.assumeIsolated { AppLaunch.controller?.engine }
        let done = DispatchSemaphore(value: 0)
        Task.detached { await engine?.shutdown(); done.signal() }
        _ = done.wait(timeout: .now() + 1.5)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// Headless commands (exit without showing UI).
enum CLI {
    static func runIfRequested() {
        let a = CommandLine.arguments
        if a.contains("--setup-credentials") {
            do { print("GTNW Chess play-history credentials: \(try PlayCredentials.setupFromCore3())") ; exit(0) }
            catch { print(error.localizedDescription); exit(1) }
        }
        if a.contains("--selftest") {
            let p = Position.start
            let ok = p.perft(3) == 8902 && UCIEngine.locate() != nil
            print("selftest perft(3)=\(p.perft(3)) stockfish=\(UCIEngine.locate()?.path ?? "missing")")
            exit(ok ? 0 : 1)
        }
    }
}

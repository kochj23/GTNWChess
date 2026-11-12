//
//  Sheets.swift
//  GTNW Chess
//
//  New game, LAN host/join, Nova Games sign-in and FEN sheets.
//

import SwiftUI

struct NewGameSheet: View {
    @ObservedObject var controller: GameController
    var done: () -> Void
    @State private var c = NewGameConfig()
    @State private var useClock = false
    @State private var clockIndex = 2

    var body: some View {
        Form {
            Picker("Mode", selection: $c.mode) {
                Text("vs Nova").tag(GameMode.vsNova)
                Text("Hot-seat (2 players, this Mac)").tag(GameMode.hotseat)
            }
            TextField("Your name", text: $c.playerName)
            if c.mode == .vsNova {
                Picker("Nova's level", selection: $c.level) {
                    ForEach(EngineLevel.allCases) { l in Text("\(l.rawValue). \(l.name) — \(l.blurb)").tag(l) }
                }
                Picker("You play", selection: $c.side) {
                    Text("Solar (white)").tag("white"); Text("Void (black)").tag("black"); Text("Random").tag("random")
                }
                if !controller.engine.hasStockfish {
                    Text("Stockfish isn't bundled in this build; Nova uses the built-in engine.").font(.caption).foregroundStyle(.orange)
                }
            } else {
                TextField("Second player (Void)", text: $c.opponentName)
            }
            Toggle("Chess clock", isOn: $useClock)
            if useClock {
                Picker("Time control", selection: $clockIndex) {
                    ForEach(ClockConfig.presets.indices, id: \.self) { i in Text(ClockConfig.presets[i].label).tag(i) }
                }
            }
            HStack {
                Button("Cancel", role: .cancel, action: done)
                Spacer()
                Button("Start") {
                    c.clock = useClock ? ClockConfig.presets[clockIndex] : nil
                    UserDefaults.standard.set(c.playerName, forKey: Prefs.playerName)
                    controller.newGame(c)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("startGame")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .onAppear { c.playerName = Prefs.playerDisplayName; c.level = controller.level }
    }
}

struct HostLANSheet: View {
    @ObservedObject var controller: GameController
    var done: () -> Void
    @State private var name = Prefs.playerDisplayName
    @State private var side = "white"
    @State private var useClock = false
    @State private var clockIndex = 2
    @State private var error: String?

    var body: some View {
        Form {
            Text("Host a game on this Mac. The other Mac finds it over Bonjour and joins with the pairing code shown here.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Your name", text: $name)
            Picker("You play", selection: $side) {
                Text("Solar (white)").tag("white"); Text("Void (black)").tag("black"); Text("Random").tag("random")
            }
            Toggle("Chess clock", isOn: $useClock)
            if useClock {
                Picker("Time control", selection: $clockIndex) {
                    ForEach(ClockConfig.presets.indices, id: \.self) { i in Text(ClockConfig.presets[i].label).tag(i) }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel", role: .cancel, action: done)
                Spacer()
                Button("Host") {
                    do {
                        UserDefaults.standard.set(name, forKey: Prefs.playerName)
                        _ = try controller.hostLAN(name: name, side: side, clock: useClock ? ClockConfig.presets[clockIndex] : nil)
                        done()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped).frame(width: 440).padding()
    }
}

struct JoinLANSheet: View {
    @ObservedObject var controller: GameController
    @ObservedObject var lan: LANSession
    var done: () -> Void
    @State private var name = Prefs.playerDisplayName
    @State private var code = ""
    @State private var picked: LANSession.Found?
    @State private var address = ""
    @State private var error: String?

    init(controller: GameController, done: @escaping () -> Void) {
        self.controller = controller
        self.lan = controller.lan
        self.done = done
    }

    var body: some View {
        Form {
            TextField("Your name", text: $name)
            Picker("Host", selection: $picked) {
                Text(lan.found.isEmpty ? "Searching…" : "Choose a host").tag(LANSession.Found?.none)
                ForEach(lan.found) { f in Text(f.name).tag(LANSession.Found?.some(f)) }
            }
            TextField("…or address (host:port)", text: $address)
            TextField("Pairing code", text: $code).font(.system(.body, design: .monospaced))
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel", role: .cancel) { lan.stop(); done() }
                Spacer()
                Button("Join") {
                    do {
                        UserDefaults.standard.set(name, forKey: Prefs.playerName)
                        try controller.joinLAN(picked, address: address.isEmpty ? nil : address, code: code, name: name)
                        done()
                    } catch { self.error = error.localizedDescription }
                }
                .disabled(!LANSecurity.isValidCode(code) || (picked == nil && address.isEmpty))
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped).frame(width: 440).padding()
        .onAppear { controller.stopLAN(); lan.browse() }
    }
}

/// First-run sign-in to Nova Games (roaming Macs without the LAN DB role). Skippable; play is never blocked.
struct SignInSheet: View {
    let client: GamesSiteClient
    var done: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to Nova Games").font(.title2.bold())
            Text("Your finished games go to the Nova Games history so Nova can review them. Your password is kept only in this Mac's Keychain. Until you sign in (or when the server is away), results wait in a local queue — play is never blocked.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Username", text: $username).textContentType(.username)
            SecureField("Password", text: $password).textContentType(.password)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Play without signing in") { UserDefaults.standard.set(true, forKey: Prefs.siteSkipped); done() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Sign In") {
                    busy = true
                    Task {
                        do { try await client.signIn(username: username, password: password); password = ""; done() }
                        catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty || password.count < 10 || busy)
            }
        }
        .padding(24).frame(width: 440)
    }
}

struct FENSheet: View {
    @ObservedObject var controller: GameController
    var done: () -> Void
    @State private var fen = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up a position (FEN)").font(.headline)
            TextField("FEN", text: $fen).font(.system(.body, design: .monospaced))
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel", role: .cancel, action: done)
                Spacer()
                Button("Load") {
                    do { try controller.loadFEN(fen); done() } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { fen = controller.game.position.fen }
    }
}

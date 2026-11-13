//
//  SettingsView.swift
//  GTNW Chess
//
//  Settings window: Graphics, Animation, Sound, Coach, Nova Games (play history, sign-in, review consent) and AI
//  (NovaAISettingsView), plus Acknowledgements (Stockfish GPLv3 notice and source offer).
//

import NovaAIKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: GameController
    @ObservedObject var ai: NovaAI

    var body: some View {
        TabView {
            GraphicsSettings().tabItem { Label("Graphics", systemImage: "cube.transparent") }
            AnimationSettings().tabItem { Label("Animation", systemImage: "bolt") }
            SoundSettings().tabItem { Label("Sound", systemImage: "speaker.wave.2") }
            CoachSettings().tabItem { Label("Coach", systemImage: "graduationcap") }
            GamesDBSettings(controller: controller, outbox: controller.outbox).tabItem { Label("Nova Games", systemImage: "trophy") }
            NovaAISettingsView(ai: ai, footer: "When AI is off or no backend answers, Nova's coach, battle banter and recaps use GTNW Chess's built-in script. AI only explains and narrates: Stockfish decides every move, and any move or square the AI mentions is checked against the real position. Keys stay in the Keychain (com.jkoch.gtnwchess.*) and only go over https. Turn off Allow Nova to run with no Nova dependency at all; Watch's language-model sides then use the other backends (local Ollama/MLX first, cloud only with your key).")
                .tabItem { Label("AI", systemImage: "sparkles") }
            AcknowledgementsView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 560)
    }
}

struct GraphicsSettings: View {
    @AppStorage(Prefs.antialias) private var antialias = true
    @AppStorage(Prefs.shadows) private var shadows = true
    var body: some View {
        Form {
            Toggle("Anti-aliasing (4× MSAA)", isOn: $antialias)
            Toggle("Soft shadows", isOn: $shadows)
            Text("View › 2D Board (⌘2) switches to a flat study board; ⌘3 returns to 3D. Drag to orbit the 3D camera, scroll to zoom.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

struct AnimationSettings: View {
    @AppStorage(Prefs.battles) private var battles = true
    @AppStorage(Prefs.speed) private var speed = 1.0
    @AppStorage(Prefs.camera) private var camera = true
    @AppStorage(Prefs.carnage) private var carnage = 2
    var body: some View {
        Form {
            Toggle("Play capture battles", isOn: $battles).accessibilityIdentifier("battlesToggle")
            Text("Off = skip animations: captures resolve instantly.").font(.caption).foregroundStyle(.secondary)
            Picker("Battle speed", selection: $speed) {
                ForEach(AnimationPrefs.speeds, id: \.self) { s in Text("\(s, specifier: "%g")×").tag(s) }
            }
            Toggle("Cinematic battle camera", isOn: $camera)
            Picker("Carnage", selection: $carnage) {
                ForEach(AnimationPrefs.carnageLevels.indices, id: \.self) { i in Text(AnimationPrefs.carnageLevels[i]).tag(i) }
            }.accessibilityIdentifier("carnagePicker")
            Text("Brutal and Maximum add screen shake, hydraulic-fluid spray, torn-off parts and scorch marks that stay on the board.").font(.caption).foregroundStyle(.secondary)
            Text("Click the board, press Space or Esc, or use the banner's Skip to end a battle early.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

struct SoundSettings: View {
    @AppStorage(Prefs.sound) private var sound = true
    @AppStorage(Prefs.volume) private var volume = 0.8
    var body: some View {
        Form {
            Toggle("Sound effects", isOn: $sound)
            Slider(value: $volume, in: 0...1) { Text("Volume") }
            Button("Test sound") { SoundPlayer.shared.play(.orbital) }
            Text("Every sound is synthesised on this Mac (AVAudioEngine); no samples are shipped.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: sound) { _, v in SoundPlayer.shared.enabled = v }
        .onChange(of: volume) { _, v in SoundPlayer.shared.volume = Float(v) }
    }
}

struct CoachSettings: View {
    @AppStorage(Prefs.coachAuto) private var auto = true
    @AppStorage(Prefs.showThreats) private var threats = true
    @AppStorage(Prefs.legalHints) private var legal = true
    @AppStorage(Prefs.playerName) private var name = ""
    var body: some View {
        Form {
            TextField("Your display name", text: $name, prompt: Text(PlayerInfo.defaultName))
            Toggle("Highlight legal moves", isOn: $legal)
            Toggle("Highlight pieces under attack", isOn: $threats)
            Toggle("Nova explains every move automatically", isOn: $auto)
            Text("The coach is per player and stays on this Mac; in LAN games each Mac coaches its own player.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

struct GamesDBSettings: View {
    @ObservedObject var controller: GameController
    @ObservedObject var outbox: PlayOutbox
    @State private var consent = false
    @State private var firstName = ""
    @State private var consentStatus: String?
    @State private var signedIn = false
    @State private var showSignIn = false

    var body: some View {
        Form {
            Section("Play history") {
                LabeledContent("Writes to", value: controller.playSinkLabel)
                LabeledContent("Queued", value: "\(outbox.pending.count) item(s)")
                LabeledContent("Written", value: "\(outbox.written)")
                if let e = outbox.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                Button("Send queued results now") { outbox.flush() }
            }
            if !(controller.outbox.sink is PGPlaySink) {
                Section("Nova Games account") {
                    if signedIn, let u = controller.site.username {
                        LabeledContent("Signed in as", value: u)
                        Button("Sign out") { Task { await controller.site.signOut(); signedIn = false } }
                    } else {
                        Button("Sign in…") { showSignIn = true }
                    }
                }
                Section("Nova's reviews") {
                    Toggle("Name me in Nova's reviews", isOn: $consent)
                        .disabled(!signedIn)
                        .accessibilityIdentifier("consentToggle")
                    TextField("First name to use", text: $firstName).disabled(!signedIn || !consent)
                    Text("Off (default): Nova's published columns call you \"the challenger\". On: only this first name, only in reviews of games you played. Turning it off affects future columns only. Saved on your Nova Games account.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save") { save() }.disabled(!signedIn)
                    if let s = consentStatus { Text(s).font(.caption) }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showSignIn) { SignInSheet(client: controller.site) { showSignIn = false; signedIn = controller.site.isConfigured; load() } }
        .onAppear { signedIn = controller.site.isConfigured; load() }
    }

    private func load() {
        guard signedIn else { return }
        Task {
            do {
                let c = try await controller.site.getConsent()
                consent = c.nameInReviews
                firstName = c.displayName ?? PlayerInfo.defaultName
                consentStatus = nil
            } catch { consentStatus = "Couldn't load: \(error.localizedDescription)" }
        }
    }

    private func save() {
        let want = ConsentForm.make(nameInReviews: consent, firstName: firstName)
        Task {
            do {
                let c = try await controller.site.setConsent(want)
                consent = c.nameInReviews
                consentStatus = c.nameInReviews ? "Saved: Nova may name you as \(c.displayName ?? "you")." : "Saved: you stay \"the challenger\"."
            } catch { consentStatus = "Not saved: \(error.localizedDescription)" }
        }
    }
}

/// The consent payload: OFF never sends a name; ON sends only a first name.
enum ConsentForm {
    static func make(nameInReviews: Bool, firstName: String) -> GamesSiteClient.Consent {
        guard nameInReviews else { return GamesSiteClient.Consent(nameInReviews: false, displayName: nil) }
        let first = firstName.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let clean = String(first.filter { $0.isLetter || $0 == "'" || $0 == "-" || $0 == "." }.prefix(40))
        return GamesSiteClient.Consent(nameInReviews: !clean.isEmpty, displayName: clean.isEmpty ? nil : clean)
    }
}

struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("GTNW Chess \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))").font(.headline)
                Text("An original chess game by Jordan Koch: the Solar and Void robot fleets settle every capture in battle. Inspired by the classic animated-chess games of the late '80s.")
                Text("Stockfish").font(.headline)
                Text(Self.stockfishNotice).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }.padding()
        }
    }

    static var stockfishNotice: String {
        guard let url = Bundle.main.url(forResource: "SOURCE", withExtension: "txt", subdirectory: "Stockfish"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            return "Stockfish is free software under the GNU GPL v3. Source: https://github.com/official-stockfish/Stockfish"
        }
        return s + "\nFull license: Contents/Resources/Stockfish/COPYING.txt"
    }
}

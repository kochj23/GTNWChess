//
//  KeyBindings.swift
//  GTNW Chess
//
//  Remappable gameplay shortcuts (Settings › Keys). Each one is a UserDefaults string such as "cmd+opt+f", registered
//  with the other preferences in `Prefs.register`, so the defaults are today's keys and "Reset to defaults" just
//  removes the overrides. File and window shortcuts (New, Open, Save, LAN, Copy FEN, Full Screen) stay fixed.
//

import AppKit
import SwiftUI

/// A gameplay command whose shortcut the player can change.
enum GameKey: String, CaseIterable, Identifiable {
    case hint, undo, flip, toggle3D, resetCamera, skipBattle

    var id: String { rawValue }
    var prefKey: String { "keys.\(rawValue)" }

    var title: String {
        switch self {
        case .hint: "Hint"
        case .undo: "Undo Move (Takeback)"
        case .flip: "Flip Board"
        case .toggle3D: "Toggle 2D / 3D"
        case .resetCamera: "Reset Camera"
        case .skipBattle: "Skip Battle"
        }
    }

    /// The menu shortcut before shortcuts became remappable.
    var defaultCombo: KeyCombo {
        switch self {
        case .hint: KeyCombo(key: "h", command: true)
        case .undo: KeyCombo(key: "z", command: true)
        case .flip: KeyCombo(key: "f", command: true, option: true)
        case .toggle3D: KeyCombo(key: "d", command: true, option: true)
        case .resetCamera: KeyCombo(key: "0", command: true)
        case .skipBattle: KeyCombo(key: KeyCombo.escape)
        }
    }
}

/// One key plus modifiers, stored as "cmd+shift+opt+ctrl+<key>" (modifiers in that order, key lowercase or "esc").
struct KeyCombo: Hashable {
    static let escape = "esc"
    var key: String
    var command = false, shift = false, option = false, control = false

    init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key.lowercased()
        self.command = command; self.shift = shift; self.option = option; self.control = control
    }

    init?(_ stored: String) {
        var parts = stored.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "+" itself can be a key: "cmd++" splits into ["cmd", "", ""].
        if parts.count >= 2, parts.suffix(2) == ["", ""] { parts.removeLast(2); parts.append("+") }
        guard let key = parts.popLast() else { return nil }
        self.init(key: key)
        for m in parts {
            switch m {
            case "cmd": command = true
            case "shift": shift = true
            case "opt": option = true
            case "ctrl": control = true
            default: return nil
            }
        }
        guard isValid else { return nil }
    }

    /// From a key press captured in Settings.
    init?(event: NSEvent) {
        let f = event.modifierFlags
        let key = event.keyCode == 53 ? KeyCombo.escape : (event.characters(byApplyingModifiers: []) ?? "")
        self.init(key: key, command: f.contains(.command), shift: f.contains(.shift), option: f.contains(.option),
                  control: f.contains(.control))
        guard isValid else { return nil }
    }

    var stored: String {
        ([command ? "cmd" : nil, shift ? "shift" : nil, option ? "opt" : nil, control ? "ctrl" : nil].compactMap { $0 } + [key])
            .joined(separator: "+")
    }

    /// Esc on its own, or one visible character with ⌘ or ⌃ (a bare letter would swallow typing in text fields).
    var isValid: Bool {
        if key == KeyCombo.escape { return true }
        guard key.count == 1, let c = key.unicodeScalars.first, c.properties.isAlphabetic || c.isASCII,
              !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains(c) else { return false }
        return command || control
    }

    /// "⌘⌥F", "Esc".
    var label: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + (key == KeyCombo.escape ? "Esc" : key.uppercased())
    }

    var shortcut: KeyboardShortcut {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return KeyboardShortcut(key == KeyCombo.escape ? .escape : KeyEquivalent(Character(key)), modifiers: m)
    }
}

enum KeyBindings {
    enum BindError: LocalizedError, Equatable {
        case invalid
        case taken(String)

        var errorDescription: String? {
            switch self {
            case .invalid: "Use Esc, or a key with ⌘ or ⌃."
            case .taken(let what): "That shortcut is already used by \(what)."
            }
        }
    }

    /// Fixed menu and system shortcuts a gameplay key may not take.
    static let reserved: [String: String] = [
        "cmd+n": "New Game", "cmd+o": "Open PGN", "cmd+s": "Save PGN", "cmd+shift+h": "Host LAN Game",
        "cmd+shift+j": "Join LAN Game", "cmd+shift+c": "Copy FEN", "cmd+ctrl+f": "Toggle Full Screen",
        "cmd+q": "Quit", "cmd+w": "Close Window", "cmd+,": "Settings", "cmd+m": "Minimize",
    ]

    static var registrationDefaults: [String: Any] {
        Dictionary(uniqueKeysWithValues: GameKey.allCases.map { ($0.prefKey, $0.defaultCombo.stored) })
    }

    static func combo(_ k: GameKey, in d: UserDefaults = .standard) -> KeyCombo {
        d.string(forKey: k.prefKey).flatMap(KeyCombo.init) ?? k.defaultCombo
    }

    /// Saves `c` for `k`, refusing invalid keys and any shortcut another command already uses.
    static func set(_ c: KeyCombo, for k: GameKey, in d: UserDefaults = .standard) throws {
        guard c.isValid else { throw BindError.invalid }
        if let other = GameKey.allCases.first(where: { $0 != k && combo($0, in: d) == c }) { throw BindError.taken(other.title) }
        if let fixed = reserved[c.stored] { throw BindError.taken(fixed) }
        d.set(c.stored, forKey: k.prefKey)
    }

    static func resetToDefaults(in d: UserDefaults = .standard) {
        for k in GameKey.allCases { d.removeObject(forKey: k.prefKey) }
    }
}

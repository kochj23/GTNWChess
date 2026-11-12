//
//  Credentials.swift
//  GTNW Chess
//
//  Keychain-only secrets for play history (never UserDefaults, files, logs or errors):
//  - Little Mister's Macs (.6/.99) write straight to the Games DB as the LAN role `gtnwchess_mac`. Its password lives
//    in the login keychain, service `nova-games-pg`, account `gtnwchess_mac` (the GTNW ad hoc convention), put
//    there once with `--setup-credentials` (SSH hand-off from core3, BatchMode, the value never printed).
//  - A roaming Mac signs in to the Nova Games site; that password is stored under
//    `com.jkoch.gtnwchess.gamessite`, account = the site username.
//

import Foundation
import Security

protocol SecretStore: Sendable {
    func read(service: String, account: String) -> String?
    func write(_ value: String, service: String, account: String) -> OSStatus
    func delete(service: String, account: String)
    func accounts(service: String) -> [String]
}

/// The login keychain (works for ad hoc builds: no access group needed).
struct LoginKeychain: SecretStore {
    func base(_ service: String, _ account: String?) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        if let account { q[kSecAttrAccount] = account }
        return q
    }

    func read(service: String, account: String) -> String? {
        var q = base(service, account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    func write(_ value: String, service: String, account: String) -> OSStatus {
        let data = Data(value.utf8)
        var st = SecItemUpdate(base(service, account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if st == errSecItemNotFound {
            var add = base(service, account)
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel] = "GTNW Chess (\(account))"
            st = SecItemAdd(add as CFDictionary, nil)
        }
        return st
    }

    func delete(service: String, account: String) { SecItemDelete(base(service, account) as CFDictionary) }

    func accounts(service: String) -> [String] {
        var q = base(service, nil)
        q[kSecReturnAttributes] = true
        q[kSecMatchLimit] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}

/// In-memory store for tests.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: String] = [:]
    private let lock = NSLock()
    init() {}
    func read(service: String, account: String) -> String? { lock.withLock { items["\(service)|\(account)"] } }
    func write(_ value: String, service: String, account: String) -> OSStatus {
        lock.withLock { items["\(service)|\(account)"] = value }
        return errSecSuccess
    }
    func delete(service: String, account: String) { _ = lock.withLock { items.removeValue(forKey: "\(service)|\(account)") } }
    func accounts(service: String) -> [String] {
        lock.withLock { items.keys.filter { $0.hasPrefix(service + "|") }.map { String($0.dropFirst(service.count + 1)) }.sorted() }
    }
}

enum PlayCredentials {
    static let pgService = "nova-games-pg"
    static let pgRole = "gtnwchess_mac"
    static let siteService = "com.jkoch.gtnwchess.gamessite"
    static let sshTarget = "kochj@192.168.1.5"
    static let remoteCommand = "sudo bash /srv/games/repo/deploy/remote.sh getpw"

    /// One line, printable ASCII, no spaces, 8...256 chars.
    static func isPlausible(_ s: String) -> Bool {
        (8...256).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.asciiValue ?? 0) > 0x20 && ($0.asciiValue ?? 0) < 0x7F }
    }

    static func isValidUsername(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) != nil
    }

    /// `--setup-credentials`: fetch the play-history role password from core3 over SSH (BatchMode, never prompts)
    /// and store it in the login keychain. Prints only a status line, never the value.
    static func setupFromCore3(store: SecretStore = LoginKeychain(), timeout: TimeInterval = 20) throws -> String {
        if store.read(service: pgService, account: pgRole) != nil { return "already stored" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", sshTarget, "\(remoteCommand) \(pgRole)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); throw PlayError.setup("ssh to core3 timed out") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let pw = String(decoding: data.prefix(1024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, isPlausible(pw) else { throw PlayError.setup("ssh getpw failed (exit \(p.terminationStatus))") }
        let st = store.write(pw, service: pgService, account: pgRole)
        guard st == errSecSuccess else { throw PlayError.setup("Keychain error \(st)") }
        return "stored"
    }
}

enum PlayError: Error, Equatable, LocalizedError {
    case setup(String)
    case notConfigured
    case http(Int, String)
    case network(String)
    case permanent(String)

    var errorDescription: String? {
        switch self {
        case .setup(let s): return "Credential setup failed: \(s)"
        case .notConfigured: return "Play history isn't set up on this Mac"
        case .http(let c, let e): return "Nova Games answered \(c) \(e)"
        case .network(let s): return "Nova Games unreachable: \(s)"
        case .permanent(let s): return "Nova Games rejected the data: \(s)"
        }
    }

    /// Worth retrying later (the outbox keeps the item).
    var isTransient: Bool {
        switch self {
        case .network, .notConfigured: return true
        case .http(let c, _): return c == 429 || c >= 500 || c == 401 || c == 403
        default: return false
        }
    }
}

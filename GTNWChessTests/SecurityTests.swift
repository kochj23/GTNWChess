//
//  SecurityTests.swift
//  GTNWChessTests
//
//  Keychain naming, https-only keys, input validation at every trust boundary (FEN, PGN, UCI, LAN frames and moves,
//  site sign-in), consent privacy, and a scan of the sources for secrets and household names.
//

import XCTest
import NovaAIKit
@testable import GTNWChess

@MainActor
final class SecurityTests: XCTestCase {
    override func tearDown() { StubHTTP.reset() }

    func testKeychainServicesAreNamespaced() {
        for b in [NovaAIBackend.openRouter, .openAI, .openWebUI] {
            XCTAssertTrue(AppAI.configuration.keychainService(for: b).hasPrefix("com.jkoch.gtnwchess."), b.rawValue)
        }
        XCTAssertTrue(PlayCredentials.siteService.hasPrefix("com.jkoch.gtnwchess."))
    }

    func testAIKeyNeverSentOverPlainHTTP() async {
        let ai = TestEnv.stubbedAI()
        ai.settings.backend = .openRouter
        ai.settings.setURL("http://openrouter.example.test/api/v1", for: .openRouter)
        ai.keys.setKey("sk-or-test-not-real-0000", for: .openRouter)
        StubHTTP.respond { _ in (200, TestEnv.ollamaReply("hello there friend")) }
        let r = await NovaNarrator(ai: ai).coach(game: Game(), playerName: "Tester")
        XCTAssertFalse(r.isAI)
        XCTAssertFalse(StubHTTP.requests.contains { $0.headers["Authorization"] != nil }, "a key went over http")
    }

    func testShippedDefaultsCarryNoKeys() {
        let ai = AppAI.makeShared()
        for b in NovaAIBackend.allCases { XCTAssertFalse(ai.keys.hasKey(for: b), b.rawValue) }
        XCTAssertFalse(AppAI.configuration.defaultSettings.urls.values.contains { $0.contains("@") }, "no credentials in URLs")
    }

    func testUCIInputValidationBlocksInjection() {
        XCTAssertThrowsError(try UCIEngine.validate(fen: Position.startFEN + "\nquit"))
        XCTAssertThrowsError(try UCIEngine.validate(fen: "not a fen"))
        XCTAssertThrowsError(try UCIEngine.validate(moves: ["e2e4", "e7e5\nposition startpos"]))
        XCTAssertThrowsError(try UCIEngine.validate(moves: ["e2e4; rm"]))
        XCTAssertNoThrow(try UCIEngine.validate(moves: ["e2e4", "e7e8q"]))
    }

    func testPGNSizeLimitAndJunk() {
        let huge = String(repeating: "1. e4 e5 ", count: 200_000)
        XCTAssertThrowsError(try PGN.importGame(huge))
        XCTAssertThrowsError(try PGN.importGame("1. e4 e5 2. Ke3 Qh4 3. Kxh4"))
        XCTAssertThrowsError(try PGN.importGame("[FEN \"rubbish\"]\n[SetUp \"1\"]\n\n1. e4"))
    }

    func testLANRefereeRejectsOutOfTurnIllegalAndStale() throws {
        let g = try Fixtures.game(["e4"])
        XCTAssertEqual(LANReferee.check(ply: 2, uci: "d2d4", game: g, remoteSide: .white), .reject("not your turn"))
        if case .reject = LANReferee.check(ply: 2, uci: "e7e4", game: g, remoteSide: .black) {} else { XCTFail("illegal accepted") }
        if case .reject = LANReferee.check(ply: 5, uci: "e7e5", game: g, remoteSide: .black) {} else { XCTFail("stale ply accepted") }
        if case .reject = LANReferee.check(ply: 2, uci: "e7e5qqqqq", game: g, remoteSide: .black) {} else { XCTFail("overlong accepted") }
        let over = try Fixtures.game(Fixtures.foolsMate)
        XCTAssertEqual(LANReferee.check(ply: 5, uci: "a2a3", game: over, remoteSide: .white), .reject("game over"))
    }

    func testLANFrameLimits() throws {
        var big = Data([0x7F, 0xFF, 0xFF, 0xFF]) + Data(repeating: 0x20, count: 16)
        XCTAssertThrowsError(try LANCodec.decode(&big)) { XCTAssertEqual($0 as? LANError, .tooLarge) }
        var zero = Data([0, 0, 0, 0])
        XCTAssertThrowsError(try LANCodec.decode(&zero))
        var junk = Data([0, 0, 0, 3]) + Data("abc".utf8)
        XCTAssertThrowsError(try LANCodec.decode(&junk))
        XCTAssertThrowsError(try LANCodec.encode(.hello(proto: 1, name: String(repeating: "x", count: 70_000), account: nil, gameID: nil, haveplies: nil)))
    }

    func testPSKDependsOnCode() {
        let a = LANSecurity.psk(code: "123456").withUnsafeBytes { Data($0) }
        let b = LANSecurity.psk(code: "123457").withUnsafeBytes { Data($0) }
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, Data("123456".utf8), "the code itself is never the key")
    }

    func testLANHostRejectsBadCode() {
        let s = LANSession()
        XCTAssertThrowsError(try s.host(code: "12ab56", serviceName: "x", advertise: false)) { XCTAssertEqual($0 as? LANError, .badCode) }
    }

    func testRemoteMovesAreRefereedByController() throws {
        let c = TestEnv.controller()
        var cfg = NewGameConfig(); cfg.mode = .lan; cfg.side = "white"; c.newGame(cfg)
        // Not connected: an injected "remote" move for white (our side) and an illegal black move are ignored.
        c.handleLAN(.move(ply: 1, uci: "e2e4", clockMs: nil))
        XCTAssertEqual(c.game.ply, 0)
        c.handleLAN(.move(ply: 1, uci: "e7e5", clockMs: nil))
        XCTAssertEqual(c.game.ply, 0)
        c.stopLAN()
    }

    func testSignInValidatesBeforeNetwork() async {
        let site = GamesSiteClient(store: MemorySecretStore(), protocolClasses: [StubHTTP.self])
        StubHTTP.respond { _ in (200, StubHTTP.json([:])) }
        for (u, p) in [("ab", "longenoughpw"), ("Robert'); DROP", "longenoughpw"), ("guest", "short")] {
            do { try await site.signIn(username: u, password: p); XCTFail("accepted \(u)") } catch {}
        }
        XCTAssertTrue(StubHTTP.requests.isEmpty, "nothing was sent")
    }

    func testSitePostsCarryOriginAndCSRFAndPasswordStaysInStore() async throws {
        let store = MemorySecretStore()
        let site = GamesSiteClient(store: store, protocolClasses: [StubHTTP.self])
        StubHTTP.respond { r in
            if r.url.path.hasSuffix("auth/csrf") { return (200, StubHTTP.json(["csrf": "tok123"])) }
            return (200, StubHTTP.json(["ok": true]))
        }
        try await site.signIn(username: "challenger", password: "correct-horse-battery")
        let post = try XCTUnwrap(StubHTTP.requests.first { $0.method == "POST" })
        XCTAssertEqual(post.headers["Origin"], GamesSiteClient.origin)
        XCTAssertEqual(post.headers["X-CSRF-Token"], "tok123")
        XCTAssertEqual(store.read(service: PlayCredentials.siteService, account: "challenger"), "correct-horse-battery")
        XCTAssertFalse(StubHTTP.requests.contains { $0.url.absoluteString.contains("correct-horse") }, "password only in the body")
        XCTAssertTrue(GamesSiteClient.base.absoluteString.hasPrefix("https://"))
    }

    func testConsentOffNeverSendsAName() async throws {
        let store = MemorySecretStore()
        _ = store.write("correct-horse-battery", service: PlayCredentials.siteService, account: "challenger")
        let site = GamesSiteClient(store: store, protocolClasses: [StubHTTP.self])
        StubHTTP.respond { r in
            if r.url.path.hasSuffix("auth/csrf") { return (200, StubHTTP.json(["csrf": "t"])) }
            let body = jsonObject(r.body)
            return (200, StubHTTP.json(["name_in_reviews": body["name_in_reviews"] ?? false, "display_name": body["display_name"] ?? NSNull()]))
        }
        let off = try await site.setConsent(ConsentForm.make(nameInReviews: false, firstName: "Householdname"))
        XCTAssertEqual(off, GamesSiteClient.Consent(nameInReviews: false, displayName: nil))
        let put = try XCTUnwrap(StubHTTP.requests.last { $0.method == "PUT" })
        XCTAssertFalse(String(decoding: put.body, as: UTF8.self).contains("Householdname"))
        let on = try await site.setConsent(ConsentForm.make(nameInReviews: true, firstName: "Jo Smith"))
        XCTAssertEqual(on.displayName, "Jo")
        XCTAssertFalse(String(decoding: StubHTTP.requests.last { $0.method == "PUT" }!.body, as: UTF8.self).contains("Smith"), "first name only")
    }

    func testLANGuestNameAndAccountAreSanitised() {
        let p = PlayerInfo.human("Eve\u{0000}\u{001B}[31m" + String(repeating: "!", count: 80), local: false, account: nil)
        XCTAssertFalse(p.name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertLessThanOrEqual(p.name.count, 32)
        XCTAssertFalse(PlayCredentials.isValidUsername("../etc"))
        XCTAssertTrue(PlayCredentials.isValidUsername("challenger"))
    }

    func testCredentialPlausibilityRejectsMultiline() {
        XCTAssertFalse(PlayCredentials.isPlausible("abc"))
        XCTAssertFalse(PlayCredentials.isPlausible("abcdefgh\nrm -rf"))
        XCTAssertTrue(PlayCredentials.isPlausible("Xy7_long-enough"))
    }

    /// No API keys, private keys, passwords or household names in the shipped sources.
    func testSourcesHoldNoSecretsOrHouseholdNames() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("GTNWChess")
        // The test runner can block forever on a network volume macOS won't let it read: read off-thread, time-bound,
        // and skip (the same scan is run by hand before release) rather than hang the suite.
        let read = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var texts: [(String, String)] = [] }
        let box = Box()
        Thread.detachNewThread {
            let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects ?? []).compactMap { $0 as? URL }
                .filter { ["swift", "plist", "txt"].contains($0.pathExtension) }
            box.texts = files.compactMap { f in (try? String(contentsOf: f, encoding: .utf8)).map { (f.lastPathComponent, $0) } }
            read.signal()
        }
        guard read.wait(timeout: .now() + 60) == .success, case let texts = box.texts, !texts.isEmpty else {
            throw XCTSkip("sources unreadable from the test runner (\(root.path)); scan them by hand")
        }
        XCTAssertGreaterThan(texts.count, 20)
        let patterns = [#"sk-or-v1-[A-Za-z0-9]{16}"#, #"sk-[A-Za-z0-9]{32}"#, "BEGIN (RSA |EC )?PRIVATE KEY", #"password\s*=\s*"[^"]{6,}""#,
                        #"\b"# + String(decoding: Data(base64Encoded: "QW15")!, as: UTF8.self) + #"\b"#]  // a household name, kept out of this public repo
        for (name, text) in texts {
            for p in patterns { XCTAssertNil(text.range(of: p, options: .regularExpression), "\(p) in \(name)") }
        }
    }

    func testBundledCAsArePresentAndParse() {
        XCTAssertNotNil(PGConnection.certificate(fromPEM: GamesSiteClient.bundledCA()))
        XCTAssertNotNil(PGConnection.certificate(fromPEM: PGConfig.bundledCA()))
    }
}

@MainActor
final class SecurityAIReplyTests: XCTestCase {
    override func tearDown() { StubHTTP.reset() }

    func testErrorBoilerplateFromABackendNeverReachesTheCoach() async throws {
        let ai = TestEnv.stubbedAI()
        let g = try Fixtures.game(["e4", "e5", "Nf3"])
        for reply in ["I'm having some trouble right now. Give me a few minutes to recover.",
                      "Sorry, something went wrong. Please try again later.",
                      "Good luck and have fun with your game today!"] {
            StubHTTP.respond { _ in (200, TestEnv.ollamaReply(reply)) }
            let r = await NovaNarrator(ai: ai).coach(game: g, playerName: "Tester")
            XCTAssertFalse(r.isAI, reply)
            XCTAssertEqual(r.value, ScriptedCoach.explain(CoachFacts.make(game: g), playerName: "Tester"))
        }
    }

    /// A cloud model side: its key goes only in the https Authorization header, never into events, summaries or the feed.
    func testModelSideKeyNeverInRecordsOrFeed() async throws {
        UserDefaults.standard.set(0.2, forKey: Prefs.watchDelay)
        defer { UserDefaults.standard.removeObject(forKey: Prefs.watchDelay) }
        let key = "test-key-0123456789-never-recorded"
        let ai = TestEnv.stubbedAI()
        XCTAssertTrue(ai.setAPIKey(key, for: .openRouter))
        StubHTTP.respond { r in
            r.url.path.hasSuffix("/chat/completions")
                ? (200, StubHTTP.json(["model": "m", "choices": [["message": ["role": "assistant", "content": "Kz9"]]]]))   // never legal
                : (200, StubHTTP.json(["data": []]))
        }
        let c = TestEnv.controller(ai: ai)
        c.newGame(TestEnv.watch(white: true, black: false, backend: .openRouter, model: "anthropic/claude-sonnet-4.5"))
        let ok = await waitUntil(20) { c.game.ply >= 1 }; XCTAssertTrue(ok, "falls back to the engine")
        c.setWatchPaused(true)
        _ = await waitUntil(5) { !c.engineThinking }
        c.takeOver()
        let chat = StubHTTP.requests.filter { $0.url.path.hasSuffix("/chat/completions") }
        XCTAssertFalse(chat.isEmpty)
        XCTAssertTrue(chat.allSatisfy { $0.url.scheme == "https" && $0.headers["Authorization"] == "Bearer \(key)" })
        XCTAssertFalse(chat.contains { String(decoding: $0.body, as: UTF8.self).contains(key) }, "never in the prompt")
        var recorded = c.outbox.pending.flatMap(\.eventRecords).map { String(decoding: $0.detail, as: UTF8.self) }
        for case .end(_, _, let e) in c.outbox.pending { recorded.append(String(decoding: e.summary, as: UTF8.self)) }
        recorded += c.feed.map(\.text) + [c.coachText, c.statusLine]
        XCTAssertTrue(recorded.contains { $0.contains("model_reply") || $0.contains("anthropic/claude") }, "the records were checked")
        XCTAssertFalse(recorded.contains { $0.contains(key) || $0.contains("Bearer") })
    }

    func testModelReplyExcerptIsClippedAndPrintable() {
        let r = ModelReply(side: .white, backend: "ollama", model: "m", reply: "e4\n" + String(repeating: "A", count: 5000) + "\u{0007}",
                           latencyMs: 1, attempt: 1, san: "e4")
        let d = jsonObject(PlayReport.modelReplyEvent(r, ply: 1, seq: 1, at: Date()).detail)
        let ex = d["excerpt"] as? String ?? ""
        XCTAssertLessThanOrEqual(ex.count, 80)
        XCTAssertFalse(ex.contains("\n"))
    }

    func testValidatorAnchorRule() throws {
        let g = try Fixtures.game(["e4"])
        let v = ChessMentionValidator(game: g, facts: CoachFacts.make(game: g))
        XCTAssertThrowsError(try v.validate("Nice weather for it, isn't it?", requireAnchor: true))
        XCTAssertNoThrow(try v.validate("Your pawn now controls the centre.", requireAnchor: true))
        XCTAssertNoThrow(try v.validate("Nice weather for it, isn't it?"))
    }
}

final class SecurityATSTests: XCTestCase {
    /// Plain http only to the two LAN Ollama hosts and the local network; never arbitrary loads.
    func testTransportExceptionsAreNarrow() throws {
        let ats = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        XCTAssertNil(ats["NSAllowsArbitraryLoads"])
        XCTAssertNil(ats["NSAllowsArbitraryLoadsInWebContent"])
        let domains = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: [String: Any]])
        XCTAssertEqual(Set(domains.keys), ["nova-core8.digitalnoise.net", "nova-core3.digitalnoise.net"])
        for (_, d) in domains { XCTAssertNil(d["NSIncludesSubdomains"]) }
        XCTAssertTrue(AppAI.fleetOllama.contains("nova-core8.digitalnoise.net"))
        XCTAssertTrue(AppAI.fleetOllamaBackup.contains("nova-core3.digitalnoise.net"))
    }
}

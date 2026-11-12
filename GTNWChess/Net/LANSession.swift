//
//  LANSession.swift
//  GTNW Chess
//
//  The network half of LAN play: host (listener + Bonjour advert), guest (browser + connect), framed messages,
//  keep-alive pings, and automatic reconnect with exponential backoff for the guest (the host keeps listening and
//  accepts the same game back). Rules live in `LANReferee`; the game controller applies validated moves.
//

import Foundation
import Network
import os

/// Validates what the other Mac sends against our own rules engine.
enum LANReferee {
    enum Verdict: Equatable { case accept(Move), reject(String) }

    static func check(ply: Int, uci: String, game: Game, remoteSide: Side) -> Verdict {
        guard !game.isOver else { return .reject("game over") }
        guard ply == game.ply + 1 else { return .reject("out of sync: expected ply \(game.ply + 1), got \(ply)") }
        guard game.sideToMove == remoteSide else { return .reject("not your turn") }
        guard uci.count <= 5, let m = game.position.move(uci: uci) else { return .reject("illegal move \(uci.prefix(8))") }
        return .accept(m)
    }

    /// Replays a host state; nil if any move is illegal.
    static func replay(_ s: LANState) -> Game? {
        guard var g = try? Game(fen: s.startFEN), s.moves.count <= PGN.maxPlies else { return nil }
        for u in s.moves { guard (try? g.play(uci: u)) != nil else { return nil } }
        if g.result == nil, let r = s.result { g.result = r }
        return g
    }
}

@MainActor
final class LANSession: ObservableObject {
    enum Role: String { case host, guest }
    enum Status: Equatable {
        case idle, listening(UInt16), connecting, connected, reconnecting(Int), failed(String), closed
        var label: String {
            switch self {
            case .idle: return "Not connected"
            case .listening(let p): return "Waiting for a challenger (port \(p))"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .reconnecting(let n): return "Reconnecting (attempt \(n))…"
            case .failed(let s): return "Failed: \(s)"
            case .closed: return "Closed"
            }
        }
    }

    struct Found: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var endpoint: NWEndpoint
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var found: [Found] = []
    private(set) var role: Role?
    private(set) var code = ""
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()
    private var target: NWEndpoint?
    private var userClosed = false
    private(set) var everConnected = false
    private var isReconnecting = false
    private var pingTimer: Timer?
    private var lastHeard = Date()
    var reconnectPolicy = Retry.Policy(attempts: 8, baseDelay: 0.5, multiplier: 2)
    var sleeper: Retry.Sleeper = Retry.taskSleep
    private let queue = DispatchQueue(label: "com.jkoch.gtnwchess.lan")
    private let log = Logger(subsystem: "com.jkoch.gtnwchess", category: "lan")

    /// Delivered on the main actor.
    var onMessage: (LANMessage) -> Void = { _ in }
    var onConnected: () -> Void = {}
    var onDisconnected: () -> Void = {}

    var listeningPort: UInt16? { listener?.port?.rawValue }

    // MARK: Host

    func host(code: String, serviceName: String, port: UInt16 = 0, advertise: Bool = true) throws {
        guard LANSecurity.isValidCode(code) else { throw LANError.badCode }
        stop()
        userClosed = false
        role = .host
        self.code = code
        let params = LANSecurity.parameters(code: code)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        if advertise { l.service = NWListener.Service(name: String(serviceName.prefix(60)), type: LANSecurity.serviceType) }
        l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
        l.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .ready: if self.connection == nil { self.status = .listening(l.port?.rawValue ?? 0) }
                case .failed(let e): self.status = .failed(e.localizedDescription)
                default: break
                }
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func accept(_ c: NWConnection) {
        // One opponent at a time; a reconnecting guest replaces a dead or stale connection (its hello carries the game).
        if let old = connection { old.stateUpdateHandler = nil; old.cancel() }
        attach(c)
    }

    // MARK: Guest

    func browse() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: LANSecurity.serviceType, domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> Found? in
                if case .service(let name, _, _, _) = r.endpoint { return Found(name: name, endpoint: r.endpoint) }
                return nil
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.found = list }
        }
        b.start(queue: queue)
        browser = b
    }

    func join(_ endpoint: NWEndpoint, code: String) throws {
        guard LANSecurity.isValidCode(code) else { throw LANError.badCode }
        role = .guest
        self.code = code
        target = endpoint
        userClosed = false
        everConnected = false
        status = .connecting
        attach(NWConnection(to: endpoint, using: LANSecurity.parameters(code: code)))
    }

    func join(host: String, port: UInt16, code: String) throws {
        try join(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), code: code)
    }

    // MARK: Connection

    private func attach(_ c: NWConnection) {
        connection = c
        buffer = Data()
        c.stateUpdateHandler = { [weak self, weak c] st in
            Task { @MainActor in
                guard let self, let c, self.connection === c else { return }
                switch st {
                case .ready:
                    self.status = .connected
                    self.everConnected = true
                    self.lastHeard = Date()
                    self.startPings()
                    self.onConnected()
                case .failed(let e), .waiting(let e):
                    self.log.notice("lan connection: \(e.localizedDescription, privacy: .public)")
                    self.lost(c, reason: e.localizedDescription)
                case .cancelled:
                    self.lost(c, reason: "closed")
                default: break
                }
            }
        }
        receive(c)
        c.start(queue: queue)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak c] data, _, done, err in
            Task { @MainActor in
                guard let self, let c, self.connection === c else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.lastHeard = Date()
                    do {
                        for m in try LANCodec.decode(&self.buffer) { self.handle(m) }
                    } catch {
                        self.log.error("lan: bad frame, dropping connection")
                        c.cancel()
                        return
                    }
                }
                if done || err != nil { c.cancel(); return }
                self.receive(c)
            }
        }
    }

    private func handle(_ m: LANMessage) {
        switch m {
        case .ping: send(.pong)
        case .pong: break
        default: onMessage(m)
        }
    }

    func send(_ m: LANMessage) {
        guard let c = connection, let d = try? LANCodec.encode(m) else { return }
        c.send(content: d, completion: .contentProcessed { _ in })
    }

    private func startPings() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.status == .connected else { return }
                if Date().timeIntervalSince(self.lastHeard) > 20 { self.connection?.cancel(); return }
                self.send(.ping)
            }
        }
    }

    private func lost(_ c: NWConnection, reason: String) {
        guard connection === c else { return }
        c.stateUpdateHandler = nil
        connection = nil
        pingTimer?.invalidate()
        onDisconnected()
        if userClosed { status = .closed; return }
        switch role {
        case .host:
            status = listener.map { .listening($0.port?.rawValue ?? 0) } ?? .failed(reason)
        case .guest:
            if !everConnected && !isReconnecting {
                status = .failed("couldn't connect — check the pairing code and that the host is waiting (\(reason))")
                return
            }
            if !isReconnecting { Task { await self.reconnect(reason: reason) } }
        case nil:
            status = .closed
        }
    }

    /// Guest: reconnect with exponential backoff to the same host (and game).
    func reconnect(reason: String) async {
        guard let target, role == .guest else { status = .failed(reason); return }
        isReconnecting = true
        defer { isReconnecting = false }
        for attempt in 1...max(1, reconnectPolicy.attempts) {
            if userClosed { return }
            status = .reconnecting(attempt)
            await sleeper(reconnectPolicy.delay(beforeRetry: attempt))
            if userClosed { return }
            attach(NWConnection(to: target, using: LANSecurity.parameters(code: code)))
            // Wait for ready or failure (up to 10 s).
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, connection != nil, status != .connected { try? await Task.sleep(nanoseconds: 100_000_000) }
            if status == .connected { return }
        }
        status = .failed("couldn't reconnect (\(reason))")
    }

    func stop() {
        userClosed = true
        pingTimer?.invalidate()
        if let c = connection { send(.bye); c.stateUpdateHandler = nil; c.cancel() }
        connection = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        found = []
        status = .idle
    }

    var isConnected: Bool { status == .connected }
}

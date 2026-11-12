//
//  PlayOutbox.swift
//  GTNW Chess
//
//  Offline-first queue for play history. Every write is queued inside the app's container (Application Support/
//  GTNW Chess/play-outbox.json) and flushed in the background with backoff, so writing never blocks or slows play.
//  Transient failures (offline, signed out, 5xx, 429) keep the item; permanent ones (4xx the server will never
//  accept) drop it. Every operation is idempotent on the server, so a resend after a crash is harmless.
//

import Foundation
import os

enum PlayOp: Codable, Equatable, Sendable {
    case start(id: UUID, startedAt: Date, player: String? = nil)
    case events(id: UUID, events: [PlayEventRecord], actions: Int)
    case end(id: UUID, startedAt: Date, end: PlaySessionEnd)

    var sessionID: UUID {
        switch self {
        case .start(let id, _, _), .events(let id, _, _), .end(let id, _, _): return id
        }
    }
}

@MainActor
final class PlayOutbox: ObservableObject {
    static let maxItems = 2_000

    @Published private(set) var pending: [PlayOp] = []
    @Published private(set) var lastError: String?
    @Published private(set) var written = 0
    @Published private(set) var dropped = 0
    private(set) var isFlushing = false
    let fileURL: URL?
    var sink: PlaySink?
    var retry = Retry.Policy(attempts: 3, baseDelay: 0.5)
    var sleeper: Retry.Sleeper = Retry.taskSleep
    private let log = Logger(subsystem: "com.jkoch.gtnwchess", category: "play")

    init(fileURL: URL?, sink: PlaySink?) {
        self.fileURL = fileURL
        self.sink = sink
        if let fileURL, let d = try? Data(contentsOf: fileURL), let ops = try? JSONDecoder().decode([PlayOp].self, from: d) {
            pending = ops
        }
    }

    static func defaultURL() -> URL {
        AppContainer.directory.appendingPathComponent("play-outbox.json")
    }

    func enqueue(_ op: PlayOp) {
        pending.append(op)
        if pending.count > Self.maxItems { pending.removeFirst(pending.count - Self.maxItems); dropped += 1 }
        save()
        flush()
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let d = try JSONEncoder().encode(pending)
            try d.write(to: fileURL, options: [.atomic])
        } catch {
            log.notice("outbox not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends pending items in order. One flush at a time; a transient failure stops the pass (retried later).
    func flush() {
        guard !isFlushing, let sink, !pending.isEmpty else { return }
        isFlushing = true
        Task { await self.drain(sink) }
    }

    /// Awaitable flush (tests, quit).
    func flushNow() async {
        guard let sink, !isFlushing else { return }
        isFlushing = true
        await drain(sink)
    }

    private func drain(_ sink: PlaySink) async {
        defer { isFlushing = false }
        while let op = pending.first {
            do {
                try await Retry.run(retry, sleep: sleeper, when: { ($0 as? PlayError)?.isTransient ?? true }) {
                    try await Self.send(op, to: sink)
                }
                pending.removeFirst()
                written += 1
                lastError = nil
                save()
            } catch let e as PlayError where !e.isTransient {
                pending.removeFirst()
                dropped += 1
                lastError = e.localizedDescription
                save()
            } catch {
                lastError = error.localizedDescription
                log.notice("play history queued: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    nonisolated static func send(_ op: PlayOp, to sink: PlaySink) async throws {
        switch op {
        case .start(let id, let at, let p): try await sink.start(id: id, startedAt: at, player: p)
        case .events(let id, let evs, let actions): try await sink.events(id: id, evs, actions: actions)
        case .end(let id, let at, let e): try await sink.end(id: id, startedAt: at, e)
        }
    }
}

/// The app's own folder (inside the user's Library; all state lives here, nothing elsewhere).
enum AppContainer {
    static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = RuntimeEnv.underXCTest
            ? FileManager.default.temporaryDirectory.appendingPathComponent("GTNWChessTests-\(ProcessInfo.processInfo.processIdentifier)")
            : base.appendingPathComponent("GTNW Chess", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

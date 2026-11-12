import Foundation

/// Retry with exponential backoff for the games DB (play history). AI requests retry inside NovaAIKit; LAN reconnects use it too.
/// The last error is rethrown; `sleep` is injectable so tests never wait.
enum Retry {
    struct Policy: Sendable, Equatable {
        var attempts = 3
        var baseDelay: TimeInterval = 0.25
        var multiplier = 2.0
        static let `default` = Policy()
        static let none = Policy(attempts: 1)
        func delay(beforeRetry n: Int) -> TimeInterval { baseDelay * pow(multiplier, Double(n - 1)) }
    }

    typealias Sleeper = @Sendable (TimeInterval) async -> Void
    static let taskSleep: Sleeper = { try? await Task.sleep(for: .seconds($0)) }

    static func run<T>(_ policy: Policy = .default, sleep: Sleeper = taskSleep,
                       isolation: isolated (any Actor)? = #isolation,
                       when shouldRetry: (Error) -> Bool = { _ in true },
                       _ body: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do { return try await body() } catch {
                guard attempt < max(1, policy.attempts), shouldRetry(error), !Task.isCancelled else { throw error }
                await sleep(policy.delay(beforeRetry: attempt))
                attempt += 1
            }
        }
    }
}

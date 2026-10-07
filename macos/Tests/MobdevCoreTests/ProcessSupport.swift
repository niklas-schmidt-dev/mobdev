import Foundation
@testable import MobdevCore

extension Process {
    /// Runs the process and waits for its end through the termination handler, without holding a
    /// thread. `waitUntilExit` blocks the test's thread and was once seen to wait forever while many
    /// processes ran (see ProcessBox); on a CI runner with three cooperative threads, a few tests
    /// blocked that way stalled the whole suite until the job's timeout (2026-10-07). Throws when
    /// the process does not end within `timeout`, after ending it.
    func runToExit(timeout: TimeInterval = 300) async throws -> Int32 {
        let ended = Locked(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                if !ended.withLock({ was in defer { was = true }; return was }) { continuation.resume(with: result) }
            }
            terminationHandler = { _ in finish(.success(())) }
            do {
                try run()
            } catch {
                finish(.failure(error))
                return
            }
            let pid = processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !ended.get() else { return }
                kill(pid, SIGKILL)
                finish(.failure(CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "timed out"])))
            }
        }
        return terminationStatus
    }
}

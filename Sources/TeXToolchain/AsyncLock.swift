import Foundation
import Synchronization

/// A FIFO async mutex that never blocks a thread: waiters are suspended continuations.
///
/// `acquire()` returns `false` (lock **not** acquired) when the waiting task is cancelled before its turn,
/// so a superseded compile request does not wait for the run in progress.
final class AsyncLock: Sendable {
    private struct Waiter {
        var id: UInt64
        var continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var locked = false
        var nextID: UInt64 = 0
        var waiters: [Waiter] = []
        /// Ids whose cancellation handler ran before their continuation was registered.
        var cancelledEarly: Set<UInt64> = []
    }

    private let state = Mutex(State())

    init() {}

    /// Waits for the lock. Returns true when acquired (call `release()` exactly once), false when the
    /// task was cancelled while waiting.
    func acquire() async -> Bool {
        let id = state.withLock { s -> UInt64 in
            s.nextID &+= 1
            return s.nextID
        }
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let immediate: Bool? = state.withLock { s in
                    if s.cancelledEarly.remove(id) != nil { return false }
                    if !s.locked {
                        s.locked = true
                        return true
                    }
                    s.waiters.append(Waiter(id: id, continuation: continuation))
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Bool, Never>? = state.withLock { s in
                if let index = s.waiters.firstIndex(where: { $0.id == id }) {
                    return s.waiters.remove(at: index).continuation
                }
                s.cancelledEarly.insert(id)
                return nil
            }
            continuation?.resume(returning: false)
        }
        // The cancellation handler may have run after the lock was handed to us; forget its marker.
        state.withLock { _ = $0.cancelledEarly.remove(id) }
        return acquired
    }

    /// Hands the lock to the next waiter (FIFO) or unlocks it.
    func release() {
        let next: CheckedContinuation<Bool, Never>? = state.withLock { s in
            if s.waiters.isEmpty {
                s.locked = false
                return nil
            }
            return s.waiters.removeFirst().continuation
        }
        next?.resume(returning: true)
    }
}

/// One `AsyncLock` per shadow workspace, shared by every `LaTeXCompiler` in the process, so that two
/// compilers for the same project never run latexmk in the same directory at the same time.
enum WorkspaceLocks {
    private static let locks = Mutex<[String: AsyncLock]>([:])

    static func lock(for key: String) -> AsyncLock {
        locks.withLock { table in
            if let existing = table[key] { return existing }
            let lock = AsyncLock()
            table[key] = lock
            return lock
        }
    }
}

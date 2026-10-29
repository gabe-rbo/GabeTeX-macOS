import Foundation
import Darwin
import Synchronization

/// Result of a finished child process.
struct ProcessOutput: Sendable {
    enum Termination: Sendable, Equatable {
        case exited(Int32)
        case signaled(Int32)
    }

    var termination: Termination
    var stdout: Data
    var stderr: Data
    /// The process was terminated because its timeout elapsed.
    var timedOut: Bool
    /// The process was terminated because the waiting task was cancelled or `terminate()` was called.
    var cancelled: Bool

    var exitCode: Int32? {
        if case .exited(let code) = termination { return code }
        return nil
    }

    var succeeded: Bool { termination == .exited(0) && !timedOut && !cancelled }

    /// stdout decoded as UTF-8 (invalid sequences replaced).
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    /// stdout followed by stderr.
    var combinedText: String {
        let out = stdoutText, err = stderrText
        if err.isEmpty { return out }
        if out.isEmpty { return err }
        return out.hasSuffix("\n") ? out + err : out + "\n" + err
    }
}

enum ProcessRunnerError: Error, Sendable, Equatable {
    /// `posix_spawn` (or pipe creation) failed; `code` is the errno value.
    case spawnFailed(path: String, code: Int32)

    var localizedMessage: String {
        switch self {
        case .spawnFailed(let path, let code):
            let reason = String(cString: strerror(code))
            return String(localized: "Could not run \(path): \(reason)")
        }
    }
}

/// Async child-process runner built on `posix_spawn`.
///
/// - The child runs in a **new process group** (`POSIX_SPAWN_SETPGROUP`), so `terminate()` can signal the
///   whole tree (latexmk → pdflatex/bibtex/biber) with `kill(-pgid, …)`: SIGTERM, then SIGKILL after a grace
///   period. Before the leader is reaped a final SIGKILL is sent to the group, which is safe because the
///   group id cannot be reused while the (zombie) leader still exists.
/// - stdout/stderr are drained concurrently by dispatch read sources (no pipe deadlocks); stdin is written
///   with `DispatchIO` and closed. No thread ever blocks waiting for the child.
/// - Signal dispositions are reset to their defaults and the signal mask cleared in the child, and only
///   fds 0–2 are inherited (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
/// - Every live process group is listed in `ProcessGroupRegistry`, so `terminateAll()` can SIGKILL all of
///   them synchronously when the app quits (task cancellation is asynchronous and would race with exit).
enum ProcessRunner {
    /// Spawns `executable` and waits for it to finish. Cancelling the calling task terminates the
    /// process group and returns an output with `cancelled == true`.
    ///
    /// - Parameter killOnTerminateAll: register the process group for `terminateAll()` (app quit). Pass
    ///   false for work that must not be interrupted half-way (tlmgr installing packages).
    static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data? = nil,
        timeout: Duration? = nil,
        killOnTerminateAll: Bool = true
    ) async throws(ProcessRunnerError) -> ProcessOutput {
        let handle = try ProcessHandle.spawn(executable, arguments: arguments, environment: environment,
                                             currentDirectory: currentDirectory, stdin: stdin,
                                             register: killOnTerminateAll)
        if let timeout { handle.setTimeout(timeout) }
        return await handle.wait()
    }

    /// Synchronously sends SIGKILL to every registered process group that is still running (their waiting
    /// tasks then return with `cancelled == true`). Lock-free and allocation-free on the common path: safe
    /// to call from `applicationWillTerminate` (or even a signal handler). Returns the number of groups.
    @discardableResult
    static func terminateAll() -> Int {
        ProcessGroupRegistry.killAll()
    }
}

/// Process-wide registry of the process groups of running children (each child leads its own group).
///
/// A fixed table of atomics, so registering, unregistering and `killAll` never block or allocate; groups
/// beyond the table's capacity (never expected) go to a small mutex-protected overflow table. A group is
/// unregistered just *before* its leader is reaped: until then the zombie leader keeps the group id reserved,
/// so `kill(-pgid, …)` can never hit an unrelated process group.
enum ProcessGroupRegistry {
    static let capacity = 256
    /// 0 = free, pgid > 0 = live group, -pgid = group killed by `killAll`.
    private static let slots: InlineArray<256, Atomic<Int32>> = InlineArray { _ in Atomic(0) }
    private static let overflow = Mutex<[pid_t: Bool]>([:])

    /// Registers a live group; returns its slot (nil: kept in the overflow table).
    static func register(_ pgid: pid_t) -> Int? {
        for i in 0..<capacity {
            if slots[i].compareExchange(expected: 0, desired: pgid, ordering: .acquiringAndReleasing).exchanged {
                return i
            }
        }
        overflow.withLock { $0[pgid] = false }
        return nil
    }

    /// Unregisters a group whose leader exited. Returns true if `killAll` killed it.
    static func unregister(_ pgid: pid_t, slot: Int?) -> Bool {
        guard let slot else { return overflow.withLock { $0.removeValue(forKey: pgid) } ?? false }
        if slots[slot].compareExchange(expected: pgid, desired: 0, ordering: .acquiringAndReleasing).exchanged {
            return false
        }
        return slots[slot].compareExchange(expected: -pgid, desired: 0, ordering: .acquiringAndReleasing).exchanged
    }

    /// SIGKILLs every registered group (and its leader, in case it left its group). Returns how many.
    static func killAll() -> Int {
        var killed = 0
        for i in 0..<capacity {
            let pgid = slots[i].load(ordering: .acquiring)
            guard pgid > 0,
                  slots[i].compareExchange(expected: pgid, desired: -pgid, ordering: .acquiringAndReleasing).exchanged
            else { continue }
            kill(-pgid, SIGKILL)
            kill(pgid, SIGKILL)
            killed += 1
        }
        let extra: [pid_t] = overflow.withLock { table in
            let live = table.filter { !$0.value }.map(\.key)
            for pgid in live { table[pgid] = true }
            return live
        }
        for pgid in extra {
            kill(-pgid, SIGKILL)
            kill(pgid, SIGKILL)
        }
        return killed + extra.count
    }

    /// Live groups (for checks).
    static var registeredGroups: [pid_t] {
        var result: [pid_t] = []
        for i in 0..<capacity {
            let pgid = slots[i].load(ordering: .relaxed)
            if pgid > 0 { result.append(pgid) }
        }
        return result + overflow.withLock { $0.filter { !$0.value }.map(\.key) }
    }
}

/// A running child process. Thread-safe; all mutable state lives behind a `Mutex`.
final class ProcessHandle: Sendable {
    let pid: pid_t
    let executablePath: String

    private let queue: DispatchQueue
    private let state: Mutex<State>
    /// Whether the group is in `ProcessGroupRegistry`, and its slot there.
    private let registered: Bool
    private let registrySlot: Int?

    private struct State {
        var stdout = Data()
        var stderr = Data()
        var stdoutOpen = true
        var stderrOpen = true
        var termination: ProcessOutput.Termination?
        var terminateRequested = false
        var timedOut = false
        var cancelled = false
        var result: ProcessOutput?
        var waiters: [CheckedContinuation<ProcessOutput, Never>] = []
        var pipeDeadlineScheduled = false
    }

    private init(pid: pid_t, executablePath: String, queue: DispatchQueue, registered: Bool, registrySlot: Int?) {
        self.pid = pid
        self.executablePath = executablePath
        self.queue = queue
        self.state = Mutex(State())
        self.registered = registered
        self.registrySlot = registrySlot
    }

    // MARK: Spawning

    static func spawn(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?,
        stdin: Data?,
        register: Bool = true
    ) throws(ProcessRunnerError) -> ProcessHandle {
        let path = executable.path
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1], inPipe: [Int32] = [-1, -1]
        func closeAll() {
            for fd in outPipe + errPipe + inPipe where fd >= 0 { close(fd) }
        }
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            let code = errno
            closeAll()
            throw .spawnFailed(path: path, code: code)
        }
        if stdin != nil, pipe(&inPipe) != 0 {
            let code = errno
            closeAll()
            throw .spawnFailed(path: path, code: code)
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if stdin != nil {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir(&actions, currentDirectory.path)
        }

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let env = environment ?? ProcessInfo.processInfo.environment
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        // The parent keeps only its ends of the pipes.
        close(outPipe[1]); close(errPipe[1])
        if stdin != nil { close(inPipe[0]) }
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            if stdin != nil { close(inPipe[1]) }
            throw .spawnFailed(path: path, code: rc)
        }

        // The child leads its own process group (pgid == pid); nobody can reap it before we do.
        let slot = register ? ProcessGroupRegistry.register(pid) : nil
        let queue = DispatchQueue(label: "io.github.gabe-rbo.GabeTeX.process.\(pid)")
        let handle = ProcessHandle(pid: pid, executablePath: path, queue: queue, registered: register, registrySlot: slot)
        handle.startReading(fd: outPipe[0], isStdout: true)
        handle.startReading(fd: errPipe[0], isStdout: false)
        if let stdin { handle.writeStdin(stdin, fd: inPipe[1]) }
        handle.startExitMonitoring()
        return handle
    }

    // MARK: Waiting

    /// Waits for the process to exit and its output pipes to close. Task cancellation terminates the process.
    func wait() async -> ProcessOutput {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProcessOutput, Never>) in
                let ready: ProcessOutput? = state.withLock { s in
                    if let r = s.result { return r }
                    s.waiters.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            self.terminate(asCancellation: true)
        }
    }

    var isFinished: Bool { state.withLock { $0.result != nil } }

    /// Terminates the process group after `timeout` unless the process finished before.
    func setTimeout(_ timeout: Duration) {
        let comps = timeout.components
        let seconds = Double(comps.seconds) + Double(comps.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds) { [self] in
            let alive = state.withLock { s -> Bool in
                guard s.termination == nil else { return false }
                s.timedOut = true
                return true
            }
            if alive { terminate(asCancellation: false) }
        }
    }

    // MARK: Termination

    /// Sends SIGTERM to the whole process group, then SIGKILL after `grace` seconds if it is still alive.
    func terminate(asCancellation: Bool = true, grace: Double = 1.5) {
        let shouldSignal = state.withLock { s -> Bool in
            if asCancellation { s.cancelled = true }
            guard s.termination == nil, !s.terminateRequested else { return false }
            s.terminateRequested = true
            return true
        }
        guard shouldSignal else { return }
        queue.async { [self] in
            // On `queue`, the leader cannot have been reaped concurrently (reaping happens on `queue`).
            let reaped = state.withLock { $0.termination != nil }
            guard !reaped else { return }
            kill(-pid, SIGTERM)
            kill(pid, SIGTERM)  // in case the child changed its own process group
            queue.asyncAfter(deadline: .now() + grace) { [self] in
                let stillAlive = state.withLock { $0.termination == nil }
                if stillAlive {
                    kill(-pid, SIGKILL)
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    // MARK: Internals (all run on `queue`)

    private func startReading(fd: Int32, isStdout: Bool) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    let chunk = Data(buffer[0..<n])
                    state.withLock { s in
                        if isStdout { s.stdout.append(chunk) } else { s.stderr.append(chunk) }
                    }
                    continue
                }
                if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
                source.cancel()   // EOF or hard error
                return
            }
        }
        source.setCancelHandler { [self] in
            close(fd)
            state.withLock { s in
                if isStdout { s.stdoutOpen = false } else { s.stderrOpen = false }
            }
            finishIfDone()
        }
        source.activate()
        // Keep the source alive until cancelled: it is retained by its own handlers' capture of `source`
        // (released by dispatch after cancellation completes).
    }

    private func writeStdin(_ data: Data, fd: Int32) {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: payload, queue: queue) { done, _, _ in
            if done { io.close() }
        }
    }

    private func startExitMonitoring() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [self] in
            if reap() { source.cancel() }
        }
        source.activate()
        // The child may already have exited before the source was registered.
        queue.async { [self] in
            if reap() { source.cancel() }
        }
    }

    /// Reaps the child if it exited. Returns true once the termination status is known.
    private func reap() -> Bool {
        if state.withLock({ $0.termination != nil }) { return true }
        // Peek first (WNOWAIT) so stray group members can be killed while the leader's pid — and therefore
        // the process-group id — is still reserved by the zombie.
        var info = siginfo_t()
        let peek = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if peek == 0 && info.si_pid == 0 { return false } // still running
        if state.withLock({ $0.terminateRequested }) { kill(-pid, SIGKILL) }
        // Leave the registry while the zombie leader still reserves the group id.
        if registered, ProcessGroupRegistry.unregister(pid, slot: registrySlot) {
            state.withLock { $0.cancelled = true }   // killed by terminateAll()
        }
        var status: Int32 = 0
        var r: pid_t
        repeat { r = waitpid(pid, &status, WNOHANG) } while r == -1 && errno == EINTR
        guard r == pid else {
            if r == -1 && errno == ECHILD {
                // Someone else reaped it; we cannot know the status.
                state.withLock { $0.termination = .exited(-1) }
                schedulePipeDeadline()
                finishIfDone()
                return true
            }
            return false
        }
        let termination: ProcessOutput.Termination
        let low = status & 0x7f
        if low == 0 {
            termination = .exited((status >> 8) & 0xff)
        } else {
            termination = .signaled(low)
        }
        state.withLock { $0.termination = termination }
        schedulePipeDeadline()
        finishIfDone()
        return true
    }

    /// A grandchild that escaped the process group could keep the pipes open forever; stop waiting for
    /// EOF a little while after the leader exited.
    private func schedulePipeDeadline() {
        let schedule = state.withLock { s -> Bool in
            guard !s.pipeDeadlineScheduled else { return false }
            s.pipeDeadlineScheduled = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + 3) { [self] in
            state.withLock { s in
                s.stdoutOpen = false
                s.stderrOpen = false
            }
            finishIfDone()
        }
    }

    private func finishIfDone() {
        let (waiters, result): ([CheckedContinuation<ProcessOutput, Never>], ProcessOutput?) = state.withLock { s in
            guard s.result == nil, let termination = s.termination, !s.stdoutOpen, !s.stderrOpen else { return ([], nil) }
            let r = ProcessOutput(termination: termination, stdout: s.stdout, stderr: s.stderr,
                                  timedOut: s.timedOut, cancelled: s.cancelled)
            s.result = r
            let w = s.waiters
            s.waiters = []
            return (w, r)
        }
        guard let result else { return }
        for w in waiters { w.resume(returning: result) }
    }
}

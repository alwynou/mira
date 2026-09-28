import Darwin
import Foundation
import MiraCore

struct MacBashResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int
    let terminationSignal: Int
    let timedOut: Bool
    let stdoutTruncated: Bool
    let stderrTruncated: Bool

    var json: JSONValue {
        .object(["stdout": .string(stdout), "stderr": .string(stderr),
                 "exit_code": .number(Double(exitCode)), "termination_signal": .number(Double(terminationSignal)),
                 "timed_out": .bool(timedOut), "stdout_truncated": .bool(stdoutTruncated),
                 "stderr_truncated": .bool(stderrTruncated)])
    }
}

/// Blocking POSIX work stays off the cooperative executor. Each invocation owns its
/// child, process group and pipes until cleanup, including after Swift cancellation.
struct MacBashRunner: Sendable {
    func run(_ command: MacBashCommand) async throws -> MacBashResult {
        let cancellation = BashCancellation()
        return try await withTaskCancellationHandler {
            let result: MacBashResult = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try execute(command, cancellation: cancellation) })
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(_ command: MacBashCommand, cancellation: BashCancellation) throws -> MacBashResult {
        if cancellation.isCancelled { throw CancellationError() }
        var stdout = try makePipe()
        defer { stdout.filter { $0 >= 0 }.forEach { close($0) } }
        var stderr = try makePipe()
        defer { stderr.filter { $0 >= 0 }.forEach { close($0) } }
        let input = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw Self.launchFailed }
        defer { close(input) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try require(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try require(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try require(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO))
        try require(posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO))
        try require(posix_spawn_file_actions_adddup2(&actions, stderr[1], STDERR_FILENO))
        try require(posix_spawn_file_actions_addchdir_np(&actions, command.workingDirectory))
        try require(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask)
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE, SIGCHLD] { sigaddset(&defaults, signal) }
        try require(posix_spawnattr_setsigmask(&attributes, &mask))
        try require(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try require(posix_spawnattr_setflags(&attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)))

        // Never copy the app's environment: BASH_ENV, exported functions, loader
        // overrides and provider credentials must not enter the child implicitly.
        let environment = [
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)",
            "TMPDIR=\(FileManager.default.temporaryDirectory.path)",
            "LANG=en_US.UTF-8", "LC_CTYPE=UTF-8", "TERM=dumb"
        ]
        var pid: pid_t = 0
        try withStrings(["/bin/bash", "--noprofile", "--norc", "-c", command.command]) { arguments in
            try withStrings(environment) { variables in
                if cancellation.isCancelled { throw CancellationError() }
                try require(posix_spawn(&pid, "/bin/bash", &actions, &attributes, arguments, variables))
            }
        }

        // Remove closed descriptors from ownership before another thread can reuse them.
        close(stdout[1]); stdout[1] = -1
        close(stderr[1]); stderr[1] = -1
        var output = BashOutput(), errors = BashOutput()
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start + UInt64(command.timeoutSeconds) * 1_000_000_000
        var cleanupStarted: UInt64?
        var sentKill = false
        var leaderExited = false
        var timedOut = false
        var waitFailed = false

        while true {
            output.drain(stdout[0])
            errors.drain(stderr[0])
            var info = siginfo_t()
            if !leaderExited {
                let outcome = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if outcome == 0 { leaderExited = info.si_pid == pid }
                else if errno != EINTR { waitFailed = true }
            }
            // If another owner reaped the child, its numeric PID is no longer a
            // safe group identity. Never send a signal using that stale identity.
            if waitFailed { break }
            let now = DispatchTime.now().uptimeNanoseconds
            if cleanupStarted == nil {
                timedOut = !leaderExited && now >= deadline
                if leaderExited || cancellation.isCancelled || timedOut || waitFailed || output.failed || errors.failed {
                    cleanupStarted = now
                    kill(-pid, SIGTERM)
                }
            }
            if let cleanupStarted, now - cleanupStarted >= 200_000_000, !sentKill {
                // The group leader is deliberately still waitable. Its PID cannot
                // be reused for another process group before this final signal.
                kill(-pid, SIGKILL)
                sentKill = true
            }
            if let cleanupStarted, sentKill, leaderExited || waitFailed {
                if (output.closed && errors.closed) || now - cleanupStarted >= 400_000_000 { break }
            }
            var readers = [pollfd(fd: output.closed ? -1 : stdout[0], events: Int16(POLLIN), revents: 0),
                           pollfd(fd: errors.closed ? -1 : stderr[0], events: Int16(POLLIN), revents: 0)]
            // EOF descriptors would make poll spin; a short sleep still bounds
            // cancellation latency while waiting for the group's shutdown grace.
            if output.closed && errors.closed { usleep(20_000) }
            else { _ = poll(&readers, nfds_t(readers.count), 20) }
        }
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
        if cancellation.isCancelled { throw CancellationError() }
        guard waited == pid, !waitFailed, !output.failed, !errors.failed else {
            throw MiraError(.storage, "The Bash process result could not be collected.")
        }
        let signal = Int(status & 0x7f)
        let exitCode = signal == 0 ? Int((status >> 8) & 0xff) : 128 + signal
        return .init(stdout: String(decoding: output.bytes, as: UTF8.self),
                     stderr: String(decoding: errors.bytes, as: UTF8.self),
                     exitCode: exitCode, terminationSignal: signal, timedOut: timedOut,
                     stdoutTruncated: output.truncated || !output.closed,
                     stderrTruncated: errors.truncated || !errors.closed)
    }

    private func makePipe() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw Self.launchFailed }
        guard fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else {
            close(descriptors[0]); close(descriptors[1])
            throw Self.launchFailed
        }
        return descriptors
    }

    private func withStrings<T>(_ strings: [String], body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
        var pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        guard pointers.allSatisfy({ $0 != nil }) else { throw Self.launchFailed }
        pointers.append(nil)
        return try pointers.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }

    private func require(_ code: Int32) throws {
        guard code == 0 else { throw Self.launchFailed }
    }

    private static var launchFailed: MiraError { .init(.unsupported, "The Bash process could not be started.") }
}

private final class BashCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

private struct BashOutput {
    var bytes: [UInt8] = []
    var truncated = false
    var closed = false
    var failed = false

    mutating func drain(_ descriptor: Int32) {
        guard !closed, !failed else { return }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        // A continuously writing child cannot starve stderr, deadlines or cancellation.
        for _ in 0..<16 {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let retained = min(count, 4_096 - bytes.count)
                bytes.append(contentsOf: buffer.prefix(retained))
                truncated = truncated || retained < count
            } else if count == 0 { closed = true; return }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR { failed = true; return }
        }
    }
}

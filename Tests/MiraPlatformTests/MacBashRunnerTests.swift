import Darwin
import Foundation
import MiraCore
import Testing

@Suite("macOS Bash processes", .timeLimit(.minutes(1)))
struct MacBashRunnerTests {
    @Test func commandRunsInItsDirectoryWithSeparateStreamsAndExitStatus() async throws {
        try await withBashDirectory { directory in
            let result = try await run("pwd; printf 'hello'; printf 'problem' >&2; exit 7", in: directory)
            let path = try #require(realpath(directory.path, nil))
            defer { free(path) }
            #expect(result.stdout == String(cString: path) + "\nhello")
            #expect(result.stderr == "problem")
            #expect(result.exitCode == 7 && result.terminationSignal == 0 && !result.timedOut)
            #expect(!result.stdoutTruncated && !result.stderrTruncated)
            _ = try ToolSchemaValidator.decode(try result.json.jsonString(), schema: MacBashTool().descriptor.outputSchema)
        }
    }

    @Test func stdinIsClosedAndEnvironmentDoesNotInheritAppVariables() async throws {
        try await withBashDirectory { directory in
            let result = try await run("if read line; then exit 9; fi; test -z \"${BASH_ENV-}\" || exit 8; /usr/bin/env", in: directory)
            #expect(result.exitCode == 0)
            #expect(result.stdout.contains("TERM=dumb"))
            let keys = Set(result.stdout.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
            #expect(keys == ["PATH", "HOME", "TMPDIR", "LANG", "LC_CTYPE", "TERM", "PWD", "SHLVL", "_"])
        }
    }

    @Test func concurrentOutputIsDrainedAfterBothBuffersReachTheirLimit() async throws {
        try await withBashDirectory { directory in
            let command = "(/usr/bin/yes o | /usr/bin/head -c 200000) & (/usr/bin/yes e | /usr/bin/head -c 200000 >&2) & wait"
            let result = try await run(command, in: directory)
            #expect(result.exitCode == 0)
            #expect(result.stdout.utf8.count == 4_096 && result.stderr.utf8.count == 4_096)
            #expect(result.stdoutTruncated && result.stderrTruncated)
            #expect(try result.json.jsonString().utf8.count <= MacBashTool().descriptor.maximumResultBytes)
        }
    }

    @Test func unicodeAndInvalidBytesProduceValidBoundedJSON() async throws {
        try await withBashDirectory { directory in
            // i18n-fixture: Escaped UTF-8 verifies verbatim Chinese shell output, without changing UI language.
            let result = try await run("printf '\\344\\275\\240\\345\\245\\275'; printf '\\377' >&2", in: directory)
            #expect(Array(result.stdout.utf8) == [0xe4, 0xbd, 0xa0, 0xe5, 0xa5, 0xbd])
            #expect(result.stderr == String(decoding: [UInt8(255)], as: UTF8.self))
            let controls = try await run("/bin/dd if=/dev/zero bs=8192 count=1 2>/dev/null", in: directory)
            #expect(controls.stdoutTruncated)
            _ = try ToolSchemaValidator.decode(try controls.json.jsonString(), schema: MacBashTool().descriptor.outputSchema)
            #expect(try controls.json.jsonString().utf8.count <= MacBashTool().descriptor.maximumResultBytes)
        }
    }

    @Test func timeoutKillsTheProcessGroupEvenWhenTermIsIgnored() async throws {
        try await withBashDirectory { directory in
            let start = ContinuousClock.now
            let result = try await run("trap '' TERM; /bin/sleep 30 & echo $! > child.pid; echo $$ > shell.pid; wait", in: directory, timeout: 1)
            #expect(result.timedOut && result.terminationSignal == Int(SIGKILL))
            #expect(start.duration(to: .now) < .seconds(4))
            try await expectStopped(directory.appendingPathComponent("child.pid"))
            try await expectStopped(directory.appendingPathComponent("shell.pid"))
        }
    }

    @Test func cancellationDrainsAndReapsTheShellAndItsChild() async throws {
        try await withBashDirectory { directory in
            let marker = directory.appendingPathComponent("child.pid")
            let task = Task { try await run("trap '' TERM; /bin/sleep 30 & echo $! > child.pid; echo $$ > shell.pid; wait", in: directory) }
            do {
                try await waitForFile(marker)
                task.cancel()
                await #expect(throws: CancellationError.self) { try await task.value }
                try await expectStopped(marker)
                try await expectStopped(directory.appendingPathComponent("shell.pid"))
            } catch { task.cancel(); _ = try? await task.value; throw error }
        }
    }

    @Test func alreadyCancelledInvocationDoesNotStartAProcess() async throws {
        try await withBashDirectory { directory in
            let task = Task {
                while !Task.isCancelled { await Task.yield() }
                return try await run("touch should-not-exist", in: directory)
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("should-not-exist").path))
        }
    }

    @Test func exitedShellDoesNotLeaveBackgroundPipeHoldersRunning() async throws {
        try await withBashDirectory { directory in
            let start = ContinuousClock.now
            let result = try await run("/bin/sleep 30 & echo $! > child.pid; printf done", in: directory)
            #expect(result.stdout == "done" && result.exitCode == 0 && !result.timedOut)
            #expect(start.duration(to: .now) < .seconds(3))
            try await expectStopped(directory.appendingPathComponent("child.pid"))
        }
    }

    @Test func preparationRejectsInvalidInputAndFreezesTheResolvedDirectory() throws {
        let temporary = FileManager.default.temporaryDirectory.path
        let command = try MacBashCommand.parse(.object(["command": .string("printf ok")]), defaultDirectory: temporary)
        #expect(command.timeoutSeconds == 30)
        #expect(command.workingDirectory == URL(fileURLWithPath: temporary).resolvingSymlinksInPath().path)
        #expect(command.approvalPrompt.contains(command.workingDirectory))
        #expect(command.approvalPrompt.hasSuffix("printf ok"))
        for arguments: JSONValue in [
            .object(["command": .string(" ")]), .object(["command": .string("a\0b")]),
            .object(["command": .string(String(repeating: "x", count: 2_049))]),
            .object(["command": .string("pwd"), "working_directory": .string("relative")]),
            .object(["command": .string("pwd"), "timeout_seconds": .number(0)]),
            .object(["command": .string("pwd"), "timeout_seconds": .number(91)])
        ] {
            #expect(throws: MiraError.self) { try MacBashCommand.parse(arguments, defaultDirectory: temporary) }
        }
        try MacBashTool().descriptor.validate()
    }

    private func run(_ command: String, in directory: URL, timeout: Int = 5) async throws -> MacBashResult {
        try await MacBashRunner().run(.init(command: command, workingDirectory: directory.path, timeoutSeconds: timeout))
    }

    private func expectStopped(_ marker: URL) async throws {
        let text = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(text))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    private func waitForFile(_ url: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    private func withBashDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-bash-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

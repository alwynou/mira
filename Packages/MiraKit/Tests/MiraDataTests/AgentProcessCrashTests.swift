import Darwin
import Foundation
import MiraCore
import Testing

@Suite("Agent recovery after process termination", .serialized, .timeLimit(.minutes(1)))
struct AgentProcessCrashTests {
    @Test(arguments: [
        "payloadStaged", "beforeJournalWrite", "afterJournalWrite", "afterJournalSync", "tornJournalTail",
        "businessCommitted", "toolResultPublished",
        "admissionPublished", "interruptedStream", "terminalPublished",
    ])
    func killedWriterRecoversInNewProcesses(scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mira-crash-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("test-owned"))
        let killed = try await ProbeProcess.run(mode: "crash", scenario: scenario, directory: directory)
        try #require(killed.ready, Comment(rawValue: killed.error))
        try #require(killed.signal && killed.status == SIGKILL, Comment(rawValue: killed.error))
        let first = try await ProbeProcess.run(mode: "verify", scenario: scenario, directory: directory)
        try #require(!first.signal && first.status == 0, Comment(rawValue: first.error))
        let report = try SessionCodec.decode([String: Int].self, from: first.output)
        if scenario == "businessCommitted" || scenario == "toolResultPublished" {
            #expect(report["businessWrites"] == 1)
            #expect(report["modelCalls"] == 1)
            #expect(report["outstandingReceipts"] == 0)
            #expect(report["settledInvocations"] == 1)
        } else if ["admissionPublished", "interruptedStream", "terminalPublished"].contains(scenario) {
            #expect(report["executions"] == 1)
            #expect(report["terminalFacts"] == 1)
            #expect(
                report["modelCalls"] == (scenario == "admissionPublished" ? 0 : 2))
            #expect(report["businessWrites"] == (["interruptedStream", "terminalPublished"].contains(scenario) ? 1 : 0))
            #expect(report["thinkingBytes"] == 0)
        } else {
            let committed = scenario == "afterJournalWrite" || scenario == "afterJournalSync"
            #expect(report["journalSequence"] == (committed ? 3 : 1))
            #expect(report["visibleBatches"] == (committed ? 2 : 1))
            #expect(report["unpublishedBodies"] == 0)
        }
        let repeated = try await ProbeProcess.run(mode: "verify", scenario: scenario, directory: directory)
        try #require(!repeated.signal && repeated.status == 0, Comment(rawValue: repeated.error))
        #expect(try SessionCodec.decode([String: Int].self, from: repeated.output) == report)
    }
}

private final class ProbeBundleMarker: NSObject {}
private struct ProbeProcessResult: Sendable {
    let ready: Bool
    let status: Int32
    let signal: Bool
    let output: Data
    let error: String
}
private enum ProbeProcess {
    static func run(mode: String, scenario: String, directory: URL) async throws -> ProbeProcessResult {
        let binary = Bundle(for: ProbeBundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent(
            "MiraCrashProbe")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw MiraError(.configuration, "The process recovery test executable was not built.")
        }
        // Pipe reads and waitpid run on a dedicated dispatch worker, never the cooperative executor.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let deadline = ProbeDeadline()
                let errorURL = directory.appendingPathComponent("process-error-\(UUID()).txt")
                do {
                    try Data().write(to: errorURL)
                    let errorHandle = try FileHandle(forWritingTo: errorURL)
                    defer {
                        try? errorHandle.close()
                        try? output.fileHandleForReading.close()
                    }
                    process.executableURL = binary
                    process.arguments = [mode, scenario, directory.path]
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = output
                    process.standardError = errorHandle
                    try process.run()
                    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                    timer.schedule(deadline: .now() + .seconds(20))
                    timer.setEventHandler {
                        if process.isRunning {
                            deadline.expire()
                            _ = Darwin.kill(process.processIdentifier, SIGKILL)
                        }
                    }
                    timer.resume()
                    defer { timer.cancel() }
                    do {
                        let marker = mode == "crash" ? try output.fileHandleForReading.read(upToCount: 1) : nil
                        let ready = marker == Data([0x52])
                        if ready { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                        let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
                        process.waitUntilExit()
                        if deadline.expired {
                            throw MiraError(.timeout, "The recovery subprocess exceeded its deadline.")
                        }
                        let errors = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
                        continuation.resume(
                            returning: .init(
                                ready: ready, status: process.terminationStatus,
                                signal: process.terminationReason == .uncaughtSignal, output: bytes, error: errors))
                    } catch {
                        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                        process.waitUntilExit()
                        throw error
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
private final class ProbeDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var expired: Bool { lock.withLock { value } }
    func expire() { lock.withLock { value = true } }
}

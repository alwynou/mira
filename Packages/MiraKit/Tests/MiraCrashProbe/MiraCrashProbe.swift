import Darwin
import Foundation
import MiraCore

/// Only the test runner creates this directory. Test input is never a library authority.
struct CrashProbeContext: Sendable {
    let directory: URL
    var journalDirectory: URL { directory.appendingPathComponent("journal", isDirectory: true) }
    var businessPath: String { directory.appendingPathComponent("Business.sqlite").path }
    func save<T: Encodable>(_ value: T) throws {
        let url = directory.appendingPathComponent("test-input.json")
        try SessionCodec.encode(value).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    func load<T: Decodable>(_ type: T.Type) throws -> T {
        try SessionCodec.decode(type, from: Data(contentsOf: directory.appendingPathComponent("test-input.json")))
    }
    /// Freeze all threads at the selected boundary. The parent kills this exact process.
    func pause() throws -> Never {
        try FileHandle.standardOutput.write(contentsOf: Data([0x52]))
        guard raise(SIGSTOP) == 0 else { throw MiraError(.storage, "The crash probe could not stop itself.") }
        throw MiraError(.conflict, "The crash probe was unexpectedly resumed.")
    }
}

@main
struct MiraCrashProbe {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 4, ["crash", "verify"].contains(arguments[1]) else {
                throw MiraError(.invalidInput, "The crash probe arguments are invalid.")
            }
            let context = CrashProbeContext(directory: URL(fileURLWithPath: arguments[3], isDirectory: true))
            guard arguments[3].hasPrefix("/"), context.directory.lastPathComponent.hasPrefix("mira-crash-"),
                FileManager.default.fileExists(atPath: context.directory.appendingPathComponent("test-owned").path)
            else {
                throw MiraError(.invalidInput, "The crash probe requires an isolated test-owned directory.")
            }
            let scenario = arguments[2]
            let report: [String: Int]
            switch scenario {
            case "payloadStaged", "beforeJournalWrite", "afterJournalWrite", "afterJournalSync", "tornJournalTail":
                if arguments[1] == "crash" { try await CrashProbeJournal.crash(context, scenario: scenario) }
                report = try await CrashProbeJournal.verify(context, scenario: scenario)
            case "businessCommitted", "toolResultPublished":
                if arguments[1] == "crash" { try await CrashProbeBusiness.crash(context, scenario: scenario) }
                report = try await CrashProbeBusiness.verify(context, scenario: scenario)
            case "admissionPublished", "interruptedStream", "terminalPublished":
                if arguments[1] == "crash" { try await CrashProbeExecution.crash(context, scenario: scenario) }
                report = try await CrashProbeExecution.verify(context, scenario: scenario)
            default:
                throw MiraError(.invalidInput, "The crash probe scenario is unknown.")
            }
            guard arguments[1] == "verify" else { throw MiraError(.conflict, "The crash probe missed its boundary.") }
            try FileHandle.standardOutput.write(contentsOf: SessionCodec.encode(report))
        } catch {
            // This executable only handles synthetic test data; never used by the application.
            let message = "Crash probe failed: \(error)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.prefix(4096).utf8))
            exit(1)
        }
    }
}

func probeRequire(_ condition: Bool, _ message: String) throws {
    guard condition else { throw MiraError(.storage, message) }
}

func probeCommit(_ result: SessionCommitResult) throws {
    if case .committed = result { return }
    if case .notCommitted(let error) = result { throw error }
    throw MiraError(.storage, "The crash probe session commit was uncertain.")
}

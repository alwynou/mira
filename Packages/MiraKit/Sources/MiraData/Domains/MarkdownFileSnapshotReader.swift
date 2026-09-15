import Foundation
import MiraCore

/// macOS selected-file adapter. Security-scoped access lasts until accepted I/O actually returns.
/// The Core application receives a value snapshot and never opens a platform URL.
public final class MarkdownFileSnapshotReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mira.markdown.snapshot", qos: .utility)
    private let lock = NSLock()
    private var accepting = true
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}
    public func read(_ url: URL) async throws -> KnowledgeImport {
        try Task.checkCancellation()
        guard lock.withLock({ if !accepting { return false }; active += 1; return true }) else {
            throw MiraError(.busy, "The Markdown file reader is closed.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result: Result<KnowledgeImport, any Error>
                do {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let value = KnowledgeImport(title: url.lastPathComponent, bytes: try ManagedBlobStore.readSelectedMarkdownFile(url))
                    try value.validate(); result = .success(value)
                } catch { result = .failure(error as? MiraError ?? MiraError(.storage, "The selected Markdown file could not be read.")) }
                self.lock.lock(); self.active -= 1
                let pending = self.active == 0 && !self.accepting ? self.waiters : []
                if !pending.isEmpty { self.waiters.removeAll() }
                self.lock.unlock(); pending.forEach { $0.resume() }
                continuation.resume(with: result)
            }
        }
    }
    public func close() async {
        await withCheckedContinuation { continuation in
            lock.lock(); accepting = false
            if active == 0 { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}

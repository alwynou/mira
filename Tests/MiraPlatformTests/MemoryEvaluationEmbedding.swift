import Foundation
import MiraCore

/// An explicit evaluation boundary: offline CI never prepares or downloads a model.
enum MemoryEvaluationEmbeddingMode: String, Codable, Sendable {
    case offline
    case local

    func injectedService() -> (any MemoryEmbeddingService)? {
        switch self {
        case .offline: OfflineMemoryEmbedding()
        case .local: nil
        }
    }

    func prepare(in group: MacLibraryWorkloads) async throws {
        guard self == .local else { return }
        await group.prepareLocalMemoryModel()
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try Task.checkCancellation()
            switch await group.localMemoryModelStatus() {
            case .ready: return
            case .failed(let error): throw error
            case .unavailable, .installing: break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw MiraError(.configuration, "The local embedding model did not become ready for evaluation.")
    }
}

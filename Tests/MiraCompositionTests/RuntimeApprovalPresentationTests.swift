#if DEBUG
    import Foundation
    import MiraCore
    import SwiftUI
    import Testing

    @Suite("Runtime approval presentation", .timeLimit(.minutes(1)))
    @MainActor
    struct RuntimeApprovalPresentationTests {
        @Test
        func pendingRequestPreservesProposalHashAndAuthorizationEpoch() async throws {
            let service = RuntimeApprovalService()
            let request = RuntimeApprovalRequest(
                invocationID: UUID(), executionID: ExecutionID(), proposalHash: "proposal-123",
                authorizationEpoch: 17, expiresAt: Date().addingTimeInterval(30),
                prompt: "Review this complete runtime request verbatim.")
            let snapshots = await service.snapshots()
            let waiting = Task {
                try await service.request(request)
            }
            var pending: RuntimeApprovalRequest?
            for await values in snapshots {
                if let value = values.first(where: { $0.id == request.id }) {
                    pending = value
                    break
                }
            }
            let visible = try #require(pending)
            #expect(visible == request)
            #expect(visible.proposalHash == "proposal-123")
            #expect(visible.authorizationEpoch == 17)

            await #expect(throws: MiraError(.unauthorized, "Approval authorization is stale.")) {
                try await service.resolve(
                    id: request.id, proposalHash: request.proposalHash,
                    authorizationEpoch: request.authorizationEpoch + 1, decision: .approved)
            }
            try await service.resolve(
                id: request.id, proposalHash: request.proposalHash,
                authorizationEpoch: request.authorizationEpoch, decision: .approved)
            #expect(try await waiting.value == .approved)
            await #expect(throws: MiraError(.notFound, "Approval request is no longer pending.")) {
                try await service.resolve(
                    id: request.id, proposalHash: request.proposalHash,
                    authorizationEpoch: request.authorizationEpoch, decision: .denied)
            }
            await service.shutdown()
        }

        @Test
        func consumedRequestCannotBeResolvedAgainAndGenericViewCompiles() async throws {
            let request = RuntimeApprovalRequest(
                invocationID: UUID(), executionID: ExecutionID(), proposalHash: "hash",
                authorizationEpoch: 2, expiresAt: Date().addingTimeInterval(30),
                prompt: "A generic prompt containing memory scope and source text.")
            var decisions: [RuntimeApprovalDecision] = []
            let view = RuntimeApprovalView(request: request) { decision in
                decisions.append(decision)
            }
            _ = AnyView(view)
            #expect(request.prompt.contains("memory scope"))
            #expect(decisions.isEmpty)

            let service = RuntimeApprovalService()
            let snapshots = await service.snapshots()
            let waiting = Task { try await service.request(request) }
            for await values in snapshots where values.contains(request) { break }
            try await service.resolve(
                id: request.id, proposalHash: request.proposalHash,
                authorizationEpoch: request.authorizationEpoch, decision: .denied)
            #expect(try await waiting.value == .denied)
            await #expect(throws: MiraError(.notFound, "Approval request is no longer pending.")) {
                try await service.resolve(
                    id: request.id, proposalHash: request.proposalHash,
                    authorizationEpoch: request.authorizationEpoch, decision: .approved)
            }
            await service.shutdown()
        }
    }
#endif

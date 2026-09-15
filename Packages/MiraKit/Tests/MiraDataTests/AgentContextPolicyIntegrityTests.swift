import Foundation
import GRDB
import Testing
@testable import MiraCore
@testable import MiraData

@Suite("Context policy integrity", .timeLimit(.minutes(1)))
struct AgentContextPolicyIntegrityTests {
    @Test func missingWorkspaceIsUnauthorized() async throws {
        try await withTaskWorkflow { fixture in
            let request = policyRequest(fixture, workspaceID: WorkspaceID())
            do {
                try await fixture.contextPolicy.validate(request)
                Issue.record("A missing workspace was accepted by context policy")
            } catch let error as MiraError {
                #expect(error.code == .unauthorized)
            }
        }
    }

    @Test func corruptWorkspaceRecordIsStorageFailure() async throws {
        try await withTaskWorkflow { fixture in
            let workspace = Workspace(id: .init(), name: "Corrupt workspace")
            let lease = try await fixture.access.acquire(in: fixture.scope)
            do {
                try await fixture.workspaces.saveWorkspace(workspace, expectedRevision: nil, authorization: lease.authorization)
            } catch {
                await lease.release()
                throw error
            }
            await lease.release()
            try await fixture.database.write { db in
                let bytes = try SessionCodec.encode(Workspace(id: workspace.id, name: workspace.name, revision: -1))
                try db.execute(sql: "UPDATE business_workspaces SET json = ? WHERE id = ?",
                               arguments: [bytes, workspace.id.rawValue.uuidString.lowercased()])
            }
            do {
                try await fixture.contextPolicy.validate(policyRequest(fixture, workspaceID: workspace.id))
                Issue.record("A corrupt workspace record was accepted by context policy")
            } catch let error as MiraError {
                #expect(error.code == .storage)
            }
            do {
                _ = try await fixture.workspaces.workspace(workspace.id)
                Issue.record("A corrupt workspace record was returned by the store")
            } catch let error as MiraError {
                #expect(error.code == .storage)
            }
        }
    }

    @Test func corruptConfigurationRecordIsStorageFailure() async throws {
        try await withTaskWorkflow { fixture in
            try await fixture.database.write { db in
                let bytes = try #require(try Data.fetchOne(db, sql: "SELECT json FROM settings_connections"))
                guard case .object(var fields) = try SessionCodec.decode(JSONValue.self, from: bytes) else {
                    throw MiraError(.storage, "The synthetic settings record is not an object.")
                }
                fields["revision"] = .number(-1)
                try db.execute(sql: "UPDATE settings_connections SET json = ?", arguments: [try SessionCodec.encode(JSONValue.object(fields))])
            }
            do {
                try await fixture.contextPolicy.validate(policyRequest(fixture))
                Issue.record("A corrupt settings record was accepted by context policy")
            } catch let error as MiraError {
                #expect(error.code == .storage)
            }
        }
    }
}

private func policyRequest(_ fixture: TaskWorkflowFixture, workspaceID: WorkspaceID? = nil) -> AgentContextRequest {
    .init(sessionID: .init(), executionID: .init(), workspaceID: workspaceID,
          userText: "Synthetic context policy request", authorizationEpoch: 0,
          destination: .model(fixture.route))
}

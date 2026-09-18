import Foundation
import Testing
@testable import MiraCore

@Suite("Agent execution plan")
struct AgentExecutionPlanTests {
    @Test func validPlanRoundTripsAndValidates() throws {
        let plan = AgentExecutionPlan(runtimeID: UUID(), catalogGeneration: 4,
            driverID: "driver.one", driverRevision: 2, instructions: "Be concise.",
            limits: .init(), priority: .foreground, route: nil)
        try plan.validate()
        let data = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(AgentExecutionPlan.self, from: data) == plan)
    }

    @Test(arguments: ["", "Driver.One", String(repeating: "a", count: 129)])
    func invalidDriverIDIsRejected(_ driverID: String) {
        #expect(throws: MiraError.self) {
            try makePlan(driverID: driverID).validate()
        }
    }

    @Test(arguments: [0, -1])
    func nonPositiveDriverRevisionIsRejected(_ revision: Int) {
        #expect(throws: MiraError.self) {
            try makePlan(driverRevision: revision).validate()
        }
    }

    @Test func instructionsAreBounded() {
        #expect(throws: MiraError.self) {
            try makePlan(instructions: String(repeating: "x", count: 65_537)).validate()
        }
    }

    @Test func limitsAndRouteAreValidated() {
        #expect(throws: MiraError.self) {
            try makePlan(limits: .init(maximumSteps: 0)).validate()
        }
        #expect(throws: MiraError.self) {
            try makePlan(route: invalidRoute()).validate()
        }
    }

    @Test(arguments: [1, 3_600_000])
    func modelPreparationTimeoutAcceptsSupportedBounds(_ timeout: Int) throws {
        let limits = AgentExecutionLimits(modelPreparationTimeoutMilliseconds: timeout)
        try limits.validate()
        #expect(limits.modelPreparationTimeoutMilliseconds == timeout)
    }

    @Test(arguments: [0, -1, 3_600_001])
    func modelPreparationTimeoutRejectsUnsupportedBounds(_ timeout: Int) {
        #expect(throws: MiraError.self) {
            try makePlan(limits: .init(modelPreparationTimeoutMilliseconds: timeout)).validate()
        }
    }

    @Test func nonDefaultModelPreparationTimeoutSurvivesPlanEncoding() throws {
        let limits = AgentExecutionLimits(modelPreparationTimeoutMilliseconds: 12_345)
        let plan = makePlan(limits: limits)
        try plan.validate()
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(AgentExecutionPlan.self, from: data)
        #expect(decoded == plan)
        #expect(decoded.limits.modelPreparationTimeoutMilliseconds == 12_345)
    }

    @Test func missingModelPreparationTimeoutIsRejectedWithoutLegacyDefault() throws {
        let data = try JSONEncoder().encode(makePlan())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var limits = try #require(object["limits"] as? [String: Any])
        #expect(limits["modelPreparationTimeoutMilliseconds"] != nil)
        limits.removeValue(forKey: "modelPreparationTimeoutMilliseconds")
        #expect(limits["modelPreparationTimeoutMilliseconds"] == nil)
        object["limits"] = limits
        let missingFieldData = try JSONSerialization.data(withJSONObject: object)

        do {
            _ = try JSONDecoder().decode(AgentExecutionPlan.self, from: missingFieldData)
            Issue.record("Missing model preparation timeout was silently defaulted")
        } catch DecodingError.keyNotFound(let key, let context) {
            #expect(key.stringValue == "modelPreparationTimeoutMilliseconds")
            #expect(context.codingPath.last?.stringValue == "limits")
        } catch {
            Issue.record("Missing model preparation timeout failed with an unexpected decoding error: \(error)")
        }
    }

    private func makePlan(driverID: String = "driver.one", driverRevision: Int = 1,
                          instructions: String = "Instructions", limits: AgentExecutionLimits = .init(),
                          route: AgentModelRoute? = nil) -> AgentExecutionPlan {
        .init(runtimeID: UUID(), catalogGeneration: 1, driverID: driverID, driverRevision: driverRevision,
              instructions: instructions, limits: limits, priority: .background, route: route)
    }

    private func invalidRoute() -> AgentModelRoute {
        .init(id: RouteID(), revision: 0, connectionID: ConnectionID(), connectionRevision: 1,
              modelDescriptorID: ModelDescriptorID(), modelRevision: 1,
              modelAuthorizationRevision: 1, adapter: .init(id: "model.adapter", revision: 1), invocationID: "test-invocation", invocationRevision: 1, endpointID: "test-endpoint", modelID: "fixture", credential: nil,
              contextWindow: 4_096, maximumOutputTokens: 512,
              capabilities: .init(streamsText: true, callsTools: false, producesThinking: false),
              configuration: .object([:]))
    }
}

import Foundation

/// The immutable runtime choices captured when an execution is admitted.
public struct AgentExecutionPlan: Codable, Sendable, Equatable {
    public let runtimeID: UUID
    public let catalogGeneration: UInt64
    public let driverID: String
    public let driverRevision: Int
    public let instructions: String
    public let limits: AgentExecutionLimits
    public let priority: RuntimePriority
    public let route: AgentModelRoute?

    public init(runtimeID: UUID, catalogGeneration: UInt64, driverID: String, driverRevision: Int,
                instructions: String, limits: AgentExecutionLimits, priority: RuntimePriority,
                route: AgentModelRoute?) {
        self.runtimeID = runtimeID; self.catalogGeneration = catalogGeneration
        self.driverID = driverID; self.driverRevision = driverRevision
        self.instructions = instructions; self.limits = limits
        self.priority = priority; self.route = route
    }

    public func validate() throws {
        guard SessionState.validIdentifier(driverID, maximumBytes: 128), driverRevision > 0,
              instructions.utf8.count <= 65_536 else {
            throw MiraError(.configuration, "The execution plan identity or instructions are invalid.")
        }
        try limits.validate()
        try route?.validate()
    }

    /// Reads the immutable plan admitted for one execution and verifies the
    /// duplicated route bit before any execution work uses it.
    public static func read(for admission: SessionAdmission,
                            from payloads: any SessionPayloadReader) async throws -> Self {
        let plan = try SessionCodec.decode(Self.self, from: await payloads.read(admission.plan))
        try plan.validate()
        guard admission.hasModelRoute == (plan.route != nil) else {
            throw MiraError(.storage, "The execution plan metadata is inconsistent.")
        }
        return plan
    }
}

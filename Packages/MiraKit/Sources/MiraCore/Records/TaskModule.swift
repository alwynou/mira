import Foundation

/// Registers task read and proposal tools into one runtime scope.
public struct TaskModule: RuntimeModule {
    public let id = "mira.tasks"
    public let dependencies: Set<String> = []

    private let registry: RuntimeRegistry<AgentCapability>
    private let store: any TaskReadStore
    private let sourceAuthorities: RuntimeRegistry<any AgentDomainSourceAuthority>

    public init(registry: RuntimeRegistry<AgentCapability>, store: any TaskReadStore,
                sourceAuthorities: RuntimeRegistry<any AgentDomainSourceAuthority>) {
        self.registry = registry
        self.store = store
        self.sourceAuthorities = sourceAuthorities
    }

    public func activate(in scope: RuntimeScope) async throws {
        try await sourceAuthorities.register(id: "tasks", value: TaskSourceAuthority(store: store), scope: scope)
        try await registry.register(
            id: "task.list",
            value: .tool(.read(TaskListTool(store: store))),
            scope: scope,
            order: 0
        )
        try await registry.register(
            id: "task.change",
            value: .tool(.localWrite(TaskMutationTool(store: store))),
            scope: scope,
            order: 1
        )
    }
}

public struct TaskSourceAuthority: AgentDomainSourceAuthority {
    public let namespace = "tasks"
    private let store: any TaskReadStore

    public init(store: any TaskReadStore) {
        self.store = store
    }

    public func validate(_ sources: [AgentSourceReference], for request: AgentContextRequest) async throws {
        for source in sources {
            guard case .domain(let namespace, let id, let revision) = source, namespace == self.namespace else { throw Self.unavailable }
            do {
                let historical = try await store.taskRevision(.init(id), revision: revision, workspaceID: request.workspaceID)
                guard historical.task.id.rawValue == id, historical.task.workspaceID == request.workspaceID,
                      historical.task.revision == revision else { throw Self.unavailable }
            } catch let error as MiraError where error.code == .notFound {
                throw Self.unavailable
            }
        }
    }
    private static var unavailable: MiraError { .init(.unauthorized, "The context source is unavailable for this destination.") }
}

private struct TaskListTool: AgentReadTool {
    var policy: AgentToolPolicyRequirement { .hostOnly }
    private let store: any TaskReadStore

    init(store: any TaskReadStore) {
        self.store = store
    }

    var descriptor: AgentToolDescriptor {
        .init(
            definition: .init(
                name: "task.list",
                description: "List tasks in the current workspace, including revisions, due times, and reminder delivery state.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "include_completed": .object(["type": .string("boolean")])
                    ]),
                    "required": .array([]),
                    "additionalProperties": .bool(false)
                ])
            ),
            revision: 1,
            outputSchema: TaskTools.listResultSchema,
            executionMode: .parallelSafe,
            timeoutMilliseconds: 30_000,
            maximumResultBytes: 32_768
        )
    }

    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        let normalized = try ToolSchemaValidator.decode(
            try arguments.jsonString(),
            schema: descriptor.definition.inputSchema
        )
        let includeCompleted = normalized["include_completed"] == .bool(true)
        let tasks = try await store.taskList(workspaceID: context.evidence.workspaceID,
                                             includeCompleted: includeCompleted,
                                             limit: 50)
        guard tasks.count <= 50, Set(tasks.map(\.id)).count == tasks.count,
              tasks.allSatisfy({ $0.workspaceID == context.evidence.workspaceID && $0.revision > 0 }) else {
            throw MiraError(.storage, "The task record is inconsistent.")
        }

        var values: [JSONValue] = []
        var sources: [AgentSourceReference] = []
        values.reserveCapacity(tasks.count)
        sources.reserveCapacity(tasks.count)

        for task in tasks {
            let value = try TaskTools.summary(task)
            let candidate = Self.result(reference: context.evidence, tasks: values + [value], truncated: false)
            guard try candidate.jsonString().utf8.count <= 24_000 else { break }
            values.append(value)
            sources.append(.domain(namespace: "tasks", id: task.id.rawValue, revision: task.revision))
        }

        let result = Self.result(reference: context.evidence,
                                 tasks: values,
                                 truncated: values.count < tasks.count || tasks.count == 50)
        return .init(input: result, sources: sources, targets: [])
    }

    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue {
        try plan.validate()
        for source in plan.sources {
            guard case .domain(let namespace, let id, let revision) = source,
                  namespace == "tasks", revision > 0 else {
                throw MiraError(.conflict, "The task list source is invalid or stale.")
            }
            let task = try await store.taskDetail(MiraTaskID(id), workspaceID: context.evidence.workspaceID)
            guard task.id.rawValue == id, task.revision == revision,
                  task.workspaceID == context.evidence.workspaceID else {
                throw MiraError(.conflict, "The task list changed before it could be returned.")
            }
        }
        return plan.input
    }

    private static func result(reference: SessionUserEvidence, tasks: [JSONValue], truncated: Bool) -> JSONValue {
        .object([
            "reference_time": .string(reference.admittedAt.ISO8601Format()),
            "time_zone": .string(reference.timeZoneIdentifier),
            "tasks": .array(tasks),
            "truncated": .bool(truncated)
        ])
    }
}

private struct TaskMutationTool: AgentLocalWriteTool {
    var policy: AgentToolPolicyRequirement { .hostOnly }
    private let store: any TaskReadStore

    init(store: any TaskReadStore) {
        self.store = store
    }

    var businessNamespace: String { "tasks.change" }

    var descriptor: AgentToolDescriptor {
        .init(
            definition: TaskTools.mutationDefinition,
            revision: 1,
            outputSchema: TaskTools.mutationResultSchema,
            executionMode: .exclusive,
            timeoutMilliseconds: 30_000,
            maximumResultBytes: 8_192
        )
    }

    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan {
        let normalized = try ToolSchemaValidator.decode(
            try arguments.jsonString(),
            schema: TaskTools.mutationDefinition.inputSchema
        )
        let evidence = TaskEvidence(context.evidence)
        try evidence.validate()
        guard normalized["quote"]?.stringValue == evidence.quote else {
            throw MiraError(.invalidInput, "The task quote must match the complete admitted user message.")
        }

        let proposal = try TaskCommandInterpreter.proposal(
            arguments: normalized,
            reference: evidence,
            workspaceID: context.evidence.workspaceID,
            operationID: context.invocationID,
            at: context.evidence.admittedAt
        )

        if let taskID = proposal.taskID {
            guard let expectedRevision = proposal.expectedRevision else {
                throw MiraError(.conflict, "The task revision is required for an existing task.")
            }
            let current = try await store.taskDetail(taskID, workspaceID: context.evidence.workspaceID)
            guard current.id == taskID, current.workspaceID == context.evidence.workspaceID,
                  current.revision == expectedRevision else {
                throw MiraError(.conflict, "The task changed before the command was prepared.")
            }
            return .init(
                input: normalized,
                sources: [],
                targets: [.domain(namespace: "tasks", id: taskID.rawValue, revision: expectedRevision)]
            )
        }

        return .init(input: normalized, sources: [], targets: [])
    }
}

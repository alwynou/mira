import Foundation
import Testing
@testable import MiraCore

@Suite("Agent runtime catalog")
struct AgentRuntimeCatalogTests {
    @Test func toolCatalogDoesNotApplyAnAdaptersWireNamingRules() throws {
        let tools: [AgentTool] = [.read(CatalogTool(name: "catalog.read")), .read(CatalogTool(name: "catalog_read"))]
        #expect(try AgentToolCatalog(tools).definitions.map(\.name) == ["catalog.read", "catalog_read"])
        #expect(throws: MiraError.self) { try AgentToolCatalog([tools[0], tools[0]]) }
    }

    @Test func snapshotProvidesAtomicTypedLookups() async throws {
        let registry = RuntimeRegistry<AgentCapability>()
        let scope = RuntimeScope(kind: .application)
        let model = CatalogModel(id: "family.one", revision: 2)
        let driver = CatalogDriver(id: "driver.one")
        let newerDriver = CatalogDriver(id: driver.id, revision: 2)
        let contributor = CatalogContributor(id: "context.one")
        let tool = CatalogTool()
        try await registry.register(id: "model", value: .model(model), scope: scope, order: 0)
        try await registry.register(id: "driver", value: .driver(driver), scope: scope, order: 1)
        try await registry.register(id: "driver.newer", value: .driver(newerDriver), scope: scope, order: 1)
        try await registry.register(id: "context", value: .context(contributor), scope: scope, order: 2)
        try await registry.register(id: "tool", value: .tool(.read(tool)), scope: scope, order: 3)

        let snapshot = try await registry.freeze()
        let catalog = try AgentRuntimeCatalog(snapshot: snapshot)
        #expect(catalog.generation == snapshot.generation)
        let lookedUpModel = try catalog.model(identity: model.identity)
        let lookedUpDriver = try catalog.driver(id: driver.id, revision: driver.revision)
        let lookedUpNewerDriver = try catalog.driver(id: newerDriver.id, revision: newerDriver.revision)
        #expect(lookedUpModel.identity == model.identity)
        #expect(lookedUpDriver.id == driver.id)
        #expect(lookedUpDriver.revision == driver.revision)
        #expect(lookedUpNewerDriver.revision == newerDriver.revision)
        #expect(catalog.contributors.map(\.id) == [contributor.id])
        #expect(catalog.tools.definitions.map(\.name) == ["catalog.read"])
        #expect(throws: MiraError.self) { try catalog.model(identity: .init(id: model.identity.id, revision: 1)) }
        #expect(throws: MiraError.self) { try catalog.driver(id: driver.id, revision: 3) }
        #expect(throws: MiraError.self) { try catalog.driver(id: "missing", revision: 1) }
        await catalog.release()
    }

    @Test func duplicateSemanticIdentitiesAreRejected() async throws {
        let registry = RuntimeRegistry<AgentCapability>()
        let scope = RuntimeScope(kind: .application)
        try await registry.register(id: "first", value: .model(CatalogModel(id: "same.model", revision: 1)), scope: scope)
        try await registry.register(id: "second", value: .model(CatalogModel(id: "same.model", revision: 2)), scope: scope)
        let snapshot = try await registry.freeze()
        do {
            let catalog = try AgentRuntimeCatalog(snapshot: snapshot)
            Issue.record("Duplicate model semantic identity was accepted")
            await catalog.release()
        } catch {
            await snapshot.release()
        }
    }

    @Test func oldSnapshotPinsScopeWhileNewSnapshotOmitsUnregisteredCapability() async throws {
        let registry = RuntimeRegistry<AgentCapability>()
        let scope = RuntimeScope(kind: .application)
        let model = CatalogModel(id: "pinned.model", revision: 1)
        try await registry.register(id: "model", value: .model(model), scope: scope)
        let old = try await registry.freeze()
        try await registry.unregister(id: "model")
        let current = try await registry.freeze()
        #expect(current.entries.isEmpty)
        #expect(old.entries.count == 1)
        let oldCatalog = try AgentRuntimeCatalog(snapshot: old)
        let lookedUpModel = try oldCatalog.model(identity: model.identity)
        #expect(lookedUpModel.identity == model.identity)
        await current.release()
        await oldCatalog.release()
        await old.release()
    }
}

private struct CatalogModel: AgentModelAdapter {
    let identity: AgentAdapterIdentity
    init(id: String, revision: Int) { identity = .init(id: id, revision: revision) }
    func prepare(_ input: AgentModelInput, route: AgentModelRoute) throws -> AgentPreparedModelRequest { fatalError("unreachable") }
    func stream(_ request: AgentPreparedModelRequest, route: AgentModelRoute) -> AgentModelOperation {
        fatalError("unreachable")
    }
    func replay(_ messages: [AgentModelMessage], from source: AgentModelRoute, to target: AgentModelRoute, boundary: AgentReplayBoundary) throws -> AgentReplayDecision { fatalError("unreachable") }
}

private struct CatalogDriver: AgentDriver {
    let id: String
    let revision: Int
    init(id: String, revision: Int = 1) { self.id = id; self.revision = revision }
    func run(in context: AgentRunContext) async throws -> AgentDriverDecision { fatalError("unreachable") }
}

private struct CatalogContributor: AgentContextContributor {
    let id: String
    let isRequired = false
    func contribute(to request: AgentContextRequest) async throws -> [AgentContextItem] { [] }
}

private struct CatalogTool: AgentReadTool {
    let policy: AgentToolPolicyRequirement = .hostOnly
    let name: String
    init(name: String = "catalog.read") { self.name = name }
    var descriptor: AgentToolDescriptor { AgentToolDescriptor(
        definition: .init(name: name, description: "Catalog test tool", inputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])),
        revision: 1,
        outputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]),
        executionMode: .exclusive,
        timeoutMilliseconds: 1_000,
        maximumResultBytes: 1_024
    ) }
    func prepare(_ arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolPlan { .init(input: arguments, sources: [], targets: []) }
    func execute(_ plan: AgentToolPlan, context: AgentToolContext) async throws -> JSONValue { .object([:]) }
}

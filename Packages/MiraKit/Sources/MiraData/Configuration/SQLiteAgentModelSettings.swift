import Foundation
import GRDB
import MiraCore

/// Current business settings in a caller-owned database. No session projection participates in these reads.
public final class SQLiteAgentModelSettings: AgentModelSettingsStore, @unchecked Sendable {
    private let database: DatabaseQueue
    private let libraryID: UUID
    private let io = DispatchQueue(label: "mira.agent-model-settings", qos: .utility)
    private let lock = NSLock()
    private var accepting = true
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    internal var isClosing: Bool { lock.withLock { !accepting } }

    public init(database: DatabaseQueue, libraryID: UUID) throws {
        self.database = database
        self.libraryID = libraryID
        do {
            try database.write { db in
                let synchronous = try Int.fetchOne(db, sql: "PRAGMA synchronous")
                guard synchronous == 2 || synchronous == 3,
                    try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1
                else { throw Self.durability }
                try SQLiteLibraryAuthority.validateInitialized(in: db, libraryID: libraryID)
                try Self.initialize(db)
            }
        } catch { throw Self.safe(error) }
    }

    /// Reject new work, drain every accepted operation, and leave the shared database open.
    public func close() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            accepting = false
            if active == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    public func discoverySnapshot(connectionID: ConnectionID) async throws -> AgentModelDiscoverySnapshot? {
        try await read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM settings_discovery WHERE connection_id = ?",
                arguments: [connectionID.rawValue.uuidString]) else { return nil }
            return try Self.decodeDiscovery(row)
        }
    }

    public func saveDiscoverySnapshot(_ value: AgentModelDiscoverySnapshot, expectedRevision: Int?,
                                      authorization: AgentLibraryAuthorization) async throws {
        try value.validate()
        try await write(authorization: authorization) { db in
            guard let connection = try Self.one(AgentConfiguredConnection.self, key: Self.key(value.connectionID.rawValue), db: db),
                connection.isEnabled, connection.configurationRevision == value.configurationRevision,
                connection.discovery?.adapter == value.adapter else { throw Self.conflict }
            let row = try Row.fetchOne(db, sql: "SELECT * FROM settings_discovery WHERE connection_id = ?",
                arguments: [value.connectionID.rawValue.uuidString])
            let previous = try row.map(Self.decodeDiscovery)
            try Self.cas(old: previous?.revision, expected: expectedRevision, value: value.revision)
            try db.execute(sql: "INSERT INTO settings_discovery(connection_id,revision,configuration_revision,json) VALUES(?,?,?,?) ON CONFLICT(connection_id) DO UPDATE SET revision=excluded.revision,configuration_revision=excluded.configuration_revision,json=excluded.json",
                arguments: [value.connectionID.rawValue.uuidString, value.revision, value.configurationRevision, try SessionCodec.encode(value)])
        }
    }

    private static func decodeDiscovery(_ row: Row) throws -> AgentModelDiscoverySnapshot {
        guard let bytes: Data = row["json"], bytes.count <= 2_097_152 else { throw invalid }
        let value = try SessionCodec.decode(AgentModelDiscoverySnapshot.self, from: bytes)
        try value.validate()
        guard try SessionCodec.encode(value) == bytes,
            (row["connection_id"] as String?) == value.connectionID.rawValue.uuidString,
            (row["revision"] as Int?) == value.revision,
            (row["configuration_revision"] as Int?) == value.configurationRevision else { throw invalid }
        return value
    }

    public func connection(id: ConnectionID) async throws -> AgentConfiguredConnection? {
        try await read { try Self.one(AgentConfiguredConnection.self, key: Self.key(id.rawValue), db: $0) }
    }

    public func model(id: ModelDescriptorID) async throws -> AgentConfiguredModel? {
        try await read { try Self.one(AgentConfiguredModel.self, key: Self.key(id.rawValue), db: $0) }
    }

    public func preset(id: RouteID) async throws -> AgentRoutePreset? {
        try await read { try Self.one(AgentRoutePreset.self, key: Self.key(id.rawValue), db: $0) }
    }

    public func connections(after: ConnectionID?, limit: Int) async throws -> [AgentConfiguredConnection] {
        try await read { try Self.page(AgentConfiguredConnection.self, after: after?.rawValue, limit: limit, db: $0) }
    }

    public func models(connectionID: ConnectionID?, after: ModelDescriptorID?, limit: Int) async throws -> [AgentConfiguredModel] {
        try await read {
            try Self.page(
                AgentConfiguredModel.self, after: after?.rawValue, limit: limit,
                filter: connectionID.map { ["connection_id": $0.rawValue.uuidString.databaseValue] } ?? [:], db: $0)
        }
    }

    public func presets(modelID: ModelDescriptorID?, after: RouteID?, limit: Int) async throws -> [AgentRoutePreset] {
        try await read {
            try Self.page(
                AgentRoutePreset.self, after: after?.rawValue, limit: limit,
                filter: modelID.map { ["model_id": $0.rawValue.uuidString.databaseValue] } ?? [:], db: $0)
        }
    }

    public func ensureConversationDefault(authorization: AgentLibraryAuthorization) async throws -> AgentRouteBinding? {
        try await write(authorization: authorization) { try Self.ensureConversationDefault(in: $0) }
    }

    @discardableResult
    private static func ensureConversationDefault(in db: Database) throws -> AgentRouteBinding? {
        let purpose = AgentModelPurposeID.conversation
        if let existing = try one(AgentRouteBinding.self, key: bindingKey(.global, purpose), db: db) { return existing }
        // A provider activation admits its already-enabled models together, in saved order.
        for row in try Row.fetchAll(db, sql: "SELECT m.* FROM settings_models m JOIN settings_presets p ON p.id = m.id ORDER BY m.rowid") {
            let model = try decode(AgentConfiguredModel.self, row: row)
            guard model.isEnabled,
                  let connection = try one(AgentConfiguredConnection.self, key: key(model.connectionID.rawValue), db: db),
                  connection.isEnabled else { continue }
            let routeID = RouteID(model.id.rawValue)
            guard let preset = try one(AgentRoutePreset.self, key: key(routeID.rawValue), db: db),
                  preset.modelDescriptorID == model.id else { continue }
            let value = AgentRouteBinding(scope: .global, purpose: purpose, routeID: routeID, revision: 1)
            try persist(value, isNew: true, db: db)
            return value
        }
        return nil
    }

    public func bindings(scope: AgentRouteScope) async throws -> [AgentRouteBinding] {
        try await read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM settings_bindings WHERE scope = ? ORDER BY purpose LIMIT 65",
                arguments: [scope.key])
            guard rows.count <= 64 else { throw Self.invalid }
            return try rows.map { try Self.decode(AgentRouteBinding.self, row: $0) }
        }
    }

    public func candidate(routeID: RouteID) async throws -> AgentModelRouteCandidate {
        try await read { try Self.assemble(routeID: routeID, db: $0) }
    }

    public func select(
        purpose: String, explicitRouteID: RouteID?,
        workspaceID: WorkspaceID?
    ) async throws -> AgentModelRouteSelection {
        // Use the common identifier rules, including the same ASCII bounds as persisted bindings.
        try AgentRouteBinding(scope: .global, purpose: purpose, routeID: explicitRouteID ?? .init(), revision: 1).validate()
        return try await read { db in
            if let explicitRouteID {
                return .init(candidate: try Self.selectedCandidate(routeID: explicitRouteID, db: db), binding: nil)
            }
            return try Self.select(purpose: purpose, workspaceID: workspaceID, in: db)
        }
    }

    public func saveConnection(_ value: AgentConfiguredConnection, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws {
        try await write(authorization: authorization) { db in
            try value.validate()
            let previous = try Self.one(AgentConfiguredConnection.self, key: value.key, db: db)
            try Self.cas(old: previous?.revision, expected: expectedRevision, value: value.revision)
            let configurationRevision: Int
            if let previous {
                let changed = previous.endpoints != value.endpoints || previous.isEnabled != value.isEnabled
                if changed {
                    guard previous.configurationRevision < Int.max else { throw Self.conflict }
                    configurationRevision = previous.configurationRevision + 1
                } else {
                    configurationRevision = previous.configurationRevision
                }
            } else {
                configurationRevision = 1
            }
            guard value.configurationRevision == configurationRevision else { throw Self.conflict }
            try Self.persist(value, isNew: previous == nil, db: db)
            if value.isEnabled { try Self.ensureConversationDefault(in: db) }
        }
    }

    public func saveModel(_ value: AgentConfiguredModel, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws {
        try await write(authorization: authorization) { try Self.saveModel(value, expectedRevision: expectedRevision, db: $0) }
    }

    public func savePreset(_ value: AgentRoutePreset, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws {
        try await write(authorization: authorization) { try Self.savePreset(value, expectedRevision: expectedRevision, db: $0) }
    }

    public func savePoolModel(
        _ model: AgentConfiguredModel, preset: AgentRoutePreset,
        expectedModelRevision: Int?, expectedPresetRevision: Int?, authorization: AgentLibraryAuthorization
    ) async throws {
        try await write(authorization: authorization) { db in
            guard model.id.rawValue == preset.id.rawValue, preset.modelDescriptorID == model.id else { throw Self.conflict }
            try Self.saveModel(model, expectedRevision: expectedModelRevision, db: db)
            try Self.savePreset(preset, expectedRevision: expectedPresetRevision, db: db)
            try Self.ensureConversationDefault(in: db)
        }
    }

    public func saveBinding(_ value: AgentRouteBinding, expectedRevision: Int?, authorization: AgentLibraryAuthorization) async throws {
        try await write(authorization: authorization) { db in
            try value.validate()
            let previous = try Self.one(AgentRouteBinding.self, key: value.key, db: db)
            try Self.cas(old: previous?.revision, expected: expectedRevision, value: value.revision)
            guard try Self.one(AgentRoutePreset.self, key: Self.key(value.routeID.rawValue), db: db) != nil else { throw Self.missing }
            try Self.persist(value, isNew: previous == nil, db: db)
        }
    }

    public func deleteConnection(id: ConnectionID, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws {
        try await write(authorization: authorization) { try Self.delete(AgentConfiguredConnection.self, key: Self.key(id.rawValue), expected: expectedRevision, db: $0) }
    }

    public func deleteModel(id: ModelDescriptorID, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws {
        try await write(authorization: authorization) { try Self.delete(AgentConfiguredModel.self, key: Self.key(id.rawValue), expected: expectedRevision, db: $0) }
    }

    public func deletePreset(id: RouteID, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws {
        try await write(authorization: authorization) { try Self.delete(AgentRoutePreset.self, key: Self.key(id.rawValue), expected: expectedRevision, db: $0) }
    }

    public func deleteBinding(scope: AgentRouteScope, purpose: String, expectedRevision: Int, authorization: AgentLibraryAuthorization) async throws {
        try await write(authorization: authorization) {
            try Self.delete(AgentRouteBinding.self, key: Self.bindingKey(scope, purpose), expected: expectedRevision, db: $0)
        }
    }

    private func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await enqueue { try self.database.read { db in
            _ = try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: self.libraryID)
            return try body(db)
        } }
    }

    private func write<T: Sendable>(authorization: AgentLibraryAuthorization,
                                    _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await enqueue { try self.database.write { db in
            let current = try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: self.libraryID)
            guard current == authorization else { throw Self.authorization }
            return try body(db)
        } }
    }

    private func enqueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        guard begin() else { throw Self.closed }
        return try await withCheckedThrowingContinuation { continuation in
            io.async {
                let result: Result<T, Error>
                do { result = .success(try body()) } catch { result = .failure(Self.safe(error)) }
                self.finish()
                continuation.resume(with: result)
            }
        }
    }

    private func begin() -> Bool {
        lock.withLock {
            guard accepting else { return false }
            active += 1
            return true
        }
    }

    private func finish() {
        lock.lock()
        active -= 1
        let pending = active == 0 && !accepting ? waiters : []
        if !pending.isEmpty { waiters.removeAll() }
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

extension SQLiteAgentModelSettings {
    public static func archiveModule() throws -> SQLiteArchiveModule {
        let restoration: SQLiteArchiveRestoration = .prepare(
            apply: { db, _ in
                var values: [AgentConfiguredConnection] = []
                try SQLiteArchiveValidation.rows(in: db, table: "settings_connections", maximumRows: AgentConfiguredConnection.limit,
                    maximumBytes: ["json": 131_072, "id": 128]) { values.append(try decode(AgentConfiguredConnection.self, row: $0)) }
                for value in values {
                    let disabled = AgentConfiguredConnection(id: value.id, revision: value.revision,
                        configurationRevision: value.configurationRevision, name: value.name, isEnabled: false,
                        definitionID: value.definitionID,
                        endpoints: value.endpoints.map { .init(id: $0.id, configuration: $0.configuration, credential: nil) },
                        discovery: value.discovery, defaultInvocation: value.defaultInvocation)
                    let bytes = try SessionCodec.encode(disabled)
                    try db.execute(sql: "UPDATE settings_connections SET json = ? WHERE id = ?", arguments: [bytes, value.id.rawValue.uuidString])
                }
            },
            verify: { db in
                try SQLiteArchiveValidation.rows(in: db, table: "settings_connections", maximumRows: AgentConfiguredConnection.limit,
                    maximumBytes: ["json": 131_072, "id": 128]) { row in
                    let value = try decode(AgentConfiguredConnection.self, row: row)
                    guard !value.isEnabled, value.endpoints.allSatisfy({ $0.credential == nil }) else { throw LibraryArchiveIO.invalid }
                }
            })
        return try SQLiteArchiveModule(identity: .init(name: "model.settings", revision: 2),
            schemaStatements: definitions.values.sorted() + [retiredDefinition] + indexDefinitions.values.sorted(), restoration: restoration) { db, snapshot in
                try SQLiteArchiveValidation.metadata("settings_schema", in: db, expectedVersion: 2)
                try SQLiteArchiveValidation.rows(in: db, table: "settings_retired_ids", maximumRows: 65_536,
                    maximumBytes: ["kind": 64, "id": 36]) { row in
                    guard let kind: String = row["kind"], let id: String = row["id"], UUID(uuidString: id) != nil,
                        ["settings_connections", "settings_models", "settings_presets"].contains(kind) else { throw LibraryArchiveIO.invalid }
                }
                try SQLiteArchiveValidation.rows(in: db, table: "settings_discovery", maximumRows: 128,
                    maximumBytes: ["json": 2_097_152, "connection_id": 36]) { _ = try decodeDiscovery($0) }
                var connections = 0, models = 0, presets = 0, bindingCount = 0
                try SQLiteArchiveValidation.rows(in: db, table: "settings_connections", maximumRows: AgentConfiguredConnection.limit,
                    maximumBytes: ["json": 131_072, "id": 128]) { _ = try decode(AgentConfiguredConnection.self, row: $0); connections += 1 }
                try SQLiteArchiveValidation.rows(in: db, table: "settings_models", maximumRows: AgentConfiguredModel.limit,
                    maximumBytes: ["json": 131_072, "id": 128, "connection_id": 128, "model_key": 512]) { _ = try decode(AgentConfiguredModel.self, row: $0); models += 1 }
                try SQLiteArchiveValidation.rows(in: db, table: "settings_presets", maximumRows: AgentRoutePreset.limit,
                    maximumBytes: ["json": 131_072, "id": 128, "model_id": 128]) { _ = try decode(AgentRoutePreset.self, row: $0); presets += 1 }
                let workspaceIDs: Set<String>
                if try db.tableExists("business_workspaces") {
                    var identifiers = Set<String>()
                    try SQLiteArchiveValidation.rows(in: db, table: "business_workspaces", maximumRows: 1024, maximumBytes: ["id": 36]) { row in
                        guard let identifier: String = row["id"] else { throw LibraryArchiveIO.invalid }
                        identifiers.insert(identifier)
                    }
                    workspaceIDs = identifiers
                } else { workspaceIDs = [] }
                var scopes: [String: Int] = [:]
                try SQLiteArchiveValidation.rows(in: db, table: "settings_bindings", maximumRows: 8_192,
                    maximumBytes: ["json": 131_072, "scope": 128, "purpose": 128, "route_id": 128]) { row in
                    bindingCount += 1
                    let binding = try decode(AgentRouteBinding.self, row: row)
                    scopes[binding.scope.key, default: 0] += 1
                    guard scopes[binding.scope.key]! <= AgentRouteBinding.limit else { throw LibraryArchiveIO.invalid }
                    if case .workspace(let id) = binding.scope { guard workspaceIDs.contains(id.rawValue.uuidString.lowercased()) else { throw LibraryArchiveIO.invalid } }
                }
                guard connections <= 128, models <= 4096, presets <= 8192, bindingCount <= 8192 else { throw LibraryArchiveIO.invalid }
                return []
            }
    }
    static func applyMetadataUpdates(_ updates: [AgentModelMetadataUpdate], in db: Database) throws {
        for update in updates {
            try update.validate()
            let connection = try one(AgentConfiguredConnection.self, key: key(update.connection.id.rawValue), db: db)
            let model = try one(AgentConfiguredModel.self, key: key(update.previous.id.rawValue), db: db)
            guard connection == update.connection, model == update.previous else { throw conflict }
            try saveModel(update.updated, expectedRevision: update.previous.revision, db: db)
        }
    }

    /// Shared transaction-local selection for business dispatch checks.
    static func select(purpose: String, workspaceID: WorkspaceID?, in db: Database) throws -> AgentModelRouteSelection {
        let scopes = [workspaceID.map(AgentRouteScope.workspace), .some(.global)]
        for scope in scopes.compactMap({ $0 }) {
            if let binding = try one(AgentRouteBinding.self, key: bindingKey(scope, purpose), db: db) {
                return .init(candidate: try selectedCandidate(routeID: binding.routeID, db: db), binding: binding)
            }
        }
        throw missing
    }

    /// The core already validated adapter semantics while freezing the route. A domain commit
    /// rechecks every authoritative configuration identity inside its own transaction.
    static func validateFrozenIdentity(_ route: AgentModelRoute, in db: Database) throws {
        try route.validate()
        let unavailable = MiraError(.unauthorized, "The frozen model route is no longer available.")
        guard let preset = try one(AgentRoutePreset.self, key: key(route.id.rawValue), db: db),
              let model = try one(AgentConfiguredModel.self, key: key(preset.modelDescriptorID.rawValue), db: db),
              let connection = try one(AgentConfiguredConnection.self, key: key(model.connectionID.rawValue), db: db)
        else { throw unavailable }
        try AgentModelRouteCandidate(connection: connection, model: model, preset: preset).validateAuthorization(for: route)

    }

    fileprivate static let definitions: [String: String] = [
        "settings_schema": "CREATE TABLE settings_schema(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL CHECK(version=2))",
        "settings_connections":
            "CREATE TABLE settings_connections(id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), config_revision INTEGER NOT NULL CHECK(config_revision>0 AND config_revision<=revision), json BLOB NOT NULL CHECK(length(json)<=131072))",
        "settings_models":
            "CREATE TABLE settings_models(id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), connection_id TEXT NOT NULL REFERENCES settings_connections(id) ON DELETE CASCADE, authorization_revision INTEGER NOT NULL CHECK(authorization_revision>0 AND authorization_revision<=revision), model_key TEXT NOT NULL, json BLOB NOT NULL CHECK(length(json)<=131072), UNIQUE(connection_id,model_key))",
        "settings_presets":
            "CREATE TABLE settings_presets(id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), model_id TEXT NOT NULL REFERENCES settings_models(id) ON DELETE CASCADE, json BLOB NOT NULL CHECK(length(json)<=131072))",
        "settings_discovery":
            "CREATE TABLE settings_discovery(connection_id TEXT PRIMARY KEY NOT NULL REFERENCES settings_connections(id) ON DELETE CASCADE, revision INTEGER NOT NULL CHECK(revision>0), configuration_revision INTEGER NOT NULL CHECK(configuration_revision>0), json BLOB NOT NULL CHECK(length(json)<=2097152))",
        "settings_bindings":
            "CREATE TABLE settings_bindings(scope TEXT NOT NULL, purpose TEXT NOT NULL, route_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), json BLOB NOT NULL CHECK(length(json)<=131072), PRIMARY KEY(scope,purpose))",
    ]
    fileprivate static let retiredDefinition = "CREATE TABLE settings_retired_ids(kind TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(kind,id))"
    fileprivate static let indexDefinitions: [String: String] = [
        "settings_models_page": "CREATE INDEX settings_models_page ON settings_models(connection_id,id)",
        "settings_presets_page": "CREATE INDEX settings_presets_page ON settings_presets(model_id,id)",
        "settings_bindings_route": "CREATE INDEX settings_bindings_route ON settings_bindings(route_id)",
    ]

    fileprivate static func initialize(_ db: Database) throws {
        let names = Array(definitions.keys) + ["settings_retired_ids"]
        let present = try names.filter { try db.tableExists($0) }
        guard present.isEmpty || present.count == names.count else { throw unsupported }
        if present.isEmpty {
            for name in ["settings_schema", "settings_connections", "settings_models", "settings_presets", "settings_bindings", "settings_discovery"] {
                try db.execute(sql: definitions[name]!)
            }
            try db.execute(sql: retiredDefinition)
            for definition in indexDefinitions.values { try db.execute(sql: definition) }
            try db.execute(sql: "INSERT INTO settings_schema(id,version) VALUES(1,2)")
        }
        for (name, definition) in definitions.merging(["settings_retired_ids": retiredDefinition], uniquingKeysWith: { first, _ in first }).merging(indexDefinitions, uniquingKeysWith: { first, _ in first }) {
            guard try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = ?", arguments: [name]) == definition else {
                throw unsupported
            }
        }
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM settings_schema") == 1,
            try Int.fetchOne(db, sql: "SELECT version FROM settings_schema WHERE id=1") == 2
        else { throw unsupported }
        for name in names {
            guard try Row.fetchOne(db, sql: "PRAGMA foreign_key_check(\(name))") == nil else { throw invalid }
        }
    }

    fileprivate static func safe(_ error: Error) -> MiraError {
        error as? MiraError ?? MiraError(.storage, "The model settings store could not access its database.")
    }
    fileprivate static let durability = MiraError(
        .configuration, "The model settings store requires durable foreign-key database settings.")
    fileprivate static let unsupported = MiraError(.unsupported, "The model settings schema is unsupported.")
    fileprivate static let invalid = MiraError(.storage, "The model settings data is invalid.")
    fileprivate static let conflict = MiraError(.conflict, "The model settings revision conflicts with the current value.")
    fileprivate static let authorization = MiraError(.unauthorized, "The model settings authorization is stale or belongs to another library.")
    fileprivate static let missing = MiraError(.notFound, "The selected model route is unavailable.")
    fileprivate static let closed = MiraError(.cancelled, "The model settings store is closed.")
    fileprivate static let capacity = MiraError(.configuration, "The model settings limit was exceeded.")

    fileprivate static func key(_ id: UUID) -> [String: DatabaseValue] { ["id": id.uuidString.databaseValue] }
    fileprivate static func bindingKey(_ scope: AgentRouteScope, _ purpose: String) -> [String: DatabaseValue] {
        ["scope": scope.key.databaseValue, "purpose": purpose.databaseValue]
    }

    fileprivate static func predicate(_ values: [String: DatabaseValue]) -> (String, StatementArguments) {
        let keys = values.keys.sorted()
        return (keys.map { "\($0) = ?" }.joined(separator: " AND "), StatementArguments(keys.map { values[$0]! }))
    }

    fileprivate static func decode<R: SettingsRecord>(_ type: R.Type, row: Row) throws -> R {
        guard let data: Data = row["json"], data.count <= 131_072 else { throw invalid }
        let value = try SessionCodec.decode(type, from: data)
        do {
            try value.validate()
        } catch let error as MiraError where error.code == .configuration {
            throw invalid
        }
        guard try SessionCodec.encode(value) == data else { throw invalid }
        for (column, expected) in value.mirrors {
            guard row.hasColumn(column), row[column] as DatabaseValue == expected else { throw invalid }
        }
        return value
    }

    fileprivate static func one<R: SettingsRecord>(_ type: R.Type, key: [String: DatabaseValue], db: Database) throws -> R? {
        let (clause, arguments) = predicate(key)
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(R.table) WHERE \(clause)", arguments: arguments) else { return nil }
        return try decode(type, row: row)
    }

    fileprivate static func page<R: SettingsRecord>(
        _ type: R.Type, after: UUID?, limit: Int,
        filter: [String: DatabaseValue] = [:], db: Database
    ) throws -> [R] {
        guard (1...128).contains(limit) else { throw capacity }
        var clauses = filter.keys.sorted().map { "\($0) = ?" }
        var arguments = filter.keys.sorted().map { filter[$0]! }
        if let after {
            clauses.append("id > ?")
            arguments.append(after.uuidString.databaseValue)
        }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        arguments.append(limit.databaseValue)
        return try Row.fetchAll(
            db, sql: "SELECT * FROM \(R.table)\(whereClause) ORDER BY id LIMIT ?",
            arguments: StatementArguments(arguments)
        ).map { try decode(type, row: $0) }
    }

    fileprivate static func cas(old: Int?, expected: Int?, value: Int) throws {
        if let expected {
            guard expected > 0, expected < Int.max, old == expected, value == expected + 1 else { throw conflict }
        } else {
            guard old == nil, value == 1 else { throw conflict }
        }
    }

    fileprivate static func persist<R: SettingsRecord>(_ value: R, isNew: Bool, db: Database) throws {
        if isNew {
            if let id = value.key["id"] {
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM settings_retired_ids WHERE kind = ? AND id = ?",
                    arguments: StatementArguments([R.table.databaseValue, id])) == nil else { throw conflict }
            }
            let (filter, arguments) = predicate(value.countScope)
            let whereClause = filter.isEmpty ? "" : " WHERE " + filter
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(R.table)\(whereClause)", arguments: arguments) ?? 0
            guard count < R.limit else { throw capacity }
        }
        let data = try SessionCodec.encode(value)
        guard data.count <= 131_072 else { throw capacity }
        let fields = value.mirrors.merging(["json": data.databaseValue], uniquingKeysWith: { first, _ in first })
        let columns = fields.keys.sorted()
        let arguments = StatementArguments(columns.map { fields[$0]! })
        let updates = columns.filter { value.key[$0] == nil }.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        let sql =
            "INSERT INTO \(R.table)(\(columns.joined(separator: ","))) VALUES(\(columns.map { _ in "?" }.joined(separator: ","))) ON CONFLICT(\(value.key.keys.sorted().joined(separator: ","))) DO UPDATE SET \(updates)"
        try db.execute(sql: sql, arguments: arguments)
    }

    fileprivate static func saveModel(_ value: AgentConfiguredModel, expectedRevision: Int?, db: Database) throws {
        try value.validate()
        guard let connection = try one(AgentConfiguredConnection.self, key: key(value.connectionID.rawValue), db: db) else { throw missing }
        for invocation in value.invocations { _ = try connection.endpoint(id: invocation.endpointID) }
        let previous = try one(AgentConfiguredModel.self, key: value.key, db: db)
        try cas(old: previous?.revision, expected: expectedRevision, value: value.revision)
        let authorizationRevision: Int
        if let previous {
            guard previous.reference == value.reference else { throw conflict }
            authorizationRevision = try value.authorizationRevision(replacing: previous)
        } else { authorizationRevision = 1 }
        guard value.authorizationRevision == authorizationRevision else { throw conflict }
        if let duplicate = try String.fetchOne(
            db, sql: "SELECT id FROM settings_models WHERE connection_id = ? AND model_key = ?",
            arguments: [value.connectionID.rawValue.uuidString, value.modelID]), duplicate != value.id.rawValue.uuidString
        {
            throw conflict
        }
        try persist(value, isNew: previous == nil, db: db)
    }

    fileprivate static func savePreset(_ value: AgentRoutePreset, expectedRevision: Int?, db: Database) throws {
        try value.validate()
        guard let model = try one(AgentConfiguredModel.self, key: key(value.modelDescriptorID.rawValue), db: db),
            model.invocations.contains(where: { $0.id == value.invocationID }) else { throw missing }
        let previous = try one(AgentRoutePreset.self, key: value.key, db: db)
        try cas(old: previous?.revision, expected: expectedRevision, value: value.revision)
        try persist(value, isNew: previous == nil, db: db)
    }

    fileprivate static func delete<R: SettingsRecord>(_ type: R.Type, key: [String: DatabaseValue], expected: Int, db: Database) throws {
        guard expected > 0, let previous = try one(type, key: key, db: db), previous.revision == expected else { throw conflict }
        if let id = key["id"] {
            guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM settings_retired_ids") ?? 0) < 65_536 else { throw capacity }
            try db.execute(sql: "INSERT INTO settings_retired_ids(kind,id) VALUES(?,?)",
                arguments: StatementArguments([R.table.databaseValue, id]))
            if R.table == "settings_connections" {
                try db.execute(sql: "INSERT OR IGNORE INTO settings_retired_ids(kind,id) SELECT 'settings_presets', p.id FROM settings_presets p JOIN settings_models m ON m.id = p.model_id WHERE m.connection_id = ?", arguments: StatementArguments([id]))
                try db.execute(sql: "INSERT OR IGNORE INTO settings_retired_ids(kind,id) SELECT 'settings_models', id FROM settings_models WHERE connection_id = ?", arguments: StatementArguments([id]))
            } else if R.table == "settings_models" {
                try db.execute(sql: "INSERT OR IGNORE INTO settings_retired_ids(kind,id) SELECT 'settings_presets', id FROM settings_presets WHERE model_id = ?", arguments: StatementArguments([id]))
            }
            guard (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM settings_retired_ids") ?? 0) <= 65_536 else { throw capacity }
        }
        let (clause, arguments) = predicate(key)
        try db.execute(sql: "DELETE FROM \(R.table) WHERE \(clause)", arguments: arguments)
    }

    private static func selectedCandidate(routeID: RouteID, db: Database) throws -> AgentModelRouteCandidate {
        let value = try assemble(routeID: routeID, db: db)
        try value.validate()
        return value
    }

    fileprivate static func assemble(routeID: RouteID, db: Database) throws -> AgentModelRouteCandidate {
        guard let preset = try one(AgentRoutePreset.self, key: key(routeID.rawValue), db: db),
            let model = try one(AgentConfiguredModel.self, key: key(preset.modelDescriptorID.rawValue), db: db),
            let connection = try one(AgentConfiguredConnection.self, key: key(model.connectionID.rawValue), db: db)
        else { throw missing }
        let candidate = AgentModelRouteCandidate(connection: connection, model: model, preset: preset)
        return candidate
    }
}

private protocol SettingsRecord: Codable, Sendable {
    static var table: String { get }
    static var limit: Int { get }
    var revision: Int { get }
    var key: [String: DatabaseValue] { get }
    var mirrors: [String: DatabaseValue] { get }
    var countScope: [String: DatabaseValue] { get }
    func validate() throws
}

extension SettingsRecord {
    fileprivate var countScope: [String: DatabaseValue] { [:] }
}

extension AgentConfiguredConnection: SettingsRecord {
    fileprivate static let table = "settings_connections"
    fileprivate static let limit = 128
    fileprivate var key: [String: DatabaseValue] { ["id": id.rawValue.uuidString.databaseValue] }
    fileprivate var mirrors: [String: DatabaseValue] {
        [
            "id": id.rawValue.uuidString.databaseValue, "revision": revision.databaseValue,
            "config_revision": configurationRevision.databaseValue,
        ]
    }
}

extension AgentConfiguredModel: SettingsRecord {
    fileprivate static let table = "settings_models"
    fileprivate static let limit = 4096
    fileprivate var key: [String: DatabaseValue] { ["id": id.rawValue.uuidString.databaseValue] }
    fileprivate var mirrors: [String: DatabaseValue] {
        [
            "id": id.rawValue.uuidString.databaseValue, "revision": revision.databaseValue,
            "connection_id": connectionID.rawValue.uuidString.databaseValue,
            "authorization_revision": authorizationRevision.databaseValue, "model_key": modelID.databaseValue,
        ]
    }
}

extension AgentRoutePreset: SettingsRecord {
    fileprivate static let table = "settings_presets"
    fileprivate static let limit = 8192
    fileprivate var key: [String: DatabaseValue] { ["id": id.rawValue.uuidString.databaseValue] }
    fileprivate var mirrors: [String: DatabaseValue] {
        [
            "id": id.rawValue.uuidString.databaseValue, "revision": revision.databaseValue,
            "model_id": modelDescriptorID.rawValue.uuidString.databaseValue,
        ]
    }
}

extension AgentRouteBinding: SettingsRecord {
    fileprivate static let table = "settings_bindings"
    fileprivate static let limit = 64
    fileprivate var key: [String: DatabaseValue] { ["scope": scope.key.databaseValue, "purpose": purpose.databaseValue] }
    fileprivate var countScope: [String: DatabaseValue] { ["scope": scope.key.databaseValue] }
    fileprivate var mirrors: [String: DatabaseValue] {
        [
            "scope": scope.key.databaseValue, "purpose": purpose.databaseValue, "revision": revision.databaseValue,
            "route_id": routeID.rawValue.uuidString.databaseValue,
        ]
    }
}

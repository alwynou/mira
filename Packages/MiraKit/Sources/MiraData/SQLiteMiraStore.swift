import Foundation
import GRDB
import MiraCore

private struct PreparedMemoryContext {
    var usages: [MemoryUsage]
    var kinds: [MemoryID: MemoryUsageKind]
}

/// The first on-disk implementation of `MiraStore`.
///
/// The store deliberately exposes synchronous operations.  Its owning application
/// actor is responsible for keeping these bounded operations off view tasks.
public final class SQLiteMiraStore: MiraStore, @unchecked Sendable {
    static let currentSchemaVersion = 9
    private static let baseMigrationName = "m0_core"
    private static let auditMigrationName = "m2_execution_audit"
    let pool: DatabasePool
    let libraryDirectory: URL
    let blobs: ManagedBlobStore
    let knowledgeFaultInjector: @Sendable (KnowledgeStorageFaultStage) throws -> Void

    public convenience init(directory: URL) throws {
        try self.init(directory: directory, knowledgeFaultInjector: { _ in })
    }

    init(directory: URL, knowledgeFaultInjector: @escaping @Sendable (KnowledgeStorageFaultStage) throws -> Void) throws {
        do {
            try Self.createDirectoryIfNeeded(directory)
            let path = directory.appendingPathComponent("Mira.sqlite", isDirectory: false).path
            var configuration = Configuration()
            configuration.label = "Mira.SQLiteMiraStore"
            configuration.foreignKeysEnabled = true
            configuration.busyMode = .timeout(5)
            let pool = try DatabasePool(path: path, configuration: configuration)
            self.pool = pool
            let version = try pool.read { db in
                try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            }
            guard version == 0 || version == Self.currentSchemaVersion else {
                throw MiraError(.unsupported, "This library uses an unsupported database version. Create a fresh library to continue; existing data was left untouched.")
            }
            let migrator = Self.makeMigrator()
            try migrator.migrate(pool)
            self.libraryDirectory = directory
            self.blobs = try ManagedBlobStore(directory: directory)
            self.knowledgeFaultInjector = knowledgeFaultInjector
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch let error as MiraError {
            throw error
        } catch {
            throw MiraError.safe(error)
        }
    }

    // MARK: - Workspace / conversation

    public func workspaces() throws -> [Workspace] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, background, allows_remote_send, allowed_connection_ids_json, revision FROM workspaces ORDER BY name COLLATE NOCASE, id")
                .map { try Self.workspace($0) }
        }}
    }

    public func saveWorkspace(_ workspace: Workspace, expectedRevision: Int?) throws {
        try safely {
            guard workspace.revision > 0, !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MiraError(.invalidInput, "The workspace information is invalid.")
            }
            try pool.write { db in
                if let current = try Int.fetchOne(db, sql: "SELECT revision FROM workspaces WHERE id = ?", arguments: [id(workspace.id)]) {
                    if let expectedRevision, current != expectedRevision {
                        throw MiraError(.conflict, "The workspace was modified by another window.")
                    }
                    guard expectedRevision == current, workspace.revision == current + 1 else { throw MiraError(.conflict, "The workspace revision is out of date.") }
                    let next = current + 1
                    try db.execute(sql: "UPDATE workspaces SET name = ?, background = ?, allows_remote_send = ?, allowed_connection_ids_json = ?, revision = ? WHERE id = ?", arguments: [workspace.name, workspace.background, workspace.allowsRemoteSend ? 1 : 0, try encodeConnectionAllowlist(workspace.allowedConnectionIDs), next, id(workspace.id)])
                } else {
                    if expectedRevision != nil || workspace.revision != 1 {
                        throw MiraError(.conflict, "The workspace no longer exists.")
                    }
                    try db.execute(sql: "INSERT INTO workspaces (id, name, background, allows_remote_send, allowed_connection_ids_json, revision) VALUES (?, ?, ?, ?, ?, ?)", arguments: [id(workspace.id), workspace.name, workspace.background, workspace.allowsRemoteSend ? 1 : 0, try encodeConnectionAllowlist(workspace.allowedConnectionIDs), workspace.revision])
                }
            }
        }
    }

    public func conversations(includeArchived: Bool) throws -> [Conversation] {
        try safely { try pool.read { db in
            let sql = includeArchived
                ? "SELECT id, workspace_id, title, is_archived, created_at, updated_at, revision FROM conversations ORDER BY updated_at, id"
                : "SELECT id, workspace_id, title, is_archived, created_at, updated_at, revision FROM conversations WHERE is_archived = 0 ORDER BY updated_at, id"
            return try Row.fetchAll(db, sql: sql).map { try Self.conversation($0) }
        }}
    }

    public func createConversation(_ conversation: Conversation) throws {
        try safely {
            guard conversation.revision > 0,
                  conversation.title.isEmpty || !conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MiraError(.invalidInput, "The conversation information is invalid.")
            }
            try pool.write { db in
                if let workspaceID = conversation.workspaceID,
                   try Int.fetchOne(db, sql: "SELECT 1 FROM workspaces WHERE id = ?", arguments: [id(workspaceID)]) == nil {
                    throw MiraError(.notFound, "The workspace does not exist.")
                }
                try db.execute(sql: "INSERT INTO conversations (id, workspace_id, title, is_archived, created_at, updated_at, revision) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [id(conversation.id), conversation.workspaceID.map(id), conversation.title, conversation.isArchived ? 1 : 0, conversation.createdAt.timeIntervalSince1970, conversation.updatedAt.timeIntervalSince1970, conversation.revision])
            }
        }
    }

    public func archiveConversation(_ conversationID: ConversationID, at: Date) throws {
        try safely {
            try pool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT revision, is_archived FROM conversations WHERE id = ?", arguments: [id(conversationID)]) else {
                    throw MiraError(.notFound, "The conversation does not exist.")
                }
                if try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE conversation_id = ? AND status IN ('queued', 'waitingForModel') LIMIT 1", arguments: [id(conversationID)]) != nil {
                    throw MiraError(.busy, "The conversation still has an execution in progress.")
                }
                if row["is_archived"] as Int == 0 {
                    try db.execute(sql: "UPDATE conversations SET is_archived = 1, updated_at = ?, revision = ? WHERE id = ?", arguments: [at.timeIntervalSince1970, (row["revision"] as Int) + 1, id(conversationID)])
                }
            }
        }
    }

    public func messages(in conversationID: ConversationID) throws -> [Message] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, conversation_id, execution_id, sequence, role, status, text, body_purged_at, created_at FROM messages WHERE conversation_id = ? ORDER BY sequence", arguments: [id(conversationID)]).map { try Self.message($0) }
        }}
    }

    public func executions(in conversationID: ConversationID) throws -> [Execution] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at, body_purged_at FROM executions WHERE conversation_id = ? ORDER BY rowid", arguments: [id(conversationID)]).map { try Self.execution($0) }
        }}
    }

    public func execution(_ executionID: ExecutionID) throws -> Execution? {
        try safely { try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at, body_purged_at FROM executions WHERE id = ?", arguments: [id(executionID)]) else { return nil }
            return try Self.execution(row)
        }}
    }

    public func draft(for executionID: ExecutionID) throws -> Draft? {
        try safely { try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT execution_id, text, body_purged_at, updated_at FROM assistant_drafts WHERE execution_id = ?", arguments: [id(executionID)]) else { return nil }
            return Draft(executionID: try executionIDValue(row["execution_id"] as String), text: row["text"] as String, updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double))
        }}
    }

    // MARK: - Model configuration

    public func modelConfiguration() throws -> ModelConfiguration {
        try safely { try pool.read { db in
            let connections = try Row.fetchAll(db, sql: "SELECT id, revision, name, provider_kind, base_url, credential_reference, credential_version, allows_loopback_http, is_enabled, connection_json FROM provider_connections ORDER BY name COLLATE NOCASE, id").map { try Self.providerConnection($0) }
            let models = try Row.fetchAll(db, sql: "SELECT id, revision, connection_id, connection_revision, model_id, context_window, text_capability, tool_capability, probe_observation_json, is_enabled, extraction_capability, protocol_mode, model_json FROM model_descriptors ORDER BY model_id COLLATE NOCASE, id").map { try Self.modelDescriptor($0) }
            let routes = try Row.fetchAll(db, sql: "SELECT id, revision, name, model_descriptor_id, max_output_tokens, requests_usage, route_json FROM model_routes ORDER BY name COLLATE NOCASE, id").map { try Self.modelRoute($0) }
            let bindings = try Row.fetchAll(db, sql: "SELECT id, scope_key, purpose, route_id, revision, binding_json FROM route_bindings ORDER BY scope_key, purpose, id").map { try Self.routeBinding($0) }
            let connectionIDs = Set(connections.map(\.id))
            let modelIDs = Set(models.map(\.id))
            let routeIDs = Set(routes.map(\.id))
            guard models.allSatisfy({ connectionIDs.contains($0.connectionID) }),
                  routes.allSatisfy({ modelIDs.contains($0.modelDescriptorID) }),
                  bindings.allSatisfy({ routeIDs.contains($0.routeID) }) else {
                throw MiraError(.storage, "The model configuration relationships are invalid.")
            }
            for binding in bindings { try Self.validateRouteScope(binding.scope, in: db) }
            return ModelConfiguration(connections: connections, models: models, routes: routes, bindings: bindings)
        }}
    }

    public func saveConnection(_ connection: ProviderConnection, expectedRevision: Int?) throws {
        try safely {
            try connection.validate()
            let encoded = try encode(connection)
            try pool.write { db in
                if let current = try Int.fetchOne(db, sql: "SELECT revision FROM provider_connections WHERE id = ?", arguments: [id(connection.id)]) {
                    guard expectedRevision == current, connection.revision == current + 1 else { throw MiraError(.conflict, "The provider connection revision is out of date.") }
                    guard let previousJSON = try String.fetchOne(db, sql: "SELECT connection_json FROM provider_connections WHERE id = ?", arguments: [id(connection.id)]) else { throw MiraError(.storage, "The provider connection contents are invalid.") }
                    let previous: ProviderConnection = try Self.decode(previousJSON)
                    try db.execute(sql: "UPDATE provider_connections SET revision = ?, name = ?, provider_kind = ?, base_url = ?, credential_reference = ?, credential_version = ?, allows_loopback_http = ?, is_enabled = ?, connection_json = ? WHERE id = ?", arguments: [connection.revision, connection.name, connection.providerKind.rawValue, connection.baseURL, connection.credentialReference, connection.credentialVersion, connection.allowsLoopbackHTTP ? 1 : 0, connection.isEnabled ? 1 : 0, encoded, id(connection.id)])
                    if Self.preservesConnectionCapabilities(from: previous, to: connection) {
                        let rows = try Row.fetchAll(db, sql: "SELECT id, revision, connection_id, connection_revision, model_id, context_window, text_capability, tool_capability, probe_observation_json, is_enabled, extraction_capability, protocol_mode, model_json FROM model_descriptors WHERE connection_id = ?", arguments: [id(connection.id)])
                        for row in rows {
                            let model = try Self.modelDescriptor(row)
                            guard model.connectionRevision == current, model.revision < Int.max else { continue }
                            var updated = model
                            updated.connectionRevision = connection.revision
                            updated.revision += 1
                            try db.execute(sql: "UPDATE model_descriptors SET revision = ?, connection_revision = ?, model_json = ? WHERE id = ?", arguments: [updated.revision, updated.connectionRevision, try Self.encode(updated), id(updated.id)])
                        }
                    }
                } else {
                    guard expectedRevision == nil, connection.revision == 1 else { throw MiraError(.conflict, "The provider connection no longer exists.") }
                    try db.execute(sql: "INSERT INTO provider_connections (id, revision, name, provider_kind, base_url, credential_reference, credential_version, allows_loopback_http, is_enabled, connection_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [id(connection.id), connection.revision, connection.name, connection.providerKind.rawValue, connection.baseURL, connection.credentialReference, connection.credentialVersion, connection.allowsLoopbackHTTP ? 1 : 0, connection.isEnabled ? 1 : 0, encoded])
                }
            }
        }
    }

    public func removeConnection(_ connectionID: ConnectionID) throws {
        try safely { try pool.write { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM provider_connections WHERE id = ?", arguments: [id(connectionID)]) != nil else { return }
            for row in try Row.fetchAll(db, sql: "SELECT id, allowed_connection_ids_json FROM workspaces WHERE allowed_connection_ids_json IS NOT NULL") {
                let allowed = try Self.decodeConnectionAllowlist(row["allowed_connection_ids_json"] as String?)
                guard let allowed else { continue }
                var updated = allowed
                updated.remove(connectionID)
                if updated != allowed {
                    try db.execute(sql: "UPDATE workspaces SET allowed_connection_ids_json = ? WHERE id = ?", arguments: [try Self.encodeConnectionAllowlist(updated), row["id"] as String])
                }
            }
            try db.execute(sql: "DELETE FROM provider_connections WHERE id = ?", arguments: [id(connectionID)])
        }}
    }

    public func saveModel(_ model: ModelDescriptor, expectedRevision: Int?) throws {
        try safely {
            try model.validate()
            let encoded = try encode(model)
            try pool.write { db in
                guard let connectionRevision = try Int.fetchOne(db, sql: "SELECT revision FROM provider_connections WHERE id = ?", arguments: [id(model.connectionID)]) else { throw MiraError(.notFound, "The provider connection does not exist.") }
                guard model.connectionRevision == connectionRevision else { throw MiraError(.conflict, "The model descriptor is based on an outdated provider connection.") }
                try Self.validateModelIdentity(model, in: db)
                if let current = try Int.fetchOne(db, sql: "SELECT revision FROM model_descriptors WHERE id = ?", arguments: [id(model.id)]) {
                    guard expectedRevision == current, model.revision == current + 1 else { throw MiraError(.conflict, "The model descriptor revision is out of date.") }
                    try db.execute(sql: "UPDATE model_descriptors SET revision = ?, connection_id = ?, connection_revision = ?, model_id = ?, context_window = ?, text_capability = ?, tool_capability = ?, probe_observation_json = ?, is_enabled = ?, extraction_capability = ?, protocol_mode = ?, model_json = ? WHERE id = ?", arguments: [model.revision, id(model.connectionID), model.connectionRevision, model.modelID, model.contextWindow, model.textCapability.rawValue, model.toolCapability.rawValue, try model.probeObservation.map(encode), model.isEnabled ? 1 : 0, model.extractionCapability.rawValue, model.protocolMode.rawValue, encoded, id(model.id)])
                } else {
                    guard expectedRevision == nil, model.revision == 1 else { throw MiraError(.conflict, "The model descriptor no longer exists.") }
                    try db.execute(sql: "INSERT INTO model_descriptors (id, revision, connection_id, connection_revision, model_id, context_window, text_capability, tool_capability, probe_observation_json, is_enabled, extraction_capability, protocol_mode, model_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [id(model.id), model.revision, id(model.connectionID), model.connectionRevision, model.modelID, model.contextWindow, model.textCapability.rawValue, model.toolCapability.rawValue, try model.probeObservation.map(encode), model.isEnabled ? 1 : 0, model.extractionCapability.rawValue, model.protocolMode.rawValue, encoded])
                }
            }
        }
    }

    public func savePoolModel(_ model: ModelDescriptor, route: ModelRoute, expectedModelRevision: Int?, expectedRouteRevision: Int?) throws {
        try safely {
            try model.validate(); try route.validate()
            guard route.id == model.poolRouteID, route.modelDescriptorID == model.id else {
                throw MiraError(.configuration, "The model pool route must be the model's canonical route.")
            }
            let modelEncoded = try encode(model)
            let routeEncoded = try encode(route)
            try pool.write { db in
                guard let connectionRevision = try Int.fetchOne(db, sql: "SELECT revision FROM provider_connections WHERE id = ?", arguments: [id(model.connectionID)]) else { throw MiraError(.notFound, "The provider connection does not exist.") }
                guard model.connectionRevision == connectionRevision else { throw MiraError(.conflict, "The model descriptor is based on an outdated provider connection.") }
                try Self.validateModelIdentity(model, in: db)
                if let current = try Int.fetchOne(db, sql: "SELECT revision FROM model_descriptors WHERE id = ?", arguments: [id(model.id)]) {
                    guard expectedModelRevision == current, model.revision == current + 1 else { throw MiraError(.conflict, "The model descriptor revision is out of date.") }
                    try db.execute(sql: "UPDATE model_descriptors SET revision = ?, connection_id = ?, connection_revision = ?, model_id = ?, context_window = ?, text_capability = ?, tool_capability = ?, probe_observation_json = ?, is_enabled = ?, extraction_capability = ?, protocol_mode = ?, model_json = ? WHERE id = ?", arguments: [model.revision, id(model.connectionID), model.connectionRevision, model.modelID, model.contextWindow, model.textCapability.rawValue, model.toolCapability.rawValue, try model.probeObservation.map(encode), model.isEnabled ? 1 : 0, model.extractionCapability.rawValue, model.protocolMode.rawValue, modelEncoded, id(model.id)])
                } else {
                    guard expectedModelRevision == nil, model.revision == 1 else { throw MiraError(.conflict, "The model descriptor no longer exists.") }
                    try db.execute(sql: "INSERT INTO model_descriptors (id, revision, connection_id, connection_revision, model_id, context_window, text_capability, tool_capability, probe_observation_json, is_enabled, extraction_capability, protocol_mode, model_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [id(model.id), model.revision, id(model.connectionID), model.connectionRevision, model.modelID, model.contextWindow, model.textCapability.rawValue, model.toolCapability.rawValue, try model.probeObservation.map(encode), model.isEnabled ? 1 : 0, model.extractionCapability.rawValue, model.protocolMode.rawValue, modelEncoded])
                }
                if let current = try Int.fetchOne(db, sql: "SELECT revision FROM model_routes WHERE id = ?", arguments: [id(route.id)]) {
                    guard try String.fetchOne(db, sql: "SELECT model_descriptor_id FROM model_routes WHERE id = ?", arguments: [id(route.id)]) == id(model.id) else { throw MiraError(.conflict, "The canonical model pool route belongs to another model.") }
                    guard expectedRouteRevision == current, route.revision == current + 1 else { throw MiraError(.conflict, "The model route revision is out of date.") }
                    try db.execute(sql: "UPDATE model_routes SET revision = ?, name = ?, model_descriptor_id = ?, max_output_tokens = ?, requests_usage = ?, route_json = ? WHERE id = ?", arguments: [route.revision, route.name, id(route.modelDescriptorID), route.maxOutputTokens, route.requestsUsage ? 1 : 0, routeEncoded, id(route.id)])
                } else {
                    guard expectedRouteRevision == nil, route.revision == 1 else { throw MiraError(.conflict, "The model route no longer exists.") }
                    try db.execute(sql: "INSERT INTO model_routes (id, revision, name, model_descriptor_id, max_output_tokens, requests_usage, route_json) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [id(route.id), route.revision, route.name, id(route.modelDescriptorID), route.maxOutputTokens, route.requestsUsage ? 1 : 0, routeEncoded])
                }
            }
        }
    }

    public func removeModel(_ modelID: ModelDescriptorID) throws {
        try safely { try pool.write { db in
            try db.execute(sql: "DELETE FROM model_descriptors WHERE id = ?", arguments: [id(modelID)])
        }}
    }

    public func saveRoute(_ route: ModelRoute, expectedRevision: Int?) throws {
        try safely {
            try route.validate()
            let encoded = try encode(route)
            try pool.write { db in
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM model_descriptors WHERE id = ?", arguments: [id(route.modelDescriptorID)]) != nil else { throw MiraError(.notFound, "The model descriptor does not exist.") }
                if let current = try Int.fetchOne(db, sql: "SELECT revision FROM model_routes WHERE id = ?", arguments: [id(route.id)]) {
                    guard expectedRevision == current, route.revision == current + 1 else { throw MiraError(.conflict, "The model route revision is out of date.") }
                    try db.execute(sql: "UPDATE model_routes SET revision = ?, name = ?, model_descriptor_id = ?, max_output_tokens = ?, requests_usage = ?, route_json = ? WHERE id = ?", arguments: [route.revision, route.name, id(route.modelDescriptorID), route.maxOutputTokens, route.requestsUsage ? 1 : 0, encoded, id(route.id)])
                } else {
                    guard expectedRevision == nil, route.revision == 1 else { throw MiraError(.conflict, "The model route no longer exists.") }
                    try db.execute(sql: "INSERT INTO model_routes (id, revision, name, model_descriptor_id, max_output_tokens, requests_usage, route_json) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [id(route.id), route.revision, route.name, id(route.modelDescriptorID), route.maxOutputTokens, route.requestsUsage ? 1 : 0, encoded])
                }
            }
        }
    }

    public func removeRoute(_ routeID: RouteID) throws {
        try safely { try pool.write { db in
            try db.execute(sql: "DELETE FROM model_routes WHERE id = ?", arguments: [id(routeID)])
        }}
    }

    public func saveRouteBinding(_ binding: RouteBinding, expectedRevision: Int?) throws {
        try safely {
            try validateRouteBinding(binding)
            let encoded = try encodeRouteBinding(binding)
            try pool.write { db in
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM model_routes WHERE id = ?", arguments: [id(binding.routeID)]) != nil else { throw MiraError(.notFound, "The model route does not exist.") }
                try validateRouteScope(binding.scope, in: db)
                if let current = try Int.fetchOne(db, sql: "SELECT revision FROM route_bindings WHERE id = ?", arguments: [binding.id]) {
                    guard expectedRevision == current, binding.revision == current + 1 else { throw MiraError(.conflict, "The route binding revision is out of date.") }
                    try db.execute(sql: "UPDATE route_bindings SET scope_key = ?, purpose = ?, route_id = ?, revision = ?, binding_json = ? WHERE id = ?", arguments: [binding.scope.key, binding.purpose.rawValue, id(binding.routeID), binding.revision, encoded, binding.id])
                } else {
                    guard expectedRevision == nil, binding.revision == 1 else { throw MiraError(.conflict, "The route binding no longer exists.") }
                    try db.execute(sql: "INSERT INTO route_bindings (id, scope_key, purpose, route_id, revision, binding_json) VALUES (?, ?, ?, ?, ?, ?)", arguments: [binding.id, binding.scope.key, binding.purpose.rawValue, id(binding.routeID), binding.revision, encoded])
                }
            }
        }
    }

    public func removeRouteBinding(_ binding: RouteBinding) throws {
        try safely { try pool.write { db in
            guard let current = try Int.fetchOne(db, sql: "SELECT revision FROM route_bindings WHERE id = ?", arguments: [binding.id]) else {
                throw MiraError(.notFound, "The route binding does not exist.")
            }
            guard current == binding.revision else { throw MiraError(.conflict, "The route binding revision is out of date.") }
            try db.execute(sql: "DELETE FROM route_bindings WHERE id = ? AND revision = ?", arguments: [binding.id, binding.revision])
            guard db.changesCount == 1 else { throw MiraError(.conflict, "The route binding revision is out of date.") }
        }}
    }

    // MARK: - Runtime persistence

    public func enqueue(conversationID: ConversationID, text: String, route: ResolvedModelRouteSnapshot, executionID: ExecutionID, messageID: MessageID, at: Date) throws -> Execution {
        try safely {
            guard !text.isEmpty else { throw MiraError(.invalidInput, "The message cannot be empty.") }
            return try pool.write { db in
                guard let conversation = try Row.fetchOne(db, sql: "SELECT is_archived FROM conversations WHERE id = ?", arguments: [id(conversationID)]) else { throw MiraError(.notFound, "The conversation does not exist.") }
                guard conversation["is_archived"] as Int == 0 else { throw MiraError(.invalidInput, "Messages cannot be sent to an archived conversation.") }
                if try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE conversation_id = ? AND status IN ('queued', 'waitingForModel') LIMIT 1", arguments: [id(conversationID)]) != nil {
                    throw MiraError(.busy, "This conversation already has an execution in progress.")
                }
                let hadUserMessage = try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE conversation_id = ? AND role = 'user' LIMIT 1", arguments: [id(conversationID)]) != nil
                let sequence = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM messages WHERE conversation_id = ?", arguments: [id(conversationID)]) ?? 1)
                let execution = Execution(id: executionID, conversationID: conversationID, triggerMessageID: messageID, route: route, createdAt: at, updatedAt: at)
                try db.execute(sql: "INSERT INTO executions (id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at) VALUES (?, ?, ?, NULL, 'queued', ?, NULL, NULL, NULL, ?, ?)", arguments: [id(executionID), id(conversationID), id(messageID), try encode(route), at.timeIntervalSince1970, at.timeIntervalSince1970])
                try db.execute(sql: "INSERT INTO messages (id, conversation_id, execution_id, sequence, role, status, text, created_at) VALUES (?, ?, ?, ?, 'user', 'committed', ?, ?)", arguments: [id(messageID), id(conversationID), id(executionID), sequence, text, at.timeIntervalSince1970])
                try db.execute(sql: "UPDATE conversations SET updated_at = ?, revision = revision + 1 WHERE id = ?", arguments: [at.timeIntervalSince1970, id(conversationID)])
                if !hadUserMessage {
                    let preview = String(text.prefix(80))
                    try db.execute(sql: "UPDATE conversations SET title = ? WHERE id = ?", arguments: [preview, id(conversationID)])
                }
                return execution
            }
        }
    }

    public func retry(executionID: ExecutionID, newExecutionID: ExecutionID, route: ResolvedModelRouteSnapshot, at: Date) throws -> Execution {
        try safely {
            return try pool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT rowid, id, conversation_id, trigger_message_id, status, route_json FROM executions WHERE id = ?", arguments: [id(executionID)]) else { throw MiraError(.notFound, "The execution does not exist.") }
                let status = row["status"] as String
                guard ["failed", "cancelled", "interrupted"].contains(status) else { throw MiraError(.conflict, "Only a finished failed execution can be retried.") }
                let conversationID = try conversationIDValue(row["conversation_id"] as String)
                let triggerID = try messageIDValue(row["trigger_message_id"] as String)
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE conversation_id = ? AND rowid > ? LIMIT 1", arguments: [id(conversationID), row["rowid"] as Int64]) == nil else { throw MiraError(.conflict, "This execution is no longer the final turn.") }
                let laterUser = try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE conversation_id = ? AND role = 'user' AND sequence > (SELECT sequence FROM messages WHERE id = ?) LIMIT 1", arguments: [id(conversationID), id(triggerID)])
                guard laterUser == nil else { throw MiraError(.conflict, "A new user message exists after this execution.") }
                if try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE conversation_id = ? AND status IN ('queued', 'waitingForModel') LIMIT 1", arguments: [id(conversationID)]) != nil { throw MiraError(.busy, "This conversation already has an execution in progress.") }
                guard try Row.fetchOne(db, sql: "SELECT 1 FROM conversations WHERE id = ? AND is_archived = 0", arguments: [id(conversationID)]) != nil else { throw MiraError(.invalidInput, "An archived conversation cannot be retried.") }
                let execution = Execution(id: newExecutionID, conversationID: conversationID, triggerMessageID: triggerID, retryOfExecutionID: executionID, route: route, createdAt: at, updatedAt: at)
                try db.execute(sql: "INSERT INTO executions (id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at) VALUES (?, ?, ?, ?, 'queued', ?, NULL, NULL, NULL, ?, ?)", arguments: [id(newExecutionID), id(conversationID), id(triggerID), id(executionID), try encode(route), at.timeIntervalSince1970, at.timeIntervalSince1970])
                try db.execute(sql: "UPDATE conversations SET updated_at = ?, revision = revision + 1 WHERE id = ?", arguments: [at.timeIntervalSince1970, id(conversationID)])
                return execution
            }
        }
    }

    public func request(for executionID: ExecutionID) throws -> CanonicalModelRequest? {
        try safely { try pool.read { db in
            // The latest model attempt is the request at the current audit boundary.
            let value = try String.fetchOne(db, sql: "SELECT request_json FROM model_attempts WHERE execution_id = ? ORDER BY step_index DESC, attempt_index DESC, rowid DESC LIMIT 1", arguments: [id(executionID)])
            guard let value else { return nil }
            return try decodeRequest(value)
        }}
    }

    public func prepareAttempt(_ attempt: ModelAttempt) throws {
        try safely {
            guard attempt.stepIndex >= 0, attempt.attemptIndex > 0 else { throw MiraError(.invalidInput, "The execution step index is invalid.") }
            guard let request = attempt.request,
                  request.executionID == attempt.executionID,
                  request.requestID == attempt.id else { throw MiraError(.invalidInput, "The request does not match the model attempt.") }
            try pool.write { db in
                guard let execution = try Row.fetchOne(db, sql: "SELECT status, body_purged_at, route_json FROM executions WHERE id = ?", arguments: [id(attempt.executionID)]) else {
                    throw MiraError(.notFound, "The execution does not exist.")
                }
                guard let status = ExecutionStatus(rawValue: execution["status"] as String), !status.isTerminal, (execution["body_purged_at"] as Double?) == nil else {
                    throw MiraError(.conflict, "The execution body has been purged or the execution has already finished.")
                }
                let memoryContext = try prepareMemoryContext(request, executionID: attempt.executionID, in: db)
                try validateExecutionMemoryContext(attempt.executionID, usages: memoryContext.usages, usageKinds: memoryContext.kinds, at: attempt.createdAt, in: db)
                for kind in [MemoryUsageKind.recall, .capture] {
                    try persistMemoryUsages(memoryContext.usages.filter { memoryContext.kinds[$0.memoryID] == kind }, executionID: attempt.executionID, at: attempt.createdAt, kind: kind, in: db)
                }
                let sourceReferences = try prepareSourceContext(request, executionID: attempt.executionID, at: attempt.createdAt, in: db)
                // Source provenance is local audit metadata; provider message bytes remain unchanged.
                var auditedRequest = request
                if !sourceReferences.isEmpty {
                    var info = try auditedRequest.contextInfo ?? .init(references: [], omissions: [], routeRevision: Self.decodeRoute(execution["route_json"]).revision)
                    info.references.removeAll { $0.kind == "sourceVersion" || $0.kind == "sourceChunk" }
                    info.references += sourceReferences
                    auditedRequest.contextInfo = info
                }

                let lastStep = try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM execution_steps WHERE execution_id = ?", arguments: [id(attempt.executionID)])
                let stepID: String
                if lastStep == nil {
                    guard attempt.attemptIndex == 1, attempt.stepIndex == 1 else { throw MiraError(.conflict, "The first step index is invalid.") }
                    stepID = attempt.stepID.uuidString.lowercased()
                    try db.execute(sql: "INSERT INTO execution_steps (id, execution_id, sequence, state, output_json, error_json, started_at, completed_at) VALUES (?, ?, ?, 'running', NULL, NULL, ?, NULL)", arguments: [stepID, id(attempt.executionID), attempt.stepIndex, attempt.createdAt.timeIntervalSince1970])
                } else if attempt.stepIndex == lastStep! {
                    guard attempt.attemptIndex > 1 else { throw MiraError(.conflict, "The attempt index is duplicated for this step.") }
                    guard let existingStep = try Row.fetchOne(db, sql: "SELECT id FROM execution_steps WHERE execution_id = ? AND sequence = ?", arguments: [id(attempt.executionID), lastStep!]),
                          existingStep["id"] as String == attempt.stepID.uuidString.lowercased(),
                          let previousAttempt = try Row.fetchOne(db, sql: "SELECT id, status, output_json FROM model_attempts WHERE execution_id = ? AND step_index = ? ORDER BY attempt_index DESC, rowid DESC LIMIT 1", arguments: [id(attempt.executionID), lastStep!]),
                          (previousAttempt["status"] as String) == AttemptStatus.failed.rawValue,
                          (previousAttempt["output_json"] as String?) == nil else { throw MiraError(.conflict, "Only a failed attempt with no output or tool calls can be retried.") }
                    let priorInvocations = try Int.fetchOne(db, sql: "SELECT 1 FROM tool_invocations WHERE execution_id = ? AND attempt_id = ? LIMIT 1", arguments: [id(attempt.executionID), previousAttempt["id"] as String])
                    guard priorInvocations == nil else { throw MiraError(.conflict, "An attempt with tool calls cannot be retried.") }
                    let expected = (try Int.fetchOne(db, sql: "SELECT attempt_index FROM model_attempts WHERE execution_id = ? AND step_index = ? ORDER BY attempt_index DESC, rowid DESC LIMIT 1", arguments: [id(attempt.executionID), lastStep!]) ?? 0) + 1
                    guard attempt.attemptIndex == expected else { throw MiraError(.conflict, "Model attempts must be created in order.") }
                    let pending = try Int.fetchOne(db, sql: "SELECT 1 FROM tool_invocations WHERE execution_id = ? AND attempt_id = ? AND result_json IS NULL LIMIT 1", arguments: [id(attempt.executionID), previousAttempt["id"] as String])
                    guard pending == nil else { throw MiraError(.conflict, "The previous tool result has not been submitted.") }
                    stepID = attempt.stepID.uuidString.lowercased()
                    try db.execute(sql: "UPDATE execution_steps SET state = 'running', output_json = NULL, error_json = NULL, body_purged_at = NULL, completed_at = NULL WHERE execution_id = ? AND sequence = ? AND body_purged_at IS NULL", arguments: [id(attempt.executionID), lastStep!])
                    guard db.changesCount == 1 else { throw MiraError(.conflict, "The execution step body has been purged.") }
                } else if attempt.stepIndex == lastStep! + 1 {
                    guard attempt.attemptIndex == 1 else { throw MiraError(.conflict, "The attempt index for a new step is invalid.") }
                    let previous = lastStep!
                    guard let previousAttempt = try Row.fetchOne(db, sql: "SELECT id, status, output_json FROM model_attempts WHERE execution_id = ? AND step_index = ? ORDER BY attempt_index DESC, rowid DESC LIMIT 1", arguments: [id(attempt.executionID), previous]),
                          (previousAttempt["status"] as String) == AttemptStatus.completed.rawValue,
                          (previousAttempt["output_json"] as String?) != nil else {
                        throw MiraError(.conflict, "The previous model output has not been submitted.")
                    }
                    let previousOutput: ModelOutput = try Self.decode(previousAttempt["output_json"] as String)
                    guard previousOutput.finishReason == .toolCalls else { throw MiraError(.conflict, "Only tool-call output can continue to the next step.") }
                    let pending = try Int.fetchOne(db, sql: "SELECT 1 FROM tool_invocations WHERE execution_id = ? AND attempt_id = ? AND result_json IS NULL LIMIT 1", arguments: [id(attempt.executionID), previousAttempt["id"] as String])
                    guard pending == nil else { throw MiraError(.conflict, "The previous tool result has not been submitted.") }
                    try db.execute(sql: "UPDATE execution_steps SET state = 'completed', completed_at = COALESCE(completed_at, ?) WHERE execution_id = ? AND sequence = ? AND state = 'waitingForTool' AND body_purged_at IS NULL", arguments: [attempt.createdAt.timeIntervalSince1970, id(attempt.executionID), previous])
                    stepID = attempt.stepID.uuidString.lowercased()
                    try db.execute(sql: "INSERT INTO execution_steps (id, execution_id, sequence, state, output_json, error_json, started_at, completed_at) VALUES (?, ?, ?, 'running', NULL, NULL, ?, NULL)", arguments: [stepID, id(attempt.executionID), attempt.stepIndex, attempt.createdAt.timeIntervalSince1970])
                } else {
                    throw MiraError(.conflict, "Execution steps must be created in order.")
                }
                try db.execute(sql: "INSERT INTO model_attempts (id, execution_id, step_id, step_index, attempt_index, request_json, status, output_json, usage_input, usage_output, error_json, created_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, 'prepared', NULL, NULL, NULL, NULL, ?, NULL)", arguments: [attempt.id.uuidString.lowercased(), id(attempt.executionID), stepID, attempt.stepIndex, attempt.attemptIndex, try encode(auditedRequest), attempt.createdAt.timeIntervalSince1970])
                try db.execute(sql: "UPDATE executions SET status = 'waitingForModel', updated_at = ? WHERE id = ? AND status IN ('queued', 'waitingForModel')", arguments: [attempt.createdAt.timeIntervalSince1970, id(attempt.executionID)])
                guard db.changesCount > 0 else { throw MiraError(.conflict, "The execution is no longer waiting.") }
            }
        }
    }

    public func attempts(for executionID: ExecutionID) throws -> [ModelAttempt] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, execution_id, step_id, step_index, attempt_index, request_json, status, output_json, usage_input, usage_output, error_json, body_purged_at, created_at, completed_at FROM model_attempts WHERE execution_id = ? ORDER BY step_index, attempt_index, rowid", arguments: [id(executionID)]).map { try Self.modelAttempt($0) }
        }}
    }

    public func finishAttempt(_ id: UUID, output: ModelOutput?, invocations: [ToolInvocation], usage: TokenUsage, error: MiraError?, at: Date) throws {
        try safely {
            try pool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT ma.execution_id, ma.step_id, ma.step_index, ma.status, ma.body_purged_at, e.body_purged_at AS execution_body_purged_at FROM model_attempts ma JOIN executions e ON e.id = ma.execution_id WHERE ma.id = ?", arguments: [id.uuidString.lowercased()]) else { throw MiraError(.notFound, "The model attempt does not exist.") }
                guard (row["status"] as String) == AttemptStatus.prepared.rawValue, (row["body_purged_at"] as Double?) == nil else { throw MiraError(.conflict, "The model attempt has already finished or its body was purged.") }
                guard (row["execution_body_purged_at"] as Double?) == nil else { throw MiraError(.conflict, "The execution body has been purged or the execution has already finished.") }
                let executionID = row["execution_id"] as String
                let toolCalls = output?.toolCalls ?? []
                guard output != nil || error != nil else { throw MiraError(.invalidInput, "The model attempt has neither output nor an error.") }
                guard output == nil || error == nil else { throw MiraError(.invalidInput, "Model output and an error cannot be submitted together.") }
                guard invocations.count == toolCalls.count else { throw MiraError(.invalidInput, "The tool call count does not match the model output.") }
                for (index, invocation) in invocations.enumerated() {
                    let call = toolCalls[index]
                    guard invocation.attemptID.uuidString.lowercased() == id.uuidString.lowercased(),
                          invocation.modelOrder == index,
                          invocation.call == call,
                          invocation.result == nil,
                          invocation.dispatchedAt == nil,
                          invocation.completedAt == nil else { throw MiraError(.invalidInput, "The tool call audit does not match.") }
                    // The provider call ID is also a schema-level unique key; the
                    // explicit preflight makes the error stable before insertion.
                    guard !call.id.isEmpty, !call.name.isEmpty else { throw MiraError(.invalidInput, "The tool call identity is invalid.") }
                }
                let finalStatus: AttemptStatus = output == nil ? .failed : .completed
                let outputJSON = try output.map(encode)
                let errorJSON = try error.map(encode)
                try db.execute(sql: "UPDATE model_attempts SET status = ?, output_json = ?, usage_input = ?, usage_output = ?, error_json = ?, completed_at = ? WHERE id = ? AND status = 'prepared'", arguments: [finalStatus.rawValue, outputJSON, usage.inputTokens, usage.outputTokens, errorJSON, at.timeIntervalSince1970, id.uuidString.lowercased()])
                guard db.changesCount == 1 else { throw MiraError(.conflict, "The model attempt has already finished.") }
                for invocation in invocations {
                    try db.execute(sql: "INSERT INTO tool_invocations (id, execution_id, attempt_id, model_order, provider_call_id, tool_name, arguments_json, status, result_json, dispatched_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', NULL, NULL, NULL)", arguments: [invocation.id.uuidString.lowercased(), executionID, invocation.attemptID.uuidString.lowercased(), invocation.modelOrder, invocation.call.id, invocation.call.name, invocation.call.arguments])
                }
                let stepState = output?.toolCalls.isEmpty == false ? "waitingForTool" : (output == nil ? "failed" : "completed")
                let stepCompletedAt: Double? = output?.toolCalls.isEmpty == false ? nil : at.timeIntervalSince1970
                try db.execute(sql: "UPDATE execution_steps SET state = ?, output_json = ?, error_json = ?, body_purged_at = NULL, completed_at = ? WHERE id = ? AND execution_id = ? AND body_purged_at IS NULL", arguments: [stepState, outputJSON, errorJSON, stepCompletedAt, row["step_id"] as String, executionID])
                guard db.changesCount == 1 else { throw MiraError(.conflict, "The execution step body has been purged.") }
                try db.execute(sql: "UPDATE executions SET updated_at = ? WHERE id = ?", arguments: [at.timeIntervalSince1970, executionID])
            }
        }
    }

    public func toolInvocations(for executionID: ExecutionID) throws -> [ToolInvocation] {
        try safely { try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, attempt_id, model_order, provider_call_id, tool_name, arguments_json, status, result_json, body_purged_at, dispatched_at, completed_at FROM tool_invocations WHERE execution_id = ? ORDER BY (SELECT step_index FROM model_attempts WHERE id = tool_invocations.attempt_id), (SELECT attempt_index FROM model_attempts WHERE id = tool_invocations.attempt_id), model_order, rowid", arguments: [id(executionID)]).map { try Self.toolInvocation($0) }
        }}
    }

    public func markToolDispatched(_ id: UUID, at: Date) throws {
        try safely {
            try pool.write { db in
                try db.execute(sql: "UPDATE tool_invocations SET status = 'dispatched', dispatched_at = ? WHERE id = ? AND status = 'pending' AND result_json IS NULL AND body_purged_at IS NULL AND EXISTS (SELECT 1 FROM executions WHERE executions.id = tool_invocations.execution_id AND executions.body_purged_at IS NULL)", arguments: [at.timeIntervalSince1970, id.uuidString.lowercased()])
                guard db.changesCount == 1 else { throw MiraError(.conflict, "The tool call was dispatched or has already finished.") }
                try db.execute(sql: "UPDATE executions SET updated_at = ? WHERE id = (SELECT execution_id FROM tool_invocations WHERE id = ?)", arguments: [at.timeIntervalSince1970, id.uuidString.lowercased()])
            }
        }
    }

    @discardableResult
    public func finishToolInvocation(_ id: UUID, result: ToolResult, at: Date) throws -> Bool {
        try safely {
            try pool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT ti.status, ti.body_purged_at, e.body_purged_at AS execution_body_purged_at FROM tool_invocations ti JOIN executions e ON e.id = ti.execution_id WHERE ti.id = ?", arguments: [id.uuidString.lowercased()]) else { throw MiraError(.notFound, "The tool call does not exist.") }
                let status: String = row["status"]
                if row["body_purged_at"] as Double? != nil { return false }
                if row["execution_body_purged_at"] as Double? != nil { return false }
                if ToolResultStatus(rawValue: status) != nil { return false }
                let dispatchFree: Set<ToolResultStatus> = [.invalidArguments, .notFound, .denied, .timedOut, .cancelledBeforeDispatch, .failed, .outputLimit]
                if status == "pending" && !dispatchFree.contains(result.status) { throw MiraError(.conflict, "The result status is invalid for an undispatched tool call.") }
                if status == "dispatched" && result.status == .cancelledBeforeDispatch { throw MiraError(.conflict, "A dispatched tool call cannot be marked as cancelled before dispatch.") }
                guard status == "pending" || status == "dispatched" else { throw MiraError(.conflict, "The tool call status is invalid.") }
                try db.execute(sql: "UPDATE tool_invocations SET status = ?, result_json = ?, completed_at = ? WHERE id = ? AND status IN ('pending', 'dispatched') AND result_json IS NULL", arguments: [result.status.rawValue, try encode(result), at.timeIntervalSince1970, id.uuidString.lowercased()])
                guard db.changesCount == 1 else { return false }
                try db.execute(sql: "UPDATE executions SET updated_at = ? WHERE id = (SELECT execution_id FROM tool_invocations WHERE id = ?)", arguments: [at.timeIntervalSince1970, id.uuidString.lowercased()])
                return true
            }
        }
    }

    public func checkpoint(executionID: ExecutionID, text: String, at: Date) throws {
        try safely {
            try pool.write { db in
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE id = ? AND status IN ('queued', 'waitingForModel') AND body_purged_at IS NULL", arguments: [id(executionID)]) != nil else { throw MiraError(.conflict, "The execution has finished; the draft cannot be saved.") }
                try db.execute(sql: "INSERT INTO assistant_drafts (execution_id, text, body_purged_at, updated_at) VALUES (?, ?, NULL, ?) ON CONFLICT(execution_id) DO UPDATE SET text = excluded.text, body_purged_at = NULL, updated_at = excluded.updated_at", arguments: [id(executionID), text, at.timeIntervalSince1970])
            }
        }
    }

    @discardableResult
    public func finish(executionID: ExecutionID, status: ExecutionStatus, text: String, usage: TokenUsage, error: MiraError?, assistantMessageID: MessageID, at: Date) throws -> Bool {
        try safely {
            guard status.isTerminal else { throw MiraError(.invalidInput, "The execution terminal state is invalid.") }
            return try pool.write { db in
                guard let execution = try Row.fetchOne(db, sql: "SELECT conversation_id, status, body_purged_at FROM executions WHERE id = ?", arguments: [id(executionID)]) else { throw MiraError(.notFound, "The execution does not exist.") }
                if execution["body_purged_at"] as Double? != nil { return false }
                let unfinishedAttempts = try Int.fetchOne(db, sql: "SELECT 1 FROM model_attempts WHERE execution_id = ? AND status = 'prepared' LIMIT 1", arguments: [id(executionID)]) != nil
                let unfinishedTools = try Int.fetchOne(db, sql: "SELECT 1 FROM tool_invocations WHERE execution_id = ? AND result_json IS NULL LIMIT 1", arguments: [id(executionID)]) != nil
                if status == .completed && (unfinishedAttempts || unfinishedTools) {
                    throw MiraError(.conflict, "The execution still has unfinished model attempts or tool calls.")
                }
                if status == .completed {
                    try db.execute(sql: "UPDATE execution_steps SET state = 'completed', completed_at = COALESCE(completed_at, ?) WHERE execution_id = ? AND state = 'waitingForTool' AND NOT EXISTS (SELECT 1 FROM tool_invocations WHERE tool_invocations.attempt_id IN (SELECT id FROM model_attempts WHERE model_attempts.step_id = execution_steps.id) AND tool_invocations.result_json IS NULL)", arguments: [at.timeIntervalSince1970, id(executionID)])
                }
                try db.execute(sql: "UPDATE executions SET status = ?, usage_input = ?, usage_output = ?, error_json = ?, updated_at = ? WHERE id = ? AND status IN ('queued', 'waitingForModel')", arguments: [status.rawValue, usage.inputTokens, usage.outputTokens, error.map(Self.encodeStoredError), at.timeIntervalSince1970, id(executionID)])
                guard db.changesCount > 0 else { return false }
                if status != .completed {
                    try closeOpenAudit(in: db, executionID: executionID, at: at)
                }
                if !text.isEmpty, (execution["body_purged_at"] as Double?) == nil {
                    let conversationID = try conversationIDValue(execution["conversation_id"] as String)
                    let sequence = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM messages WHERE conversation_id = ?", arguments: [id(conversationID)]) ?? 1)
                    let messageStatus: MessageStatus = status == .completed ? .committed : .interrupted
                    try db.execute(sql: "INSERT INTO messages (id, conversation_id, execution_id, sequence, role, status, text, created_at) VALUES (?, ?, ?, ?, 'assistant', ?, ?, ?)", arguments: [id(assistantMessageID), id(conversationID), id(executionID), sequence, messageStatus.rawValue, text, at.timeIntervalSince1970])
                }
                if status == .completed {
                    try enqueueMemoryExtractionIfEligible(executionID: executionID, at: at, in: db)
                }
                try db.execute(sql: "DELETE FROM assistant_drafts WHERE execution_id = ?", arguments: [id(executionID)])
                try db.execute(sql: "UPDATE conversations SET updated_at = ?, revision = revision + 1 WHERE id = ?", arguments: [at.timeIntervalSince1970, execution["conversation_id"] as String])
                return true
            }
        }
    }

    public func recoverInterrupted(at: Date) throws {
        try safely {
            try pool.write { db in
                let rows = try Row.fetchAll(db, sql: "SELECT id, conversation_id, body_purged_at FROM executions WHERE status IN ('queued', 'waitingForModel')")
                for row in rows {
                    let executionID = try executionIDValue(row["id"] as String)
                    let conversationID = try conversationIDValue(row["conversation_id"] as String)
                    let draft = try Row.fetchOne(db, sql: "SELECT text, body_purged_at FROM assistant_drafts WHERE execution_id = ?", arguments: [id(executionID)])
                    try db.execute(sql: "UPDATE executions SET status = 'interrupted', updated_at = ? WHERE id = ? AND status IN ('queued', 'waitingForModel')", arguments: [at.timeIntervalSince1970, id(executionID)])
                    let interrupted = db.changesCount > 0
                    if interrupted, let draft, (row["body_purged_at"] as Double?) == nil, (draft["body_purged_at"] as Double?) == nil {
                        let already = try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE execution_id = ? AND role = 'assistant' LIMIT 1", arguments: [id(executionID)])
                        if already == nil {
                            let sequence = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM messages WHERE conversation_id = ?", arguments: [id(conversationID)]) ?? 1)
                            try db.execute(sql: "INSERT INTO messages (id, conversation_id, execution_id, sequence, role, status, text, created_at) VALUES (?, ?, ?, ?, 'assistant', 'interrupted', ?, ?)", arguments: [id(EntityID<MessageTag>()), id(conversationID), id(executionID), sequence, draft["text"] as String, at.timeIntervalSince1970])
                        }
                        try db.execute(sql: "DELETE FROM assistant_drafts WHERE execution_id = ?", arguments: [id(executionID)])
                    }
                    if interrupted, (row["body_purged_at"] as Double?) == nil {
                        try closeOpenAudit(in: db, executionID: executionID, at: at)
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics and backup

    public func diagnostics() throws -> StorageDiagnostics {
        try safely {
            let probe = try DatabaseQueue(path: ":memory:")
            return try probe.write { db in
                try db.execute(sql: "ATTACH DATABASE ':memory:' AS linked")
                var fts5 = false
                var trigram = false
                do {
                    try db.execute(sql: "CREATE VIRTUAL TABLE linked.fts_probe USING fts5(content, tokenize='unicode61')")
                    fts5 = true
                } catch { }
                do {
                    try db.execute(sql: "CREATE VIRTUAL TABLE linked.trigram_probe USING fts5(content, tokenize='trigram')")
                    trigram = true
                } catch { }
                let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "unknown"
                return StorageDiagnostics(sqliteVersion: version, supportsFTS5: fts5, supportsTrigram: trigram)
            }
        }
    }

    /// Close every audit record which may still represent work at a terminal
    /// execution boundary. A dispatched call is conservatively marked
    /// interrupted because its side effect may already have happened; a call
    /// which was never dispatched is explicitly cancelled before dispatch.
    private func closeOpenAudit(in db: Database, executionID: ExecutionID, at: Date) throws {
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE id = ? AND body_purged_at IS NULL", arguments: [id(executionID)]) != nil else { return }
        try db.execute(sql: "UPDATE tool_invocations SET status = 'interrupted', result_json = ?, completed_at = ? WHERE execution_id = ? AND status = 'dispatched' AND result_json IS NULL AND body_purged_at IS NULL", arguments: [try encode(ToolResult(status: .interrupted, text: "The execution was interrupted.")), at.timeIntervalSince1970, id(executionID)])
        try db.execute(sql: "UPDATE tool_invocations SET status = 'cancelledBeforeDispatch', result_json = ?, completed_at = ? WHERE execution_id = ? AND status = 'pending' AND result_json IS NULL AND body_purged_at IS NULL", arguments: [try encode(ToolResult(status: .cancelledBeforeDispatch, text: "The tool was not dispatched because the execution ended.")), at.timeIntervalSince1970, id(executionID)])
        try db.execute(sql: "UPDATE model_attempts SET status = 'interrupted', error_json = ?, completed_at = ? WHERE execution_id = ? AND status = 'prepared' AND body_purged_at IS NULL", arguments: [Self.encodeStoredError(MiraError(.interrupted, "The execution was interrupted.")), at.timeIntervalSince1970, id(executionID)])
        try db.execute(sql: "UPDATE execution_steps SET state = 'interrupted', error_json = ?, body_purged_at = NULL, completed_at = ? WHERE execution_id = ? AND state IN ('running', 'waitingForTool') AND body_purged_at IS NULL", arguments: [Self.encodeStoredError(MiraError(.interrupted, "The execution was interrupted.")), at.timeIntervalSince1970, id(executionID)])
    }

    public func exportBackup(to destination: URL) throws {
        try exportLibraryBackup(to: destination)
    }

    public func restoreBackup(from source: URL, to directory: URL) throws {
        try restoreLibraryBackup(from: source, to: directory)
    }
}

// MARK: - Schema

extension SQLiteMiraStore {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = makeBaseMigrator()
        migrator.registerMigration(auditMigrationName) { db in
            try createAuditSchema(in: db)
            try createMemorySchema(in: db)
            try createMemoryExtractionSchema(in: db)
            try createKnowledgeSchema(in: db)
            try db.execute(sql: "PRAGMA user_version = 9")
        }
        return migrator
    }

    static func makeBaseMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(baseMigrationName) { db in
            try createSchema(in: db)
            try db.execute(sql: "PRAGMA user_version = 9")
        }
        return migrator
    }

    static func schemaSignature(in db: Database) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").map { row in
            let type: String = row["type"], name: String = row["name"]
            let sql: String? = row["sql"]
            return "\(type)|\(name)|\(sql ?? "<nil>")"
        })
    }

    static func createSchema(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE workspaces (
          id TEXT PRIMARY KEY NOT NULL,
          name TEXT NOT NULL CHECK(length(trim(name)) > 0),
          background TEXT NOT NULL,
          allows_remote_send INTEGER NOT NULL CHECK(allows_remote_send IN (0, 1)),
          allowed_connection_ids_json TEXT,
          revision INTEGER NOT NULL CHECK(revision > 0)
        );
        CREATE TABLE conversations (
          id TEXT PRIMARY KEY NOT NULL,
          workspace_id TEXT REFERENCES workspaces(id) ON DELETE RESTRICT,
          title TEXT NOT NULL,
          is_archived INTEGER NOT NULL CHECK(is_archived IN (0, 1)),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          revision INTEGER NOT NULL CHECK(revision > 0)
        );
        CREATE TABLE provider_connections (
          id TEXT PRIMARY KEY NOT NULL,
          revision INTEGER NOT NULL CHECK(revision > 0),
          name TEXT NOT NULL CHECK(length(trim(name)) > 0),
          provider_kind TEXT NOT NULL CHECK(provider_kind IN ('openAICompatible', 'anthropic')),
          base_url TEXT NOT NULL,
          credential_reference TEXT NOT NULL CHECK(length(trim(credential_reference)) > 0),
          credential_version INTEGER NOT NULL CHECK(credential_version > 0),
          allows_loopback_http INTEGER NOT NULL CHECK(allows_loopback_http IN (0, 1)),
          is_enabled INTEGER NOT NULL CHECK(is_enabled IN (0, 1)),
          connection_json TEXT NOT NULL
        );
        CREATE TABLE model_descriptors (
          id TEXT PRIMARY KEY NOT NULL,
          revision INTEGER NOT NULL CHECK(revision > 0),
          connection_id TEXT NOT NULL REFERENCES provider_connections(id) ON DELETE CASCADE,
          connection_revision INTEGER NOT NULL CHECK(connection_revision > 0),
          model_id TEXT NOT NULL CHECK(length(trim(model_id)) > 0),
          context_window INTEGER,
          text_capability TEXT NOT NULL CHECK(text_capability IN ('unknown', 'declared', 'verified', 'failed')),
          tool_capability TEXT NOT NULL CHECK(tool_capability IN ('unknown', 'declared', 'verified', 'failed')),
          probe_observation_json TEXT,
          is_enabled INTEGER NOT NULL CHECK(is_enabled IN (0, 1)),
          extraction_capability TEXT NOT NULL CHECK(extraction_capability IN ('unknown', 'declared', 'verified', 'failed')),
          protocol_mode TEXT NOT NULL CHECK(protocol_mode IN ('standard', 'thinkingDisabled', 'unsupportedReasoning')),
          model_json TEXT NOT NULL
        );
        CREATE TABLE model_routes (
          id TEXT PRIMARY KEY NOT NULL,
          revision INTEGER NOT NULL CHECK(revision > 0),
          name TEXT NOT NULL CHECK(length(trim(name)) > 0),
          model_descriptor_id TEXT NOT NULL REFERENCES model_descriptors(id) ON DELETE CASCADE,
          max_output_tokens INTEGER NOT NULL CHECK(max_output_tokens > 0),
          requests_usage INTEGER NOT NULL CHECK(requests_usage IN (0, 1)),
          route_json TEXT NOT NULL
        );
        CREATE TABLE route_bindings (
          id TEXT PRIMARY KEY NOT NULL,
          scope_key TEXT NOT NULL,
          purpose TEXT NOT NULL CHECK(purpose IN ('conversation', 'memoryExtraction')),
          route_id TEXT NOT NULL REFERENCES model_routes(id) ON DELETE CASCADE,
          revision INTEGER NOT NULL CHECK(revision > 0),
          binding_json TEXT NOT NULL,
          UNIQUE(scope_key, purpose)
        );
        CREATE TABLE executions (
          id TEXT PRIMARY KEY NOT NULL,
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          trigger_message_id TEXT NOT NULL,
          retry_of_execution_id TEXT REFERENCES executions(id) ON DELETE RESTRICT,
          status TEXT NOT NULL CHECK(status IN ('queued', 'waitingForModel', 'completed', 'failed', 'cancelled', 'interrupted')),
          route_json TEXT NOT NULL,
          usage_input INTEGER,
          usage_output INTEGER,
          error_json TEXT,
          body_purged_at REAL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(id, conversation_id),
          FOREIGN KEY(trigger_message_id, conversation_id) REFERENCES messages(id, conversation_id) DEFERRABLE INITIALLY DEFERRED
        );
        CREATE TABLE messages (
          id TEXT PRIMARY KEY NOT NULL,
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          execution_id TEXT,
          sequence INTEGER NOT NULL CHECK(sequence > 0),
          role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
          status TEXT NOT NULL CHECK(status IN ('committed', 'interrupted', 'failed')),
          text TEXT NOT NULL,
          body_purged_at REAL,
          created_at REAL NOT NULL,
          UNIQUE(conversation_id, sequence),
          UNIQUE(id, conversation_id),
          FOREIGN KEY(execution_id, conversation_id) REFERENCES executions(id, conversation_id) DEFERRABLE INITIALLY DEFERRED
        );
        CREATE TABLE assistant_drafts (
          execution_id TEXT PRIMARY KEY NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
          text TEXT NOT NULL,
          body_purged_at REAL,
          updated_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX executions_one_active_per_conversation ON executions(conversation_id) WHERE status IN ('queued', 'waitingForModel');
        CREATE UNIQUE INDEX messages_one_assistant_per_execution ON messages(execution_id) WHERE role = 'assistant';
        CREATE INDEX conversations_workspace_updated ON conversations(workspace_id, updated_at, id);
        CREATE INDEX messages_conversation_sequence ON messages(conversation_id, sequence);
        CREATE INDEX executions_conversation_created ON executions(conversation_id, created_at, id);
        CREATE UNIQUE INDEX model_descriptors_connection ON model_descriptors(connection_id, model_id);
        CREATE INDEX model_routes_descriptor ON model_routes(model_descriptor_id, name, id);
        CREATE INDEX route_bindings_scope_purpose ON route_bindings(scope_key, purpose, id);
        """)
    }

    static func createAuditSchema(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE execution_steps (
          id TEXT PRIMARY KEY NOT NULL,
          execution_id TEXT NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
          sequence INTEGER NOT NULL CHECK(sequence > 0),
          state TEXT NOT NULL CHECK(state IN ('running', 'waitingForTool', 'completed', 'failed', 'interrupted')),
          output_json TEXT,
          error_json TEXT,
          body_purged_at REAL,
          started_at REAL NOT NULL,
          completed_at REAL,
          UNIQUE(id, execution_id, sequence),
          UNIQUE(execution_id, sequence),
          CHECK((state IN ('running', 'waitingForTool') AND completed_at IS NULL) OR (state IN ('completed', 'failed', 'interrupted') AND completed_at IS NOT NULL))
        );
        CREATE TABLE model_attempts (
          id TEXT PRIMARY KEY NOT NULL,
          execution_id TEXT NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
          step_id TEXT NOT NULL,
          step_index INTEGER NOT NULL CHECK(step_index > 0),
          attempt_index INTEGER NOT NULL CHECK(attempt_index > 0),
          request_json TEXT,
          status TEXT NOT NULL CHECK(status IN ('prepared', 'completed', 'failed', 'interrupted')),
          output_json TEXT,
          usage_input INTEGER,
          usage_output INTEGER,
          error_json TEXT,
          body_purged_at REAL,
          created_at REAL NOT NULL,
          completed_at REAL,
          UNIQUE(id, execution_id),
          UNIQUE(execution_id, step_id, step_index, attempt_index),
          FOREIGN KEY(step_id, execution_id, step_index) REFERENCES execution_steps(id, execution_id, sequence) ON DELETE CASCADE,
          CHECK((status = 'prepared' AND completed_at IS NULL) OR (status IN ('completed', 'failed', 'interrupted') AND completed_at IS NOT NULL)),
          CHECK(status != 'completed' OR output_json IS NOT NULL OR body_purged_at IS NOT NULL)
        );
        CREATE TABLE tool_invocations (
          id TEXT PRIMARY KEY NOT NULL,
          execution_id TEXT NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
          attempt_id TEXT NOT NULL,
          model_order INTEGER NOT NULL CHECK(model_order >= 0),
          provider_call_id TEXT NOT NULL CHECK(length(provider_call_id) > 0),
          tool_name TEXT NOT NULL CHECK(length(tool_name) > 0),
          arguments_json TEXT,
          status TEXT NOT NULL CHECK(status IN ('pending', 'dispatched', 'succeeded', 'invalidArguments', 'notFound', 'denied', 'timedOut', 'cancelledBeforeDispatch', 'cancelled', 'failed', 'outputLimit', 'interrupted')),
          result_json TEXT,
          body_purged_at REAL,
          dispatched_at REAL,
          completed_at REAL,
          UNIQUE(attempt_id, model_order),
          UNIQUE(attempt_id, provider_call_id),
          UNIQUE(id, execution_id),
          FOREIGN KEY(attempt_id, execution_id) REFERENCES model_attempts(id, execution_id) ON DELETE CASCADE,
          CHECK((status IN ('pending', 'dispatched') AND result_json IS NULL AND completed_at IS NULL) OR (status NOT IN ('pending', 'dispatched') AND ((result_json IS NOT NULL AND completed_at IS NOT NULL) OR body_purged_at IS NOT NULL))),
          CHECK((status = 'pending' AND dispatched_at IS NULL) OR status != 'pending'),
          CHECK((status = 'dispatched' AND dispatched_at IS NOT NULL) OR status != 'dispatched'),
          CHECK((status IN ('pending', 'invalidArguments', 'notFound', 'cancelledBeforeDispatch') AND dispatched_at IS NULL) OR (status IN ('dispatched', 'succeeded', 'cancelled', 'interrupted') AND dispatched_at IS NOT NULL) OR status IN ('denied', 'timedOut', 'failed', 'outputLimit'))
        );
        CREATE INDEX execution_steps_execution_sequence ON execution_steps(execution_id, sequence);
        CREATE INDEX model_attempts_execution_order ON model_attempts(execution_id, step_index, attempt_index);
        CREATE INDEX tool_invocations_execution_order ON tool_invocations(execution_id, attempt_id, model_order);
        """)
    }

    static func createMemorySchema(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE memories (
          id TEXT PRIMARY KEY NOT NULL,
          scope_key TEXT NOT NULL,
          scope_json TEXT NOT NULL,
          subject TEXT NOT NULL CHECK(subject IN ('user', 'workspace')),
          state TEXT NOT NULL CHECK(state IN ('active', 'candidate', 'archived', 'rejected', 'removed')),
          origin TEXT NOT NULL CHECK(origin IN ('explicitUser', 'observedUserStatement', 'agentInference')),
          authority TEXT NOT NULL CHECK(authority IN ('explicitUser', 'observedUser', 'inferred')),
          superseded_by TEXT REFERENCES memories(id) ON DELETE RESTRICT,
          revision INTEGER NOT NULL CHECK(revision > 0),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          deleted_at REAL,
          forgotten_at REAL,
          draft_json TEXT,
          source_kind TEXT NOT NULL CHECK(source_kind IN ('message', 'manualEntry')),
          source_id TEXT NOT NULL,
          assertion_hash TEXT NOT NULL,
          memory_json TEXT NOT NULL
        );
        CREATE UNIQUE INDEX memories_business_identity ON memories(source_kind, source_id, subject, scope_key, assertion_hash) WHERE forgotten_at IS NULL;
        CREATE TABLE memory_evidence (
          id TEXT PRIMARY KEY NOT NULL,
          memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
          source_kind TEXT NOT NULL CHECK(source_kind IN ('message', 'manualEntry')),
          source_id TEXT NOT NULL,
          source_revision INTEGER NOT NULL CHECK(source_revision > 0),
          conversation_id TEXT REFERENCES conversations(id) ON DELETE RESTRICT,
          excerpt TEXT,
          source_hash TEXT,
          speaker_role TEXT NOT NULL CHECK(speaker_role IN ('user', 'assistant')),
          created_at REAL NOT NULL,
          body_purged_at REAL,
          evidence_json TEXT NOT NULL,
          UNIQUE(memory_id, source_kind, source_id)
        );
        CREATE TABLE memory_revisions (
          memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
          revision INTEGER NOT NULL CHECK(revision > 0),
          draft_json TEXT,
          actor TEXT NOT NULL,
          changed_at REAL NOT NULL,
          body_purged_at REAL,
          revision_json TEXT NOT NULL,
          PRIMARY KEY(memory_id, revision)
        );
        CREATE TABLE memory_replacements (
          id TEXT PRIMARY KEY NOT NULL,
          replacement_id TEXT NOT NULL REFERENCES memories(id) ON DELETE RESTRICT,
          previous_id TEXT NOT NULL REFERENCES memories(id) ON DELETE RESTRICT,
          state TEXT NOT NULL CHECK(state IN ('proposed', 'confirmed', 'rejected')),
          created_at REAL NOT NULL,
          replacement_json TEXT NOT NULL,
          UNIQUE(replacement_id, previous_id)
        );
        CREATE TABLE memory_operation_receipts (
          operation_id TEXT PRIMARY KEY NOT NULL,
          payload_hash TEXT NOT NULL,
          memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE RESTRICT,
          disposition TEXT NOT NULL CHECK(disposition IN ('created', 'existing', 'replacementProposed')),
          created_at REAL NOT NULL,
          receipt_json TEXT NOT NULL
        );
        CREATE TABLE memory_source_suppressions (
          source_kind TEXT NOT NULL CHECK(source_kind IN ('message', 'manualEntry')),
          source_id TEXT NOT NULL,
          suppressed_at REAL NOT NULL,
          reason TEXT NOT NULL,
          suppression_json TEXT NOT NULL,
          PRIMARY KEY(source_kind, source_id)
        );
        CREATE TABLE memory_usages (
          execution_id TEXT NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
          memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE RESTRICT,
          revision INTEGER NOT NULL CHECK(revision > 0),
          usage_kind TEXT NOT NULL CHECK(usage_kind IN ('recall', 'capture')),
          created_at REAL NOT NULL,
          usage_json TEXT NOT NULL,
          PRIMARY KEY(execution_id, memory_id)
        );
        CREATE TABLE execution_history_dependencies (
          execution_id TEXT NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
          source_execution_id TEXT NOT NULL REFERENCES executions(id) ON DELETE CASCADE,
          PRIMARY KEY(execution_id, source_execution_id),
          CHECK(execution_id != source_execution_id)
        );
        CREATE VIRTUAL TABLE memory_search USING fts5(memory_id UNINDEXED, content, tokenize='trigram');
        CREATE INDEX memories_scope_state_updated ON memories(scope_key, state, updated_at, id);
        CREATE INDEX memory_evidence_memory ON memory_evidence(memory_id, created_at, id);
        CREATE INDEX memory_revisions_memory ON memory_revisions(memory_id, revision);
        CREATE INDEX memory_replacements_previous ON memory_replacements(previous_id, created_at, id);
        CREATE INDEX memory_usages_execution ON memory_usages(execution_id, memory_id);
        CREATE INDEX execution_history_dependencies_source ON execution_history_dependencies(source_execution_id, execution_id);
        """)
    }

    static func createDirectoryIfNeeded(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path), (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw MiraError(.storage, "The database directory is invalid.")
        }
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw MiraError(.storage, "The database directory is invalid.") }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return
        }
    }

    static func encodeStoredError(_ error: MiraError) -> String {
        (try? encode(error)) ?? ""
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func preservesConnectionCapabilities(from old: ProviderConnection, to new: ProviderConnection) -> Bool {
        old.providerKind == new.providerKind
            && old.baseURL == new.baseURL
            && old.credentialReference == new.credentialReference
            && old.credentialVersion == new.credentialVersion
            && old.allowsLoopbackHTTP == new.allowsLoopbackHTTP

    }

    static func validateModelIdentity(_ model: ModelDescriptor, in db: Database) throws {
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM model_descriptors WHERE connection_id = ? AND model_id = ? AND id != ? LIMIT 1", arguments: [id(model.connectionID), model.modelID, id(model.id)]) == nil else {
            throw MiraError(.conflict, "A model with this ID is already configured for the provider connection.")
        }
    }

    static func decodeRoute(_ value: String) throws -> ResolvedModelRouteSnapshot {
        let route: ResolvedModelRouteSnapshot = try decode(value)
        try validateHistoricalRoute(route)
        return route
    }

    /// Execution routes are immutable snapshots. Validate their self-contained
    /// transport contract without consulting the current configuration tables.
    static func validateHistoricalRoute(_ route: ResolvedModelRouteSnapshot) throws {
        let expectedAdapter = route.providerKind == .anthropic ? "anthropic-messages/1" : "openai-chat-completions/2"
        guard route.revision > 0, route.connectionRevision > 0, route.modelRevision > 0,
              !route.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              route.name.count <= 100,
              !route.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              route.modelID.count <= 300,
              !route.credentialReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              route.credentialVersion > 0, route.adapterVersion == expectedAdapter,
              let contextWindow = route.contextWindow, contextWindow > 0, contextWindow <= 10_000_000,
              route.maxOutputTokens > 0, route.maxOutputTokens < contextWindow else {
            throw MiraError(.storage, "The execution route snapshot is invalid.")
        }
        do {
            _ = try route.validatedEndpoint()
        } catch {
            throw MiraError(.storage, "The execution route snapshot is invalid.")
        }
    }

    static func decodeRequest(_ value: String) throws -> CanonicalModelRequest {
        try decode(value)
    }

    static func decode<T: Decodable>(_ value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(T.self, from: Data(value.utf8))
    }

    func safely<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let error as MiraError { throw error }
        catch { throw MiraError.safe(error) }
    }

    func id<Tag>(_ value: EntityID<Tag>) -> String { Self.id(value) }
    func encode<T: Encodable>(_ value: T) throws -> String { try Self.encode(value) }
    func decodeRoute(_ value: String) throws -> ResolvedModelRouteSnapshot { try Self.decodeRoute(value) }
    func decodeRequest(_ value: String) throws -> CanonicalModelRequest { try Self.decodeRequest(value) }
    func executionIDValue(_ value: String) throws -> ExecutionID { try Self.executionIDValue(value) }
    func conversationIDValue(_ value: String) throws -> ConversationID { try Self.conversationIDValue(value) }
    func messageIDValue(_ value: String) throws -> MessageID { try Self.messageIDValue(value) }
    func encodeConnectionAllowlist(_ value: Set<ConnectionID>?) throws -> String? { try Self.encodeConnectionAllowlist(value) }
    func encodeRouteBinding(_ binding: RouteBinding) throws -> String { try Self.encodeRouteBinding(binding) }

    static func id<Tag>(_ value: EntityID<Tag>) -> String { value.rawValue.uuidString.lowercased() }
    static func workspace(_ row: Row) throws -> Workspace {
        guard let uuid = UUID(uuidString: row["id"] as String) else { throw MiraError(.storage, "The database contents are invalid.") }
        let allowlist = try decodeConnectionAllowlist(row["allowed_connection_ids_json"] as String?)
        return Workspace(id: WorkspaceID(uuid), name: row["name"] as String, background: row["background"] as String, allowsRemoteSend: (row["allows_remote_send"] as Int) != 0, revision: row["revision"] as Int, allowedConnectionIDs: allowlist)
    }
    static func conversation(_ row: Row) throws -> Conversation {
        guard let uuid = UUID(uuidString: row["id"] as String) else { throw MiraError(.storage, "The database contents are invalid.") }
        let workspaceID = try (row["workspace_id"] as String?).map { value -> WorkspaceID in guard let value = UUID(uuidString: value) else { throw MiraError(.storage, "The database contents are invalid.") }; return WorkspaceID(value) }
        return Conversation(id: ConversationID(uuid), workspaceID: workspaceID, title: row["title"] as String, isArchived: (row["is_archived"] as Int) != 0, createdAt: Date(timeIntervalSince1970: row["created_at"] as Double), updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double), revision: row["revision"] as Int)
    }
    static func message(_ row: Row) throws -> Message {
        guard let uuid = UUID(uuidString: row["id"] as String), let conversationUUID = UUID(uuidString: row["conversation_id"] as String), let role = MessageRole(rawValue: row["role"] as String), let status = MessageStatus(rawValue: row["status"] as String) else { throw MiraError(.storage, "The database contents are invalid.") }
        let executionID = try (row["execution_id"] as String?).map { value -> ExecutionID in guard let value = UUID(uuidString: value) else { throw MiraError(.storage, "The database contents are invalid.") }; return ExecutionID(value) }
        let bodyPurgedAt = (row["body_purged_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        if bodyPurgedAt != nil, (row["text"] as String).isEmpty == false { throw MiraError(.storage, "The purged message still contains a body.") }
        return Message(id: MessageID(uuid), conversationID: ConversationID(conversationUUID), executionID: executionID, sequence: row["sequence"] as Int, role: role, status: status, text: row["text"] as String, createdAt: Date(timeIntervalSince1970: row["created_at"] as Double), bodyPurgedAt: (row["body_purged_at"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }
    static func execution(_ row: Row) throws -> Execution {
        guard let status = ExecutionStatus(rawValue: row["status"] as String) else { throw MiraError(.storage, "The database contents are invalid.") }
        let retryID = try (row["retry_of_execution_id"] as String?).map { value -> ExecutionID in guard let value = UUID(uuidString: value) else { throw MiraError(.storage, "The database contents are invalid.") }; return ExecutionID(value) }
        let bodyPurgedAt = (row["body_purged_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        if bodyPurgedAt != nil, (row["error_json"] as String?) != nil { throw MiraError(.storage, "The purged execution still contains an error body.") }
        return Execution(id: ExecutionID(try uuid(row["id"] as String)), conversationID: ConversationID(try uuid(row["conversation_id"] as String)), triggerMessageID: MessageID(try uuid(row["trigger_message_id"] as String)), retryOfExecutionID: retryID, status: status, route: try decodeRoute(row["route_json"] as String), usage: TokenUsage(inputTokens: row["usage_input"] as Int?, outputTokens: row["usage_output"] as Int?), error: (row["error_json"] as String?).flatMap { try? decode($0) }, createdAt: Date(timeIntervalSince1970: row["created_at"] as Double), updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double), bodyPurgedAt: bodyPurgedAt)
    }
    static func uuid(_ value: String) throws -> UUID { guard let value = UUID(uuidString: value) else { throw MiraError(.storage, "The database contents are invalid.") }; return value }
    static func executionIDValue(_ value: String) throws -> ExecutionID { ExecutionID(try uuid(value)) }
    static func conversationIDValue(_ value: String) throws -> ConversationID { ConversationID(try uuid(value)) }
    static func messageIDValue(_ value: String) throws -> MessageID { MessageID(try uuid(value)) }

    static func encodeConnectionAllowlist(_ value: Set<ConnectionID>?) throws -> String? {
        guard let value else { return nil }
        return try encode(value.map { id($0) }.sorted())
    }

    static func decodeConnectionAllowlist(_ value: String?) throws -> Set<ConnectionID>? {
        guard let value else { return nil }
        let ids: [String] = try decode(value)
        var result = Set<ConnectionID>()
        for raw in ids {
            guard let uuid = UUID(uuidString: raw), result.insert(ConnectionID(uuid)).inserted else { throw MiraError(.storage, "The workspace connection allowlist is invalid.") }
        }
        return result
    }

    static func providerConnection(_ row: Row) throws -> ProviderConnection {
        let connection: ProviderConnection = try decode(row["connection_json"] as String)
        guard id(connection.id) == (row["id"] as String), connection.revision == row["revision"] as Int,
              connection.name == (row["name"] as String), connection.providerKind.rawValue == (row["provider_kind"] as String),
              connection.baseURL == (row["base_url"] as String), connection.credentialReference == (row["credential_reference"] as String),
              connection.credentialVersion == row["credential_version"] as Int, connection.allowsLoopbackHTTP == ((row["allows_loopback_http"] as Int) != 0),
              connection.isEnabled == ((row["is_enabled"] as Int) != 0) else {
            throw MiraError(.storage, "The provider connection contents are inconsistent.")
        }
        try connection.validate()
        return connection
    }

    static func modelDescriptor(_ row: Row) throws -> ModelDescriptor {
        let model: ModelDescriptor = try decode(row["model_json"] as String)
        let observation: ProbeObservation? = try (row["probe_observation_json"] as String?).map { try decode($0) }
        guard id(model.id) == (row["id"] as String), model.revision == row["revision"] as Int,
              id(model.connectionID) == (row["connection_id"] as String), model.connectionRevision == row["connection_revision"] as Int,
              model.modelID == (row["model_id"] as String), model.contextWindow == (row["context_window"] as Int?),
              model.textCapability.rawValue == (row["text_capability"] as String), model.toolCapability.rawValue == (row["tool_capability"] as String),
              model.isEnabled == ((row["is_enabled"] as Int) != 0),
              model.extractionCapability.rawValue == (row["extraction_capability"] as String),
              model.protocolMode.rawValue == (row["protocol_mode"] as String),
              model.probeObservation == observation else {
            throw MiraError(.storage, "The model descriptor contents are inconsistent.")
        }
        try model.validate()
        return model
    }

    static func modelRoute(_ row: Row) throws -> ModelRoute {
        let route: ModelRoute = try decode(row["route_json"] as String)
        guard id(route.id) == (row["id"] as String), route.revision == row["revision"] as Int,
              route.name == (row["name"] as String), id(route.modelDescriptorID) == (row["model_descriptor_id"] as String),
              route.maxOutputTokens == row["max_output_tokens"] as Int, route.requestsUsage == ((row["requests_usage"] as Int) != 0) else {
            throw MiraError(.storage, "The model route contents are inconsistent.")
        }
        try route.validate()
        return route
    }

    static func encodeRouteBinding(_ binding: RouteBinding) throws -> String {
        guard var object = try JSONSerialization.jsonObject(with: Data(encode(binding).utf8)) as? [String: Any] else { throw MiraError(.storage, "The route binding contents are invalid.") }
        object["id"] = binding.id
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func routeBinding(_ row: Row) throws -> RouteBinding {
        let raw = row["binding_json"] as String
        guard let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], object["id"] as? String == (row["id"] as String) else { throw MiraError(.storage, "The route binding contents are inconsistent.") }
        let binding: RouteBinding = try decode(raw)
        guard binding.id == (row["id"] as String), binding.scope.key == (row["scope_key"] as String), binding.purpose.rawValue == (row["purpose"] as String),
              id(binding.routeID) == (row["route_id"] as String), binding.revision == row["revision"] as Int else {
            throw MiraError(.storage, "The route binding contents are inconsistent.")
        }
        return binding
    }

    static func validateRouteBinding(_ binding: RouteBinding) throws {
        guard binding.revision > 0, binding.id == "\(binding.scope.key):\(binding.purpose.rawValue)" else { throw MiraError(.invalidInput, "The route binding information is invalid.") }
    }

    func validateRouteBinding(_ binding: RouteBinding) throws { try Self.validateRouteBinding(binding) }

    static func validateRouteScope(_ scope: RouteScope, in db: Database) throws {
        switch scope {
        case .global: return
        case .workspace(let workspaceID):
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM workspaces WHERE id = ?", arguments: [id(workspaceID)]) != nil else { throw MiraError(.notFound, "The workspace does not exist.") }
        case .conversation(let conversationID):
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM conversations WHERE id = ?", arguments: [id(conversationID)]) != nil else { throw MiraError(.notFound, "The conversation does not exist.") }
        }
    }

    func validateRouteScope(_ scope: RouteScope, in db: Database) throws { try Self.validateRouteScope(scope, in: db) }

    static func modelAttempt(_ row: Row) throws -> ModelAttempt {
        let attemptID = try uuid(row["id"] as String)
        let executionID = try executionIDValue(row["execution_id"] as String)
        let stepID = try uuid(row["step_id"] as String)
        guard let status = AttemptStatus(rawValue: row["status"] as String) else { throw MiraError(.storage, "The database model attempt status is invalid.") }
        let purgedAt = (row["body_purged_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        var attempt = ModelAttempt(id: attemptID, executionID: executionID, stepID: stepID, stepIndex: row["step_index"] as Int, attemptIndex: row["attempt_index"] as Int, request: try (row["request_json"] as String?).map { try decodeRequest($0) }, createdAt: Date(timeIntervalSince1970: row["created_at"] as Double), bodyPurgedAt: purgedAt)
        attempt.status = status
        attempt.output = try (row["output_json"] as String?).map { try decode($0) }
        attempt.usage = TokenUsage(inputTokens: row["usage_input"] as Int?, outputTokens: row["usage_output"] as Int?)
        attempt.error = try (row["error_json"] as String?).map { try decode($0) }
        attempt.completedAt = (row["completed_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        if purgedAt != nil, attempt.request != nil || attempt.output != nil || attempt.error != nil { throw MiraError(.storage, "The purged model attempt still contains a body.") }
        return attempt
    }

    static func toolInvocation(_ row: Row) throws -> ToolInvocation {
        let id = try uuid(row["id"] as String)
        let attemptID = try uuid(row["attempt_id"] as String)
        let purgedAt = (row["body_purged_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        let arguments = (row["arguments_json"] as String?) ?? ""
        let call = CanonicalToolCall(id: row["provider_call_id"] as String, name: row["tool_name"] as String, arguments: arguments)
        let status = row["status"] as String
        if purgedAt != nil {
            guard row["arguments_json"] as String? == nil, row["result_json"] as String? == nil else { throw MiraError(.storage, "The purged tool result still contains a body.") }
            if status == "pending" || status == "dispatched" {
                guard row["completed_at"] as Double? == nil else { throw MiraError(.storage, "The purged tool result has an invalid completion state.") }
            } else {
                guard ToolResultStatus(rawValue: status) != nil, row["completed_at"] as Double? != nil else { throw MiraError(.storage, "The purged tool result has an invalid completion state.") }
            }
            return ToolInvocation(id: id, attemptID: attemptID, modelOrder: row["model_order"] as Int, call: call, result: nil, dispatchedAt: (row["dispatched_at"] as Double?).map(Date.init(timeIntervalSince1970:)), completedAt: (row["completed_at"] as Double?).map(Date.init(timeIntervalSince1970:)), bodyPurgedAt: purgedAt)
        }
        guard ToolResultStatus(rawValue: status) != nil else {
            guard (status == "pending" || status == "dispatched"), row["arguments_json"] as String? != nil else { throw MiraError(.storage, "The database tool call status is invalid.") }
            return ToolInvocation(id: id, attemptID: attemptID, modelOrder: row["model_order"] as Int, call: call, result: nil, dispatchedAt: (row["dispatched_at"] as Double?).map(Date.init(timeIntervalSince1970:)), completedAt: nil, bodyPurgedAt: purgedAt)
        }
        guard row["arguments_json"] as String? != nil,
              let resultJSON = row["result_json"] as String?,
              let result: ToolResult = try? decode(resultJSON),
              result.status.rawValue == status else { throw MiraError(.storage, "The database tool result is invalid.") }
        return ToolInvocation(id: id, attemptID: attemptID, modelOrder: row["model_order"] as Int, call: call, result: result, dispatchedAt: (row["dispatched_at"] as Double?).map(Date.init(timeIntervalSince1970:)), completedAt: (row["completed_at"] as Double?).map(Date.init(timeIntervalSince1970:)), bodyPurgedAt: nil)
    }

    static func memoryUsages(in request: CanonicalModelRequest) throws -> [MemoryUsage] {
        var result: [MemoryUsage] = []
        var seen: [MemoryID: Int] = [:]
        for reference in request.contextInfo?.references ?? [] where reference.kind == "memory" {
            guard let uuid = UUID(uuidString: reference.id), let revision = reference.revision, revision > 0 else {
                throw MiraError(.storage, "The memory context reference is invalid.")
            }
            let id = MemoryID(uuid)
            if let prior = seen[id] {
                guard prior == revision else { throw MiraError(.storage, "The memory context references disagree.") }
            } else {
                seen[id] = revision
                result.append(MemoryUsage(memoryID: id, revision: revision))
            }
        }
        return result
    }

    fileprivate func prepareMemoryContext(_ request: CanonicalModelRequest, executionID: ExecutionID, in db: Database) throws -> PreparedMemoryContext {
        var kinds: [MemoryID: MemoryUsageKind] = [:]
        var usages: [MemoryUsage] = []
        for usage in try Self.memoryUsages(in: request) {
            kinds[usage.memoryID] = .recall
            usages.append(usage)
        }
        guard let execution = try Row.fetchOne(db, sql: "SELECT conversation_id, trigger_message_id FROM executions WHERE id = ?", arguments: [id(executionID)]) else { throw MiraError(.notFound, "The execution does not exist.") }
        let conversationID = try conversationIDValue(execution["conversation_id"] as String)
        guard let triggerSequence = try Int.fetchOne(db, sql: "SELECT sequence FROM messages WHERE id = ? AND conversation_id = ?", arguments: [execution["trigger_message_id"] as String, id(conversationID)]) else { throw MiraError(.storage, "The execution trigger message is invalid.") }
        let historyReferences = request.contextInfo?.references.filter { $0.kind == "historyMessage" } ?? []
        var sourceExecutions: Set<ExecutionID> = []
        for reference in historyReferences {
            guard let messageUUID = UUID(uuidString: reference.id),
                  let message = try Row.fetchOne(db, sql: "SELECT conversation_id, execution_id, sequence, body_purged_at FROM messages WHERE id = ?", arguments: [reference.id.lowercased()]),
                  (message["conversation_id"] as String) == id(conversationID),
                  (message["sequence"] as Int) < triggerSequence,
                  (message["body_purged_at"] as Double?) == nil else { throw MiraError(.storage, "The history message reference is invalid.") }
            _ = messageUUID
            if let sourceExecutionValue = message["execution_id"] as String? {
                guard let sourceID = try? executionIDValue(sourceExecutionValue) else { throw MiraError(.storage, "The history message execution reference is invalid.") }
                sourceExecutions.insert(sourceID)
            }
            let triggered = try String.fetchAll(db, sql: "SELECT id FROM executions WHERE trigger_message_id = ?", arguments: [reference.id.lowercased()]).map { try executionIDValue($0) }
            sourceExecutions.formUnion(triggered)
        }
        for sourceExecutionID in sourceExecutions {
            guard sourceExecutionID != executionID,
                  let source = try Row.fetchOne(db, sql: "SELECT conversation_id, trigger_message_id FROM executions WHERE id = ?", arguments: [id(sourceExecutionID)]),
                  (source["conversation_id"] as String) == id(conversationID),
                  let sourceSequence = try Int.fetchOne(db, sql: "SELECT sequence FROM messages WHERE id = ? AND conversation_id = ?", arguments: [source["trigger_message_id"] as String, id(conversationID)]),
                  sourceSequence < triggerSequence else { throw MiraError(.storage, "The history execution dependency is invalid.") }
            try db.execute(sql: "INSERT OR IGNORE INTO execution_history_dependencies (execution_id, source_execution_id) VALUES (?, ?)", arguments: [id(executionID), id(sourceExecutionID)])
            let sourceUsages = try Row.fetchAll(db, sql: "SELECT memory_id, revision, usage_kind, usage_json FROM memory_usages WHERE execution_id = ?", arguments: [id(sourceExecutionID)])
            for row in sourceUsages {
                let usage: MemoryUsage = try Self.decode(row["usage_json"] as String)
                guard Self.id(usage.memoryID) == (row["memory_id"] as String), usage.revision == (row["revision"] as Int), let kind = MemoryUsageKind(rawValue: row["usage_kind"] as String) else { throw MiraError(.storage, "The memory usage record is invalid.") }
                if let prior = usages.first(where: { $0.memoryID == usage.memoryID }) {
                    guard prior.revision == usage.revision else { throw MiraError(.conflict, "The memory usage revisions disagree.") }
                    if kind == .recall { kinds[usage.memoryID] = .recall }
                } else {
                    usages.append(usage)
                    kinds[usage.memoryID] = kind
                }
            }
        }
        return PreparedMemoryContext(usages: usages, kinds: kinds)
    }

    func persistMemoryUsages(_ usages: [MemoryUsage], executionID: ExecutionID, at: Date, kind: MemoryUsageKind = .recall, in db: Database) throws {
        for usage in usages {
            if let row = try Row.fetchOne(db, sql: "SELECT revision, usage_kind FROM memory_usages WHERE execution_id = ? AND memory_id = ?", arguments: [id(executionID), Self.id(usage.memoryID)]) {
                guard (row["revision"] as Int) == usage.revision else { throw MiraError(.conflict, "The memory usage revision is out of date.") }
                let existingKind = MemoryUsageKind(rawValue: row["usage_kind"] as String)
                if existingKind == .capture, kind == .recall {
                    try db.execute(sql: "UPDATE memory_usages SET usage_kind = 'recall' WHERE execution_id = ? AND memory_id = ?", arguments: [id(executionID), Self.id(usage.memoryID)])
                }
            } else {
                try db.execute(sql: "INSERT INTO memory_usages (execution_id, memory_id, revision, usage_kind, created_at, usage_json) VALUES (?, ?, ?, ?, ?, ?)", arguments: [id(executionID), Self.id(usage.memoryID), usage.revision, kind.rawValue, at.timeIntervalSince1970, try Self.encode(usage)])
            }
        }
    }

    static func validateBackupMetadata(in db: Database) throws {
        let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        let expectedMigrations = [baseMigrationName, auditMigrationName]
        guard migrations == expectedMigrations else { throw MiraError(.unsupported, "The backup contains unknown database migrations.") }
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        var expectedTables: Set<String> = ["grdb_migrations", "workspaces", "conversations", "provider_connections", "model_descriptors", "model_routes", "route_bindings", "executions", "messages", "assistant_drafts", "execution_steps", "model_attempts", "tool_invocations", "memories", "memory_evidence", "memory_revisions", "memory_replacements", "memory_operation_receipts", "memory_source_suppressions", "memory_usages", "execution_history_dependencies", "memory_capture_policy", "memory_extraction_jobs", "memory_extraction_attempts", "memory_extraction_decisions", "memory_search", "memory_search_config", "memory_search_data", "memory_search_docsize", "memory_search_idx", "memory_search_content"]
        expectedTables.formUnion(try knowledgeTableNames(in: db))
        guard Set(tables) == expectedTables else { throw MiraError(.unsupported, "The backup contains an unknown database schema.") }
        let unexpectedProgrammableObjects = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('trigger', 'view')")
        guard unexpectedProgrammableObjects.isEmpty else { throw MiraError(.unsupported, "The backup contains unknown database objects.") }
    }

    static func validateContents(in db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT id, name, background, allows_remote_send, allowed_connection_ids_json, revision FROM workspaces") { _ = try workspace(row) }
        for row in try Row.fetchAll(db, sql: "SELECT id, workspace_id, title, is_archived, created_at, updated_at, revision FROM conversations") { _ = try conversation(row) }
        for row in try Row.fetchAll(db, sql: "SELECT id, revision, name, provider_kind, base_url, credential_reference, credential_version, allows_loopback_http, is_enabled, connection_json FROM provider_connections") { _ = try providerConnection(row) }
        for row in try Row.fetchAll(db, sql: "SELECT id, revision, connection_id, connection_revision, model_id, context_window, text_capability, tool_capability, probe_observation_json, is_enabled, extraction_capability, protocol_mode, model_json FROM model_descriptors") { _ = try modelDescriptor(row) }
        for row in try Row.fetchAll(db, sql: "SELECT id, revision, name, model_descriptor_id, max_output_tokens, requests_usage, route_json FROM model_routes") { _ = try modelRoute(row) }
        for row in try Row.fetchAll(db, sql: "SELECT id, scope_key, purpose, route_id, revision, binding_json FROM route_bindings") {
            let binding = try routeBinding(row)
            try validateRouteBinding(binding)
            try validateRouteScope(binding.scope, in: db)
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, conversation_id, trigger_message_id, retry_of_execution_id, status, route_json, usage_input, usage_output, error_json, created_at, updated_at, body_purged_at FROM executions") { _ = try execution(row) }
        for row in try Row.fetchAll(db, sql: "SELECT id, conversation_id, execution_id, sequence, role, status, text, body_purged_at, created_at FROM messages") { _ = try message(row) }
        for row in try Row.fetchAll(db, sql: "SELECT execution_id, text, body_purged_at, updated_at FROM assistant_drafts") {
            _ = try executionIDValue(row["execution_id"] as String)
            if row["body_purged_at"] as Double? != nil {
                guard (row["text"] as String).isEmpty,
                      try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE id = ? AND body_purged_at IS NOT NULL", arguments: [row["execution_id"] as String]) != nil else { throw MiraError(.storage, "The database purged draft marker is invalid.") }
            }
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, execution_id, step_id, step_index, attempt_index, request_json, status, output_json, usage_input, usage_output, error_json, body_purged_at, created_at, completed_at FROM model_attempts") {
                let attempt = try modelAttempt(row)
                if let request = attempt.request {
                    guard request.executionID == attempt.executionID,
                          request.requestID == attempt.id,
                          attempt.bodyPurgedAt == nil else { throw MiraError(.storage, "The database audit request identity is invalid.") }
                } else {
                    guard attempt.bodyPurgedAt != nil, attempt.output == nil, attempt.error == nil else { throw MiraError(.storage, "The database purged attempt marker is invalid.") }
                }
                guard !(attempt.status == .prepared && attempt.output != nil),
                      !(attempt.status == .prepared && attempt.completedAt != nil) else { throw MiraError(.storage, "The database audit request identity is invalid.") }
                let rows = try Row.fetchAll(db, sql: "SELECT id, attempt_id, model_order, provider_call_id, tool_name, arguments_json, status, result_json, body_purged_at, dispatched_at, completed_at FROM tool_invocations WHERE attempt_id = ? ORDER BY model_order, rowid", arguments: [attempt.id.uuidString.lowercased()])
                let storedInvocations = try rows.map { try toolInvocation($0) }
                let expectedCalls = attempt.output?.toolCalls ?? []
                guard attempt.bodyPurgedAt != nil || storedInvocations.count == expectedCalls.count,
                      attempt.bodyPurgedAt != nil ||
                      storedInvocations.enumerated().allSatisfy({ index, invocation in
                          invocation.attemptID == attempt.id && invocation.modelOrder == index && invocation.call == expectedCalls[index]
                      }) else { throw MiraError(.storage, "The database model call does not match the tool audit.") }
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, attempt_id, model_order, provider_call_id, tool_name, arguments_json, status, result_json, body_purged_at, dispatched_at, completed_at FROM tool_invocations") {
                let invocation = try toolInvocation(row)
                let storedAttemptID = try uuid(row["attempt_id"] as String)
                let status = row["status"] as String
                let dispatched = row["dispatched_at"] as Double?
                let validDispatchState = (status == "pending" || status == "invalidArguments" || status == "notFound" || status == "cancelledBeforeDispatch") ? dispatched == nil :
                    (status == "dispatched" || status == "succeeded" || status == "cancelled" || status == "interrupted") ? dispatched != nil :
                    (status == "denied" || status == "timedOut" || status == "failed" || status == "outputLimit")
                guard invocation.attemptID == storedAttemptID, validDispatchState else { throw MiraError(.storage, "The database tool call association is invalid.") }
        }
        try validateMemoryContents(in: db)
        try validateKnowledgeContents(in: db)
        try Self.validateMemoryExtractionContents(in: db)
        // Ensure the structural constraints that are not represented by a
        // Codable payload also hold for hand-edited files.
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM execution_steps WHERE sequence < 0 OR state NOT IN ('running','waitingForTool','completed','failed','interrupted') LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM execution_steps WHERE sequence = 0 LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM execution_steps WHERE (state IN ('running','waitingForTool') AND completed_at IS NOT NULL) OR (state IN ('completed','failed','interrupted') AND completed_at IS NULL) LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM execution_steps WHERE body_purged_at IS NOT NULL AND (output_json IS NOT NULL OR error_json IS NOT NULL) LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM model_attempts WHERE (request_json IS NULL AND body_purged_at IS NULL) OR (body_purged_at IS NOT NULL AND (request_json IS NOT NULL OR output_json IS NOT NULL OR error_json IS NOT NULL)) OR step_index < 0 OR attempt_index <= 0 LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM model_attempts ma JOIN executions e ON e.id = ma.execution_id WHERE (e.body_purged_at IS NOT NULL AND ma.body_purged_at IS NULL) OR (ma.body_purged_at IS NOT NULL AND e.body_purged_at IS NULL) LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM tool_invocations ti JOIN executions e ON e.id = ti.execution_id LEFT JOIN model_attempts ma ON ma.id = ti.attempt_id WHERE (e.body_purged_at IS NOT NULL AND ti.body_purged_at IS NULL) OR (ma.body_purged_at IS NOT NULL AND ti.body_purged_at IS NULL) OR (ti.body_purged_at IS NOT NULL AND (ti.arguments_json IS NOT NULL OR ti.result_json IS NOT NULL)) LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM execution_steps s JOIN executions e ON e.id = s.execution_id WHERE e.body_purged_at IS NOT NULL AND s.body_purged_at IS NULL LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM messages m JOIN executions e ON e.id = m.execution_id WHERE e.body_purged_at IS NOT NULL AND m.role = 'assistant' AND (m.body_purged_at IS NULL OR m.text != '') LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM assistant_drafts d JOIN executions e ON e.id = d.execution_id WHERE e.body_purged_at IS NOT NULL AND (d.body_purged_at IS NULL OR d.text != '') LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM tool_invocations WHERE provider_call_id = '' OR tool_name = '' OR model_order < 0 LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE body_purged_at IS NOT NULL AND text != '' LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM assistant_drafts WHERE body_purged_at IS NOT NULL AND text != '' LIMIT 1") == nil,
              try Int.fetchOne(db, sql: "SELECT 1 FROM executions WHERE body_purged_at IS NOT NULL AND error_json IS NOT NULL LIMIT 1") == nil else {
            throw MiraError(.storage, "The database audit contents are invalid.")
        }
    }
}

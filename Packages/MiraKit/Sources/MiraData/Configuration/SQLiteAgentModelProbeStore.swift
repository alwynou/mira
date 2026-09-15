import Foundation
import GRDB
import CryptoKit
import MiraCore

/// Persists only capability attestations. It is deliberately separate from
/// `AgentModelSettingsStore` so probe writes do not add defaults to settings
/// mocks or make discovery look like verification.
public final class SQLiteAgentModelProbeStore: AgentModelProbeStore, @unchecked Sendable {
    private let database: DatabaseQueue
    private let libraryID: UUID

    public init(database: DatabaseQueue, libraryID: UUID) throws {
        self.database = database
        self.libraryID = libraryID
        try database.read { db in try SQLiteLibraryAuthority.validateInitialized(in: db, libraryID: libraryID) }
    }

    public func candidate(routeID: RouteID, authorization: AgentLibraryAuthorization) async throws
        -> AgentModelRouteCandidate
    {
        guard authorization.libraryID == libraryID else {
            throw MiraError(.unauthorized, "The capability probe authorization belongs to another library.")
        }
        do {
            return try await database.read { db in
                guard try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: libraryID) == authorization
                else {
                    throw MiraError(.unauthorized, "The capability probe authorization is stale.")
                }
                return try Self.readCandidate(routeID: routeID, in: db)
            }
        } catch let error as MiraError { throw error } catch {
            throw MiraError(.storage, "The model route candidate could not be read.")
        }
    }

    public func save(
        _ observation: AgentModelProbeObservation,
        authorization: AgentLibraryAuthorization
    ) async throws {
        try observation.validate()
        guard authorization.libraryID == libraryID else {
            throw MiraError(.unauthorized, "The capability probe authorization belongs to another library.")
        }
        do {
            try await database.write { db in
                guard try SQLiteLibraryAuthority.availableAuthorization(in: db, libraryID: libraryID) == authorization
                else {
                    throw MiraError(.unauthorized, "The capability probe authorization is stale.")
                }
                let current = try Self.readCandidate(routeID: observation.candidate.preset.id, in: db)
                guard current == observation.candidate else {
                    throw MiraError(.conflict, "The model route changed while the capability probe was running.")
                }
                let model = current.model

                guard model.revision < Int.max else {
                    throw MiraError(.conflict, "The configured model revision is exhausted.")
                }
                let spec = try current.invocation
                let fingerprintBytes = try SessionCodec.encode(current)
                let fingerprint = SHA256.hash(data: fingerprintBytes).map { String(format: "%02x", $0) }.joined()
                let fields = observation.probe.capabilityIDs.map { "observation.\($0)" }
                var facts = model.facts.filter {
                    !($0.source == .probe && $0.sourceID == observation.probe.id && $0.invocationID == spec.id && fields.contains($0.field))
                }
                for field in fields {
                    facts.append(.init(field: field, value: .string(observation.outcome.rawValue), source: .probe,
                                       sourceID: observation.probe.id, sourceRevision: String(observation.probe.revision),
                                       observedAt: observation.observedAt, invocationID: spec.id,
                                       configurationFingerprint: fingerprint))
                }
                let updated = AgentConfiguredModel(
                    id: model.id, revision: model.revision + 1, authorizationRevision: model.authorizationRevision,
                    reference: model.reference, displayName: model.displayName, isEnabled: model.isEnabled,
                    invocations: model.invocations, facts: facts)
                try updated.validate()
                let bytes = try SessionCodec.encode(updated)
                guard bytes.count <= 131_072 else {
                    throw MiraError(.outputLimit, "The model capability record is too large.")
                }
                try db.execute(
                    sql: "UPDATE settings_models SET revision = ?, json = ? WHERE id = ? AND revision = ?",
                    arguments: [updated.revision, bytes, model.id.rawValue.uuidString, model.revision])
                guard db.changesCount == 1 else {
                    throw MiraError(.conflict, "The model capability revision changed during the probe save.")
                }
            }
        } catch let error as MiraError { throw error } catch {
            throw MiraError(.storage, "The model capability probe could not be saved.")
        }
    }

    /// The caller holds one transaction. Check the stored byte count before materializing JSON.
    private static func boundedRow(table: String, key: String, in db: Database) throws -> Row? {
        guard
            let length = try Int.fetchOne(
                db, sql: "SELECT length(CAST(json AS BLOB)) FROM \(table) WHERE id = ?", arguments: [key])
        else {
            return nil
        }
        guard (1...131_072).contains(length) else {
            throw MiraError(.storage, "The model route candidate is invalid.")
        }
        return try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = ?", arguments: [key])
    }

    private static func readCandidate(routeID: RouteID, in db: Database) throws -> AgentModelRouteCandidate {
        let routeKey = routeID.rawValue.uuidString
        guard let presetRow = try boundedRow(table: "settings_presets", key: routeKey, in: db),
            let presetData: Data = presetRow["json"],
            let preset = try? SessionCodec.decode(AgentRoutePreset.self, from: presetData),
            (presetRow["id"] as String?) == routeKey,
            (presetRow["revision"] as Int?) == preset.revision,
            (presetRow["model_id"] as String?) == preset.modelDescriptorID.rawValue.uuidString,
            preset.id.rawValue.uuidString == routeKey,
            let modelRow = try boundedRow(
                table: "settings_models", key: preset.modelDescriptorID.rawValue.uuidString, in: db),
            let modelData: Data = modelRow["json"],
            let model = try? SessionCodec.decode(AgentConfiguredModel.self, from: modelData),
            (modelRow["id"] as String?) == model.id.rawValue.uuidString,
            (modelRow["revision"] as Int?) == model.revision,
            (modelRow["connection_id"] as String?) == model.connectionID.rawValue.uuidString,
            (modelRow["authorization_revision"] as Int?) == model.authorizationRevision,
            (modelRow["model_key"] as String?) == model.modelID,
            let connectionRow = try boundedRow(
                table: "settings_connections", key: model.connectionID.rawValue.uuidString, in: db),
            let connectionData: Data = connectionRow["json"],
            let connection = try? SessionCodec.decode(AgentConfiguredConnection.self, from: connectionData),
            (connectionRow["id"] as String?) == connection.id.rawValue.uuidString,
            (connectionRow["revision"] as Int?) == connection.revision,
            (connectionRow["config_revision"] as Int?) == connection.configurationRevision
        else {
            throw MiraError(.notFound, "The selected model route is unavailable.")
        }
        do {
            try connection.validate()
            try model.validate()
            try preset.validate()
        } catch {
            throw MiraError(.storage, "The model route candidate is invalid.")
        }
        guard model.connectionID == connection.id,
            preset.modelDescriptorID == model.id,
            connection.isEnabled,
            model.isEnabled,
            let window = try AgentModelRouteCandidate(connection: connection, model: model, preset: preset).invocation.contextWindow,
            preset.maximumOutputTokens < window
        else {
            throw MiraError(.conflict, "The selected model route is unavailable or stale.")
        }
        return AgentModelRouteCandidate(connection: connection, model: model, preset: preset)
    }
}

import Foundation

/// Local provenance accompanying a canonical request; never serialized into a provider's wire body.
public struct RequestContextInfo: Codable, Sendable, Equatable {
    public struct Reference: Codable, Sendable, Equatable {
        public var kind: String
        public var id: String
        public var revision: Int?
        public init(kind: String, id: String, revision: Int? = nil) { self.kind = kind; self.id = id; self.revision = revision }
    }
    public var references: [Reference]
    public var omissions: [String]
    public var routeRevision: Int
    public var estimatedInputBytes: Int?
    public init(references: [Reference], omissions: [String], routeRevision: Int) {
        self.references = references; self.omissions = omissions; self.routeRevision = routeRevision
    }
}

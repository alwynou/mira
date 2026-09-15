import Foundation

public protocol CredentialReader: Sendable {
    /// Read at dispatch time. Implementations must enforce reference/version identity.
    func read(reference: String, version: Int) throws -> String
}

import Foundation
import MiraCore
import Observation

/// New-conversation UX preferences are local to this Mac and never authorize execution.
/// The concrete selected model is validated and committed through the session journal.
@MainActor @Observable
final class ConversationModelPreferences {
    static let shared = ConversationModelPreferences(defaults: .standard)
    private var values: [String: String]
    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "conversation.model.preferences"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        values = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }
    func followsLastSelection(libraryID: UUID, scope: AgentRouteScope) -> Bool? {
        values[policyKey(libraryID, scope)].map { $0 == "followLastSelection" }
    }
    func setFollowing(_ following: Bool?, libraryID: UUID, scope: AgentRouteScope) {
        values[policyKey(libraryID, scope)] = following.map { $0 ? "followLastSelection" : "fixed" }
        defaults.set(values, forKey: Self.storageKey)
    }
    func lastRoute(libraryID: UUID) -> RouteID? {
        values[libraryID.uuidString + ":lastRoute"].flatMap(UUID.init(uuidString:)).map { RouteID($0) }
    }
    func remember(_ routeID: RouteID, libraryID: UUID) {
        values[libraryID.uuidString + ":lastRoute"] = routeID.rawValue.uuidString
        defaults.set(values, forKey: Self.storageKey)
    }
    private func policyKey(_ libraryID: UUID, _ scope: AgentRouteScope) -> String {
        libraryID.uuidString + ":" + scope.key
    }
}

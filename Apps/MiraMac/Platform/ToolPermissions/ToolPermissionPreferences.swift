import Foundation
import MiraCore
import Observation

enum ToolPermissionLevel: String, CaseIterable, Sendable {
    case ask, automatic, fullAccess
}

enum ToolPermissionScope: Equatable, Sendable {
    case defaults
    case conversation(libraryID: UUID, conversationID: ConversationID)

    fileprivate var storageKey: String? {
        guard case .conversation(let libraryID, let conversationID) = self else { return nil }
        return "\(libraryID.uuidString)/\(conversationID.rawValue.uuidString)"
    }
}

/// Host-owned defaults and conversation consent, independent of journal content.
@MainActor @Observable
final class ToolPermissionPreferences {
    static let storageKey = "tools.permissionLevel"
    static let conversationsKey = "tools.conversationPermissionLevels"
    static let shared: ToolPermissionPreferences = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            return .init(defaults: UserDefaults(suiteName: "com.alwynou.mira.demo.tool-permissions")!)
        }
        #endif
        return .init(defaults: .standard)
    }()

    private(set) var level: ToolPermissionLevel
    private var conversationLevels: [String: String]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        level = defaults.string(forKey: Self.storageKey).flatMap(ToolPermissionLevel.init(rawValue:)) ?? .ask
        conversationLevels = defaults.dictionary(forKey: Self.conversationsKey) as? [String: String] ?? [:]
    }

    func level(for scope: ToolPermissionScope) -> ToolPermissionLevel {
        guard let key = scope.storageKey else { return level }
        // A conversation without saved consent never inherits a later global elevation.
        return conversationLevels[key].flatMap(ToolPermissionLevel.init(rawValue:)) ?? .ask
    }

    func select(_ level: ToolPermissionLevel, for scope: ToolPermissionScope = .defaults) {
        if let key = scope.storageKey {
            conversationLevels[key] = level.rawValue
            defaults.set(conversationLevels, forKey: Self.conversationsKey)
        } else {
            defaults.set(level.rawValue, forKey: Self.storageKey)
            self.level = level
        }
    }

    /// Capture before admission can dispatch tools; retries retain the same conversation choice.
    func captureDefault(for scope: ToolPermissionScope) {
        guard let key = scope.storageKey, conversationLevels[key] == nil else { return }
        select(level, for: scope)
    }

    func discardUncommittedConversation(_ scope: ToolPermissionScope) {
        guard let key = scope.storageKey else { return }
        conversationLevels.removeValue(forKey: key)
        defaults.set(conversationLevels, forKey: Self.conversationsKey)
    }
}

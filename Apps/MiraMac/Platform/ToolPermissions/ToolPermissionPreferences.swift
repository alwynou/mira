import Foundation
import Observation

enum ToolPermissionLevel: String, CaseIterable, Sendable {
    case ask, automatic, fullAccess
}

/// Host-owned consent, shared by every conversation and independent of library data.
@MainActor @Observable
final class ToolPermissionPreferences {
    static let storageKey = "tools.permissionLevel"
    static let shared: ToolPermissionPreferences = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            return .init(defaults: UserDefaults(suiteName: "com.alwynou.mira.demo.tool-permissions")!)
        }
        #endif
        return .init(defaults: .standard)
    }()

    private(set) var level: ToolPermissionLevel
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        level = defaults.string(forKey: Self.storageKey).flatMap(ToolPermissionLevel.init(rawValue:)) ?? .ask
    }

    func select(_ level: ToolPermissionLevel) {
        defaults.set(level.rawValue, forKey: Self.storageKey)
        self.level = level
    }
}

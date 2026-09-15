import Foundation
import MiraCore
import UserNotifications

protocol MacNotificationRetirementPort: Sendable {
    func pendingIDs() async throws -> [String]
    func deliveredIDs() async throws -> [String]
    func removeIDs(_ identifiers: [String]) async throws
}

/// Removes only the system notifications owned by one exact Mira library namespace.
actor MacNotificationRetirement {
    private let port: any MacNotificationRetirementPort

    init() {
        port = SystemMacNotificationRetirementPort()
    }

    init(port: any MacNotificationRetirementPort) {
        self.port = port
    }

    static func retire(namespace: String) async throws {
        try await MacNotificationRetirement().retire(namespace: namespace)
    }

    func retire(namespace: String) async throws {
        let prefix = "mira.\(namespace)."
        let pending = try await port.pendingIDs()
        let delivered = try await port.deliveredIDs()
        let owned = Set((pending + delivered).filter { $0.hasPrefix(prefix) })
        guard !owned.isEmpty else { return }

        try await port.removeIDs(Array(owned).sorted())
        let remainingPending = try await port.pendingIDs()
        let remainingDelivered = try await port.deliveredIDs()
        let remaining = (remainingPending + remainingDelivered).filter { $0.hasPrefix(prefix) }
        guard remaining.isEmpty else {
            throw MiraError(
                .storage,
                "Some notifications for this library remain after retirement. Retry notification cleanup.")
        }
    }
}

private actor SystemMacNotificationRetirementPort: MacNotificationRetirementPort {
    private let center = UNUserNotificationCenter.current()

    func pendingIDs() async throws -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func deliveredIDs() async throws -> [String] {
        await center.deliveredNotifications().map(\.request.identifier)
    }

    func removeIDs(_ identifiers: [String]) async throws {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

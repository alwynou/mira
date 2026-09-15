import Foundation
import MiraCore
import Testing

@Suite("macOS notification retirement", .timeLimit(.minutes(1)))
struct MacNotificationRetirementTests {
    @Test
    func retiresPendingAndDeliveredIDsForOnlyTheExactNamespace() async throws {
        let namespace = "library-one"
        let pending = [
            "mira.\(namespace).pending",
            "mira.\(namespace)-other.delivered",
            "mira.other.pending",
        ]
        let delivered = [
            "mira.\(namespace).delivered",
            "mira.\(namespace).duplicate",
            "mira.\(namespace).pending",
            "mira.\(namespace)",
        ]
        let fixture = NotificationRetirementFixture(pending: pending, delivered: delivered)
        let retirement = MacNotificationRetirement(port: fixture)

        try await retirement.retire(namespace: namespace)

        #expect(
            await fixture.removedIDs == [
                "mira.\(namespace).delivered",
                "mira.\(namespace).duplicate",
                "mira.\(namespace).pending",
            ])
        #expect(
            try await fixture.pendingIDs() == [
                "mira.\(namespace)-other.delivered",
                "mira.other.pending",
            ])
        #expect(try await fixture.deliveredIDs() == ["mira.\(namespace)"])
    }

    @Test
    func repeatedRetirementIsIdempotent() async throws {
        let namespace = "library-repeat"
        let fixture = NotificationRetirementFixture(
            pending: ["mira.\(namespace).pending"], delivered: [])
        let retirement = MacNotificationRetirement(port: fixture)

        try await retirement.retire(namespace: namespace)
        try await retirement.retire(namespace: namespace)

        #expect(await fixture.removeCalls.count == 1)
        #expect(try await fixture.pendingIDs().isEmpty)
    }

    @Test
    func removalFailurePropagatesWithoutRemovingOtherNamespaces() async throws {
        let namespace = "library-failure"
        let other = "mira.other.keep"
        let fixture = NotificationRetirementFixture(
            pending: ["mira.\(namespace).pending", other], delivered: [], failRemoval: true)
        let retirement = MacNotificationRetirement(port: fixture)

        await #expect(throws: MiraError.self) {
            try await retirement.retire(namespace: namespace)
        }
        #expect(try await fixture.pendingIDs() == ["mira.\(namespace).pending", other])
        #expect(await fixture.removedIDs == ["mira.\(namespace).pending"])
    }

    @Test
    func remainingMatchingIDsProduceARetryableError() async throws {
        let namespace = "library-remains"
        let retained = "mira.\(namespace).retained"
        let fixture = NotificationRetirementFixture(
            pending: ["mira.\(namespace).removed", retained], delivered: [], retainedIDs: [retained])
        let retirement = MacNotificationRetirement(port: fixture)

        await #expect(throws: MiraError.self) {
            try await retirement.retire(namespace: namespace)
        }
        #expect(try await fixture.pendingIDs() == [retained])
    }
}

private actor NotificationRetirementFixture: MacNotificationRetirementPort {
    private var pending: Set<String>
    private var delivered: Set<String>
    private let retainedIDs: Set<String>
    private let failRemoval: Bool
    private(set) var removedIDs: [String] = []
    private(set) var removeCalls: [[String]] = []

    init(
        pending: [String], delivered: [String],
        failRemoval: Bool = false, retainedIDs: Set<String> = []
    ) {
        self.pending = Set(pending)
        self.delivered = Set(delivered)
        self.failRemoval = failRemoval
        self.retainedIDs = retainedIDs
    }

    func pendingIDs() async throws -> [String] { pending.sorted() }
    func deliveredIDs() async throws -> [String] { delivered.sorted() }

    func removeIDs(_ identifiers: [String]) async throws {
        removeCalls.append(identifiers)
        removedIDs.append(contentsOf: identifiers)
        if failRemoval {
            throw MiraError(.storage, "Synthetic notification removal failed.")
        }
        for identifier in identifiers where !retainedIDs.contains(identifier) {
            pending.remove(identifier)
            delivered.remove(identifier)
        }
    }
}

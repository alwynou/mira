import Foundation
import MiraCore
import MiraData
import MiraProviders
import Observation

@MainActor @Observable
final class AppContainer {
    let application: MiraApplication?
    let startupError: MiraError?
    let directory: URL
    let isDemo: Bool
    let credentials = KeychainCredentials()
    let memoryApprovals = MemoryApprovalCoordinator()
    private let provider: any ModelProviderPort
    private let credentialCleanup: CredentialCleanup
    var maintenanceMessage: String?
    private var didSeedDemo = false

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        isDemo = arguments.contains("--demo")
        #else
        isDemo = false
        #endif
        var argumentError: MiraError?
        if let index = arguments.firstIndex(of: "--data-directory") {
            if arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") {
                directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            } else {
                directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-Invalid-Launch")
                argumentError = .init(.configuration, "--data-directory requires an absolute path. The default library was not opened.")
            }
        } else if isDemo {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-Demo-\(UUID().uuidString)", isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mira", isDirectory: true)
        }
        credentialCleanup = CredentialCleanup(directory: directory)
        #if DEBUG
        provider = isDemo ? DemoProvider(stress: arguments.contains("--demo-stress")) : HTTPModelProvider(credentials: credentials)
        #else
        provider = HTTPModelProvider(credentials: credentials)
        #endif
        if let argumentError {
            application = nil; startupError = argumentError
            return
        }
        do {
            let store = try SQLiteMiraStore(directory: directory)
            let memoryTools = MemoryTools.readOnly(store: store) + [MemoryRememberTool(store: store, approvals: memoryApprovals)] + KnowledgeTools.readOnly(store: store)
            application = try MiraApplication(store: store, provider: provider, tools: ToolRegistry(memoryTools), memoryApprovals: memoryApprovals)
            startupError = nil
            if let application { Task { await application.startBackgroundWork() } }
            if !isDemo {
                do { maintenanceMessage = try credentialCleanup.reconcile(retaining: store.modelConfiguration().connections, credentials: credentials) }
                catch { maintenanceMessage = MiraError.safe(error).message }
            }
        } catch {
            application = nil; startupError = MiraError.safe(error)
        }
    }

    func discoverModels(for connection: ProviderConnection) async throws -> [DiscoveredModel] {
        guard !isDemo, let application else { throw MiraError(.configuration, "Model discovery is unavailable in demo mode or without an open library.") }
        let before = try await application.library().configuration
        guard before.connections.first(where: { $0.id == connection.id }) == connection, connection.isEnabled else {
            throw MiraError(.configuration, "Activate the current provider configuration before fetching models.")
        }
        let models = try await HTTPModelDiscovery(credentials: credentials).models(for: connection)
        try Task.checkCancellation()
        let after = try await application.library().configuration
        guard after.connections.first(where: { $0.id == connection.id }) == connection else {
            throw MiraError(.conflict, "The provider changed while fetching models. Fetch the list again.")
        }
        return models
    }

    func probe(_ route: ResolvedModelRouteSnapshot, kind: CapabilityProbeKind) async -> ProbeObservation {
        await ProviderCapabilityProbe(provider: provider).run(route: route, kind: kind)
    }

    func saveProbe(_ observation: ProbeObservation, for route: ResolvedModelRouteSnapshot) async throws {
        guard let application else { throw MiraError(.storage, "The library is not open.") }
        try await application.saveProbe(observation, for: route)
    }

    func seedDemo() async throws {
        guard isDemo, !didSeedDemo, let application else { return }
        didSeedDemo = true
        let library = try await application.library()
        if library.configuration.connections.isEmpty {
            let connection = ProviderConnection(name: "Local Demo", providerKind: .openAICompatible, baseURL: "https://demo.invalid/v1", credentialReference: "demo")
            let model = ModelDescriptor(connectionID: connection.id, modelID: "mira-demo", contextWindow: 32_768, textCapability: .declared)
            let route = ModelRoute(id: model.poolRouteID, name: "Local Demo", modelDescriptorID: model.id)
            try await application.saveConnection(connection, expectedRevision: nil)
            try await application.savePoolModel(model, route: route, expectedModelRevision: nil, expectedRouteRevision: nil)
            try await application.saveRouteBinding(.init(scope: .global, purpose: .conversation, routeID: route.id), expectedRevision: nil)
        }
    }

    /// Installs a new immutable credential version first; rolls it back if the DB commit fails.
    func saveConnection(_ route: ProviderConnection, previous: ProviderConnection?, secret: String) async throws {
        guard let application else { throw MiraError(.storage, "The library is not open.") }
        var updated = route
        let replacement = !secret.isEmpty
        if replacement {
            updated.credentialReference = UUID().uuidString
            updated.credentialVersion = (previous?.credentialVersion ?? 0) + 1
            // Write-ahead references let startup distinguish committed credentials from abandoned ones.
            try credentialCleanup.enqueue([updated] + (previous.map { [$0] } ?? []))
            do { try credentials.save(secret, reference: updated.credentialReference, version: updated.credentialVersion) }
            catch { await retryCredentialCleanup(); throw error }
        } else if previous == nil { throw MiraError(.credentialMissing, "A new connection requires an API key.") }
        do { try await application.saveConnection(updated, expectedRevision: previous?.revision) }
        catch {
            if replacement { await retryCredentialCleanup() }
            throw error
        }
        if replacement { await retryCredentialCleanup() }
    }

    func removeConnection(_ route: ProviderConnection) async throws {
        guard let application else { throw MiraError(.storage, "The library is not open.") }
        try credentialCleanup.enqueue([route])
        do { try await application.removeConnection(route.id) }
        catch { await retryCredentialCleanup(); throw error }
        await retryCredentialCleanup()
    }

    func retryCredentialCleanup() async {
        guard let application, !isDemo else { return }
        do {
            let routes = try await application.library().configuration.connections
            maintenanceMessage = try credentialCleanup.reconcile(retaining: routes, credentials: credentials)
        } catch { maintenanceMessage = MiraError.safe(error).message }
    }
}

#if DEBUG
/// Explicit --demo only, with a separate temporary library. Never a network failure fallback.
private struct DemoProvider: ModelProviderPort {
    var stress = false
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let answer = stress ? Self.stressAnswer : """
                    # Mira Local Demo

                    Hello, I am Mira. This reply is generated locally to verify streaming Markdown, cancellation, and recovery after restarting.

                    You sent:

                    > \(request.messages.last?.text ?? "")

                    ## Supported Content

                    - Headings, lists, and quotes
                    - **Emphasis**, `inline code`, and tables
                    - Clickable `http(s)` links

                    ```swift
                    let message = "Hello, Mira!"
                    print(message)
                    ```

                    | Capability | Status |
                    | --- | --- |
                    | Local streaming | Available |
                    | Network requests | Disabled |

                    [Learn about Swift](https://www.swift.org)

                    Connect your own model to start a real conversation. Memory and source retrieval will follow in later milestones.
                    """
                    if stress {
                        let thinking = "Reviewing the synthetic rendering fixture, its tables, lists, code, and final marker. "
                        for count in 1...20 {
                            try await Task.sleep(for: .milliseconds(25))
                            continuation.yield(.reasoning(.init(format: .openAIContent, text: String(repeating: thinking, count: count))))
                        }
                        continuation.yield(.reasoning(.init(format: .openAIContent, text: String(repeating: thinking, count: 20), isComplete: true)))
                    }
                    let characters = Array(answer)
                    let chunkSize = stress ? 24 : 1
                    for start in stride(from: 0, to: characters.count, by: chunkSize) {
                        try await Task.sleep(for: .milliseconds(stress ? 12 : 18))
                        continuation.yield(.textDelta(String(characters[start..<min(start + chunkSize, characters.count)])))
                    }
                    continuation.yield(.finished(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: CancellationError()) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Deterministic, network-free stress content enabled only by --demo --demo-stress.
    private static let stressAnswer: String = {
        var result = "# Rendering stress fixture\n\n"
        for index in 1...24 {
            result += """
            ## Section \(index)

            This synthetic paragraph verifies stable Markdown measurement during streaming, resizing, selection, and rapid scrolling. **Emphasis**, `inline code`, and [a link](https://www.swift.org) remain available.

            - First item with a longer explanation that wraps over several lines in a narrow window.
                - Nested item with **strong text** and a detail to read.
            - Second item with a short explanation.

            > A block quote with sufficient text to wrap onto another line and exercise the paragraph layout cache.

            ```swift
            let section = \(index)
            let values = (0..<8).map { $0 * section }
            print(values)
            ```

            | Column A | Column B | Column C | Column D |
            | --- | --- | --- | --- |
            | A long wrapping value for section \(index) | Another wrapping value | Small | Complete |
            | One | Two | Three | Four |

            Inline math: $a^2 + b^2 = c^2$.

            """ + "\n\n"
        }
        return result + "## End of rendering fixture\n\nThe final stream marker is visible.\n"
    }()

}
#endif

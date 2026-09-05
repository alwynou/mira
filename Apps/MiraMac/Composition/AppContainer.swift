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
        provider = isDemo ? DemoProvider() : HTTPModelProvider(credentials: credentials)
        #else
        provider = HTTPModelProvider(credentials: credentials)
        #endif
        if let argumentError {
            application = nil; startupError = argumentError
            return
        }
        do {
            let store = try SQLiteMiraStore(directory: directory)
            application = try MiraApplication(store: store, provider: provider)
            startupError = nil
            if !isDemo {
                do { maintenanceMessage = try credentialCleanup.reconcile(retaining: store.modelConfiguration().connections, credentials: credentials) }
                catch { maintenanceMessage = MiraError.safe(error).message }
            }
        } catch {
            application = nil; startupError = MiraError.safe(error)
        }
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
            let route = ModelRoute(name: "Local Demo", modelDescriptorID: model.id)
            try await application.saveConnection(connection, expectedRevision: nil)
            try await application.saveModel(model, expectedRevision: nil)
            try await application.saveRoute(route, expectedRevision: nil)
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
    func stream(request: CanonicalModelRequest, route: ResolvedModelRouteSnapshot) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let answer = """
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
                    for character in answer {
                        try await Task.sleep(for: .milliseconds(18))
                        continuation.yield(.textDelta(String(character)))
                    }
                    continuation.yield(.finished(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: CancellationError()) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif

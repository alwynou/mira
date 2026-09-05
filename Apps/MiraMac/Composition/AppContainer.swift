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
                argumentError = .init(.configuration, "--data-directory 需要绝对路径；未打开默认资料库。")
            }
        } else if isDemo {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-Demo-\(UUID().uuidString)", isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mira", isDirectory: true)
        }
        credentialCleanup = CredentialCleanup(directory: directory)
        if let argumentError {
            application = nil; startupError = argumentError
            return
        }
        do {
            let store = try SQLiteMiraStore(directory: directory)
            let provider: any ModelProviderPort
            #if DEBUG
            if isDemo { provider = DemoProvider() }
            else { provider = HTTPModelProvider(credentials: credentials) }
            #else
            provider = HTTPModelProvider(credentials: credentials)
            #endif
            application = try MiraApplication(store: store, provider: provider)
            startupError = nil
            if !isDemo {
                do { maintenanceMessage = try credentialCleanup.reconcile(retaining: store.routes(), credentials: credentials) }
                catch { maintenanceMessage = MiraError.safe(error).message }
            }
        } catch {
            application = nil; startupError = MiraError.safe(error)
        }
    }

    func seedDemo() async throws {
        guard isDemo, !didSeedDemo, let application else { return }
        didSeedDemo = true
        let library = try await application.library()
        if library.routes.isEmpty {
            try await application.saveRoute(.init(name: "本机演示", providerKind: .openAICompatible, baseURL: "https://demo.invalid/v1", modelID: "mira-demo", credentialReference: "demo", contextWindow: 32_768), expectedRevision: nil)
        }
    }

    /// Installs a new immutable credential version first; rolls it back if the DB commit fails.
    func saveRoute(_ route: ModelRoute, previous: ModelRoute?, secret: String) async throws {
        guard let application else { throw MiraError(.storage, "资料库未打开。") }
        var updated = route
        let replacement = !secret.isEmpty
        if replacement {
            updated.credentialReference = UUID().uuidString
            updated.credentialVersion = (previous?.credentialVersion ?? 0) + 1
            // Write-ahead references let startup distinguish committed credentials from abandoned ones.
            try credentialCleanup.enqueue([updated] + (previous.map { [$0] } ?? []))
            do { try credentials.save(secret, reference: updated.credentialReference, version: updated.credentialVersion) }
            catch { await retryCredentialCleanup(); throw error }
        } else if previous == nil { throw MiraError(.credentialMissing, "新连接需要 API Key。") }
        do { try await application.saveRoute(updated, expectedRevision: previous?.revision) }
        catch {
            if replacement { await retryCredentialCleanup() }
            throw error
        }
        if replacement { await retryCredentialCleanup() }
    }

    func removeRoute(_ route: ModelRoute) async throws {
        guard let application else { return }
        try credentialCleanup.enqueue([route])
        do { try await application.removeRoute(route.id) }
        catch { await retryCredentialCleanup(); throw error }
        await retryCredentialCleanup()
    }

    func retryCredentialCleanup() async {
        guard let application, !isDemo else { return }
        do {
            let routes = try await application.library().routes
            maintenanceMessage = try credentialCleanup.reconcile(retaining: routes, credentials: credentials)
        } catch { maintenanceMessage = "连接状态已保留。" + MiraError.safe(error).message }
    }
}

#if DEBUG
/// Explicit --demo only, with a separate temporary library. Never a network failure fallback.
private struct DemoProvider: ModelProviderPort {
    func stream(request: CanonicalModelRequest, route: ModelRoute) -> AsyncThrowingStream<CanonicalStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let answer = "你好，我是 Mira。\n\n这是一段仅在本机生成的演示回复，用来检查流式显示、停止生成与重启恢复。\n\n你刚才发送了：\n\(request.messages.last?.text ?? "")\n\n连接自己的模型后，就可以开始真实对话。记忆、资料检索与工具执行将在后续里程碑加入。"
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

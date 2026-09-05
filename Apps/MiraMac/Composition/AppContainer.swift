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
                argumentError = .init(.configuration, "--data-directory 需要绝对路径；未打开默认资料库。")
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
                do { maintenanceMessage = try credentialCleanup.reconcile(retaining: store.routes(), credentials: credentials) }
                catch { maintenanceMessage = MiraError.safe(error).message }
            }
        } catch {
            application = nil; startupError = MiraError.safe(error)
        }
    }

    func probe(_ route: ModelRoute, kind: CapabilityProbeKind) async -> ProbeObservation {
        await ProviderCapabilityProbe(provider: provider).run(route: route, kind: kind)
    }

    func saveProbe(_ observation: ProbeObservation, for route: ModelRoute) async throws {
        try Task.checkCancellation()
        guard observation.state == .verified || observation.state == .failed else { return }
        guard let application else { return }
        let current = try await application.library(includeArchived: true).routes.first { $0.id == route.id }
        guard let current, current == route else {
            throw MiraError(.conflict, "连接配置已变化，检测结果未覆盖新的编辑内容。")
        }
        var updated = current
        if observation.type == .text { updated.textCapability = observation.state }
        else { updated.toolCapability = observation.state }
        updated.probeObservation = observation
        updated.revision += 1
        try Task.checkCancellation()
        try await application.saveRoute(updated, expectedRevision: current.revision)
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
                    let answer = """
                    # Mira 本机演示

                    你好，我是 Mira。这段回复由本机生成，用来检查流式 Markdown、停止生成与重启恢复。

                    你刚才发送了：

                    > \(request.messages.last?.text ?? "")

                    ## 支持的内容

                    - 标题、列表与引用
                    - **强调**、`行内代码` 与表格
                    - 仅允许点击 `http(s)` 链接

                    ```swift
                    let message = "你好，Mira！"
                    print(message)
                    ```

                    | 能力 | 状态 |
                    | --- | --- |
                    | 本机流式输出 | 可用 |
                    | 网络请求 | 未启用 |

                    [了解 Swift](https://www.swift.org)

                    连接自己的模型后，就可以开始真实对话。记忆、资料检索与工具执行将在后续里程碑加入。
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

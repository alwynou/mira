#if DEBUG
    import Foundation
    import MiraCore
    import MiraData
    import Testing

    @Suite("macOS benchmark module", .timeLimit(.minutes(1)))
    struct MacBenchmarkModuleTests {
        @Test func seedUsesTheApplicationRuntimeAndLeavesCredentialsUntouched() async throws {
            try await withDirectory { directory in
                let credentials = CompositionCredentials()
                let library = try await MacLibrary.open(embeddings: OfflineMemoryEmbedding(),
                    directory: directory,
                    notifications: CompositionNotifications(),
                    credentials: credentials,
                    modules: { [MacBenchmarkModule(registry: $0)] })
                do {
                    let group = try await library.workloads()
                    let ids = try await MacBenchmarkModule.seed(in: group, turns: [2, 3])
                    #expect(ids == MacBenchmarkModule.sessionIDs)
                    let repeatedIDs = try await MacBenchmarkModule.seed(in: group, turns: [2, 3])
                    #expect(repeatedIDs == ids)
                    for (index, id) in ids.enumerated() {
                        let page = try await group.queries.messagePage(sessionID: id, limit: 128)
                        #expect(page.session?.title.text == "Synthetic Switch \(index + 1)")
                        #expect(page.messages.filter { $0.summary.role == .user }.count == [2, 3][index])
                        #expect(page.messages.filter { $0.summary.role == .assistant }.count == [2, 3][index])
                        let answer = try #require(page.messages.first { $0.summary.role == .assistant })
                        if case .available(let body) = answer.body {
                            #expect(body.contains("Mira benchmark fixture"))
                        } else {
                            Issue.record("The local benchmark reply body was not available.")
                        }
                    }
                    #expect(credentials.enteredOperations.isEmpty)
                    #expect(await library.close().isSettled)
                } catch {
                    _ = await library.close()
                    throw error
                }
            }
        }
    }
#endif

#if DEBUG
import MiraCore
import Testing

@Suite("macOS local demo module")
struct MacDemoModuleTests {
    @Test func demoIdentityUsesAnExplicitInvocationAdapter() {
        #expect(MacDemoModule.adapterIdentity.id == "mac.demo")
        #expect(!MacDemoModule.modelID.isEmpty)
    }
}
#endif

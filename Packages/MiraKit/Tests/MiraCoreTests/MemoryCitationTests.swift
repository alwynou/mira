import Foundation
import MiraCore
import Testing

struct MemoryCitationTests {
    @Test func completeReferencesAreBoundedDistinctAndStrict() throws {
        let reference = MemoryCitationReference(memoryID: MemoryID(), revision: 12)
        let text = "Fact [\(reference.id)] repeated [\(reference.id)] incomplete [memory:\(UUID())@3"
        #expect(MemoryCitationReference.references(in: text) == [reference])
        for invalid in ["memory:\(UUID())@0", "memory:\(UUID())@-1", "memory:\(UUID())@01", "memory:\(UUID())@2@3", "https://example.invalid/memory:\(UUID())@1", "memory:no-id@1"] {
            #expect(MemoryCitationReference(rawValue: invalid) == nil)
        }
        let many = (0..<40).map { _ in "[\(MemoryCitationReference(memoryID: MemoryID(), revision: 1).id)]" }.joined(separator: " ")
        #expect(MemoryCitationReference.references(in: many).count == 32)
    }
}

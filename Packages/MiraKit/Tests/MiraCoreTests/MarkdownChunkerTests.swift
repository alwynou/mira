import Foundation
import Testing
@testable import MiraCore

struct MarkdownChunkerTests {
    @Test func emptyAndBOMOnlySourcesHaveNoSlices() throws {
        #expect(try MarkdownChunker.chunk(Data()).isEmpty)
        #expect(try MarkdownChunker.chunk(Data([0xEF, 0xBB, 0xBF])).isEmpty)
        #expect(MarkdownChunker.parserVersion == "markdown-lines-v1")
        #expect(MarkdownChunker.maxFileBytes == 10 * 1024 * 1024)
    }

    @Test func preservesBOMOffsetsCRLFUnicodeAndHeadingPath() throws {
        let chinese = "中文路径与Swift类型" // i18n-fixture: Preserve CJK and mixed code/path text for parser byte offsets.
        let source = "# Guide\r\n\(chinese)\r\n## Details\r\nvalue = \"é\"\r\n"
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(source.utf8)
        let slices = try MarkdownChunker.chunk(data)

        #expect(slices.count == 1)
        let slice = try #require(slices.first)
        #expect(slice.sequence == 0)
        #expect(slice.startLine == 1)
        #expect(slice.endLine == 4)
        #expect(slice.startUTF8Offset == 3)
        #expect(slice.endUTF8Offset == data.count)
        // The slice starts at the document root, so its path is the active top-level heading.
        #expect(slice.headingPath == ["Guide"])
        #expect(slice.text == source)
        #expect(slice.text.utf8.count == data.count - 3)
    }

    @Test func headingPathUpdatesWhenAChunkStartsAtAChildHeading() throws {
        let source = "# Guide\n" + String(repeating: "body ", count: 1_100) + "\n## Details\nvalue\n"
        let slices = try MarkdownChunker.chunk(Data(source.utf8))
        let childSlice = try #require(slices.first(where: { $0.text.hasPrefix("## Details") }))
        #expect(childSlice.headingPath == ["Guide", "Details"])
        #expect(slices.map(\.text).joined() == source)
    }

    @Test func tracksSetextHeadingsAndIgnoresHeadingSyntaxInsideFences() throws {
        let source = "Title\n=====\ntext\n```swift\n# Inside code\n```\n## Outside\nbody\n"
        let slices = try MarkdownChunker.chunk(Data(source.utf8))
        #expect(slices.count == 1)
        let slice = try #require(slices.first)
        #expect(slice.headingPath == ["Title"])
        #expect(!slice.headingPath.contains("Inside code"))
        #expect(slice.text == source)
    }

    @Test func boundsHeadingMetadataWithoutChangingSourceText() throws {
        let source = "# " + String(repeating: "h", count: 2_000) + "\nbody\n"
        let slices = try MarkdownChunker.chunk(Data(source.utf8))
        let slice = try #require(slices.first)
        #expect(slice.headingPath.count == 1)
        #expect(slice.headingPath[0].utf8.count <= 512)
        #expect(slices.map(\.text).joined() == source)
    }

    @Test func keepsBoundedFenceTogetherAndPreservesEveryByte() throws {
        let code = String(repeating: "let value = 1\n", count: 350)
        let source = "intro\n```swift\n\(code)```\nafter\n"
        let sourceBytes = Array(source.utf8)
        let slices = try MarkdownChunker.chunk(Data(sourceBytes))

        #expect(slices.count == 2)
        #expect(slices.allSatisfy { $0.text.utf8.count <= 8192 })
        #expect(slices.map(\.text).joined() == source)
        let fencedSlice = try #require(slices.first(where: { $0.text.contains("```swift") }))
        #expect(fencedSlice.text.contains("```swift"))
        #expect(fencedSlice.text.contains("```\nafter") || fencedSlice.text.hasSuffix("```\n"))
        #expect(fencedSlice.headingPath.isEmpty)
        #expect(slices.allSatisfy { $0.startUTF8Offset < $0.endUTF8Offset })
        #expect(slices.last?.endUTF8Offset == sourceBytes.count)
    }

    @Test func splitsLongLinesAtScalarBoundariesAndUsesExactOffsets() throws {
        let combining = "é" // i18n-fixture: Keep a combining sequence to verify scalar-boundary splitting.
        let source = String(repeating: "x", count: 8_190) + combining + "\nend"
        let data = Data(source.utf8)
        let slices = try MarkdownChunker.chunk(data)

        #expect(slices.count >= 2)
        #expect(slices.allSatisfy { $0.text.utf8.count <= 8192 })
        #expect(slices.map(\.text).joined() == source)
        for slice in slices {
            let bytes = Array(data)[slice.startUTF8Offset..<slice.endUTF8Offset]
            #expect(String(decoding: bytes, as: UTF8.self) == slice.text)
            #expect(slice.startUTF8Offset == (slice.sequence == 0 ? 0 : slices[slice.sequence - 1].endUTF8Offset))
        }
    }

    @Test func rejectsInvalidBinaryAndOversizedInput() {
        #expect(throws: MiraError.self) { try MarkdownChunker.chunk(Data([0x23, 0xFF])) }
        #expect(throws: MiraError.self) { try MarkdownChunker.chunk(Data([0x23, 0x00])) }
        #expect(throws: MiraError.self) { try MarkdownChunker.chunk(Data([0x23, 0x01])) }
        #expect(throws: MiraError.self) {
            try MarkdownChunker.chunk(Data(repeating: 0x61, count: MarkdownChunker.maxFileBytes + 1))
        }
    }
}

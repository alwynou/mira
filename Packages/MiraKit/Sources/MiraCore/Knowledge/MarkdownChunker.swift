import Foundation

/// A deterministic, immutable slice of one Markdown source version.
public struct MarkdownChunkSlice: Codable, Equatable, Sendable {
    public let sequence: Int
    public let startLine: Int
    public let endLine: Int
    public let startUTF8Offset: Int
    public let endUTF8Offset: Int
    public let headingPath: [String]
    public let text: String

    public init(
        sequence: Int,
        startLine: Int,
        endLine: Int,
        startUTF8Offset: Int,
        endUTF8Offset: Int,
        headingPath: [String],
        text: String
    ) {
        self.sequence = sequence
        self.startLine = startLine
        self.endLine = endLine
        self.startUTF8Offset = startUTF8Offset
        self.endUTF8Offset = endUTF8Offset
        self.headingPath = headingPath
        self.text = text
    }
}

/// Foundation-only Markdown segmentation for immutable source snapshots.
public enum MarkdownChunker {
    public static let parserVersion = "markdown-lines-v1"
    public static let maxFileBytes = 10 * 1024 * 1024

    private static let targetChunkBytes = 4 * 1024
    private static let hardChunkBytes = 8 * 1024
    private static let maxHeadingBytes = 512
    private static let maxHeadingDepth = 6

    public static func chunk(_ data: Data) throws -> [MarkdownChunkSlice] {
        guard data.count <= maxFileBytes else {
            throw MiraError(.invalidInput, "The Markdown source exceeds the 10 MiB limit.")
        }

        let bytes = Array(data)
        let bomLength = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        let sourceBytes = Array(bytes.dropFirst(bomLength))
        guard let source = String(data: Data(sourceBytes), encoding: .utf8) else {
            throw MiraError(.invalidInput, "The Markdown source is invalid.")
        }
        guard source.unicodeScalars.allSatisfy(Self.isPermittedScalar) else {
            throw MiraError(.invalidInput, "The Markdown source is invalid.")
        }
        guard !source.isEmpty else { return [] }

        let scalars = Self.scalarUnits(in: source)
        let lines = Self.makeLines(scalars: scalars, byteCount: sourceBytes.count)
        let fenceIDs = Self.findFences(lines: lines, scalars: scalars)
        let headingEvents = Self.findHeadings(lines: lines, scalars: scalars, fenceIDs: fenceIDs)
        let headingPaths = Self.makeHeadingPaths(lines: lines, events: headingEvents)
        let pieces = Self.makePieces(
            lines: lines,
            scalars: scalars,
            fenceIDs: fenceIDs,
            headingPaths: headingPaths
        )
        let groups = Self.makeGroups(pieces: pieces, lines: lines, fenceIDs: fenceIDs)
        let ranges = Self.pack(groups: groups, pieces: pieces, lines: lines, headingEvents: headingEvents)

        return ranges.enumerated().map { sequence, range in
            let first = pieces[range.start]
            let last = pieces[range.end - 1]
            let start = first.startByte + bomLength
            let end = last.endByte + bomLength
            let text = String(decoding: sourceBytes[first.startByte..<last.endByte], as: UTF8.self)
            return MarkdownChunkSlice(
                sequence: sequence,
                startLine: first.lineIndex + 1,
                endLine: last.lineIndex + 1,
                startUTF8Offset: start,
                endUTF8Offset: end,
                headingPath: first.headingPath,
                text: text
            )
        }
    }

    private struct ScalarUnit {
        let value: Unicode.Scalar
        let startByte: Int
        let endByte: Int
    }

    private struct Line {
        let index: Int
        let startScalar: Int
        let contentEndScalar: Int
        let endScalar: Int
        let startByte: Int
        let contentEndByte: Int
        let endByte: Int
    }

    private struct Piece {
        let lineIndex: Int
        let startByte: Int
        let endByte: Int
        let completeLine: Bool
        let fenceID: Int?
        let headingPath: [String]

        var byteCount: Int { endByte - startByte }
    }

    private struct Group {
        let start: Int
        let end: Int
        let isFenced: Bool
    }

    private struct ChunkRange {
        let start: Int
        let end: Int
    }

    private static func isPermittedScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x09 || value == 0x0A || value == 0x0D { return true }
        if value < 0x20 || (0x7F...0x9F).contains(value) { return false }
        return true
    }

    private static func scalarUnits(in source: String) -> [ScalarUnit] {
        var offset = 0
        return source.unicodeScalars.map { scalar in
            let width = String(scalar).utf8.count
            defer { offset += width }
            return ScalarUnit(value: scalar, startByte: offset, endByte: offset + width)
        }
    }

    private static func makeLines(scalars: [ScalarUnit], byteCount: Int) -> [Line] {
        var lines: [Line] = []
        var start = 0
        var index = 0
        while index < scalars.count {
            let lineStart = index
            while index < scalars.count {
                let value = scalars[index].value.value
                if value == 0x0D {
                    index += 1
                    if index < scalars.count && scalars[index].value.value == 0x0A { index += 1 }
                    break
                }
                if value == 0x0A {
                    index += 1
                    break
                }
                index += 1
            }
            var contentEnd = index
            if contentEnd > lineStart && scalars[contentEnd - 1].value.value == 0x0A { contentEnd -= 1 }
            if contentEnd > lineStart && scalars[contentEnd - 1].value.value == 0x0D { contentEnd -= 1 }
            let startByte = lineStart < scalars.count ? scalars[lineStart].startByte : byteCount
            let contentEndByte = contentEnd > lineStart ? scalars[contentEnd - 1].endByte : startByte
            let endByte = index > lineStart ? scalars[index - 1].endByte : startByte
            lines.append(Line(
                index: lines.count,
                startScalar: lineStart,
                contentEndScalar: contentEnd,
                endScalar: index,
                startByte: startByte,
                contentEndByte: contentEndByte,
                endByte: endByte
            ))
            start = index
        }
        // `start` is intentionally retained as a line cursor; an empty trailing line
        // after a newline has no bytes and therefore does not need a slice.
        _ = start
        return lines
    }

    private static func content(_ line: Line, scalars: [ScalarUnit]) -> String {
        guard line.contentEndScalar > line.startScalar else { return "" }
        let values = scalars[line.startScalar..<line.contentEndScalar].map(\.value)
        return String(String.UnicodeScalarView(values))
    }

    private static func firstNonSpaceIndex(_ values: [Unicode.Scalar]) -> Int {
        var index = 0
        while index < values.count && (values[index].value == 0x20 || values[index].value == 0x09) { index += 1 }
        return index
    }

    private static func fenceMarker(_ text: String) -> (Unicode.Scalar, Int)? {
        let values = Array(text.unicodeScalars)
        let first = firstNonSpaceIndex(values)
        guard first <= 3, first < values.count, values[first].value == 0x60 || values[first].value == 0x7E else { return nil }
        let marker = values[first]
        var end = first
        while end < values.count && values[end] == marker { end += 1 }
        guard end - first >= 3 else { return nil }
        return (marker, end - first)
    }

    private static func isFenceClosing(_ text: String, marker: Unicode.Scalar, length: Int) -> Bool {
        let values = Array(text.unicodeScalars)
        let first = firstNonSpaceIndex(values)
        guard first <= 3, first < values.count, values[first] == marker else { return false }
        var end = first
        while end < values.count && values[end] == marker { end += 1 }
        guard end - first >= length else { return false }
        return values[end...].allSatisfy { $0.value == 0x20 || $0.value == 0x09 }
    }

    private static func findFences(lines: [Line], scalars: [ScalarUnit]) -> [Int?] {
        var result = Array<Int?>(repeating: nil, count: lines.count)
        var active: (id: Int, marker: Unicode.Scalar, length: Int)?
        var nextID = 0
        for line in lines {
            let text = content(line, scalars: scalars)
            if let current = active {
                result[line.index] = current.id
                if isFenceClosing(text, marker: current.marker, length: current.length) { active = nil }
            } else if let (marker, length) = fenceMarker(text) {
                let id = nextID
                nextID += 1
                active = (id, marker, length)
                result[line.index] = id
            }
        }
        return result
    }

    private static func atxHeading(_ text: String) -> (Int, String)? {
        let values = Array(text.unicodeScalars)
        let first = firstNonSpaceIndex(values)
        guard first <= 3, first < values.count else { return nil }
        var end = first
        while end < values.count && values[end].value == 0x23 { end += 1 }
        let level = end - first
        guard (1...6).contains(level), end == values.count || values[end].value == 0x20 || values[end].value == 0x09 else { return nil }
        var title = String(String.UnicodeScalarView(values[end...])).trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = title.range(of: #"\s+#+$"#, options: .regularExpression) { title.removeSubrange(hash) }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return (level, title)
    }

    private static func setextLevel(_ text: String) -> Int? {
        let values = Array(text.unicodeScalars)
        let first = firstNonSpaceIndex(values)
        guard first <= 3, first < values.count else { return nil }
        let marker = values[first].value
        guard marker == 0x3D || marker == 0x2D else { return nil }
        var end = first
        while end < values.count && values[end].value == marker { end += 1 }
        guard end - first >= 1 else { return nil }
        guard values[end...].allSatisfy({ $0.value == 0x20 || $0.value == 0x09 }) else { return nil }
        return marker == 0x3D ? 1 : 2
    }

    private static func findHeadings(lines: [Line], scalars: [ScalarUnit], fenceIDs: [Int?]) -> [Int: (Int, String)] {
        var events: [Int: (Int, String)] = [:]
        for line in lines {
            guard fenceIDs[line.index] == nil, let heading = atxHeading(content(line, scalars: scalars)) else { continue }
            events[line.index] = heading
        }
        guard lines.count > 1 else { return events }
        for index in 0..<(lines.count - 1) {
            guard fenceIDs[index] == nil, fenceIDs[index + 1] == nil,
                  !content(lines[index], scalars: scalars).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let level = setextLevel(content(lines[index + 1], scalars: scalars)) else { continue }
            let title = content(lines[index], scalars: scalars).trimmingCharacters(in: .whitespacesAndNewlines)
            events[index] = (level, title)
        }
        return events
    }

    private static func makeHeadingPaths(lines: [Line], events: [Int: (Int, String)]) -> [[String]] {
        var paths = Array(repeating: [String](), count: lines.count)
        var current: [String] = []
        for line in lines {
            if let (level, title) = events[line.index] {
                let boundedTitle = boundedUTF8(title, maxBytes: maxHeadingBytes)
                if level <= current.count {
                    current = Array(current.prefix(level - 1)) + [boundedTitle]
                } else {
                    current.append(boundedTitle)
                }
                if current.count > maxHeadingDepth { current = Array(current.prefix(maxHeadingDepth)) }
            }
            paths[line.index] = current
        }
        return paths
    }

    private static func boundedUTF8(_ text: String, maxBytes: Int) -> String {
        var values: [Unicode.Scalar] = []
        var bytes = 0
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf8.count
            guard bytes + width <= maxBytes else { break }
            values.append(scalar)
            bytes += width
        }
        return String(String.UnicodeScalarView(values))
    }

    private static func makePieces(lines: [Line], scalars: [ScalarUnit], fenceIDs: [Int?], headingPaths: [[String]]) -> [Piece] {
        var pieces: [Piece] = []
        for line in lines {
            var scalarStart = line.startScalar
            if line.endByte - line.startByte <= hardChunkBytes {
                pieces.append(Piece(lineIndex: line.index, startByte: line.startByte, endByte: line.endByte, completeLine: true, fenceID: fenceIDs[line.index], headingPath: headingPaths[line.index]))
                continue
            }
            while scalarStart < line.endScalar {
                let limit = min(line.endByte, scalars[scalarStart].startByte + hardChunkBytes)
                var scalarEnd = scalarStart
                while scalarEnd < line.endScalar && scalars[scalarEnd].endByte <= limit { scalarEnd += 1 }
                if scalarEnd == scalarStart { scalarEnd += 1 }
                if scalarEnd < line.endScalar,
                   scalars[scalarEnd - 1].value.value == 0x0D,
                   scalars[scalarEnd].value.value == 0x0A {
                    scalarEnd -= 1
                }
                let startByte = scalars[scalarStart].startByte
                let endByte = scalars[scalarEnd - 1].endByte
                pieces.append(Piece(lineIndex: line.index, startByte: startByte, endByte: endByte, completeLine: scalarEnd == line.endScalar, fenceID: fenceIDs[line.index], headingPath: headingPaths[line.index]))
                scalarStart = scalarEnd
            }
        }
        return pieces
    }

    private static func makeGroups(pieces: [Piece], lines: [Line], fenceIDs: [Int?]) -> [Group] {
        var groups: [Group] = []
        var pieceIndex = 0
        while pieceIndex < pieces.count {
            guard let fenceID = pieces[pieceIndex].fenceID else {
                groups.append(Group(start: pieceIndex, end: pieceIndex + 1, isFenced: false))
                pieceIndex += 1
                continue
            }
            let indices = pieces.indices.filter { pieces[$0].fenceID == fenceID }
            let first = indices.first ?? pieceIndex
            let last = indices.last ?? pieceIndex
            let total = pieces[first...last].reduce(0) { $0 + $1.byteCount }
            if first == pieceIndex && total <= hardChunkBytes {
                groups.append(Group(start: first, end: last + 1, isFenced: true))
                pieceIndex = last + 1
            } else {
                groups.append(Group(start: pieceIndex, end: pieceIndex + 1, isFenced: false))
                pieceIndex += 1
            }
        }
        _ = lines
        _ = fenceIDs
        return groups
    }

    private static func pack(groups: [Group], pieces: [Piece], lines: [Line], headingEvents: [Int: (Int, String)]) -> [ChunkRange] {
        guard !groups.isEmpty else { return [] }
        var result: [ChunkRange] = []
        var startGroup = 0
        while startGroup < groups.count {
            var endGroup = startGroup
            var bytes = 0
            var preferredEnd: Int?
            while endGroup < groups.count {
                let group = groups[endGroup]
                let nextBytes = pieces[group.start..<group.end].reduce(0) { $0 + $1.byteCount }
                if bytes > 0 && bytes + nextBytes > hardChunkBytes { break }
                if bytes > 0 && bytes + nextBytes > targetChunkBytes {
                    if group.isFenced && bytes + nextBytes <= hardChunkBytes {
                        bytes += nextBytes
                        endGroup += 1
                    }
                    break
                }
                bytes += nextBytes
                endGroup += 1
                if endGroup < groups.count && isPreferredBoundary(after: group, next: groups[endGroup], pieces: pieces, lines: lines, headingEvents: headingEvents) {
                    preferredEnd = endGroup
                }
            }
            if endGroup == startGroup { endGroup += 1 }
            if endGroup < groups.count, let preferredEnd, preferredEnd > startGroup {
                endGroup = preferredEnd
            }
            let firstPiece = groups[startGroup].start
            let lastPiece = groups[endGroup - 1].end
            result.append(ChunkRange(start: firstPiece, end: lastPiece))
            startGroup = endGroup
        }
        return result
    }

    private static func isPreferredBoundary(after group: Group, next: Group, pieces: [Piece], lines: [Line], headingEvents: [Int: (Int, String)]) -> Bool {
        if group.isFenced { return true }
        let previous = pieces[group.end - 1]
        let following = pieces[next.start]
        if headingEvents[following.lineIndex] != nil { return true }
        guard previous.completeLine else { return false }
        let line = lines[previous.lineIndex]
        return line.contentEndByte == line.startByte
    }
}

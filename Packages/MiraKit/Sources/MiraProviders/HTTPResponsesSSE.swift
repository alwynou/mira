import Foundation

enum ResponsesProtocolError: Error { case malformed, prematureEOF, provider, resourceLimit }

/// Bounded SSE framing for the Responses protocol. UTF-8 is decoded only at
/// complete line boundaries; multi-line data fields are joined per SSE.
struct ResponsesSSEFrame: Sendable {
    let event: String
    let data: String
}

struct ResponsesSSEParser {
    private var bytes: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName = ""
    private var eventSize = 0
    private var totalSize = 0
    private let maxLineSize = 1_048_576
    private let maxEventSize = 4_194_304
    private let maxTotalSize = 8_388_608

    mutating func feed(_ data: Data, emit: (ResponsesSSEFrame) throws -> Void) throws {
        totalSize += data.count
        guard totalSize <= maxTotalSize else { throw ResponsesProtocolError.resourceLimit }
        bytes.append(contentsOf: data)
        while true {
            var delimiterIndex: Int?
            var delimiterLength = 1
            for index in bytes.indices {
                if bytes[index] == 10 { delimiterIndex = index; break }
                if bytes[index] == 13 {
                    guard index + 1 < bytes.count else { break }
                    delimiterIndex = index
                    delimiterLength = bytes[index + 1] == 10 ? 2 : 1
                    break
                }
            }
            guard let index = delimiterIndex else {
                guard bytes.count <= maxLineSize else { throw ResponsesProtocolError.malformed }
                return
            }
            let line = Array(bytes[..<index])
            bytes.removeFirst(index + delimiterLength)
            try process(line, emit: emit)
        }
    }

    mutating func finish(emit: (ResponsesSSEFrame) throws -> Void) throws {
        if !bytes.isEmpty {
            guard bytes.count <= maxLineSize else { throw ResponsesProtocolError.malformed }
            let line = bytes; bytes.removeAll(keepingCapacity: false)
            try process(line, emit: emit)
        }
        try dispatch(emit: emit)
    }

    private mutating func process(_ lineBytes: [UInt8], emit: (ResponsesSSEFrame) throws -> Void) throws {
        guard let line = String(bytes: lineBytes, encoding: .utf8) else { throw ResponsesProtocolError.malformed }
        if line.isEmpty { try dispatch(emit: emit); return }
        if line.first == ":" { return }
        let separator = line.firstIndex(of: ":")
        let field: String
        var value: String
        if let separator {
            field = String(line[..<separator]); value = String(line[line.index(after: separator)...])
            if value.first == " " { value.removeFirst() }
        } else { field = line; value = "" }
        switch field {
        case "event": eventName = value
        case "data":
            eventSize += value.utf8.count + (dataLines.isEmpty ? 0 : 1)
            guard eventSize <= maxEventSize else { throw ResponsesProtocolError.resourceLimit }
            dataLines.append(value)
        default: break
        }
    }

    private mutating func dispatch(emit: (ResponsesSSEFrame) throws -> Void) throws {
        guard !dataLines.isEmpty else { eventName = ""; eventSize = 0; return }
        try emit(.init(event: eventName, data: dataLines.joined(separator: "\n")))
        eventName = ""; dataLines.removeAll(keepingCapacity: true); eventSize = 0
    }
}

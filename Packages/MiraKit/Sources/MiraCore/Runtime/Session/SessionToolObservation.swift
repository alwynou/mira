import Foundation

/// The model-facing tool observation is derived from the canonical resolution.
/// The result content remains owned by its SessionContent bytes; this helper
/// only decodes those bytes to form the request envelope.
enum SessionToolObservation {
    static func value(_ resolution: SessionToolResolution) throws -> JSONValue {
        let content: JSONValue
        if let result = resolution.result {
            guard result.kind == .toolResult else {
                throw MiraError(.storage, "The committed tool result is unavailable.")
            }
            content = try SessionCodec.decode(JSONValue.self, from: result.bytes)
        } else {
            content = .null
        }
        var fields: [String: JSONValue] = [
            "authority": .string("untrusted_tool_observation"),
            "content": content,
            "status": .string(resolution.status.rawValue)
        ]
        if let error = resolution.error {
            fields["error"] = try SessionCodec.decode(JSONValue.self, from: SessionCodec.encode(error))
        }
        return .object(fields)
    }
}

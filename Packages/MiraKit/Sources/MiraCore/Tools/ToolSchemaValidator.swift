import Foundation

/// Deliberately small JSON Schema subset. Unsupported schemas fail at registration instead of weakening validation.
public enum ToolSchemaValidator {
    public static func validateSchema(_ schema: JSONValue, depth: Int = 0) throws {
        guard depth <= 16, case .object(let fields) = schema, let type = fields["type"]?.stringValue else {
            throw invalidSchema
        }
        let common: Set<String> = ["type", "description", "enum"]
        let specific: Set<String>
        switch type {
        case "object":
            specific = ["properties", "required", "additionalProperties"]
            guard case .object(let properties) = fields["properties"], fields["additionalProperties"] == .bool(false)
            else { throw invalidSchema }
            if let required = fields["required"] {
                guard case .array(let names) = required,
                    names.allSatisfy({ $0.stringValue.map { properties[$0] != nil } ?? false }),
                    Set(names.compactMap(\.stringValue)).count == names.count
                else { throw invalidSchema }
            }
            for child in properties.values { try validateSchema(child, depth: depth + 1) }
        case "array":
            specific = ["items", "minItems", "maxItems"]
            guard let items = fields["items"], fields["maxItems"] != nil else { throw invalidSchema }
            try validateSchema(items, depth: depth + 1)
        case "string": specific = ["minLength", "maxLength"]
        case "integer", "number": specific = ["minimum", "maximum"]
        case "boolean": specific = []
        default: throw invalidSchema
        }
        guard Set(fields.keys).isSubset(of: common.union(specific)) else { throw invalidSchema }
        if let options = fields["enum"] {
            guard case .array(let values) = options, !values.isEmpty else { throw invalidSchema }
        }
        for key in ["minItems", "maxItems", "minLength", "maxLength", "minimum", "maximum"] {
            if let value = fields[key] {
                guard case .number(let n) = value, n.isFinite else { throw invalidSchema }
                if key != "minimum" && key != "maximum" { guard n >= 0, n.rounded() == n else { throw invalidSchema } }
            }
        }
        for pair in [("minItems", "maxItems"), ("minLength", "maxLength"), ("minimum", "maximum")] {
            if case .number(let low) = fields[pair.0], case .number(let high) = fields[pair.1], low > high {
                throw invalidSchema
            }
        }
    }
    public static func decode(_ arguments: String, schema: JSONValue) throws -> JSONValue {
        guard arguments.utf8.count <= 65_536,
            let value = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)),
            case .object = value
        else { throw invalidArguments }
        try validate(value, schema: schema)
        return value
    }
    public static func validate(_ value: JSONValue, schema: JSONValue, depth: Int = 0) throws {
        guard depth <= 16, case .object(let fields) = schema else { throw invalidArguments }
        if case .array(let options) = fields["enum"], !options.contains(value) { throw invalidArguments }
        switch (fields["type"]?.stringValue, value) {
        case ("object", .object(let object)):
            guard case .object(let properties) = fields["properties"],
                Set(object.keys).isSubset(of: Set(properties.keys))
            else { throw invalidArguments }
            if case .array(let required) = fields["required"],
                required.contains(where: { object[$0.stringValue ?? ""] == nil })
            {
                throw invalidArguments
            }
            for (key, child) in object {
                guard let childSchema = properties[key] else { throw invalidArguments }
                try validate(child, schema: childSchema, depth: depth + 1)
            }
        case ("array", .array(let array)):
            guard let items = fields["items"] else { throw invalidArguments }
            try bounds(Double(array.count), fields: fields, min: "minItems", max: "maxItems")
            for child in array { try validate(child, schema: items, depth: depth + 1) }
        case ("string", .string(let string)):
            try bounds(Double(string.unicodeScalars.count), fields: fields, min: "minLength", max: "maxLength")
        case ("integer", .number(let number)):
            guard number.isFinite, number.rounded() == number else { throw invalidArguments }
            try bounds(number, fields: fields, min: "minimum", max: "maximum")
        case ("number", .number(let number)):
            guard number.isFinite else { throw invalidArguments }
            try bounds(number, fields: fields, min: "minimum", max: "maximum")
        case ("boolean", .bool): break
        default: throw invalidArguments
        }
    }
    private static func bounds(_ value: Double, fields: [String: JSONValue], min: String, max: String) throws {
        if case .number(let limit) = fields[min], value < limit { throw invalidArguments }
        if case .number(let limit) = fields[max], value > limit { throw invalidArguments }
    }
    private static var invalidSchema: MiraError {
        .init(.configuration, "Tool parameter schema is unsupported or missing bounds.")
    }
    private static var invalidArguments: MiraError {
        .init(.invalidInput, "Tool arguments do not match the declared structure or size limits.")
    }
}

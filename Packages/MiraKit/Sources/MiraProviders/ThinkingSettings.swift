import Foundation

public enum ThinkingMode: String, Codable, CaseIterable, Sendable {
    case providerDefault, enabled, disabled, adaptive
}

/// A provider-declared reasoning effort value.
///
/// Effort names are model metadata, so this type intentionally stays open
/// rather than baking a global list into the provider layer.
public struct ThinkingEffort: RawRepresentable, Codable, Hashable, Sendable, Equatable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let low = Self(rawValue: "low")
    public static let medium = Self(rawValue: "medium")
    public static let high = Self(rawValue: "high")
    public static let xhigh = Self(rawValue: "xhigh")
    public static let max = Self(rawValue: "max")

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// User-selected request controls, frozen with the route for the entire execution.
public struct ThinkingSettings: Codable, Sendable, Equatable {
    public var mode: ThinkingMode
    public var effort: ThinkingEffort?
    public var budgetTokens: Int?

    public init(mode: ThinkingMode = .providerDefault, effort: ThinkingEffort? = nil, budgetTokens: Int? = nil) {
        self.mode = mode
        self.effort = effort
        self.budgetTokens = budgetTokens
    }

    private enum CodingKeys: String, CodingKey { case mode, effort, budgetTokens }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(ThinkingMode.self, forKey: .mode) ?? .providerDefault
        effort = try container.decodeIfPresent(ThinkingEffort.self, forKey: .effort)
        budgetTokens = try container.decodeIfPresent(Int.self, forKey: .budgetTokens)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encodeIfPresent(budgetTokens, forKey: .budgetTokens)
    }
}

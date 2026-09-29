import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var foundationValue: Any {
        switch self {
        case .string(let value): value
        case .integer(let value): Int(value)
        case .number(let value): value
        case .bool(let value): value
        case .object(let value): value.mapValues(\.foundationValue)
        case .array(let value): value.map(\.foundationValue)
        case .null: NSNull()
        }
    }

    init(foundationValue: Any) {
        switch foundationValue {
        case let value as String: self = .string(value)
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID(): self = .bool(value.boolValue)
        case let value as NSNumber where ["f", "d"].contains(String(cString: value.objCType)): self = .number(value.doubleValue)
        case let value as NSNumber: self = .integer(value.int64Value)
        case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init(foundationValue:)))
        case let value as [Any]: self = .array(value.map(JSONValue.init(foundationValue:)))
        default: self = .null
        }
    }
}

import CoreFoundation

struct SubscriptionSource: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var url: String
    var enabled: Bool = true
    var providerCompatible: Bool? = nil
    var updatedAt: Int64? = nil
    var lastError: String? = nil
}

struct ProxyNode: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var sourceId: String? = nil
    var name: String
    var type: String
    var server: String
    var port: Int
    var enabled: Bool = true
    var options: [String: JSONValue] = [:]
}

struct PolicyGroup: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var id: String { name }
    var type: String = "select"
    var members: [String] = []
    var extra: [String: JSONValue] = [:]
    var membersExplicit: Bool = false
}

struct RuleCondition: Codable, Equatable, Sendable {
    var groupOperator: String? = nil
    var type: String? = nil
    var value: String = ""
    var argument: String? = nil
    var noResolve: Bool = false
    var source: Bool = false
    var children: [RuleCondition] = []

    enum CodingKeys: String, CodingKey {
        case groupOperator = "operator"
        case type, value, argument, noResolve, source, children
    }
}

struct RoutingRule: Codable, Identifiable, Equatable, Sendable {
    var id: String { UUID().uuidString }
    var type: String
    var value: String
    var group: String
    var noResolve: Bool = false
    var source: Bool = false
    var conditions: [RuleCondition] = []
    var extraParameters: [String] = []
    var rawLine: String? = nil
}

struct RuleProvider: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var type: String = "http"
    var url: String = ""
    var path: String = ""
    var interval: Int = 86400
    var behavior: String = "domain"
    var format: String = "yaml"
    var payload: [String] = []
    var headers: [String: [String]] = [:]
    var extra: [String: JSONValue] = [:]
    var sourceTemplateId: String? = nil
    var sourceTemplateName: String? = nil
}

struct SubRuleProfile: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var id: String { name }
    var rules: [RoutingRule] = []
}

struct RuleProfile: Codable, Equatable, Sendable {
    var groups: [PolicyGroup] = [PolicyGroup(name: "PROXY")]
    var rules: [RoutingRule] = []
    var providers: [RuleProvider] = []
    var subRules: [SubRuleProfile] = []
}

struct ConfigProfile: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var fileName: String
    var selectedSourceIds: Set<String> = []
    var enabledNodeIds: Set<String> = []
    var ruleProfile: RuleProfile = RuleProfile()
    var sourceMode: String = "EMBED_NODES"
    var enabledRegions: Set<String> = ["hk", "tw", "jp", "sg", "us", "kr", "other"]
    var regionOverrides: [String: String] = [:]
    var templateId: String? = nil
    var templateProviderBindings: [String: String] = [:]
    var mihomoSettings: [String: JSONValue] = [:]
    var advancedYaml: String? = nil

    init(id: String, name: String, fileName: String? = nil) {
        self.id = id
        self.name = name
        self.fileName = fileName ?? name
    }
}

struct ConfigTemplate: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var rawYaml: String
    var fileName: String
    var createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var remoteURL: String? = nil
    var refreshedAt: Int64? = nil
}

struct RuleProviderStatus: Codable, Equatable, Sendable {
    var profileId: String
    var providerId: String
    var refreshedAt: Int64? = nil
    var error: String? = nil
    var itemCount: Int? = nil
    var cacheFileName: String? = nil
}

struct AppState: Codable, Equatable, Sendable {
    var sources: [SubscriptionSource] = []
    var nodes: [ProxyNode] = []
    var profiles: [ConfigProfile] = [ConfigProfile(id: "default", name: "默认配置")]
    var activeProfileId: String = "default"
    var templates: [ConfigTemplate] = []
    var ruleProviderStatuses: [RuleProviderStatus] = []

    var activeProfile: ConfigProfile {
        profiles.first(where: { $0.id == activeProfileId }) ?? profiles.first ?? ConfigProfile(id: "default", name: "默认配置")
    }
}

extension JSONValue {
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var intValue: Int? {
        switch self {
        case .integer(let value): Int(exactly: value)
        case .number(let value): Int(exactly: value)
        case .string(let value): Int(value)
        default: nil
        }
    }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
}

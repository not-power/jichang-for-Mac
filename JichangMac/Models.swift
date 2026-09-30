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

    enum CodingKeys: String, CodingKey { case id, name, url, enabled, providerCompatible, updatedAt, lastError }
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

    enum CodingKeys: String, CodingKey { case id, sourceId, name, type, server, port, enabled, options }
}

struct PolicyGroup: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var id: String { name }
    var type: String = "select"
    var members: [String] = []
    var extra: [String: JSONValue] = [:]
    var membersExplicit: Bool = false

    enum CodingKeys: String, CodingKey { case name, type, members, extra, membersExplicit }
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

    enum CodingKeys: String, CodingKey { case type, value, group, noResolve, source, conditions, extraParameters, rawLine }
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

    enum CodingKeys: String, CodingKey { case id, name, type, url, path, interval, behavior, format, payload, headers, extra, sourceTemplateId, sourceTemplateName }
}

struct SubRuleProfile: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var id: String { name }
    var rules: [RoutingRule] = []

    enum CodingKeys: String, CodingKey { case name, rules }
}

struct RuleProfile: Codable, Equatable, Sendable {
    var groups: [PolicyGroup] = [PolicyGroup(name: "PROXY")]
    var rules: [RoutingRule] = []
    var providers: [RuleProvider] = []
    var subRules: [SubRuleProfile] = []

    enum CodingKeys: String, CodingKey { case groups, rules, providers, subRules }
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

    enum CodingKeys: String, CodingKey { case id, name, fileName, selectedSourceIds, enabledNodeIds, ruleProfile, sourceMode, enabledRegions, regionOverrides, templateId, templateProviderBindings, mihomoSettings, advancedYaml }
}

struct ConfigTemplate: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var rawYaml: String
    var fileName: String
    var createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var remoteURL: String? = nil
    var refreshedAt: Int64? = nil

    enum CodingKeys: String, CodingKey { case id, name, rawYaml, fileName, createdAt, remoteURL, refreshedAt }
}

struct RuleProviderStatus: Codable, Equatable, Sendable {
    var profileId: String
    var providerId: String
    var refreshedAt: Int64? = nil
    var error: String? = nil
    var itemCount: Int? = nil
    var cacheFileName: String? = nil

    enum CodingKeys: String, CodingKey { case profileId, providerId, refreshedAt, error, itemCount, cacheFileName }
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

    enum CodingKeys: String, CodingKey { case sources, nodes, profiles, activeProfileId, templates, ruleProviderStatuses }
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

extension SubscriptionSource {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        providerCompatible = try c.decodeIfPresent(Bool.self, forKey: .providerCompatible)
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

extension ProxyNode {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        server = try c.decode(String.self, forKey: .server)
        port = try c.decode(Int.self, forKey: .port)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        options = try c.decodeIfPresent([String: JSONValue].self, forKey: .options) ?? [:]
    }
}

extension PolicyGroup {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "select"
        members = try c.decodeIfPresent([String].self, forKey: .members) ?? []
        extra = try c.decodeIfPresent([String: JSONValue].self, forKey: .extra) ?? [:]
        membersExplicit = try c.decodeIfPresent(Bool.self, forKey: .membersExplicit) ?? false
    }
}

extension RuleCondition {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupOperator = try c.decodeIfPresent(String.self, forKey: .groupOperator)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        argument = try c.decodeIfPresent(String.self, forKey: .argument)
        noResolve = try c.decodeIfPresent(Bool.self, forKey: .noResolve) ?? false
        source = try c.decodeIfPresent(Bool.self, forKey: .source) ?? false
        children = try c.decodeIfPresent([RuleCondition].self, forKey: .children) ?? []
    }
}

extension RoutingRule {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        value = try c.decode(String.self, forKey: .value)
        group = try c.decode(String.self, forKey: .group)
        noResolve = try c.decodeIfPresent(Bool.self, forKey: .noResolve) ?? false
        source = try c.decodeIfPresent(Bool.self, forKey: .source) ?? false
        conditions = try c.decodeIfPresent([RuleCondition].self, forKey: .conditions) ?? []
        extraParameters = try c.decodeIfPresent([String].self, forKey: .extraParameters) ?? []
        rawLine = try c.decodeIfPresent(String.self, forKey: .rawLine)
    }
}

extension RuleProvider {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "http"
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 86400
        behavior = try c.decodeIfPresent(String.self, forKey: .behavior) ?? "domain"
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "yaml"
        payload = try c.decodeIfPresent([String].self, forKey: .payload) ?? []
        headers = try c.decodeIfPresent([String: [String]].self, forKey: .headers) ?? [:]
        extra = try c.decodeIfPresent([String: JSONValue].self, forKey: .extra) ?? [:]
        sourceTemplateId = try c.decodeIfPresent(String.self, forKey: .sourceTemplateId)
        sourceTemplateName = try c.decodeIfPresent(String.self, forKey: .sourceTemplateName)
    }
}

extension SubRuleProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        rules = try c.decodeIfPresent([RoutingRule].self, forKey: .rules) ?? []
    }
}

extension RuleProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([PolicyGroup].self, forKey: .groups) ?? [PolicyGroup(name: "PROXY")]
        rules = try c.decodeIfPresent([RoutingRule].self, forKey: .rules) ?? []
        providers = try c.decodeIfPresent([RuleProvider].self, forKey: .providers) ?? []
        subRules = try c.decodeIfPresent([SubRuleProfile].self, forKey: .subRules) ?? []
    }
}

extension ConfigProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? c.decode(String.self, forKey: .name)
        selectedSourceIds = try c.decodeIfPresent(Set<String>.self, forKey: .selectedSourceIds) ?? []
        enabledNodeIds = try c.decodeIfPresent(Set<String>.self, forKey: .enabledNodeIds) ?? []
        ruleProfile = try c.decodeIfPresent(RuleProfile.self, forKey: .ruleProfile) ?? RuleProfile()
        sourceMode = try c.decodeIfPresent(String.self, forKey: .sourceMode) ?? "EMBED_NODES"
        enabledRegions = try c.decodeIfPresent(Set<String>.self, forKey: .enabledRegions) ?? ["hk", "tw", "jp", "sg", "us", "kr", "other"]
        regionOverrides = try c.decodeIfPresent([String: String].self, forKey: .regionOverrides) ?? [:]
        templateId = try c.decodeIfPresent(String.self, forKey: .templateId)
        templateProviderBindings = try c.decodeIfPresent([String: String].self, forKey: .templateProviderBindings) ?? [:]
        mihomoSettings = try c.decodeIfPresent([String: JSONValue].self, forKey: .mihomoSettings) ?? [:]
        advancedYaml = try c.decodeIfPresent(String.self, forKey: .advancedYaml)
    }
}

extension ConfigTemplate {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        rawYaml = try c.decode(String.self, forKey: .rawYaml)
        fileName = try c.decode(String.self, forKey: .fileName)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? Int64(Date().timeIntervalSince1970 * 1000)
        remoteURL = try c.decodeIfPresent(String.self, forKey: .remoteURL)
        refreshedAt = try c.decodeIfPresent(Int64.self, forKey: .refreshedAt)
    }
}

extension RuleProviderStatus {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decode(String.self, forKey: .profileId)
        providerId = try c.decode(String.self, forKey: .providerId)
        refreshedAt = try c.decodeIfPresent(Int64.self, forKey: .refreshedAt)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        itemCount = try c.decodeIfPresent(Int.self, forKey: .itemCount)
        cacheFileName = try c.decodeIfPresent(String.self, forKey: .cacheFileName)
    }
}

extension AppState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([SubscriptionSource].self, forKey: .sources) ?? []
        nodes = try c.decodeIfPresent([ProxyNode].self, forKey: .nodes) ?? []
        profiles = try c.decodeIfPresent([ConfigProfile].self, forKey: .profiles) ?? [ConfigProfile(id: "default", name: "默认配置")]
        activeProfileId = try c.decodeIfPresent(String.self, forKey: .activeProfileId) ?? "default"
        templates = try c.decodeIfPresent([ConfigTemplate].self, forKey: .templates) ?? []
        ruleProviderStatuses = try c.decodeIfPresent([RuleProviderStatus].self, forKey: .ruleProviderStatuses) ?? []
    }
}

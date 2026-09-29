import Foundation
import Yams

struct GeneratedConfig {
    var yaml: String
    var exportedNodes: Int
    var skippedNodes: Int
    var referencedSubscriptions: Int = 0
    var unresolvedTemplateProviders: [String] = []
}

enum MihomoConfigGenerator {
    static let regions: [(key: String, title: String, pattern: String)] = [
        ("hk", "香港", "香港|港|hong[ ._-]?kong|\\bhk\\b"),
        ("tw", "台湾", "台湾|臺灣|台北|taiwan|taipei|\\btw\\b"),
        ("jp", "日本", "日本|东京|大阪|japan|tokyo|osaka|\\bjp\\b"),
        ("sg", "新加坡", "新加坡|狮城|singapore|\\bsg\\b"),
        ("us", "美国", "美国|洛杉矶|西雅图|纽约|united states|america|\\busa?\\b"),
        ("kr", "韩国", "韩国|首尔|korea|seoul|\\bkr\\b"),
        ("other", "其他", "")
    ]
    static let supportedNodeTypes: Set<String> = ["ss", "ssr", "vmess", "vless", "trojan", "hysteria", "hysteria2", "tuic", "wireguard", "anytls", "snell", "socks5", "http", "ssh", "socks"]

    static func generate(_ state: AppState, profile: ConfigProfile? = nil) throws -> GeneratedConfig {
        let profile = profile ?? state.activeProfile
        var root: [String: Any] = [:]
        if let templateId = profile.templateId, let template = state.templates.first(where: { $0.id == templateId }) {
            root = try Yams.load(yaml: template.rawYaml) as? [String: Any] ?? [:]
        }
        if let advanced = profile.advancedYaml, !advanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let values = try Yams.load(yaml: advanced) as? [String: Any] ?? [:]
            root.merge(values) { _, new in new }
        }

        let selectedSources = state.sources.filter { profile.selectedSourceIds.contains($0.id) }
        let selectedSourceIds = Set(selectedSources.map(\.id))
        let selectedNodes = state.nodes.filter { profile.enabledNodeIds.contains($0.id) && ($0.sourceId == nil || selectedSourceIds.contains($0.sourceId!)) }
        let referenceMode = profile.sourceMode == "REFERENCE_SUBSCRIPTIONS"
        let providerSources = referenceMode ? selectedSources.filter { $0.providerCompatible == true } : []
        let providerSourceIDs = Set(providerSources.map(\.id))
        let nodes = selectedNodes.filter { supportedNodeTypes.contains($0.type.lowercased()) && (!referenceMode || $0.sourceId == nil || !providerSourceIDs.contains($0.sourceId!)) }
        let nodeNames = makeUniqueNames(nodes)
        let nameByNodeID = Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), nodeNames))
        let allNodeNames = Dictionary(uniqueKeysWithValues: selectedNodes.map { ($0.id, safeName($0.name)) })
        var proxyProviders = root["proxy-providers"] as? [String: Any] ?? [:]
        let templatePlaceholderNames = proxyProviders.compactMap { name, value -> String? in
            guard let body = value as? [String: Any], (body["type"] as? String)?.lowercased() == "http" else { return nil }
            return isSubscriptionPlaceholder(body["url"] as? String ?? "") ? name : nil
        }
        let boundTemplates: [(String, SubscriptionSource)] = templatePlaceholderNames.compactMap { name in
            let explicitlyBound = profile.templateProviderBindings[name].flatMap { id in providerSources.first { $0.id == id } }
            let implicit = providerSources.count == 1 ? providerSources.first : nil
            guard let source = explicitlyBound ?? implicit else { return nil }
            return (name, source)
        }
        for (name, source) in boundTemplates {
            var body = proxyProviders[name] as? [String: Any] ?? [:]
            body["url"] = source.url
            proxyProviders[name] = body
        }
        let boundSourceIDs = Set(boundTemplates.map { $0.1.id })
        let genericSources = providerSources.filter { !boundSourceIDs.contains($0.id) }
        let genericProviderNames = genericSources.indices.map { "订阅-\($0 + 1)" }
        for (index, source) in genericSources.enumerated() {
            proxyProviders[genericProviderNames[index]] = [
                "type": "http", "url": source.url, "path": "./providers/\(safeName(source.name)).yaml",
                "interval": 86400, "health-check": ["enable": true, "url": "https://www.gstatic.com/generate_204", "interval": 300]
            ]
        }
        let providerNames = boundTemplates.map(\.0) + genericProviderNames
        let unresolvedTemplateProviders = templatePlaceholderNames.filter { name in !boundTemplates.contains(where: { $0.0 == name }) }
        let enabledRegions = profile.enabledRegions
        let proxyRows = nodes.map { node -> [String: Any] in
            var proxy = node.options.mapValues(\.foundationValue)
            proxy["name"] = nameByNodeID[node.id] ?? safeName(node.name)
            proxy["type"] = node.type
            proxy["server"] = node.server
            proxy["port"] = node.port
            return proxy
        }

        let groups = profile.ruleProfile.groups.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        var groupRows: [[String: Any]] = groups.map { group in
            let configured = group.members.compactMap { member -> String? in
                if member.hasPrefix("node:") {
                    let id = String(member.dropFirst(5))
                    if let localName = nameByNodeID[id] { return localName }
                    if providerNames.isEmpty, let remote = allNodeNames[id] { return remote }
                    return nil
                }
                return member
            }
            let isImplicitAll = group.members.isEmpty && !group.membersExplicit
            var row: [String: Any] = ["name": safeName(group.name), "type": group.type, "proxies": isImplicitAll ? nodeNames : configured]
            for (key, value) in group.extra { row[key] = value.foundationValue }
            let referencesRemote = referenceMode && !providerNames.isEmpty && (isImplicitAll || group.members.contains { member in
                guard member.hasPrefix("node:") else { return false }
                let id = String(member.dropFirst(5))
                guard let sourceId = selectedNodes.first(where: { $0.id == id })?.sourceId else { return false }
                return providerSourceIDs.contains(sourceId)
            })
            if referencesRemote {
                let configuredUse: [String]? = {
                    guard case .array(let values)? = group.extra["use"] else { return nil }
                    return values.compactMap(\.stringValue)
                }()
                let chosenUse = configuredUse?.filter { providerNames.contains($0) || !templatePlaceholderNames.contains($0) } ?? providerNames
                if !chosenUse.isEmpty { row["use"] = chosenUse }
                let remoteNames = group.members.compactMap { member -> String? in
                    guard member.hasPrefix("node:") else { return nil }
                    let id = String(member.dropFirst(5))
                    guard let sourceId = selectedNodes.first(where: { $0.id == id })?.sourceId, providerSourceIDs.contains(sourceId) else { return nil }
                    return allNodeNames[id]
                }
                if !remoteNames.isEmpty { row["filter"] = remoteNames.map(exactNamePattern).joined(separator: "|") }
            }
            if ["url-test", "fallback", "load-balance"].contains(group.type) {
                row["url"] = row["url"] ?? "https://www.gstatic.com/generate_204"
                row["interval"] = row["interval"] ?? 300
            }
            return row
        }
        let existingNames = Set(groupRows.compactMap { $0["name"] as? String })
        let generatedRegionNames = regions.filter { enabledRegions.contains($0.key) }.map { "🌏 \($0.title)" }
        for region in regions where enabledRegions.contains(region.key) && !existingNames.contains("🌏 \(region.title)") {
            let localNodes = nodes.filter { regionFor($0, profile: profile) == region.key }
            groupRows.append(["name": "🌏 \(region.title)", "type": "select", "proxies": localNodes.compactMap { nameByNodeID[$0.id] }.ifEmpty(["DIRECT"])])
        }
        if !generatedRegionNames.isEmpty,
           let proxyIndex = groupRows.firstIndex(where: { ($0["name"] as? String) == "PROXY" }),
           groups.first(where: { $0.name == "PROXY" }).map({ $0.members.isEmpty && !$0.membersExplicit }) == true {
            groupRows[proxyIndex]["proxies"] = generatedRegionNames
        } else if !generatedRegionNames.isEmpty, !groups.contains(where: { $0.name == "PROXY" }) {
            groupRows.insert(["name": "PROXY", "type": "select", "proxies": generatedRegionNames], at: 0)
        }
        if groupRows.isEmpty { groupRows = [["name": "PROXY", "type": "select", "proxies": nodeNames.isEmpty ? ["DIRECT"] : nodeNames]] }
        let availableTargets = Set(groupRows.compactMap { $0["name"] as? String }).union(["DIRECT", "REJECT"])
        let rules = profile.ruleProfile.rules.compactMap { serialize(rule: $0, validTargets: availableTargets) }
        let finalRules = rules + (rules.contains(where: { $0.hasPrefix("MATCH,") }) ? [] : ["MATCH,\(availableTargets.contains("PROXY") ? "PROXY" : "DIRECT")"])

        root["mixed-port"] = root["mixed-port"] ?? 7890
        root["allow-lan"] = root["allow-lan"] ?? false
        root["mode"] = root["mode"] ?? "rule"
        root["log-level"] = root["log-level"] ?? "info"
        root["ipv6"] = root["ipv6"] ?? true
        for (key, value) in profile.mihomoSettings { root[key] = value.foundationValue }
        root["proxies"] = proxyRows
        root["proxy-groups"] = groupRows
        root["rules"] = finalRules
        if proxyProviders.isEmpty { root.removeValue(forKey: "proxy-providers") }
        else { root["proxy-providers"] = proxyProviders }
        if !profile.ruleProfile.providers.isEmpty {
            root["rule-providers"] = Dictionary(uniqueKeysWithValues: profile.ruleProfile.providers.map { provider in
                let body: [String: Any] = ["type": provider.type, "behavior": provider.behavior, "format": provider.format, "path": provider.path, "url": provider.url, "interval": provider.interval]
                    .merging(provider.extra.mapValues(\.foundationValue)) { _, new in new }
                return (safeName(provider.name), body)
            })
        }
        if !profile.ruleProfile.subRules.isEmpty {
            root["sub-rules"] = Dictionary(uniqueKeysWithValues: profile.ruleProfile.subRules.map { sub in
                (safeName(sub.name), sub.rules.compactMap { serialize(rule: $0, validTargets: availableTargets, fallback: "DIRECT") })
            })
        }
        return GeneratedConfig(yaml: try Yams.dump(object: root), exportedNodes: nodes.count, skippedNodes: selectedNodes.count - nodes.count, referencedSubscriptions: providerSources.count, unresolvedTemplateProviders: unresolvedTemplateProviders)
    }

    private static func serialize(rule: RoutingRule, validTargets: Set<String>, fallback: String = "") -> String? {
        if let raw = rule.rawLine, !raw.isEmpty { return raw }
        let type = rule.type.uppercased().trimmingCharacters(in: .whitespaces)
        let target = rule.group.isEmpty ? fallback : rule.group
        guard validTargets.contains(target), !type.isEmpty else { return nil }
        if type == "MATCH" { return "MATCH,\(target)" }
        var parts = [type, rule.value, target]
        parts.append(contentsOf: rule.extraParameters)
        if rule.noResolve { parts.append("no-resolve") }
        if rule.source { parts.append("source") }
        return parts.joined(separator: ",")
    }

    private static func makeUniqueNames(_ nodes: [ProxyNode]) -> [String] {
        var counts: [String: Int] = [:]
        return nodes.map { node in
            let base = safeName(node.name).isEmpty ? "Node" : safeName(node.name)
            counts[base, default: 0] += 1
            return counts[base] == 1 ? base : "\(base)-\(counts[base]!)"
        }
    }

    private static func safeName(_ value: String) -> String { value.replacingOccurrences(of: ",", with: "，").trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func exactNamePattern(_ name: String) -> String { "^(?:" + NSRegularExpression.escapedPattern(for: name) + ")$" }

    private static func regionFor(_ node: ProxyNode, profile: ConfigProfile) -> String {
        if let override = profile.regionOverrides[node.id], regions.contains(where: { $0.key == override }) { return override }
        return regions.first { $0.key != "other" && (try? NSRegularExpression(pattern: $0.pattern, options: [.caseInsensitive]).firstMatch(in: node.name, range: NSRange(node.name.startIndex..., in: node.name))) != nil }?.key ?? "other"
    }

    private static func isSubscriptionPlaceholder(_ value: String) -> Bool {
        let marker = try? NSRegularExpression(pattern: "(?i)(\\{\\{|\\$\\{?|订阅.{0,6}(地址|链接|url)|机场.{0,6}(地址|链接|url)|your[_ -]?(subscription|url)|placeholder|replace[_ -]?me|example\\.(com|org|net))")
        let range = NSRange(value.startIndex..., in: value)
        if marker?.firstMatch(in: value, range: range) != nil { return true }
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return true }
        return false
    }
}

private extension Array where Element == String {
    func ifEmpty(_ fallback: @autoclosure () -> [String]) -> [String] { isEmpty ? fallback() : self }
}

private extension Sequence {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

enum SubscriptionParser {
    static func parse(_ text: String, sourceId: String? = nil) throws -> (nodes: [ProxyNode], skipped: Int) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { throw ServiceError.noNodes }
        if let root = try? Yams.load(yaml: raw) as? [String: Any], let proxies = root["proxies"] as? [[String: Any]] {
            let nodes = proxies.compactMap { proxy -> ProxyNode? in
                guard let name = proxy["name"] as? String, let type = proxy["type"] as? String,
                      let server = proxy["server"] as? String, let port = (proxy["port"] as? NSNumber)?.intValue else { return nil }
                var options = proxy.mapValues(JSONValue.init(foundationValue:))
                options.removeValue(forKey: "name"); options.removeValue(forKey: "type"); options.removeValue(forKey: "server"); options.removeValue(forKey: "port")
                return ProxyNode(id: UUID().uuidString, sourceId: sourceId, name: name, type: type, server: server, port: port, options: options)
            }
            if !nodes.isEmpty { return (nodes, proxies.count - nodes.count) }
        }
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let nodes = lines.compactMap { parseLink($0, sourceId: sourceId) }
        guard !nodes.isEmpty else { throw ServiceError.noNodes }
        return (nodes, lines.count - nodes.count)
    }

    private static func parseLink(_ text: String, sourceId: String?) -> ProxyNode? {
        if text.lowercased().hasPrefix("vmess://") {
            guard let data = decodeBase64(String(text.dropFirst(8))),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let host = object["add"] as? String, let port = Int("\(object["port"] ?? "")") else { return nil }
            var options: [String: JSONValue] = [:]
            options["uuid"] = JSONValue(foundationValue: object["id"] ?? "")
            options["alterId"] = JSONValue(foundationValue: object["aid"] ?? 0)
            options["cipher"] = JSONValue(foundationValue: object["scy"] ?? "auto")
            let tls = (object["tls"] as? String)?.lowercased() == "tls"
            options["tls"] = .bool(tls)
            if let sni = object["sni"] as? String, !sni.isEmpty { options["servername"] = .string(sni) }
            if let network = object["net"] as? String, network != "tcp" { options["network"] = .string(network) }
            if let path = object["path"] as? String, !path.isEmpty { options["ws-opts"] = .object(["path": .string(path)]) }
            return ProxyNode(id: UUID().uuidString, sourceId: sourceId, name: (object["ps"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host, type: "vmess", server: host, port: port, options: options)
        }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              ["ss", "ssr", "vless", "trojan", "hysteria", "hysteria2", "tuic", "anytls", "socks", "socks5", "http"].contains(scheme),
              components.port != nil else { return nil }
        if scheme == "ss", components.host == nil {
            guard let delimiter = text.range(of: "://") else { return nil }
            let payload = String(text[delimiter.upperBound...]).components(separatedBy: "?").first ?? ""
            let decoded = payload.removingPercentEncoding.flatMap(decodeBase64).flatMap { String(data: $0, encoding: .utf8) }
            guard let decoded, decoded.contains("@") else { return nil }
            return parseLink("ss://\(decoded)\(components.fragment.map { "#\($0)" } ?? "")", sourceId: sourceId)
        }
        guard let host = components.host, let port = components.port else { return nil }
        let name = components.fragment?.removingPercentEncoding ?? host
        var options: [String: JSONValue] = [:]
        let user = components.user?.removingPercentEncoding ?? ""
        let password = components.password?.removingPercentEncoding ?? ""
        if scheme == "ss", !user.isEmpty {
            options["cipher"] = .string(user)
            options["password"] = .string(password)
        } else if !user.isEmpty {
            if scheme == "vless" || scheme == "tuic" { options["uuid"] = .string(user) }
            else { options["password"] = .string(user) }
        }
        if !password.isEmpty && scheme != "ss" { options["password"] = .string(password) }
        if let fragment = components.fragment, !fragment.isEmpty { options["tls"] = .bool(["trojan", "hysteria", "hysteria2", "tuic", "anytls"].contains(scheme) || components.queryItems?.contains(where: { $0.name == "security" && $0.value == "tls" }) == true) }
        for item in components.queryItems ?? [] where ["sni", "servername", "flow", "network", "type"].contains(item.name) {
            options[item.name == "sni" ? "servername" : item.name] = .string(item.value ?? "")
        }
        return ProxyNode(id: UUID().uuidString, sourceId: sourceId, name: name, type: scheme == "socks" ? "socks5" : scheme, server: host, port: port, options: options)
    }

    private static func decodeBase64(_ source: String) -> Data? {
        var value = source.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }
}

enum RuleDiagnostics {
    static func inspect(_ profile: ConfigProfile, nodeIDs: Set<String>) -> [String] {
        let groupNames = Set(profile.ruleProfile.groups.map(\.name)).union(["DIRECT", "REJECT"])
        var issues: [String] = []
        for group in profile.ruleProfile.groups where group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("策略组名称不能为空。") }
        for group in profile.ruleProfile.groups {
            for member in group.members where member.hasPrefix("node:") && !nodeIDs.contains(String(member.dropFirst(5))) { issues.append("策略组「\(group.name)」引用了不存在的节点。") }
        }
        for (index, rule) in profile.ruleProfile.rules.enumerated() where !groupNames.contains(rule.group) && !rule.type.uppercased().contains("RULE-SET") {
            issues.append("第 \(index + 1) 条规则指向未知策略「\(rule.group)」。")
        }
        if !profile.ruleProfile.rules.contains(where: { $0.type.uppercased() == "MATCH" }) { issues.append("规则末尾缺少 MATCH 兜底项，导出时会自动补充。") }
        return issues
    }
}

enum RuleSimulator {
    static func match(_ input: String, rules: [RoutingRule]) -> RoutingRule? {
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rules.first { rule in
            let value = rule.value.lowercased()
            return switch rule.type.uppercased() {
            case "DOMAIN": candidate == value
            case "DOMAIN-SUFFIX": candidate == value || candidate.hasSuffix("." + value)
            case "DOMAIN-KEYWORD": candidate.contains(value)
            case "MATCH": true
            default: false
            }
        }
    }
}

enum ServiceError: LocalizedError {
    case noNodes
    case invalidURL
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .noNodes: "没有识别到受支持的节点内容。"
        case .invalidURL: "请输入有效的 HTTP 或 HTTPS 地址。"
        case .httpStatus(let status): "服务器返回 HTTP \(status)。"
        }
    }
}

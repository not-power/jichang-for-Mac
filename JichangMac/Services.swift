import Foundation
import Yams

struct GeneratedConfig: Sendable {
    var yaml: String
    var exportedNodes: Int
    var skippedNodes: Int
    var referencedSubscriptions: Int = 0
    var unresolvedTemplateProviders: [String] = []
    var templateProviders: [String] = []
    var issues: [ConfigIssue] = []
    var canExport: Bool { !issues.contains { $0.severity == .error } }
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
        var root = try ConfigDocument.effective(state, profile: profile).mapValues(\.foundationValue)
        let selectedSources = state.sources.filter { profile.selectedSourceIds.contains($0.id) }
        let selectedSourceIds = Set(selectedSources.map(\.id))
        let selectedNodes = state.nodes.filter { profile.enabledNodeIds.contains($0.id) && ($0.sourceId == nil || selectedSourceIds.contains($0.sourceId!)) }
        let referenceMode = profile.sourceMode == "REFERENCE_SUBSCRIPTIONS"
        var proxyProviders = root["proxy-providers"] as? [String: Any] ?? [:]
        let templatePlaceholderNames = proxyProviders.compactMap { name, value -> String? in
            guard let body = value as? [String: Any], (body["type"] as? String)?.lowercased() == "http" else { return nil }
            return isSubscriptionPlaceholder(body["url"] as? String ?? "") ? name : nil
        }.sorted()
        let eligibleSources = selectedSources.filter { $0.providerCompatible == true }
        let boundTemplates: [(String, SubscriptionSource)] = templatePlaceholderNames.compactMap { name in
            guard let source = profile.templateProviderBindings[name].flatMap({ id in eligibleSources.first { $0.id == id } }) else { return nil }
            return (name, source)
        }
        for (name, source) in boundTemplates {
            var body = proxyProviders[name] as? [String: Any] ?? [:]
            body["url"] = source.url
            proxyProviders[name] = body
        }
        let boundSourceIDs = Set(boundTemplates.map { $0.1.id })
        let providerSources = eligibleSources.filter { referenceMode || boundSourceIDs.contains($0.id) }
        let providerSourceIDs = Set(providerSources.map(\.id))
        let nodes = selectedNodes.filter { supportedNodeTypes.contains($0.type.lowercased()) && ($0.sourceId == nil || !providerSourceIDs.contains($0.sourceId!)) }
        let nodeNames = makeUniqueNames(nodes)
        let nameByNodeID = Dictionary(zip(nodes.map(\.id), nodeNames), uniquingKeysWith: { first, _ in first })
        let allNodeNames = Dictionary(selectedNodes.map { ($0.id, safeName($0.name)) }, uniquingKeysWith: { first, _ in first })
        let unresolvedTemplateProviders = templatePlaceholderNames.filter { name in !boundTemplates.contains(where: { $0.0 == name }) }
        for name in unresolvedTemplateProviders { proxyProviders.removeValue(forKey: name) }
        let genericSources = providerSources.filter { !boundSourceIDs.contains($0.id) }
        var usedProviderNames = Set(proxyProviders.keys).union(templatePlaceholderNames)
        let genericProviderNames = genericSources.indices.map { index in
            var name = "订阅-\(index + 1)"
            while usedProviderNames.contains(name) { name += "-" }
            usedProviderNames.insert(name)
            return name
        }
        for (index, source) in genericSources.enumerated() {
            proxyProviders[genericProviderNames[index]] = [
                "type": "http", "url": source.url, "path": "./providers/\(genericProviderNames[index]).yaml",
                "interval": 86400, "health-check": ["enable": true, "url": "https://www.gstatic.com/generate_204", "interval": 300]
            ]
        }
        let providerNames = boundTemplates.map(\.0) + genericProviderNames
        let enabledRegions = profile.enabledRegions
        let proxyRows = nodes.map { node -> [String: Any] in
            var proxy = node.options.mapValues(\.foundationValue)
            proxy["name"] = nameByNodeID[node.id] ?? safeName(node.name)
            proxy["type"] = node.type.lowercased() == "socks" ? "socks5" : node.type.lowercased()
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
            for (key, value) in group.extra where !["name", "type", "proxies"].contains(key) { row[key] = value.foundationValue }
            let referencesRemote = !providerNames.isEmpty && (isImplicitAll || group.members.contains { member in
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
            // Only groups affected by an omitted placeholder receive a local fallback.
            // An independently configured empty group keeps its explicit empty members.
            let originalUse = group.extra["use"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let omittedUse = originalUse.contains { unresolvedTemplateProviders.contains($0) }
            if let use = row["use"] as? [String] { row["use"] = use.filter { !unresolvedTemplateProviders.contains($0) } }
            let includesProviders = row["include-all"] as? Bool == true || row["include-all-providers"] as? Bool == true
            let omittedAutomaticProviders = includesProviders && !unresolvedTemplateProviders.isEmpty && proxyProviders.isEmpty
            if (omittedUse || omittedAutomaticProviders), (row["proxies"] as? [String] ?? []).isEmpty,
               (row["use"] as? [String] ?? []).isEmpty, !(includesProviders && !proxyProviders.isEmpty) {
                row["proxies"] = nodeNames.isEmpty ? ["DIRECT"] : nodeNames
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
            var row: [String: Any] = ["name": "🌏 \(region.title)", "type": "select", "proxies": localNodes.compactMap { nameByNodeID[$0.id] }]
            if !providerNames.isEmpty {
                row["use"] = providerNames
                row["filter"] = region.key == "other" ? "(?i)^(?!.*(?:" + regions.filter { $0.key != "other" }.map(\.pattern).joined(separator: "|") + ")).*$" : "(?i)" + region.pattern
            } else if localNodes.isEmpty { row["proxies"] = ["DIRECT"] }
            groupRows.append(row)
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
        let rules = try profile.ruleProfile.rules.map(RuleCodec.serialize)
        let finalRules = rules + (rules.contains(where: { $0.hasPrefix("MATCH,") }) ? [] : ["MATCH,\(availableTargets.contains("PROXY") ? "PROXY" : "DIRECT")"])

        root["proxies"] = proxyRows
        root["proxy-groups"] = groupRows
        root["rules"] = finalRules
        if proxyProviders.isEmpty { root.removeValue(forKey: "proxy-providers") }
        else { root["proxy-providers"] = proxyProviders }
        root["rule-providers"] = Dictionary(profile.ruleProfile.providers.map { provider in
            var body = provider.extra.mapValues(\.foundationValue)
            body["type"] = provider.type; body["behavior"] = provider.behavior
            body["format"] = provider.format
            if provider.type == "http" { body["url"] = provider.url; body["interval"] = provider.interval; body["header"] = provider.headers }
            else { body.removeValue(forKey: "url"); body.removeValue(forKey: "interval"); body.removeValue(forKey: "header") }
            if provider.type == "inline" { body["payload"] = provider.payload; body.removeValue(forKey: "path") }
            else { body.removeValue(forKey: "payload"); if !provider.path.isEmpty { body["path"] = provider.path } else { body.removeValue(forKey: "path") } }
            return (provider.name, body)
        }, uniquingKeysWith: { first, _ in first })
        root["sub-rules"] = Dictionary(try profile.ruleProfile.subRules.map { sub in
            (sub.name, try sub.rules.map(RuleCodec.serialize))
        }, uniquingKeysWith: { first, _ in first })
        let values = root.mapValues(JSONValue.init(foundationValue:))
        var issues = ConfigurationDiagnostics.inspect(state, profile: profile, root: values)
        for name in unresolvedTemplateProviders {
            issues.append(ConfigIssue(severity: .warning, location: "代理集合.\(name)", message: "未绑定的订阅占位符已跳过；相关空组使用本地节点，无节点时使用直连。可在分享页面选择绑定。"))
        }
        for node in selectedNodes where !supportedNodeTypes.contains(node.type.lowercased()) {
            issues.append(ConfigIssue(severity: .error, location: "节点.\(node.name)", message: "当前版本不支持此协议：\(node.type)，不能静默忽略。"))
        }
        for node in nodes where node.server.isEmpty || !(1...65535).contains(node.port) {
            issues.append(ConfigIssue(severity: .error, location: "节点.\(node.name)", message: "服务器或端口无效。"))
        }
        return GeneratedConfig(yaml: try ConfigDocument.dump(values), exportedNodes: nodes.count, skippedNodes: selectedNodes.filter { !supportedNodeTypes.contains($0.type.lowercased()) }.count, referencedSubscriptions: providerSources.count, unresolvedTemplateProviders: unresolvedTemplateProviders, templateProviders: templatePlaceholderNames, issues: issues)
    }

    private static func makeUniqueNames(_ nodes: [ProxyNode]) -> [String] {
        var used = Set<String>()
        return nodes.map { node in
            let base = safeName(node.name).isEmpty ? "Node" : safeName(node.name)
            var name = base, suffix = 2
            while used.contains(name) { name = "\(base)-\(suffix)"; suffix += 1 }
            used.insert(name)
            return name
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
    @concurrent
    static func parseInBackground(_ text: String, sourceId: String?) async throws -> (nodes: [ProxyNode], skipped: Int) {
        try parse(text, sourceId: sourceId)
    }
    static func isProviderCompatible(_ text: String) -> Bool {
        guard let root = try? Yams.load(yaml: text) as? [String: Any] else { return false }
        return root["proxies"] is [[String: Any]]
    }
    static func parse(_ text: String, sourceId: String? = nil) throws -> (nodes: [ProxyNode], skipped: Int) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
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
        if !raw.contains("://"), let decoded = decodeBase64(raw.filter { !$0.isWhitespace }), let expanded = String(data: decoded, encoding: .utf8), expanded.contains("://") {
            return try parse(expanded, sourceId: sourceId)
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
            let decoded = decodeBase64(user).flatMap { String(data: $0, encoding: .utf8) }
            let credential = decoded?.split(separator: ":", maxSplits: 1).map(String.init) ?? []
            options["cipher"] = .string(credential.count == 2 ? credential[0] : user)
            options["password"] = .string(credential.count == 2 ? credential[1] : password)
        } else if !user.isEmpty {
            if scheme == "vless" || scheme == "tuic" { options["uuid"] = .string(user) }
            else { options["password"] = .string(user) }
        }
        if !password.isEmpty && scheme != "ss" { options["password"] = .string(password) }
        options["tls"] = .bool(["trojan", "hysteria", "hysteria2", "tuic", "anytls"].contains(scheme) || components.queryItems?.contains(where: { $0.name == "security" && $0.value == "tls" }) == true)
        for item in components.queryItems ?? [] where ["sni", "servername", "flow", "network", "type"].contains(item.name) {
            let key = item.name == "sni" ? "servername" : (item.name == "type" ? "network" : item.name)
            if key != "network" || item.value != "tcp" { options[key] = .string(item.value ?? "") }
        }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if ["ws", "http"].contains(query["type"] ?? query["network"] ?? "") {
            var ws: [String: JSONValue] = [:]
            if let path = query["path"] { ws["path"] = .string(path) }
            if let host = query["host"] { ws["headers"] = .object(["Host": .string(host)]) }
            if !ws.isEmpty { options["ws-opts"] = .object(ws) }
        }
        if query["type"] == "grpc", let service = query["serviceName"] { options["grpc-opts"] = .object(["grpc-service-name": .string(service)]) }
        if let insecure = query["allowInsecure"] ?? query["insecure"] { options["skip-cert-verify"] = .bool(insecure == "1" || insecure == "true") }
        if let alpn = query["alpn"] { options["alpn"] = .array(alpn.split(separator: ",").map { .string(String($0)) }) }
        if let fingerprint = query["fp"] { options["client-fingerprint"] = .string(fingerprint) }
        if scheme == "tuic", let relay = query["udp_relay_mode"] { options["udp-relay-mode"] = .string(relay) }
        return ProxyNode(id: UUID().uuidString, sourceId: sourceId, name: name, type: scheme == "socks" ? "socks5" : scheme, server: host, port: port, options: options)
    }

    private static func decodeBase64(_ source: String) -> Data? {
        var value = source.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
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

import Foundation
import Yams

struct ConfigIssue: Equatable, Sendable {
    enum Severity: String, Sendable { case error = "错误", warning = "警告", unchecked = "未检查" }
    let severity: Severity
    let location: String
    let message: String
    var description: String { "【\(severity.rawValue)】\(location)：\(message)" }
}

enum ConfigDocument {
    static let managed: Set<String> = ["proxies", "proxy-groups", "rules", "rule-providers", "sub-rules"]
    static let builtins: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "PASS-RULE", "COMPATIBLE"]
    static let defaults: [String: JSONValue] = ["mixed-port": .integer(7890), "mode": .string("rule"), "log-level": .string("info"), "allow-lan": .bool(false), "ipv6": .bool(true)]

    static func parse(_ text: String) throws -> [String: JSONValue] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        do {
            guard let root = try Yams.load(yaml: text) as? [String: Any] else { throw ConfigError.message("YAML 根节点必须是配置对象。") }
            return root.mapValues(JSONValue.init(foundationValue:))
        } catch let error as YamlError {
            switch error {
            case .scanner(_, let problem, let mark, _), .parser(_, let problem, let mark, _), .composer(_, let problem, let mark, _):
                throw ConfigError.message("YAML 第 \(mark.line) 行、第 \(mark.column) 列：\(problem)")
            default: throw ConfigError.message("YAML 格式无效：\(error)")
            }
        }
    }

    static func dump(_ values: [String: JSONValue]) throws -> String {
        let yaml = try Yams.dump(object: values.mapValues(\.foundationValue), allowUnicode: true)
        return try readableSupplementaryUnicode(yaml)
    }
    // libYAML still escapes supplementary scalars (emoji and some CJK characters).
    // Replace only parsed double-quoted string tokens; literal backslash sequences stay intact.
    private static func readableSupplementaryUnicode(_ yaml: String) throws -> String {
        guard yaml.contains("\\U"), let root = try Yams.compose(yaml: yaml) else { return yaml }
        var strings: [Node.Scalar] = []
        func collect(_ node: Node) {
            switch node {
            case .scalar(let scalar):
                if scalar.style == .doubleQuoted, scalar.string.unicodeScalars.contains(where: { $0.value > 0xFFFF }) { strings.append(scalar) }
            case .sequence(let sequence): sequence.forEach(collect)
            case .mapping(let mapping): mapping.forEach { collect($0.key); collect($0.value) }
            case .alias: break
            }
        }
        collect(root)
        guard !strings.isEmpty else { return yaml }
        var scalars = Array(yaml.unicodeScalars)
        let lineStarts = [0] + scalars.indices.filter { scalars[$0] == "\n" }.map { $0 + 1 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var replacements: [(range: Range<Int>, value: [Unicode.Scalar])] = []
        for string in strings {
            guard let mark = string.mark, lineStarts.indices.contains(mark.line - 1) else { continue }
            let start = lineStarts[mark.line - 1] + mark.column - 1
            guard scalars.indices.contains(start), scalars[start] == "\"" else { continue }
            var end = start + 1
            while end < scalars.count {
                if scalars[end] == "\\" { end += 2; continue }
                if scalars[end] == "\"" { break }
                end += 1
            }
            guard end < scalars.count else { continue }
            let encoded = try encoder.encode(string.string)
            guard let text = String(data: encoded, encoding: .utf8) else { throw ConfigError.message("YAML 字符串无法编码为 UTF-8。") }
            replacements.append((start..<end + 1, Array(text.unicodeScalars)))
        }
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            scalars.replaceSubrange(replacement.range, with: replacement.value)
        }
        return String(String.UnicodeScalarView(scalars))
    }
    static func merge(_ base: [String: JSONValue], _ override: [String: JSONValue]) -> [String: JSONValue] {
        base.merging(override) { old, new in
            if case .object(let left) = old, case .object(let right) = new { return .object(merge(left, right)) }
            return new
        }
    }
    static func inherited(_ state: AppState, profile: ConfigProfile) throws -> [String: JSONValue] {
        let template = state.templates.first { $0.id == profile.templateId }
        return merge(merge(defaults, try parse(template?.rawYaml ?? "")), try parse(profile.advancedYaml ?? ""))
    }
    static func effective(_ state: AppState, profile: ConfigProfile) throws -> [String: JSONValue] {
        merge(try inherited(state, profile: profile), profile.mihomoSettings)
    }
    static func value(_ root: [String: JSONValue], at path: String) -> JSONValue? {
        let parts = path.split(separator: ".").map(String.init)
        var dictionary = root
        for (index, key) in parts.enumerated() {
            if index == parts.count - 1 { return dictionary[key] }
            guard case .object(let object)? = dictionary[key] else { return nil }
            dictionary = object
        }
        return nil
    }
    static func set(_ root: inout [String: JSONValue], at path: String, to value: JSONValue?) {
        var parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first else { return }
        parts.removeFirst()
        if parts.isEmpty { root[first] = value; return }
        var child: [String: JSONValue] = [:]
        if case .object(let existing)? = root[first] { child = existing }
        set(&child, at: parts.joined(separator: "."), to: value)
        root[first] = child.isEmpty ? nil : .object(child)
    }
}

enum ConfigError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

enum RuleCodec {
    static let types = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-WILDCARD", "DOMAIN-REGEX", "GEOSITE", "IP-CIDR", "IP-CIDR6", "IP-SUFFIX", "IP-ASN", "GEOIP", "SRC-GEOIP", "SRC-IP-ASN", "SRC-IP-CIDR", "SRC-IP-SUFFIX", "DST-PORT", "SRC-PORT", "IN-PORT", "IN-TYPE", "IN-USER", "IN-NAME", "REMATCH-NAME", "PROCESS-PATH", "PROCESS-PATH-WILDCARD", "PROCESS-PATH-REGEX", "PROCESS-NAME", "PROCESS-NAME-WILDCARD", "PROCESS-NAME-REGEX", "UID", "NETWORK", "DSCP", "RULE-SET", "AND", "OR", "NOT", "SUB-RULE", "MATCH"]
    static func split(_ line: String) throws -> [String] {
        var parts: [String] = [], part = "", depth = 0, escaped = false
        for character in line {
            if escaped { part.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; part.append(character); continue }
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1; if depth < 0 { throw ConfigError.message("规则括号不匹配。") } }
            if character == "," && depth == 0 { parts.append(part.trimmingCharacters(in: .whitespaces)); part = "" }
            else { part.append(character) }
        }
        guard depth == 0 else { throw ConfigError.message("规则括号不匹配。") }
        parts.append(part.trimmingCharacters(in: .whitespaces))
        return parts
    }
    static func parse(_ line: String) throws -> RoutingRule {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = try split(line)
        let type = parts.first?.uppercased() ?? ""
        let targetIndex = type == "MATCH" ? 1 : 2
        guard parts.count > targetIndex, !type.isEmpty, !parts[targetIndex].isEmpty,
              type == "MATCH" || !parts[1].isEmpty else { throw ConfigError.message("规则需要类型、匹配值和目标；MATCH 只需要目标。") }
        let extras = Array(parts.dropFirst(targetIndex + 1))
        return RoutingRule(type: type, value: type == "MATCH" ? "" : parts[1], group: parts[targetIndex],
                           noResolve: extras.contains("no-resolve"), source: extras.contains("src") || extras.contains("source"),
                           extraParameters: extras.filter { !["src", "source", "no-resolve"].contains($0) }, rawLine: line)
    }
    static func parseLines(_ text: String) throws -> [RoutingRule] {
        try text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.isEmpty || clean.hasPrefix("#") { return nil }
            do { return try parse(clean) }
            catch { throw ConfigError.message("第 \(index + 1) 行：\(error.localizedDescription)") }
        }
    }
    static func condition(_ value: RuleCondition) throws -> String {
        if let op = value.groupOperator {
            guard ["AND", "OR", "NOT"].contains(op.uppercased()), !value.children.isEmpty,
                  op.uppercased() != "NOT" || value.children.count == 1 else { throw ConfigError.message("组合条件的类型或子条件数量无效。") }
            return "(\(op.uppercased()),(\(try value.children.map(condition).joined(separator: ","))))"
        }
        guard let type = value.type, !type.isEmpty, !value.value.isEmpty else { throw ConfigError.message("组合条件不完整。") }
        var parts = [type.uppercased(), value.value]
        if let argument = value.argument, !argument.isEmpty { parts.append(argument) }
        if value.noResolve { parts.append("no-resolve") }
        if value.source { parts.append("src") }
        return "(\(parts.joined(separator: ",")))"
    }
    static func serialize(_ rule: RoutingRule) throws -> String {
        if let raw = rule.rawLine, !raw.isEmpty {
            var parsed = try parse(raw)
            parsed.rawLine = nil
            return try serialize(parsed)
        }
        let type = rule.type.uppercased()
        guard !rule.group.isEmpty else { throw ConfigError.message("规则缺少目标。") }
        if type == "MATCH" { return "MATCH,\(rule.group)" }
        let expression: String
        if !rule.conditions.isEmpty {
            if type == "SUB-RULE" { expression = try rule.conditions.map(condition).joined(separator: ",") }
            else { expression = "(\(try rule.conditions.map(condition).joined(separator: ",")))" }
        } else { expression = rule.value }
        guard !type.isEmpty, !expression.isEmpty else { throw ConfigError.message("规则缺少匹配条件。") }
        var parts = [type, expression, rule.group]
        parts.append(contentsOf: rule.extraParameters.filter { !["source", "src", "no-resolve"].contains($0) })
        if rule.noResolve { parts.append("no-resolve") }
        if rule.source { parts.append("src") }
        let result = parts.joined(separator: ",")
        _ = try parse(result)
        return result
    }
    static func renameTarget(_ rule: RoutingRule, from old: String, to new: String, subRule: Bool = false) -> RoutingRule {
        var result = rule
        if let raw = result.rawLine, let parsed = try? parse(raw) { result = parsed; result.conditions = rule.conditions }
        if result.group == old && (result.type.uppercased() == "SUB-RULE") == subRule {
            result.group = new; result.rawLine = nil
        }
        return result
    }
}

enum ProfileReferences {
    static func rename(_ profile: inout ConfigProfile, from old: String, to new: String, kind: String) {
        func changed(_ rule: RoutingRule) -> RoutingRule {
            if kind == "provider" {
                var result = (rule.rawLine.flatMap { try? RuleCodec.parse($0) }) ?? rule
                if result.type == "RULE-SET", result.value == old { result.value = new; result.rawLine = nil }
                result.conditions = rule.conditions.map(changeCondition)
                if result.conditions != rule.conditions { result.rawLine = nil }
                // Nested RULE-SET conditions in imported raw expressions.
                if let raw = result.rawLine {
                    let token = "(RULE-SET,\(old),"
                    if raw.contains(token) { result.rawLine = raw.replacingOccurrences(of: token, with: "(RULE-SET,\(new),") }
                    else { result.rawLine = raw.replacingOccurrences(of: "(RULE-SET,\(old))", with: "(RULE-SET,\(new))") }
                }
                return result
            }
            return RuleCodec.renameTarget(rule, from: old, to: new, subRule: kind == "subRule")
        }
        func changeCondition(_ condition: RuleCondition) -> RuleCondition {
            var value = condition
            if value.type == "RULE-SET", value.value == old { value.value = new }
            value.children = value.children.map(changeCondition)
            return value
        }
        profile.ruleProfile.rules = profile.ruleProfile.rules.map(changed)
        for index in profile.ruleProfile.subRules.indices { profile.ruleProfile.subRules[index].rules = profile.ruleProfile.subRules[index].rules.map(changed) }
        if kind == "group" {
            for index in profile.ruleProfile.groups.indices {
                profile.ruleProfile.groups[index].members = profile.ruleProfile.groups[index].members.map { $0 == old ? new : $0 }
                for key in ["default-selected", "empty-fallback"] where profile.ruleProfile.groups[index].extra[key] == .string(old) { profile.ruleProfile.groups[index].extra[key] = .string(new) }
            }
            for index in profile.ruleProfile.providers.indices where profile.ruleProfile.providers[index].extra["proxy"] == .string(old) { profile.ruleProfile.providers[index].extra["proxy"] = .string(new) }
        }
    }
}

enum ConfigurationDiagnostics {
    static func inspect(_ state: AppState, profile: ConfigProfile, root: [String: JSONValue]) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        func add(_ location: String, _ message: String, _ severity: ConfigIssue.Severity = .error) { issues.append(ConfigIssue(severity: severity, location: location, message: message)) }
        func duplicate(_ names: [String], at location: String) {
            for (name, values) in Dictionary(grouping: names, by: { $0 }) where values.count > 1 { add(location, "名称重复：\(name)") }
            for name in names where name.isEmpty || name.contains(",") { add(location, "名称不能为空或包含英文逗号。") }
        }
        duplicate(profile.ruleProfile.groups.map(\.name), at: "策略组")
        duplicate(profile.ruleProfile.providers.map(\.name), at: "规则集")
        duplicate(profile.ruleProfile.subRules.map(\.name), at: "子规则")
        let groupRows = root["proxy-groups"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let proxyNames = Set(root["proxies"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? [])
        let groupNames = Set(groupRows.compactMap { $0["name"]?.stringValue })
        let targets = groupNames.union(proxyNames).union(ConfigDocument.builtins)
        let providerNames = Set(root["rule-providers"]?.objectValue?.keys.map { $0 } ?? [])
        let proxyProviders = Set(root["proxy-providers"]?.objectValue?.keys.map { $0 } ?? [])
        let subNames = Set(profile.ruleProfile.subRules.map(\.name))
        var groupEdges: [String: [String]] = [:], subEdges: [String: [String]] = [:]
        for row in groupRows {
            let name = row["name"]?.stringValue ?? "?"
            let members = row["proxies"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if proxyNames.contains(name) || ConfigDocument.builtins.contains(name) { add("策略组.\(name)", "名称与节点或内置策略冲突。") }
            for member in members where !targets.contains(member) { add("策略组.\(name)", "成员不存在：\(member)") }
            for use in row["use"]?.arrayValue?.compactMap(\.stringValue) ?? [] where !proxyProviders.contains(use) { add("策略组.\(name).use", "代理集合不存在：\(use)") }
            groupEdges[name] = members.filter { groupNames.contains($0) }
            if let type = row["type"]?.stringValue, !["select", "url-test", "fallback", "load-balance", "relay"].contains(type) { add("策略组.\(name).type", "未知类型：\(type)") }
            if row["type"]?.stringValue == "relay" { add("策略组.\(name)", "relay 已弃用，请考虑 dialer-proxy。", .warning) }
            for key in ["interval", "timeout", "tolerance", "max-failed-times"] {
                if let value = row[key] {
                    if case .integer(let number) = value, number >= 0 {} else { add("策略组.\(name).\(key)", "需要非负整数。") }
                }
            }
            for key in ["lazy", "disable-udp", "include-all", "include-all-proxies", "include-all-providers", "hidden"] {
                if let value = row[key], value.boolValue == nil { add("策略组.\(name).\(key)", "需要 true 或 false。") }
            }
            for key in ["url", "filter", "exclude-filter", "exclude-type", "strategy", "expected-status", "default-selected", "empty-fallback", "icon"] {
                if let value = row[key], value.stringValue == nil { add("策略组.\(name).\(key)", "需要文本。") }
            }
            if let strategy = row["strategy"]?.stringValue, !["consistent-hashing", "round-robin", "sticky-sessions"].contains(strategy) { add("策略组.\(name).strategy", "负载均衡策略无效。") }
        }
        for group in profile.ruleProfile.groups {
            for member in group.members where member.hasPrefix("node:") {
                let id = String(member.dropFirst(5))
                if !state.nodes.contains(where: { $0.id == id }) || !profile.enabledNodeIds.contains(id) { add("策略组.\(group.name)", "引用了不存在或未启用的节点。") }
            }
        }
        func inspectRules(_ rules: [RoutingRule], at location: String) {
            for (index, rule) in rules.enumerated() {
                let path = "\(location)[\(index + 1)]"
                do {
                    let line = try RuleCodec.serialize(rule), parsed = try RuleCodec.parse(line)
                    if !RuleCodec.types.contains(parsed.type) { add(path, "规则类型尚未检查：\(parsed.type)", .unchecked) }
                    if parsed.type == "SUB-RULE" {
                        if !subNames.contains(parsed.group) { add(path, "子规则不存在：\(parsed.group)") }
                        if location.hasPrefix("子规则.") { subEdges[String(location.dropFirst(4)), default: []].append(parsed.group) }
                    } else if !targets.contains(parsed.group) { add(path, "目标不存在：\(parsed.group)") }
                    if parsed.type == "RULE-SET", !providerNames.contains(parsed.value) { add(path, "规则集不存在：\(parsed.value)") }
                    let pattern = #"\(RULE-SET,([^,()]+)"#
                    if let regex = try? NSRegularExpression(pattern: pattern) {
                        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                            if let range = Range(match.range(at: 1), in: line), !providerNames.contains(String(line[range])) { add(path, "组合条件中的规则集不存在：\(line[range])") }
                        }
                    }
                    if ["AND", "OR", "NOT"].contains(parsed.type) || parsed.type == "SUB-RULE" {
                        if !parsed.value.hasPrefix("(") || !parsed.value.hasSuffix(")") { add(path, "组合条件必须使用括号。") }
                    }
                    if parsed.type == "MATCH", index < rules.count - 1 { add(path, "后续规则不会被匹配。", .warning) }
                } catch { add(path, error.localizedDescription) }
            }
        }
        inspectRules(profile.ruleProfile.rules, at: "规则")
        for sub in profile.ruleProfile.subRules { inspectRules(sub.rules, at: "子规则.\(sub.name)") }
        func cycles(_ edges: [String: [String]], at location: String) {
            var visited = Set<String>(), active = Set<String>()
            func visit(_ name: String) {
                if active.contains(name) { add(location, "存在循环引用：\(name)"); return }
                if !visited.insert(name).inserted { return }
                active.insert(name)
                for next in edges[name] ?? [] { visit(next) }
                active.remove(name)
            }
            for name in edges.keys.sorted() { visit(name) }
        }
        cycles(groupEdges, at: "策略组"); cycles(subEdges, at: "子规则")
        if !profile.ruleProfile.rules.contains(where: { $0.type.uppercased() == "MATCH" }) { add("规则", "导出时自动补充 MATCH 兜底规则。", .warning) }
        for provider in profile.ruleProfile.providers {
            let path = "规则集.\(provider.name)"
            if !["http", "file", "inline"].contains(provider.type) { add(path, "来源类型无效。") }
            if provider.type == "http", !validURL(provider.url) { add(path, "HTTP 来源需要有效的 HTTP(S) 地址。") }
            if provider.type == "file", provider.path.isEmpty { add(path, "文件来源需要路径。") }
            if !["domain", "ipcidr", "classical"].contains(provider.behavior) { add(path, "behavior 无效。") }
            if !["yaml", "text", "mrs"].contains(provider.format) || (provider.format == "mrs" && (provider.behavior == "classical" || provider.type == "inline")) { add(path, "规则集格式组合无效。") }
            if provider.interval < 0 { add(path, "刷新间隔不能为负。") }
            if let target = provider.extra["proxy"]?.stringValue, !targets.contains(target) { add(path, "下载代理不存在：\(target)") }
        }
        let paths = profile.ruleProfile.providers.map(\.path).filter { !$0.isEmpty }
        if Set(paths).count != paths.count { add("规则集.path", "缓存路径不能重复。") }
        for section in ["dns", "tun", "sniffer"] {
            if let value = root[section], value.objectValue == nil { add(section, "配置段需要 YAML 对象。") }
        }
        if Set(state.nodes.map(\.id)).count != state.nodes.count { add("节点", "节点 ID 重复，请重新导入。"); }
        for row in groupRows {
            let name = row["name"]?.stringValue ?? "?"
            for key in ["filter", "exclude-filter"] {
                if let pattern = row[key]?.stringValue, !pattern.isEmpty, (try? NSRegularExpression(pattern: pattern)) == nil { add("策略组.\(name).\(key)", "正则表达式无效。") }
            }
            for key in ["proxies", "use"] {
                if let value = row[key], value.arrayValue?.allSatisfy({ $0.stringValue != nil }) != true { add("策略组.\(name).\(key)", "需要文本列表。") }
            }
        }
        for field in SettingsCatalog.all {
            guard let value = ConfigDocument.value(root, at: field.path) else { continue }
            if let error = field.validate(value) { add(field.path, error) }
        }
        if ConfigDocument.value(root, at: "dns.respect-rules") == .bool(true),
           ConfigDocument.value(root, at: "dns.proxy-server-nameserver")?.arrayValue?.isEmpty != false { add("dns.proxy-server-nameserver", "respect-rules 开启时需要节点域名解析服务器。") }
        for path in ["tproxy-port", "routing-mark", "external-controller-pipe", "tun.auto-redirect", "tun.gso", "tun.gso-max-size", "tun.route-address-set", "tun.route-exclude-address-set", "tun.include-uid", "tun.include-uid-range", "tun.exclude-uid", "tun.exclude-uid-range", "tun.include-android-user", "tun.include-mac-address", "tun.exclude-mac-address", "tun.include-package", "tun.exclude-package", "tun.iproute2-table-index", "tun.iproute2-rule-index"] where ConfigDocument.value(root, at: path) != nil { add(path, "此项不适用于 macOS；已保留导出。", .warning) }
        if let advanced = try? ConfigDocument.parse(profile.advancedYaml ?? "") {
            for key in advanced.keys.sorted() where ConfigDocument.managed.contains(key) { add("高级 YAML.\(key)", "此字段由管理列表生成，高级 YAML 内容不会覆盖列表。", .warning) }
            func conflicts(_ values: [String: JSONValue], prefix: String = "") {
                for (key, value) in values {
                    let path = prefix.isEmpty ? key : prefix + "." + key
                    if case .object(let object) = value { conflicts(object, prefix: path) }
                    else if let original = ConfigDocument.value(advanced, at: path), original != value { add(path, "表单设置覆盖了高级 YAML 中的同名字段。", .warning) }
                }
            }
            conflicts(profile.mihomoSettings)
        }
        return issues
    }
    static func validURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let host = url.host, !host.isEmpty else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

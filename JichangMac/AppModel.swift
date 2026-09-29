import Foundation
import Observation
import CryptoKit
import Yams

@MainActor @Observable
final class AppModel {
    var state: AppState
    var notice: String?
    var isWorking = false
    var searchText = ""
    var generatedConfig: GeneratedConfig?

    private let stateURL: URL
    private let cacheRoot: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Jichang", isDirectory: true)
        stateURL = support.appendingPathComponent("state.json")
        cacheRoot = support.appendingPathComponent("rule-providers", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? Data(contentsOf: stateURL), let loaded = try? JSONDecoder().decode(AppState.self, from: data) {
            state = loaded.profiles.isEmpty ? AppState() : loaded
        } else {
            state = AppState()
        }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: stateURL.path) { persist() }
        regenerate()
    }

    var activeProfile: ConfigProfile { state.activeProfile }

    func persist() {
        do {
            let data = try encoder.encode(state)
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: stateURL, options: .atomic)
            regenerate()
        } catch { notice = "保存失败：\(error.localizedDescription)" }
    }

    func regenerate() {
        do { generatedConfig = try MihomoConfigGenerator.generate(state) }
        catch { generatedConfig = nil; notice = "配置生成失败：\(error.localizedDescription)" }
    }

    func setActiveProfile(_ id: String) {
        guard state.profiles.contains(where: { $0.id == id }) else { return }
        state.activeProfileId = id
        persist()
    }

    func addProfile(name: String, copyCurrent: Bool = true) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !state.profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame }) else { notice = "配置名称不能为空或重复。"; return }
        var profile = copyCurrent ? activeProfile : ConfigProfile(id: UUID().uuidString, name: clean)
        profile.id = UUID().uuidString
        profile.name = clean
        profile.fileName = clean
        state.profiles.append(profile)
        state.activeProfileId = profile.id
        persist()
    }

    func addSource(name: String, url: String) async {
        guard let parsedURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(parsedURL.scheme?.lowercased() ?? ""), parsedURL.host != nil else { notice = ServiceError.invalidURL.localizedDescription; return }
        let source = SubscriptionSource(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (parsedURL.host ?? "订阅") : name, url: parsedURL.absoluteString)
        state.sources.append(source)
        var profile = activeProfile
        profile.selectedSourceIds.insert(source.id)
        replaceActive(profile)
        persist()
        await refreshSource(source.id)
    }

    func refreshSource(_ sourceId: String) async {
        guard let sourceIndex = state.sources.firstIndex(where: { $0.id == sourceId }) else { return }
        var source = state.sources[sourceIndex]
        isWorking = true
        defer { isWorking = false }
        do {
            var request = URLRequest(url: URL(string: source.url)!)
            request.setValue("JichangMac/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ServiceError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1) }
            let raw = String(decoding: data, as: UTF8.self)
            let result = try SubscriptionParser.parse(raw, sourceId: source.id)
            let previousNodes = state.nodes.filter { $0.sourceId == source.id }
            var priorIDsByIdentity = Dictionary(grouping: previousNodes, by: nodeIdentity).mapValues { $0.map(\.id) }
            var occurrences: [String: Int] = [:]
            let stabilizedNodes = result.nodes.map { node -> ProxyNode in
                let identity = nodeIdentity(node)
                let occurrence = occurrences[identity, default: 0]
                occurrences[identity] = occurrence + 1
                if var prior = priorIDsByIdentity[identity], !prior.isEmpty {
                    let id = prior.removeFirst()
                    priorIDsByIdentity[identity] = prior
                    var matched = node; matched.id = id; return matched
                }
                let digestInput = Data("\(source.id)|\(identity)|\(occurrence)".utf8)
                let digest = SHA256.hash(data: digestInput).prefix(16).map { String(format: "%02x", $0) }.joined()
                var fresh = node; fresh.id = "sub-\(digest)"; return fresh
            }
            let oldIDs = Set(previousNodes.map(\.id))
            let knownIDs = Set(stabilizedNodes.map(\.id))
            for index in state.profiles.indices {
                let sourceSelected = state.profiles[index].selectedSourceIds.contains(source.id)
                let selectedBefore = state.profiles[index].enabledNodeIds
                state.profiles[index].enabledNodeIds.subtract(oldIDs)
                state.profiles[index].enabledNodeIds.formUnion(stabilizedNodes.filter { node in
                    selectedBefore.contains(node.id) || (sourceSelected && !oldIDs.contains(node.id))
                }.map(\.id))
                state.profiles[index].enabledNodeIds.formIntersection(Set(state.nodes.filter { $0.sourceId != source.id }.map(\.id)).union(knownIDs))
            }
            state.nodes.removeAll { $0.sourceId == source.id }
            state.nodes.append(contentsOf: stabilizedNodes)
            source.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
            source.lastError = nil
            source.providerCompatible = raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("proxies:")
            state.sources[sourceIndex] = source
            notice = "订阅已更新，识别 \(result.nodes.count) 个节点。"
        } catch {
            source.lastError = error.localizedDescription
            state.sources[sourceIndex] = source
            notice = "订阅刷新失败：\(error.localizedDescription)"
        }
        persist()
    }

    func importNodes(_ rawText: String) {
        do {
            let parsed = try SubscriptionParser.parse(rawText)
            state.nodes.append(contentsOf: parsed.nodes)
            var profile = activeProfile
            profile.enabledNodeIds.formUnion(parsed.nodes.map(\.id))
            replaceActive(profile)
            notice = "已导入 \(parsed.nodes.count) 个节点，跳过 \(parsed.skipped) 条。"
            persist()
        } catch { notice = error.localizedDescription }
    }

    func removeNode(_ id: String) {
        state.nodes.removeAll { $0.id == id }
        for index in state.profiles.indices {
            state.profiles[index].enabledNodeIds.remove(id)
            for groupIndex in state.profiles[index].ruleProfile.groups.indices {
                state.profiles[index].ruleProfile.groups[groupIndex].members.removeAll { $0 == "node:\(id)" }
            }
        }
        persist()
    }

    func importTemplate(rawYaml: String, fileName: String) {
        do {
            _ = try Yams.load(yaml: rawYaml)
            let name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            guard !state.templates.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { notice = "模板名称已存在。"; return }
            state.templates.append(ConfigTemplate(id: UUID().uuidString, name: name, rawYaml: rawYaml, fileName: fileName))
            notice = "模板已导入。"
            persist()
        } catch { notice = "模板 YAML 无效：\(error.localizedDescription)" }
    }

    func createProfile(from template: ConfigTemplate) {
        addProfile(name: template.name, copyCurrent: false)
        guard var profile = state.profiles.first(where: { $0.id == state.activeProfileId }) else { return }
        profile.templateId = template.id
        if let root = try? Yams.load(yaml: template.rawYaml) as? [String: Any] {
            if let values = root["proxies"] as? [[String: Any]] {
                let parsed = values.compactMap { proxy -> ProxyNode? in
                    guard let name = proxy["name"] as? String, let type = proxy["type"] as? String,
                          let server = proxy["server"] as? String, let port = (proxy["port"] as? NSNumber)?.intValue else { return nil }
                    var options = proxy.mapValues(JSONValue.init(foundationValue:))
                    ["name", "type", "server", "port"].forEach { options.removeValue(forKey: $0) }
                    return ProxyNode(id: UUID().uuidString, name: name, type: type, server: server, port: port, options: options)
                }
                state.nodes.append(contentsOf: parsed)
                profile.enabledNodeIds.formUnion(parsed.map(\.id))
            }
            if let rawGroups = root["proxy-groups"] as? [[String: Any]] {
                let nodeIDs = Dictionary(state.nodes.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
                profile.ruleProfile.groups = rawGroups.compactMap { raw in
                    guard let name = raw["name"] as? String else { return nil }
                    let members = (raw["proxies"] as? [String] ?? []).map { nodeIDs[$0].map { "node:\($0)" } ?? $0 }
                    let extra = raw.filter { !["name", "type", "proxies"].contains($0.key) }.mapValues(JSONValue.init(foundationValue:))
                    return PolicyGroup(name: name, type: raw["type"] as? String ?? "select", members: members, extra: extra)
                }
            }
            if let rawRules = root["rules"] as? [String] {
                profile.ruleProfile.rules = rawRules.compactMap(parseTemplateRule)
            }
            if let rawProviders = root["rule-providers"] as? [String: [String: Any]] {
                profile.ruleProfile.providers = rawProviders.map { name, raw in
                    RuleProvider(
                        id: UUID().uuidString, name: name, type: raw["type"] as? String ?? "http",
                        url: raw["url"] as? String ?? "", path: raw["path"] as? String ?? "",
                        interval: (raw["interval"] as? NSNumber)?.intValue ?? 86400,
                        behavior: raw["behavior"] as? String ?? "domain", format: raw["format"] as? String ?? "yaml",
                        payload: raw["payload"] as? [String] ?? [],
                        headers: raw["header"] as? [String: [String]] ?? [:],
                        extra: raw.filter { !["type", "url", "path", "interval", "behavior", "format", "payload", "header"].contains($0.key) }.mapValues(JSONValue.init(foundationValue:))
                    )
                }
            }
            if let rawSubRules = root["sub-rules"] as? [String: [String]] {
                profile.ruleProfile.subRules = rawSubRules.map { name, rules in SubRuleProfile(name: name, rules: rules.compactMap(parseTemplateRule)) }
            }
            profile.mihomoSettings = root.mapValues(JSONValue.init(foundationValue:))
        }
        replaceActive(profile)
        persist()
    }

    func saveRuleText(groups: String? = nil, rules: String? = nil, providers: String? = nil) {
        do {
            var profile = activeProfile
            if let groups {
                let decoded = try JSONDecoder().decode([PolicyGroup].self, from: Data(groups.utf8))
                profile.ruleProfile.groups = decoded
            }
            if let rules {
                let decoded = try JSONDecoder().decode([RoutingRule].self, from: Data(rules.utf8))
                profile.ruleProfile.rules = decoded
            }
            if let providers {
                let decoded = try JSONDecoder().decode([RuleProvider].self, from: Data(providers.utf8))
                profile.ruleProfile.providers = decoded
            }
            replaceActive(profile)
            persist()
            notice = "规则配置已保存。"
        } catch { notice = "规则 JSON 无效：\(error.localizedDescription)" }
    }

    func refreshProvider(_ provider: RuleProvider) async {
        guard let url = URL(string: provider.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { notice = "规则集 URL 无效。"; return }
        isWorking = true
        defer { isWorking = false }
        do {
            var request = URLRequest(url: url)
            for (key, values) in provider.headers { request.setValue(values.joined(separator: ", "), forHTTPHeaderField: key) }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ServiceError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1) }
            let profileFolder = cacheRoot.appendingPathComponent(activeProfile.id, isDirectory: true)
            try FileManager.default.createDirectory(at: profileFolder, withIntermediateDirectories: true)
            let cacheName = provider.id.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression) + ".cache"
            try data.write(to: profileFolder.appendingPathComponent(cacheName), options: .atomic)
            state.ruleProviderStatuses.removeAll { $0.profileId == activeProfile.id && $0.providerId == provider.id }
            state.ruleProviderStatuses.append(RuleProviderStatus(profileId: activeProfile.id, providerId: provider.id, refreshedAt: Int64(Date().timeIntervalSince1970 * 1000), itemCount: data.count, cacheFileName: cacheName))
            notice = "规则集已刷新。"
        } catch { notice = "规则集刷新失败：\(error.localizedDescription)" }
        persist()
    }

    func exportBackup() throws -> Data {
        try PortableBackup.make(stateData: encoder.encode(state), cacheRoot: cacheRoot)
    }

    func importBackup(_ data: Data) throws {
        let contents = try PortableBackup.read(data)
        let restored = try decoder.decode(AppState.self, from: contents.stateData)
        guard !restored.profiles.isEmpty, restored.profiles.contains(where: { $0.id == restored.activeProfileId }) else { throw BackupError.invalidFormat }
        try PortableBackup.restoreCaches(contents.cacheFiles, to: cacheRoot)
        state = restored
        try encoder.encode(restored).write(to: stateURL, options: .atomic)
        regenerate()
        notice = "备份已恢复。"
    }

    private func replaceActive(_ profile: ConfigProfile) {
        if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) { state.profiles[index] = profile }
    }

    private func nodeIdentity(_ node: ProxyNode) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let options = (try? encoder.encode(node.options)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "\(node.type.lowercased())|\(node.server.lowercased())|\(node.port)|\(node.name.trimmingCharacters(in: .whitespacesAndNewlines))|\(options)"
    }

    private func parseTemplateRule(_ line: String) -> RoutingRule? {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        let type = parts[0].uppercased()
        let isMatch = type == "MATCH"
        let targetIndex = isMatch ? 1 : (type == "AND" || type == "OR" || type == "NOT" ? parts.count - 1 : 2)
        guard parts.indices.contains(targetIndex) else { return nil }
        let value = isMatch ? "MATCH" : parts[1]
        let extras = parts.dropFirst(min(3, parts.count)).filter { !$0.isEmpty }
        return RoutingRule(type: type, value: value, group: parts[targetIndex], noResolve: extras.contains("no-resolve"), source: extras.contains("src"), extraParameters: extras.filter { $0 != "no-resolve" && $0 != "src" }, rawLine: ["AND", "OR", "NOT"].contains(type) ? line : nil)
    }
}

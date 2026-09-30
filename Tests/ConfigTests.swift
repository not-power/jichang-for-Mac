import Foundation
import AppKit
import Testing
@testable import JichangCore

private func minimalState() -> AppState {
    var profile = ConfigProfile(id: "test", name: "测试")
    profile.enabledRegions = []
    profile.ruleProfile.groups = [PolicyGroup(name: "PROXY", members: ["DIRECT"], membersExplicit: true)]
    profile.ruleProfile.rules = [RoutingRule(type: "MATCH", value: "", group: "PROXY")]
    return AppState(profiles: [profile], activeProfileId: "test")
}
private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("jichang-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func recursiveMergeAndArrayReplacement() throws {
    var state = minimalState()
    state.templates = [ConfigTemplate(id: "template", name: "模板", rawYaml: "dns:\n  enable: true\n  nameserver: [1.1.1.1]\n  fallback: [8.8.8.8]\n", fileName: "t.yaml")]
    state.profiles[0].templateId = "template"
    state.profiles[0].advancedYaml = "dns:\n  nameserver: [9.9.9.9]\n  ipv6: false\n"
    state.profiles[0].mihomoSettings = ["dns": .object(["listen": .string("127.0.0.1:1053"), "ipv6": .bool(true)])]
    let config = try MihomoConfigGenerator.generate(state), root = try ConfigDocument.parse(config.yaml)
    #expect(ConfigDocument.value(root, at: "dns.enable") == .bool(true))
    #expect(ConfigDocument.value(root, at: "dns.nameserver") == .array([.string("9.9.9.9")]))
    #expect(ConfigDocument.value(root, at: "dns.fallback") == .array([.string("8.8.8.8")]))
    #expect(ConfigDocument.value(root, at: "dns.ipv6") == .bool(true))
    #expect(config.issues.contains { $0.location == "dns.ipv6" && $0.severity == .warning })
}
@Test(arguments: ["http", "file", "inline"])
func providerExport(type: String) throws {
    var state = minimalState()
    state.profiles[0].ruleProfile.providers = [RuleProvider(id: "p", name: "sample", type: type, url: "https://rules.example.org/test", path: "./sample.yaml", payload: ["+.example.com"], headers: ["User-Agent": ["test"]], extra: ["size-limit": .integer(123)])]
    let config = try MihomoConfigGenerator.generate(state), root = try ConfigDocument.parse(config.yaml)
    let provider = try #require(root["rule-providers"]?.objectValue?["sample"]?.objectValue)
    #expect(provider["size-limit"] == .integer(123))
    #expect((provider["payload"] != nil) == (type == "inline"))
    #expect((provider["header"] != nil) == (type == "http"))
    #expect((provider["url"] != nil) == (type == "http"))
    #expect((provider["path"] != nil) == (type != "inline"))
    #expect(config.canExport)
}
@Test(arguments: [
    "DOMAIN-SUFFIX,example.com,PROXY", "MATCH,DIRECT", "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve,src",
    "AND,((DOMAIN-SUFFIX,example.com),(NETWORK,TCP)),PROXY", "NOT,((DOMAIN,example.com)),DIRECT", "SUB-RULE,(NETWORK,TCP),child"
])
func ruleRoundTrip(line: String) throws { #expect(try RuleCodec.serialize(RuleCodec.parse(line)) == line) }
@Test func structuredConditionsAndSource() throws {
    let rule = RoutingRule(type: "AND", value: "", group: "DIRECT", conditions: [RuleCondition(type: "DOMAIN", value: "example.com"), RuleCondition(type: "NETWORK", value: "TCP")])
    #expect(try RuleCodec.serialize(rule) == "AND,((DOMAIN,example.com),(NETWORK,TCP)),DIRECT")
    #expect(try RuleCodec.serialize(RoutingRule(type: "IP-CIDR", value: "10.0.0.0/8", group: "DIRECT", source: true)) == "IP-CIDR,10.0.0.0/8,DIRECT,src")
    #expect(try RuleCodec.serialize(RuleCodec.parse("IP-CIDR,10.0.0.0/8,DIRECT,source")) == "IP-CIDR,10.0.0.0/8,DIRECT,src")
}
@Test(arguments: ["DOMAIN,a", "AND,((DOMAIN,a),DIRECT", "MATCH,", "DOMAIN,,DIRECT"])
func invalidRulesDoNotDisappear(line: String) {
    #expect(throws: (any Error).self) { try RuleCodec.parse(line) }
}
@Test func invalidTargetBlocksExportAndKeepsRule() throws {
    var state = minimalState(); state.profiles[0].ruleProfile.rules.insert(RoutingRule(type: "DOMAIN", value: "example.com", group: "missing"), at: 0)
    let config = try MihomoConfigGenerator.generate(state)
    #expect(!config.canExport); #expect(config.yaml.contains("missing"))
}
@Test func cyclesAndMissingReferences() throws {
    var state = minimalState()
    state.profiles[0].ruleProfile.groups = [PolicyGroup(name: "A", members: ["B"]), PolicyGroup(name: "B", members: ["A"])]
    state.profiles[0].ruleProfile.rules = [try RuleCodec.parse("RULE-SET,missing,A"), try RuleCodec.parse("SUB-RULE,(NETWORK,TCP),one")]
    state.profiles[0].ruleProfile.subRules = [SubRuleProfile(name: "one", rules: [try RuleCodec.parse("SUB-RULE,(NETWORK,TCP),two")]), SubRuleProfile(name: "two", rules: [try RuleCodec.parse("SUB-RULE,(NETWORK,TCP),one")])]
    let config = try MihomoConfigGenerator.generate(state)
    #expect(!config.canExport)
    #expect(config.issues.filter { $0.message.contains("循环") }.count == 2)
    #expect(config.issues.contains { $0.message.contains("规则集不存在") })
}
@Test func renameReferencesIncludingRawRules() throws {
    var profile = minimalState().activeProfile
    profile.ruleProfile.rules = [try RuleCodec.parse("AND,((NETWORK,TCP),(DOMAIN,example.com)),PROXY"), try RuleCodec.parse("RULE-SET,old,PROXY"), try RuleCodec.parse("SUB-RULE,(NETWORK,TCP),oldSub")]
    profile.ruleProfile.subRules = [SubRuleProfile(name: "child", rules: [try RuleCodec.parse("MATCH,PROXY")])]
    ProfileReferences.rename(&profile, from: "PROXY", to: "New", kind: "group")
    ProfileReferences.rename(&profile, from: "old", to: "new", kind: "provider")
    ProfileReferences.rename(&profile, from: "oldSub", to: "newSub", kind: "subRule")
    #expect(try RuleCodec.serialize(profile.ruleProfile.rules[0]).hasSuffix(",New"))
    #expect(try RuleCodec.serialize(profile.ruleProfile.rules[1]) == "RULE-SET,new,New")
    #expect(try RuleCodec.serialize(profile.ruleProfile.rules[2]) == "SUB-RULE,(NETWORK,TCP),newSub")
    #expect(profile.ruleProfile.subRules[0].rules[0].group == "New")
}
@Test func duplicateNamesNeverCrash() throws {
    var state = minimalState()
    state.profiles[0].ruleProfile.providers = [RuleProvider(id: "1", name: "a", type: "inline"), RuleProvider(id: "2", name: "a", type: "inline")]
    #expect(try !MihomoConfigGenerator.generate(state).canExport)
}
@Test func duplicateNodesReceiveUniqueNames() throws {
    var state = minimalState()
    state.nodes = ["A", "A", "A-2", "A"].enumerated().map { ProxyNode(id: String($0.offset), name: $0.element, type: "ss", server: "example.com", port: 443, options: ["cipher": .string("aes-128-gcm"), "password": .string("test")]) }
    state.profiles[0].enabledNodeIds = Set(state.nodes.map(\.id))
    let root = try ConfigDocument.parse(MihomoConfigGenerator.generate(state).yaml)
    let names = try #require(root["proxies"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue })
    #expect(Set(names).count == 4)
}
@Test func base64SubscriptionAndParameters() throws {
    let link = "vless://12345678-1234-1234-1234-123456789012@example.com:443?type=ws&security=tls&sni=cdn.example.com&path=%2Fsocket&host=cdn.example.com#test"
    let encoded = Data((link + "\nunknown://test").utf8).base64EncodedString()
    let parsed = try SubscriptionParser.parse(encoded)
    #expect(parsed.nodes.count == 1); #expect(parsed.skipped == 1)
    #expect(parsed.nodes[0].options["network"] == .string("ws"))
    #expect(parsed.nodes[0].options["tls"] == .bool(true))
    #expect(parsed.nodes[0].options["ws-opts"]?.objectValue?["path"] == .string("/socket"))
}
@Test func yamlSubscriptionRecognitionAndUnknownFields() throws {
    let yaml = "# test\nmode: rule\nproxies:\n- name: node\n  type: ss\n  server: example.com\n  port: 443\n  custom-field: {nested: [true, 12]}\n"
    #expect(SubscriptionParser.isProviderCompatible(yaml))
    let result = try SubscriptionParser.parse(yaml)
    #expect(result.nodes[0].options["custom-field"]?.objectValue?["nested"] == .array([.bool(true), .integer(12)]))
}
@Test func oldAndAndroidStateDecodesWithDefaults() throws {
    let data = Data(#"{"profiles":[{"id":"old","name":"旧配置","ruleProfile":{"groups":[{"name":"PROXY"}],"rules":[{"type":"MATCH","value":"","group":"DIRECT"}]}}],"activeProfileId":"old"}"#.utf8)
    let state = try JSONDecoder().decode(AppState.self, from: data)
    #expect(state.activeProfile.fileName == "旧配置")
    #expect(state.activeProfile.ruleProfile.groups[0].extra.isEmpty)
    #expect(try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state)) == state)
}
@Test func portableBackupRoundTrip() throws {
    let temp = try tempDirectory(); defer { try? FileManager.default.removeItem(at: temp) }
    let state = minimalState(), data = try JSONEncoder().encode(state)
    let cache = temp.appendingPathComponent("cache"); try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data("payload".utf8).write(to: cache.appendingPathComponent("sample"))
    let backup = try PortableBackup.make(stateData: data, cacheRoot: cache)
    let decoded = try PortableBackup.read(backup)
    #expect(try JSONDecoder().decode(AppState.self, from: decoded.stateData) == state)
    #expect(decoded.cacheFiles["sample"] == Data("payload".utf8))
}
@Test func configurationPipelineRejectsOldRevision() async throws {
    let temp = try tempDirectory(); defer { try? FileManager.default.removeItem(at: temp) }
    let pipeline = ConfigurationPipeline(), url = temp.appendingPathComponent("state.json")
    _ = await pipeline.process(minimalState(), revision: 2, at: url)
    #expect(await pipeline.process(AppState(), revision: 1, at: url) == nil)
    #expect(try JSONDecoder().decode(AppState.self, from: Data(contentsOf: url)).activeProfile.id == "test")
}
@Test @MainActor func templatePreservesEmptyGroupAndProviderDetails() async throws {
    let temp = try tempDirectory(); defer { try? FileManager.default.removeItem(at: temp) }
    let model = AppModel(supportDirectory: temp)
    let template = ConfigTemplate(id: "t", name: "模板", rawYaml: """
    proxy-groups:
    - name: PROXY
      type: select
      proxies: []
    rule-providers:
      inline:
        type: inline
        behavior: domain
        payload: ['+.example.com']
      remote:
        type: http
        behavior: domain
        url: https://rules.example.org/rules.yaml
        header:
          User-Agent: [test]
    sub-rules:
      child: ["DOMAIN,example.com,DIRECT"]
    rules: ["SUB-RULE,(NETWORK,TCP),child", "MATCH,PROXY"]
    """, fileName: "t.yaml")
    model.state.templates.append(template); model.createProfile(from: template)
    await model.flush()
    let root = try ConfigDocument.parse(#require(model.generatedConfig).yaml)
    let group = try #require(root["proxy-groups"]?.arrayValue?.first?.objectValue)
    #expect(group["proxies"] == .array([]))
    #expect(root["rule-providers"]?.objectValue?["inline"]?.objectValue?["payload"] == .array([.string("+.example.com")]))
    #expect(root["rule-providers"]?.objectValue?["remote"]?.objectValue?["header"]?.objectValue?["User-Agent"] == .array([.string("test")]))
    #expect(model.activeProfile.ruleProfile.rules[0].group == "child")
}
@Test @MainActor func formsRetainDraftAndOnlySaveEdits() async throws {
    _ = NSApplication.shared
    let temp = try tempDirectory(); defer { try? FileManager.default.removeItem(at: temp) }
    let model = AppModel(supportDirectory: temp)
    let fields = [SettingField("dns.enable", "DNS", .boolean), SettingField("mixed-port", "端口", .integer(0, 65535))]
    let effective: [String: JSONValue] = ["dns": .object(["enable": .bool(true)]), "mixed-port": .integer(1234)]
    let form = FieldForm(fields: fields, values: effective, inherited: effective, model: model, key: "test:form")
    #expect(try form.applying(to: [:]).isEmpty)
    form.setText("bad", at: "mixed-port")
    #expect(throws: (any Error).self) { try form.applying(to: [:]) }
    let restored = FieldForm(fields: fields, values: effective, model: model, key: "test:form")
    #expect(restored.text(at: "mixed-port") == "bad")
    restored.setText("7891", at: "mixed-port")
    let result = try restored.applying(to: [:])
    #expect(result == ["mixed-port": .integer(7891)])
    #expect(EditorDraftStore(url: temp.appendingPathComponent("drafts.json")).get("test:form")?["mixed-port"] == "7891")
    await model.flush()
}
@Test @MainActor func exportFixturesForMihomo() throws {
    guard let folder = ProcessInfo.processInfo.environment["JICHANG_FIXTURE_OUTPUT"] else { return }
    let output = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var state = minimalState()
    try MihomoConfigGenerator.generate(state).yaml.write(to: output.appendingPathComponent("basic.yaml"), atomically: true, encoding: .utf8)
    state.profiles[0].advancedYaml = """
    dns:
      enable: true
      enhanced-mode: fake-ip
      nameserver: [1.1.1.1]
      proxy-server-nameserver: [8.8.8.8]
      respect-rules: true
    tun:
      enable: true
      stack: mixed
      auto-route: true
      auto-detect-interface: true
      dns-hijack: [any:53]
    sniffer:
      enable: true
      sniff:
        HTTP: {ports: [80, '8080-8880']}
        TLS: {ports: [443]}
        QUIC: {ports: [443]}
    """
    try MihomoConfigGenerator.generate(state).yaml.write(to: output.appendingPathComponent("network.yaml"), atomically: true, encoding: .utf8)
    state.profiles[0].ruleProfile.providers = [RuleProvider(id: "p", name: "inline", type: "inline", behavior: "domain", payload: ["+.example.com"])]
    state.profiles[0].ruleProfile.subRules = [SubRuleProfile(name: "child", rules: [try RuleCodec.parse("AND,((DOMAIN-SUFFIX,example.com),(NETWORK,TCP)),DIRECT")])]
    state.profiles[0].ruleProfile.rules = [try RuleCodec.parse("SUB-RULE,(NETWORK,TCP),child"), try RuleCodec.parse("RULE-SET,inline,DIRECT"), try RuleCodec.parse("IP-CIDR,10.0.0.0/8,DIRECT,no-resolve,src"), try RuleCodec.parse("MATCH,PROXY")]
    let generated = try MihomoConfigGenerator.generate(state); #expect(generated.canExport)
    try generated.yaml.write(to: output.appendingPathComponent("complex.yaml"), atomically: true, encoding: .utf8)
    try JSONEncoder().encode(state).write(to: output.appendingPathComponent("state.json"))
}

@Test @MainActor func refreshStaysWithOriginalProfileAndReportsCount() async throws {
    guard let base = ProcessInfo.processInfo.environment["JICHANG_FIXTURE_SERVER"] else { return }
    let temp = try tempDirectory(); defer { try? FileManager.default.removeItem(at: temp) }
    let model = AppModel(supportDirectory: temp)
    model.state = minimalState()
    let provider = RuleProvider(id: "remote", name: "remote", url: base + "/slow.yaml")
    model.state.profiles[0].ruleProfile.providers = [provider]
    model.state.profiles.append(ConfigProfile(id: "other", name: "其他"))
    let task = Task { await model.refreshProvider(provider) }
    try await Task.sleep(for: .milliseconds(30))
    model.setActiveProfile("other")
    await task.value
    let status = try #require(model.state.ruleProviderStatuses.first)
    #expect(status.profileId == "test"); #expect(status.itemCount == 2)
    #expect(FileManager.default.fileExists(atPath: temp.appendingPathComponent("rule-providers/test/remote.cache").path))
    #expect(!FileManager.default.fileExists(atPath: temp.appendingPathComponent("rule-providers/other/remote.cache").path))
    await model.flush()
}
@Test @MainActor func providerEditDuringRefreshDiscardsResult() async throws {
    guard let base = ProcessInfo.processInfo.environment["JICHANG_FIXTURE_SERVER"] else { return }
    let temp = try tempDirectory(); defer { try? FileManager.default.removeItem(at: temp) }
    let model = AppModel(supportDirectory: temp); model.state = minimalState()
    await model.flush()
    let provider = RuleProvider(id: "remote", name: "remote", url: base + "/slow.yaml")
    model.state.profiles[0].ruleProfile.providers = [provider]
    let task = Task { await model.refreshProvider(provider) }
    try await Task.sleep(for: .milliseconds(30))
    model.state.profiles[0].ruleProfile.providers[0].url = base + "/different.yaml"
    await task.value
    #expect(model.state.ruleProviderStatuses.isEmpty)
    await model.flush()
}
@Test @MainActor func mrsCountIsUnknownAndBadYamlReportsFailure() async throws {
    guard let base = ProcessInfo.processInfo.environment["JICHANG_FIXTURE_SERVER"] else { return }
    let temp = try tempDirectory(); defer { try? FileManager.default.removeItem(at: temp) }
    let model = AppModel(supportDirectory: temp); model.state = minimalState()
    var provider = RuleProvider(id: "remote", name: "remote", url: base + "/sample.mrs", format: "mrs")
    model.state.profiles[0].ruleProfile.providers = [provider]
    await model.refreshProvider(provider)
    #expect(model.state.ruleProviderStatuses.first?.itemCount == nil)
    #expect(model.state.ruleProviderStatuses.first?.cacheFileName != nil)
    provider.url = base + "/bad.yaml"; provider.format = "yaml"
    model.state.profiles[0].ruleProfile.providers = [provider]
    await model.refreshProvider(provider)
    #expect(model.state.ruleProviderStatuses.first?.error != nil)
    await model.flush()
}
@Test @MainActor func localShareReturnsOnlyTokenPathAndUpdates() async throws {
    let server = LocalShareServer(config: "mode: rule", fileName: "test.yaml")
    let url = try await server.start(); defer { server.stop() }
    var parts = try #require(URLComponents(string: url)); parts.host = "127.0.0.1"
    let local = try #require(parts.url)
    let (first, response) = try await URLSession.shared.data(from: local)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: first, as: UTF8.self) == "mode: rule")
    server.update(config: "mode: direct", fileName: "test.yaml")
    let (second, _) = try await URLSession.shared.data(from: local)
    #expect(String(decoding: second, as: UTF8.self) == "mode: direct")
    parts.path = "/config.yaml"
    let (_, missing) = try await URLSession.shared.data(from: #require(parts.url))
    #expect((missing as? HTTPURLResponse)?.statusCode == 404)
}
@Test @MainActor func settingsAndRulesFitWindowSizesAndAppearances() async throws {
    _ = NSApplication.shared
    let temp = try tempDirectory(); defer { try? FileManager.default.removeItem(at: temp) }
    let model = AppModel(supportDirectory: temp); model.state = minimalState()
    await model.flush()
    let workspace = WorkspaceController(model: model)
    let pages: [WorkspacePage] = [SettingsPage(model: model, workspace: workspace), ConfigurationPage(model: model, workspace: workspace, destination: .yaml), ConfigurationPage(model: model, workspace: workspace, destination: .diagnostics), RulesPage(model: model, workspace: workspace, initialTab: 0), SharePage(model: model, workspace: workspace)]
    let output = ProcessInfo.processInfo.environment["JICHANG_UI_RENDER_OUTPUT"].map { URL(fileURLWithPath: $0) }
    if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    for (index, page) in pages.enumerated() {
        let view = page.view
        page.refresh()
        let widthConstraint = view.widthAnchor.constraint(equalToConstant: 700)
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 700)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        for width in [700.0, 980.0] {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                view.appearance = NSAppearance(named: name)
                widthConstraint.constant = width
                view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
                view.layoutSubtreeIfNeeded()
                #expect(abs(view.frame.width - CGFloat(width)) < 1)
                for scroll in view.subviews.compactMap({ $0 as? NSScrollView }) { #expect(scroll.frame.width > 0) }
                if let output, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent("page-\(index)-\(Int(width))-\(name.rawValue).png")) }
                }
            }
        }
    }
    await model.flush()
}
@Test func referenceProvidersAndCoreFixtures() throws {
    guard let folder = ProcessInfo.processInfo.environment["JICHANG_FIXTURE_OUTPUT"], let server = ProcessInfo.processInfo.environment["JICHANG_FIXTURE_SERVER"] else { return }
    let output = URL(fileURLWithPath: folder)
    var state = minimalState()
    state.sources = [SubscriptionSource(id: "source", name: "test", url: server + "/subscription.yaml", providerCompatible: true)]
    state.profiles[0].selectedSourceIds = ["source"]
    state.profiles[0].sourceMode = "REFERENCE_SUBSCRIPTIONS"
    state.profiles[0].enabledRegions = ["hk", "other"]
    state.profiles[0].ruleProfile.groups = [PolicyGroup(name: "PROXY")]
    let config = try MihomoConfigGenerator.generate(state)
    #expect(config.canExport)
    let root = try ConfigDocument.parse(config.yaml)
    #expect(root["proxy-providers"]?.objectValue?.count == 1)
    #expect(root["proxy-groups"]?.arrayValue?.contains { $0.objectValue?["name"] == .string("🌏 其他") && $0.objectValue?["use"]?.arrayValue?.count == 1 } == true)
    try config.yaml.write(to: output.appendingPathComponent("reference.yaml"), atomically: true, encoding: .utf8)
    state = minimalState()
    state.profiles[0].ruleProfile.providers = [RuleProvider(id: "p", name: "remote", type: "http", url: server + "/sample.yaml", behavior: "domain", headers: ["User-Agent": ["JichangVerification"]])]
    state.profiles[0].ruleProfile.rules.insert(try RuleCodec.parse("RULE-SET,remote,DIRECT"), at: 0)
    try MihomoConfigGenerator.generate(state).yaml.write(to: output.appendingPathComponent("http-provider.yaml"), atomically: true, encoding: .utf8)
    state.profiles[0].ruleProfile.providers[0].type = "file"; state.profiles[0].ruleProfile.providers[0].path = "./sample.yaml"
    try MihomoConfigGenerator.generate(state).yaml.write(to: output.appendingPathComponent("file-provider.yaml"), atomically: true, encoding: .utf8)
}
@Test(arguments: ["dns: true", "mode: typo", "mixed-port: 65536", "dns:\n  respect-rules: true\n", "sniffer:\n  sniff:\n    TLS:\n      ports: [80000]", "sniffer:\n  sniff:\n    TLS:\n      ports: [oops-80-443]"])
func invalidSettingsBlockExport(yaml: String) throws {
    var state = minimalState(); state.profiles[0].advancedYaml = yaml
    #expect(try !MihomoConfigGenerator.generate(state).canExport)
}
@Test(arguments: ["lazy", "interval", "strategy"])
func importedGroupFieldTypesAreChecked(key: String) throws {
    var state = minimalState()
    state.profiles[0].ruleProfile.groups[0].extra[key] = key == "strategy" ? .integer(1) : .string("invalid")
    let config = try MihomoConfigGenerator.generate(state)
    #expect(!config.canExport)
    #expect(config.issues.contains { $0.severity == .error && $0.location == "策略组.PROXY." + key })
}

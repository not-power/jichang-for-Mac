import AppKit
import CoreImage.CIFilterBuiltins
import Darwin
import Network
import SwiftUI
import UniformTypeIdentifiers
import Yams

enum MacPage: String, CaseIterable, Identifiable {
    case overview, sources, nodes, templates, groups, rules, providers, subRules, diagnostics, settings, advanced, share
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "概览"
        case .sources: "订阅"
        case .nodes: "节点"
        case .templates: "模板"
        case .groups: "策略组"
        case .rules: "分流规则"
        case .providers: "规则集"
        case .subRules: "子规则"
        case .diagnostics: "校验与模拟"
        case .settings: "基础配置"
        case .advanced: "高级 YAML"
        case .share: "配置导出"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .sources: "arrow.triangle.2.circlepath"
        case .nodes: "point.3.connected.trianglepath.dotted"
        case .templates: "doc.text"
        case .groups: "rectangle.3.group"
        case .rules: "line.3.horizontal.decrease.circle"
        case .providers: "externaldrive.connected.to.line.below"
        case .subRules: "list.bullet.indent"
        case .diagnostics: "checkmark.shield"
        case .settings: "slider.horizontal.3"
        case .advanced: "curlybraces"
        case .share: "square.and.arrow.up"
        }
    }
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var selection: MacPage? = .overview
    @State private var showSourceSheet = false
    @State private var showNodeSheet = false
    @State private var showTemplateSheet = false
    @State private var newProfileName = ""
    @State private var showProfileSheet = false
    @State private var showRestoreConfirmation = false
    @State private var pendingBackup: Data?
    @State private var simulatorInput = ""
    @State private var sharing = false
    @State private var shareURL: String?
    @State private var shareServer: LocalShareServer?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("工作区") {
                    pageRow(.overview)
                    pageRow(.sources)
                    pageRow(.nodes)
                    pageRow(.templates)
                }
                Section("规则") {
                    pageRow(.groups)
                    pageRow(.rules)
                    pageRow(.providers)
                    pageRow(.subRules)
                    pageRow(.diagnostics)
                    pageRow(.settings)
                    pageRow(.advanced)
                }
                Section("输出") { pageRow(.share) }
            }
            .listStyle(.sidebar)
            .navigationTitle("鸡场")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                    Picker("当前配置", selection: Binding(get: { model.state.activeProfileId }, set: model.setActiveProfile)) {
                        ForEach(model.state.profiles) { profile in Text(profile.name).tag(profile.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Button { showProfileSheet = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .help("新建配置")
                }
                .padding(12)
                .background(.bar)
            }
        } detail: {
            detail
                .frame(minWidth: 720, minHeight: 520)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(selection?.title ?? "鸡场").font(.headline)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { importBackupPanel() } label: { Label("导入备份", systemImage: "square.and.arrow.down") }
                        Button { exportBackupPanel() } label: { Label("导出备份", systemImage: "square.and.arrow.up") }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $model.searchText, prompt: "搜索当前列表")
        .sheet(isPresented: $showSourceSheet) { SourceEditor { name, url in Task { await model.addSource(name: name, url: url) } } }
        .sheet(isPresented: $showNodeSheet) { NodeImportEditor { model.importNodes($0) } }
        .sheet(isPresented: $showTemplateSheet) { TemplateImportEditor { model.importTemplate(rawYaml: $0, fileName: $1) } }
        .sheet(isPresented: $showProfileSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("新建配置").font(.title2.bold())
                TextField("配置名称", text: $newProfileName)
                Toggle("复制当前配置", isOn: .constant(true)).disabled(true)
                HStack { Spacer(); Button("取消") { showProfileSheet = false }; Button("创建") { model.addProfile(name: newProfileName); newProfileName = ""; showProfileSheet = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 360)
        }
        .alert("导入备份会替换本机数据", isPresented: $showRestoreConfirmation) {
            Button("取消", role: .cancel) { pendingBackup = nil }
            Button("替换并恢复", role: .destructive) {
                if let pendingBackup { do { try model.importBackup(pendingBackup) } catch { model.notice = error.localizedDescription } }
                pendingBackup = nil
            }
        } message: {
            Text("备份中的订阅、节点、模板、配置、规则和规则集缓存将完整替换本机数据。建议先导出当前备份。")
        }
        .alert("鸡场", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("好") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .onChange(of: model.generatedConfig?.yaml) { _, yaml in
            if sharing, let yaml { shareServer?.update(config: yaml, fileName: model.activeProfile.fileName) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jichangExportBackup)) { _ in exportBackupPanel() }
        .onReceive(NotificationCenter.default.publisher(for: .jichangImportBackup)) { _ in importBackupPanel() }
        .onDisappear { shareServer?.stop() }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .overview {
        case .overview: OverviewView(model: model, navigate: { selection = $0 })
        case .sources: SourcesView(model: model, add: { showSourceSheet = true })
        case .nodes: NodesView(model: model, add: { showNodeSheet = true })
        case .templates: TemplatesView(model: model, add: { showTemplateSheet = true })
        case .groups: RuleJSONEditor(title: "策略组", values: encode(model.activeProfile.ruleProfile.groups), placeholder: "[]") { model.saveRuleText(groups: $0) }
        case .rules: RuleJSONEditor(title: "分流规则", values: encode(model.activeProfile.ruleProfile.rules), placeholder: "[]") { model.saveRuleText(rules: $0) }
        case .providers: ProvidersView(model: model)
        case .subRules: SubRulesView(model: model)
        case .diagnostics: DiagnosticsView(model: model, input: $simulatorInput)
        case .settings: SettingsView(model: model)
        case .advanced: AdvancedYAMLView(model: model)
        case .share: ShareView(model: model, sharing: $sharing, shareURL: $shareURL, shareServer: $shareServer)
        }
    }

    private func pageRow(_ page: MacPage) -> some View {
        Label(page.title, systemImage: page.symbol).tag(page)
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder.pretty.encode(value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func importBackupPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: PortableBackup.fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            _ = try PortableBackup.read(data)
            pendingBackup = data
            showRestoreConfirmation = true
        } catch { model.notice = error.localizedDescription }
    }

    private func exportBackupPanel() {
        do {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: PortableBackup.fileExtension) ?? .data]
            panel.nameFieldStringValue = "鸡场备份.\(PortableBackup.fileExtension)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try model.exportBackup().write(to: url, options: .atomic)
            model.notice = "备份已导出。"
        } catch { model.notice = error.localizedDescription }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
}

private struct OverviewView: View {
    @Bindable var model: AppModel
    var navigate: (MacPage) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.activeProfile.name).font(.largeTitle.bold())
                    Text("管理 Mihomo 订阅、节点与分流配置。数据保存在这台 Mac 上。")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    MetricCard(title: "订阅", count: model.state.sources.count, symbol: "arrow.triangle.2.circlepath") { navigate(.sources) }
                    MetricCard(title: "节点", count: model.state.nodes.count, symbol: "point.3.connected.trianglepath.dotted") { navigate(.nodes) }
                    MetricCard(title: "分流规则", count: model.activeProfile.ruleProfile.rules.count, symbol: "line.3.horizontal.decrease.circle") { navigate(.rules) }
                    MetricCard(title: "规则集", count: model.activeProfile.ruleProfile.providers.count, symbol: "externaldrive.connected.to.line.below") { navigate(.providers) }
                }
                GroupBox("配置检查") {
                    let issues = RuleDiagnostics.inspect(model.activeProfile, nodeIDs: Set(model.state.nodes.map(\.id)))
                    if issues.isEmpty { Label("没有发现明显的规则引用问题。", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { VStack(alignment: .leading, spacing: 8) { ForEach(issues.prefix(5), id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }; Button("查看全部") { navigate(.diagnostics) }.buttonStyle(.link) } }
                }
                HStack {
                    Button { navigate(.share) } label: { Label("预览并导出配置", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
                    Button { navigate(.templates) } label: { Label("管理模板", systemImage: "doc.text") }.buttonStyle(.bordered)
                }
            }
            .padding(28)
        }
    }
}

private struct MetricCard: View {
    let title: String; let count: Int; let symbol: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack { Image(systemName: symbol).font(.title2).foregroundStyle(.tint); VStack(alignment: .leading) { Text("\(count)").font(.title2.bold()); Text(title).foregroundStyle(.secondary) }; Spacer() }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

private struct SourcesView: View {
    @Bindable var model: AppModel
    var add: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("订阅").font(.title2.bold()); Spacer(); Button("刷新全部") { Task { for source in model.state.sources { await model.refreshSource(source.id) } } }; Button(action: add) { Label("添加订阅", systemImage: "plus") }.buttonStyle(.borderedProminent) }.padding()
            Table(filtered) {
                TableColumn("使用") { source in Toggle("", isOn: sourceBinding(source)).labelsHidden() }
                TableColumn("名称") { source in Text(source.name).fontWeight(.medium) }
                TableColumn("订阅地址") { source in Text(source.url).lineLimit(1).textSelection(.enabled).foregroundStyle(.secondary) }
                TableColumn("状态") { source in Text(source.lastError ?? (source.updatedAt == nil ? "尚未刷新" : "已更新")).foregroundStyle(source.lastError == nil ? Color.secondary : Color.red) }
                TableColumn("操作") { source in HStack { Button("刷新") { Task { await model.refreshSource(source.id) } }; Button("移除", role: .destructive) { model.state.sources.removeAll { $0.id == source.id }; model.persist() } } }
            }.padding(.horizontal)
            if model.state.sources.isEmpty { EmptyState(title: "还没有订阅", detail: "添加 HTTP 或 HTTPS 订阅地址，自动获取节点。", actionTitle: "添加订阅", action: add) }
        }
    }
    private var filtered: [SubscriptionSource] { model.state.sources.filter { model.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(model.searchText) || $0.url.localizedCaseInsensitiveContains(model.searchText) } }
    private func sourceBinding(_ source: SubscriptionSource) -> Binding<Bool> { Binding(get: { model.activeProfile.selectedSourceIds.contains(source.id) }, set: { selected in var profile = model.activeProfile; if selected { profile.selectedSourceIds.insert(source.id) } else { profile.selectedSourceIds.remove(source.id) }; if let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) { model.state.profiles[index] = profile }; model.persist() }) }
}

private struct NodesView: View {
    @Bindable var model: AppModel
    var add: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("节点").font(.title2.bold()); Text("\(filtered.count) 个").foregroundStyle(.secondary); Spacer(); Button(action: add) { Label("粘贴或导入", systemImage: "plus") }.buttonStyle(.borderedProminent) }.padding()
            Table(filtered) {
                TableColumn("启用") { node in Toggle("", isOn: enabledBinding(node)).labelsHidden() }
                TableColumn("名称") { node in Text(node.name).fontWeight(.medium) }
                TableColumn("类型") { node in Text(node.type.uppercased()).monospaced() }
                TableColumn("服务器") { node in Text("\(node.server):\(node.port)").monospaced().textSelection(.enabled) }
                TableColumn("操作") { node in Button("删除", role: .destructive) { model.removeNode(node.id) } }
            }.padding(.horizontal)
            if model.state.nodes.isEmpty { EmptyState(title: "还没有节点", detail: "导入节点链接或添加订阅。", actionTitle: "导入节点", action: add) }
        }
    }
    private var filtered: [ProxyNode] { model.state.nodes.filter { model.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(model.searchText) || $0.server.localizedCaseInsensitiveContains(model.searchText) } }
    private func enabledBinding(_ node: ProxyNode) -> Binding<Bool> { Binding(get: { model.activeProfile.enabledNodeIds.contains(node.id) }, set: { isEnabled in var profile = model.activeProfile; if isEnabled { profile.enabledNodeIds.insert(node.id) } else { profile.enabledNodeIds.remove(node.id) }; if let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) { model.state.profiles[index] = profile }; model.persist() }) }
}

private struct TemplatesView: View {
    @Bindable var model: AppModel
    var add: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("模板").font(.title2.bold()); Spacer(); Button(action: add) { Label("导入 YAML", systemImage: "plus") }.buttonStyle(.borderedProminent) }.padding()
            Table(filtered) {
                TableColumn("名称") { template in Text(template.name).fontWeight(.medium) }
                TableColumn("原始文件") { template in Text(template.fileName).foregroundStyle(.secondary) }
                TableColumn("操作") { template in HStack { Button("基于模板创建配置") { model.createProfile(from: template) }; Button("删除", role: .destructive) { model.state.templates.removeAll { $0.id == template.id }; model.persist() } } }
            }.padding(.horizontal)
            if model.state.templates.isEmpty { EmptyState(title: "还没有模板", detail: "导入 Mihomo YAML 作为配置模板。", actionTitle: "导入 YAML", action: add) }
        }
    }
    private var filtered: [ConfigTemplate] { model.state.templates.filter { model.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(model.searchText) } }
}

private struct EmptyState: View {
    let title: String; let detail: String; let actionTitle: String; let action: () -> Void
    var body: some View { VStack(spacing: 8) { Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary); Text(title).font(.headline); Text(detail).foregroundStyle(.secondary); Button(actionTitle, action: action).padding(.top, 6) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
}

private struct SourceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    var save: (String, String) -> Void
    var body: some View { VStack(alignment: .leading, spacing: 14) { Text("添加订阅").font(.title2.bold()); TextField("名称（可选）", text: $name); TextField("HTTP 或 HTTPS 订阅地址", text: $url); HStack { Spacer(); Button("取消") { dismiss() }; Button("添加并刷新") { save(name, url); dismiss() }.keyboardShortcut(.defaultAction).disabled(url.isEmpty) } }.padding(24).frame(width: 460) }
}

private struct NodeImportEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var raw = ""
    var save: (String) -> Void
    var body: some View { VStack(alignment: .leading, spacing: 14) { Text("导入节点").font(.title2.bold()); Text("粘贴 VMess、VLESS、Trojan、Shadowsocks 链接或 Mihomo YAML。每行一个链接。").foregroundStyle(.secondary); TextEditor(text: $raw).font(.system(.body, design: .monospaced)).frame(minHeight: 220).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary)); HStack { Button("从文件导入…") { openFile() }; Spacer(); Button("取消") { dismiss() }; Button("导入") { save(raw); dismiss() }.keyboardShortcut(.defaultAction).disabled(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }.padding(24).frame(width: 640, height: 390) }
    private func openFile() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "yaml") ?? .plainText, .data]; guard panel.runModal() == .OK, let url = panel.url else { return }; raw = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}

private struct TemplateImportEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var raw = ""
    @State private var fileName = "template.yaml"
    var save: (String, String) -> Void
    var body: some View { VStack(alignment: .leading, spacing: 14) { Text("导入 YAML 模板").font(.title2.bold()); TextField("文件名", text: $fileName); TextEditor(text: $raw).font(.system(.body, design: .monospaced)).frame(minHeight: 250).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary)); HStack { Button("打开 YAML 文件…") { openFile() }; Spacer(); Button("取消") { dismiss() }; Button("保存模板") { save(raw, fileName); dismiss() }.keyboardShortcut(.defaultAction).disabled(raw.isEmpty) } }.padding(24).frame(width: 700, height: 450) }
    private func openFile() { let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText, .plainText]; guard panel.runModal() == .OK, let url = panel.url else { return }; fileName = url.lastPathComponent; raw = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}

private struct RuleJSONEditor: View {
    let title: String
    @State var values: String
    var placeholder: String = "[]"
    var save: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text(title).font(.title2.bold()); Text("可编辑此结构化 JSON；保存时会校验字段格式。").foregroundStyle(.secondary) }; Spacer(); Button("保存") { save(values) }.buttonStyle(.borderedProminent) }
            TextEditor(text: $values).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden).padding(8).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }.padding(24)
    }
}

private struct ProvidersView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("规则集").font(.title2.bold()); Spacer(); Button("刷新全部") { Task { for provider in model.activeProfile.ruleProfile.providers { await model.refreshProvider(provider) } } } }.padding()
            Table(filtered) {
                TableColumn("名称") { provider in Text(provider.name).fontWeight(.medium) }
                TableColumn("类型") { provider in Text(provider.type + " · " + provider.format).foregroundStyle(.secondary) }
                TableColumn("地址") { provider in Text(provider.url.isEmpty ? "内嵌规则" : provider.url).lineLimit(1).textSelection(.enabled) }
                TableColumn("操作") { provider in Button("刷新") { Task { await model.refreshProvider(provider) } }.disabled(provider.url.isEmpty || model.isWorking) }
            }.padding(.horizontal)
            VStack(alignment: .leading, spacing: 10) {
                Text("规则集结构编辑").font(.headline)
                RuleJSONEditor(title: "规则集 JSON", values: encode(model.activeProfile.ruleProfile.providers), placeholder: "[]") { model.saveRuleText(providers: $0) }
                    .frame(maxHeight: 340)
            }.padding(.horizontal)
            if model.activeProfile.ruleProfile.providers.isEmpty { EmptyState(title: "还没有规则集", detail: "添加 HTTP、文件或内嵌规则集可在导出时写入配置。", actionTitle: "编辑规则集", action: {}) }
        }
    }
    private var filtered: [RuleProvider] { model.activeProfile.ruleProfile.providers.filter { model.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(model.searchText) || $0.url.localizedCaseInsensitiveContains(model.searchText) } }
    private func encode<T: Encodable>(_ value: T) -> String { guard let data = try? JSONEncoder.pretty.encode(value) else { return "[]" }; return String(decoding: data, as: UTF8.self) }
}

private struct SubRulesView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("子规则").font(.title2.bold())
            Text("子规则以 JSON 列表保留名称和规则顺序，可直接编辑并保存。").foregroundStyle(.secondary)
            RuleJSONEditor(title: "子规则 JSON", values: encode(model.activeProfile.ruleProfile.subRules)) { text in
                do {
                    let subRules = try JSONDecoder().decode([SubRuleProfile].self, from: Data(text.utf8))
                    var profile = model.activeProfile; profile.ruleProfile.subRules = subRules
                    if let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) { model.state.profiles[index] = profile }
                    model.persist(); model.notice = "子规则已保存。"
                } catch { model.notice = "子规则 JSON 无效：\(error.localizedDescription)" }
            }
        }.padding(24)
    }
    private func encode<T: Encodable>(_ value: T) -> String { guard let data = try? JSONEncoder.pretty.encode(value) else { return "[]" }; return String(decoding: data, as: UTF8.self) }
}

private struct DiagnosticsView: View {
    @Bindable var model: AppModel
    @Binding var input: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("校验与模拟").font(.title2.bold())
                let issues = RuleDiagnostics.inspect(model.activeProfile, nodeIDs: Set(model.state.nodes.map(\.id)))
                GroupBox("配置检查") {
                    if issues.isEmpty { Label("没有发现明显的规则引用问题。", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { VStack(alignment: .leading, spacing: 8) { ForEach(issues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) } } }
                }
                GroupBox("规则模拟") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("输入域名，查看第一条可识别规则的匹配结果。")
                        HStack { TextField("example.com", text: $input); Button("模拟") { } }
                        if !input.isEmpty {
                            if let rule = RuleSimulator.match(input, rules: model.activeProfile.ruleProfile.rules) {
                                Label("\(rule.type), \(rule.value) → \(rule.group)", systemImage: "arrow.turn.down.right").foregroundStyle(.tint)
                            } else { Text("当前简易模拟器未找到匹配项。").foregroundStyle(.secondary) }
                        }
                    }.padding(4)
                }
            }.padding(24)
        }
    }
}

private struct SettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("配置文件") {
                TextField("名称", text: binding(\.name))
                TextField("导出文件名", text: binding(\.fileName))
                Picker("节点来源", selection: binding(\.sourceMode)) {
                    Text("内嵌节点").tag("EMBED_NODES")
                    Text("引用订阅").tag("REFERENCE_SUBSCRIPTIONS")
                }
            }
            Section("Mihomo 常用设置") {
                NumberSetting(model: model, key: "mixed-port", title: "混合端口", defaultValue: 7890)
                ToggleSetting(model: model, key: "allow-lan", title: "允许局域网连接", defaultValue: false)
                ToggleSetting(model: model, key: "ipv6", title: "启用 IPv6", defaultValue: true)
                TextField("运行模式", text: jsonStringBinding("mode", fallback: "rule"))
                TextField("日志等级", text: jsonStringBinding("log-level", fallback: "info"))
            }
        }.formStyle(.grouped).padding(24).navigationTitle("基础配置")
    }
    private func binding(_ keyPath: WritableKeyPath<ConfigProfile, String>) -> Binding<String> { Binding(get: { model.activeProfile[keyPath: keyPath] }, set: { value in var profile = model.activeProfile; profile[keyPath: keyPath] = value; replace(profile) }) }
    private func replace(_ profile: ConfigProfile) { if let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) { model.state.profiles[index] = profile }; model.persist() }
    private func jsonStringBinding(_ key: String, fallback: String) -> Binding<String> { Binding(get: { model.activeProfile.mihomoSettings[key]?.stringValue ?? fallback }, set: { value in var profile = model.activeProfile; profile.mihomoSettings[key] = .string(value); replace(profile) }) }
}

private struct NumberSetting: View {
    @Bindable var model: AppModel; let key: String; let title: String; let defaultValue: Int
    var body: some View { TextField(title, value: Binding(get: { model.activeProfile.mihomoSettings[key]?.intValue ?? defaultValue }, set: { value in update(.integer(Int64(value))) }), format: .number).frame(maxWidth: 160) }
    private func update(_ value: JSONValue) { var profile = model.activeProfile; profile.mihomoSettings[key] = value; if let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) { model.state.profiles[index] = profile }; model.persist() }
}

private struct ToggleSetting: View {
    @Bindable var model: AppModel; let key: String; let title: String; let defaultValue: Bool
    var body: some View { Toggle(title, isOn: Binding(get: { model.activeProfile.mihomoSettings[key]?.boolValue ?? defaultValue }, set: { value in update(value) })) }
    private func update(_ value: Bool) { var profile = model.activeProfile; profile.mihomoSettings[key] = .bool(value); if let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) { model.state.profiles[index] = profile }; model.persist() }
}

private struct AdvancedYAMLView: View {
    @Bindable var model: AppModel
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { VStack(alignment: .leading) { Text("高级 YAML").font(.title2.bold()); Text("填写需要覆盖或补充的 Mihomo 根字段。").foregroundStyle(.secondary) }; Spacer(); Button("校验并保存") { save() }.buttonStyle(.borderedProminent) }
            TextEditor(text: $value).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden).padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }.padding(24).onAppear { value = model.activeProfile.advancedYaml ?? "" }
    }
    private func save() { do { if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { _ = try Yams.load(yaml: value) }; var profile = model.activeProfile; profile.advancedYaml = value; if let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) { model.state.profiles[index] = profile }; model.persist(); model.notice = "高级 YAML 已保存。" } catch { model.notice = "YAML 无效：\(error.localizedDescription)" } }
}

private struct ShareView: View {
    @Bindable var model: AppModel
    @Binding var sharing: Bool
    @Binding var shareURL: String?
    @Binding var shareServer: LocalShareServer?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading) { Text("配置导出").font(.title2.bold()); Text("目标内核：Mihomo（Clash.Meta）").foregroundStyle(.secondary) }; Spacer(); Picker("节点来源", selection: sourceMode) { Text("内嵌节点").tag("EMBED_NODES"); Text("引用订阅").tag("REFERENCE_SUBSCRIPTIONS") }.pickerStyle(.segmented).frame(width: 300) }
            HStack(spacing: 12) { Label("\(model.generatedConfig?.exportedNodes ?? 0) 个节点", systemImage: "point.3.connected.trianglepath.dotted"); if let generated = model.generatedConfig, generated.skippedNodes > 0 { Label("跳过 \(generated.skippedNodes) 个不支持节点", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }; Spacer(); Text(model.activeProfile.fileName + ".yaml").foregroundStyle(.secondary) }
            if let unresolved = model.generatedConfig?.unresolvedTemplateProviders, !unresolved.isEmpty {
                GroupBox("模板订阅绑定") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("选择兼容的 Mihomo 订阅后再导出。当前配置包含未绑定的模板订阅：\(unresolved.joined(separator: "、"))。")
                            .foregroundStyle(.orange)
                        ForEach(unresolved, id: \.self) { name in
                            Picker(name, selection: providerBinding(name)) {
                                Text("未绑定").tag(String?.none)
                                ForEach(model.state.sources.filter { $0.providerCompatible == true && model.activeProfile.selectedSourceIds.contains($0.id) }) { source in
                                    Text(source.name).tag(Optional(source.id))
                                }
                            }
                        }
                    }
                }
            }
            HStack { Button { saveYAML() } label: { Label("导出 YAML…", systemImage: "square.and.arrow.down") }.buttonStyle(.borderedProminent).disabled(hasUnresolved); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.generatedConfig?.yaml ?? "", forType: .string); model.notice = "YAML 已复制。" } label: { Label("复制", systemImage: "doc.on.doc") }.disabled(hasUnresolved); Button { preview() } label: { Label("打开预览窗口", systemImage: "eye") }; Button { toggleSharing() } label: { Label(sharing ? "停止局域网分享" : "开启局域网分享", systemImage: sharing ? "stop.fill" : "wifi") }.disabled(model.generatedConfig == nil || hasUnresolved) }
            if let shareURL { HStack(alignment: .top, spacing: 16) { QRCodeView(value: shareURL).frame(width: 160, height: 160).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading, spacing: 10) { Label("局域网分享已开启", systemImage: "wifi").font(.headline); Text(shareURL).font(.system(.body, design: .monospaced)).textSelection(.enabled); Text("接收设备需连接可互访的同一局域网。链接持有者可以下载当前配置，请只分享给信任的人。").foregroundStyle(.secondary); Button("复制分享链接") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(shareURL, forType: .string); model.notice = "分享链接已复制。" } } } }
            Text("生成的 YAML").font(.headline)
            if let yaml = model.generatedConfig?.yaml { TextEditor(text: .constant(yaml)).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden).padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).textSelection(.enabled) }
            else { ContentUnavailableView("无法生成配置", systemImage: "exclamationmark.triangle", description: Text("检查模板和高级 YAML 后重试。")) }
        }.padding(24)
    }
    private var hasUnresolved: Bool { !(model.generatedConfig?.unresolvedTemplateProviders.isEmpty ?? true) }
    private var sourceMode: Binding<String> { Binding(get: { model.activeProfile.sourceMode }, set: { var profile = model.activeProfile; profile.sourceMode = $0; if let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) { model.state.profiles[index] = profile }; model.persist() }) }
    private func providerBinding(_ name: String) -> Binding<String?> { Binding(get: { model.activeProfile.templateProviderBindings[name] }, set: { value in var profile = model.activeProfile; if let value { profile.templateProviderBindings[name] = value } else { profile.templateProviderBindings.removeValue(forKey: name) }; if let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) { model.state.profiles[index] = profile }; model.persist() }) }
    private func saveYAML() { guard let yaml = model.generatedConfig?.yaml else { return }; let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText]; panel.nameFieldStringValue = model.activeProfile.fileName + ".yaml"; guard panel.runModal() == .OK, let url = panel.url else { return }; do { try Data(yaml.utf8).write(to: url, options: .atomic); model.notice = "配置已导出到 \(url.lastPathComponent)。" } catch { model.notice = error.localizedDescription } }
    private func preview() { guard let yaml = model.generatedConfig?.yaml else { return }; let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false); preview.title = "配置预览 · \(model.activeProfile.fileName)"; preview.contentView = NSHostingView(rootView: TextEditor(text: .constant(yaml)).font(.system(.body, design: .monospaced))); preview.center(); preview.makeKeyAndOrderFront(nil) }
    private func toggleSharing() {
        if sharing { shareServer?.stop(); shareServer = nil; shareURL = nil; sharing = false; return }
        guard let yaml = model.generatedConfig?.yaml else { return }
        let server = LocalShareServer(config: yaml, fileName: model.activeProfile.fileName + ".yaml")
        Task { do { shareURL = try await server.start(); shareServer = server; sharing = true } catch { model.notice = error.localizedDescription } }
    }
}

private struct QRCodeView: View {
    let value: String
    var body: some View {
        if let image = makeImage() { Image(nsImage: image).interpolation(.none).resizable().scaledToFit() }
        else { Image(systemName: "qrcode").resizable().scaledToFit().padding(20).foregroundStyle(.secondary) }
    }
    private func makeImage() -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

@MainActor
final class LocalShareServer {
    private var listener: NWListener?
    private var config: String
    private var fileName: String
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let queue = DispatchQueue(label: "com.jichang.mac.share")

    init(config: String, fileName: String) { self.config = config; self.fileName = fileName }

    func update(config: String, fileName: String) { self.config = config; self.fileName = fileName }

    func start() async throws -> String {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.respond(to: connection) }
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: ServiceError.invalidURL) }
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard let address = Self.localAddress() else { stop(); throw ServiceError.invalidURL }
        return "http://\(address):\(port)/\(token)/config.yaml"
    }

    func stop() { listener?.cancel(); listener = nil }

    private func respond(to connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            Task { @MainActor in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let path = request.components(separatedBy: " ").dropFirst().first ?? ""
                let safeName = self.fileName.replacingOccurrences(of: "\"", with: "")
                let body: Data
                let status: String
                if path == "/\(self.token)/config.yaml" { body = Data(self.config.utf8); status = "200 OK" }
                else { body = Data("Not Found".utf8); status = "404 Not Found" }
                let header = "HTTP/1.1 \(status)\r\nContent-Type: application/yaml; charset=utf-8\r\nContent-Disposition: attachment; filename=\"\(safeName)\"\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                var response = Data(header.utf8); response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private static func localAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            let interface = item.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), String(cString: interface.ifa_name) != "lo0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                   let terminator = host.firstIndex(of: 0) {
                    return String(decoding: host[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            current = interface.ifa_next
        }
        return nil
    }
}

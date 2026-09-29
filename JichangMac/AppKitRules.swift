import AppKit
import Yams

@MainActor
final class RulesPage: WorkspacePage, NSTableViewDataSource, NSTableViewDelegate {
    private enum Kind: Int {
        case groups, rules, providers, subRules, diagnostics, settings, yaml
        var isEditorOnly: Bool { rawValue >= Kind.diagnostics.rawValue }
        var title: String { ["策略组", "分流规则", "规则集", "子规则", "配置校验", "常规配置", "高级 YAML"][rawValue] }
        var subtitle: String {
            switch self {
            case .groups: "编辑策略组类型与成员"
            case .rules: "按顺序编辑 Mihomo 分流规则"
            case .providers: "管理并刷新远程规则集"
            case .subRules: "维护规则集引用的子规则"
            case .diagnostics: "检查引用并模拟规则匹配"
            case .settings: "配置端口、运行模式与网络行为"
            case .yaml: "编辑需要覆盖或补充的根级 YAML 字段"
            }
        }
    }
    private struct Row: Equatable { let id: String; let values: [String] }
    private let table = NSTableView()
    private let search = NSSearchField()
    private let inspector = UI.vertical([], spacing: 11)
    private let editor = UI.vertical([], spacing: 14)
    private let split = NSSplitView()
    private let addButton = UI.button("新增", symbol: "plus", target: nil, action: nil)
    private let advancedButton = UI.button("高级 JSON…", symbol: "curlybraces", target: nil, action: nil)
    private var pageHeader: NSStackView?
    private let status = UI.secondary("")
    private var kind: Kind
    private var rows: [Row] = []
    private var selectedID: String?
    private var reloading = false
    private var fields: [NSTextField] = []
    private var editorText: NSTextView?
    private var membersEditor: NSTextView?
    private var allowLAN = NSButton(checkboxWithTitle: "允许局域网连接", target: nil, action: nil)
    private var ipv6 = NSButton(checkboxWithTitle: "启用 IPv6", target: nil, action: nil)
    private let settingsMode = NSSegmentedControl(labels: ["表单", "YAML"], trackingMode: .selectOne, target: nil, action: nil)
    private var settingsForm: NSStackView?
    private var settingsYAMLScroll: NSScrollView?
    private var settingsYAMLText: NSTextView?
    private let settingsFormSaveButton = UI.button("保存配置", target: nil, action: nil, prominent: true)
    private let settingsYAMLSaveButton = UI.button("校验并保存", target: nil, action: nil, prominent: true)

    init(model: AppModel, workspace: WorkspaceController, initialTab: Int = 0) {
        kind = Kind(rawValue: initialTab) ?? .groups
        super.init(model: model, workspace: workspace)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        inspector.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        search.placeholderString = "搜索规则"; search.target = self; search.action = #selector(refreshFromSearch)
        search.widthAnchor.constraint(equalToConstant: 190).isActive = true
        addButton.target = self; addButton.action = #selector(add)
        advancedButton.target = self; advancedButton.action = #selector(advanced)
        settingsFormSaveButton.target = self; settingsFormSaveButton.action = #selector(saveSettings)
        settingsYAMLSaveButton.target = self; settingsYAMLSaveButton.action = #selector(saveSettingsYAML)
        table.rowHeight = 30; table.style = .inset
        table.delegate = self; table.dataSource = self
        let columns: [(String, String, CGFloat)]
        switch kind {
        case .rules: columns = [("index", "序号", 54), ("type", "类型", 130), ("value", "匹配值", 300), ("target", "策略", 150)]
        case .groups: columns = [("name", "名称", 190), ("type", "类型", 130), ("members", "成员", 100)]
        case .providers: columns = [("name", "名称", 160), ("behavior", "行为", 110), ("url", "来源地址", 320)]
        case .subRules: columns = [("name", "名称", 180), ("count", "规则数", 100)]
        default: columns = [("name", "名称", 180)]
        }
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let list = UI.scroll(table); list.borderType = .bezelBorder
        let inspectorScroll = UI.scroll(inspector)
        split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(list); split.addArrangedSubview(inspectorScroll)
        split.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        let heading = UI.header(kind.title, subtitle: kind.subtitle)
        if kind.isEditorOnly {
            let header = UI.horizontal([heading, NSView()])
            pageHeader = header
            root.addSubview(header)
            root.addSubview(editor)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
                header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
                header.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
                header.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
                editor.leadingAnchor.constraint(equalTo: header.leadingAnchor),
                editor.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                editor.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
                editor.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
            ])
        } else {
            let header = UI.horizontal([heading, NSView(), advancedButton, addButton])
            let controls = UI.horizontal([NSView(), search])
            pageHeader = header
            root.addSubview(header)
            root.addSubview(controls)
            root.addSubview(split)
            root.addSubview(status)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
                header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
                header.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
                controls.leadingAnchor.constraint(equalTo: header.leadingAnchor),
                controls.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                controls.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
                split.leadingAnchor.constraint(equalTo: header.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                split.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
                split.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
                status.leadingAnchor.constraint(equalTo: header.leadingAnchor),
                status.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
                list.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
                inspectorScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 310),
                inspector.widthAnchor.constraint(equalTo: inspectorScroll.contentView.widthAnchor)
            ])
        }
        view = root
        if kind.isEditorOnly {
            renderEditor()
            updateSettingsHeaderAction()
            editor.setContentHuggingPriority(.defaultLow, for: .vertical)
        }
    }

    override func refresh() {
        let query = search.stringValue
        let profile = model.activeProfile
        let all: [Row]
        switch kind {
        case .groups: all = profile.ruleProfile.groups.map { Row(id: $0.name, values: [$0.name, $0.type, "\($0.members.count) 个"]) }
        case .rules: all = profile.ruleProfile.rules.enumerated().map { Row(id: String($0.offset), values: [String($0.offset + 1), $0.element.type, $0.element.value, $0.element.group]) }
        case .providers: all = profile.ruleProfile.providers.map { Row(id: $0.id, values: [$0.name, $0.behavior, $0.url.isEmpty ? "内嵌规则" : $0.url]) }
        case .subRules: all = profile.ruleProfile.subRules.map { Row(id: $0.name, values: [$0.name, "\($0.rules.count) 条"]) }
        default: all = []
        }
        let filtered = all.filter { query.isEmpty || $0.values.contains { $0.localizedCaseInsensitiveContains(query) } }
        if rows != filtered { reloading = true; rows = filtered; table.reloadData(); reloading = false }
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        } else { selectedID = nil; if table.selectedRow >= 0 { table.deselectAll(nil) } }
        if !kind.isEditorOnly { addButton.title = "新增\(kind.title)" }
        updateSettingsHeaderAction()
        status.stringValue = kind.isEditorOnly ? "" : (kind == .rules ? "\(rows.count) 条规则 · 按列表顺序匹配" : "\(rows.count) 项")
        if kind.isEditorOnly { renderEditor() }
        else if !(view.window?.firstResponder is NSTextView) { renderInspector() }
        if kind.isEditorOnly {
            view.layoutSubtreeIfNeeded()
            editor.layoutSubtreeIfNeeded()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        guard let tableColumn else { return nil }
        let cell = NSTableCellView()
        let columnIndex = tableView.tableColumns.firstIndex(of: tableColumn) ?? 0
        let value = rows[row].values.indices.contains(columnIndex) ? rows[row].values[columnIndex] : ""
        let label = UI.label(value)
        label.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        renderInspector()
    }
    @objc private func refreshFromSearch() { refresh() }
    @objc private func add() { selectedID = nil; table.deselectAll(nil); renderInspector(new: true) }
    @objc private func advanced() {
        let profile = model.activeProfile
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data?
        switch kind {
        case .groups: data = try? encoder.encode(profile.ruleProfile.groups)
        case .rules: data = try? encoder.encode(profile.ruleProfile.rules)
        case .providers: data = try? encoder.encode(profile.ruleProfile.providers)
        case .subRules: data = try? encoder.encode(profile.ruleProfile.subRules)
        default: return
        }
        guard let data, let text = UI.textPrompt("高级 JSON", initial: String(decoding: data, as: UTF8.self), explanatory: "保存时会校验 JSON 结构。") else { return }
        switch kind {
        case .groups: model.saveRuleText(groups: text)
        case .rules: model.saveRuleText(rules: text)
        case .providers: model.saveRuleText(providers: text)
        case .subRules:
            do { var profile = model.activeProfile; profile.ruleProfile.subRules = try JSONDecoder().decode([SubRuleProfile].self, from: Data(text.utf8)); replace(profile) }
            catch { UI.alert("JSON 无效：\(error.localizedDescription)") }
        default: break
        }
    }
    private func addField(_ label: String, value: String, to stack: NSStackView) {
        let field = NSTextField(string: value); field.placeholderString = label
        let caption = UI.secondary(label)
        let group = UI.vertical([caption, field], spacing: 4)
        stack.addArrangedSubview(group)
        if stack === inspector { field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        else { field.widthAnchor.constraint(equalToConstant: 420).isActive = true }
        fields.append(field)
    }
    private func renderInspector(new: Bool = false) {
        for child in inspector.arrangedSubviews { inspector.removeArrangedSubview(child); child.removeFromSuperview() }
        fields = []
        membersEditor = nil
        guard !split.isHidden else { return }
        if selectedID == nil && !new { inspector.addArrangedSubview(UI.secondary("选择一项以编辑，或点按“新增”。")); return }
        inspector.addArrangedSubview(UI.label(new ? "新增" : "详细信息", style: .headline, weight: .semibold))
        let profile = model.activeProfile
        switch kind {
        case .groups:
            let group = profile.ruleProfile.groups.first { $0.name == selectedID }
            addField("名称", value: group?.name ?? "", to: inspector)
            addField("类型（select、url-test 等）", value: group?.type ?? "select", to: inspector)
            inspector.addArrangedSubview(UI.secondary("成员（每行一个名称）"))
            let (membersScroll, membersView) = UI.textEditor(group?.members.joined(separator: "\n") ?? "")
            membersEditor = membersView
            inspector.addArrangedSubview(membersScroll)
            membersScroll.widthAnchor.constraint(equalTo: inspector.widthAnchor, constant: -32).isActive = true
            membersScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        case .rules:
            let rule = selectedID.flatMap(Int.init).flatMap { profile.ruleProfile.rules.indices.contains($0) ? profile.ruleProfile.rules[$0] : nil }
            addField("类型（如 DOMAIN-SUFFIX）", value: rule?.type ?? "DOMAIN-SUFFIX", to: inspector)
            addField("匹配值", value: rule?.value ?? "", to: inspector)
            addField("目标策略组", value: rule?.group ?? profile.ruleProfile.groups.first?.name ?? "PROXY", to: inspector)
            if let rule, !rule.conditions.isEmpty { inspector.addArrangedSubview(UI.secondary("组合条件请使用高级 JSON 编辑。")) }
        case .providers:
            let provider = profile.ruleProfile.providers.first { $0.id == selectedID }
            addField("名称", value: provider?.name ?? "", to: inspector)
            addField("地址", value: provider?.url ?? "", to: inspector)
            addField("行为（domain、ipcidr、classical）", value: provider?.behavior ?? "domain", to: inspector)
            if provider != nil { inspector.addArrangedSubview(UI.button("刷新规则集", symbol: "arrow.clockwise", target: self, action: #selector(refreshProvider))) }
        case .subRules:
            let sub = profile.ruleProfile.subRules.first { $0.name == selectedID }
            addField("名称", value: sub?.name ?? "", to: inspector)
            inspector.addArrangedSubview(UI.secondary("子规则列表请使用高级 JSON 编辑。"))
        default: break
        }
        inspector.addArrangedSubview(UI.horizontal([UI.button("保存", target: self, action: #selector(saveItem), prominent: true), UI.button("删除", target: self, action: #selector(deleteItem))]))
    }
    @objc private func saveItem() {
        let values = fields.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        var profile = model.activeProfile
        switch kind {
        case .groups:
            guard values.count == 2, !values[0].isEmpty else { UI.alert("请输入策略组名称。") ; return }
            guard !profile.ruleProfile.groups.contains(where: { $0.name == values[0] && $0.name != selectedID }) else { UI.alert("策略组名称已存在。") ; return }
            var group = profile.ruleProfile.groups.first { $0.name == selectedID } ?? PolicyGroup(name: values[0])
            let oldName = group.name
            group.name = values[0]; group.type = values[1].isEmpty ? "select" : values[1]
            group.members = (membersEditor?.string ?? "").split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            group.membersExplicit = true
            if let index = profile.ruleProfile.groups.firstIndex(where: { $0.name == selectedID }) { profile.ruleProfile.groups[index] = group }
            else { profile.ruleProfile.groups.append(group) }
            if oldName != group.name {
                for index in profile.ruleProfile.rules.indices where profile.ruleProfile.rules[index].group == oldName { profile.ruleProfile.rules[index].group = group.name }
                for index in profile.ruleProfile.groups.indices { profile.ruleProfile.groups[index].members = profile.ruleProfile.groups[index].members.map { $0 == oldName ? group.name : $0 } }
                for subIndex in profile.ruleProfile.subRules.indices { for ruleIndex in profile.ruleProfile.subRules[subIndex].rules.indices where profile.ruleProfile.subRules[subIndex].rules[ruleIndex].group == oldName { profile.ruleProfile.subRules[subIndex].rules[ruleIndex].group = group.name } }
            }
            selectedID = group.name
        case .rules:
            guard values.count == 3, !values[0].isEmpty, !values[2].isEmpty, !values[1].isEmpty || values[0].uppercased() == "MATCH" else { UI.alert("规则条件不完整。") ; return }
            var rule = selectedID.flatMap(Int.init).flatMap { profile.ruleProfile.rules.indices.contains($0) ? profile.ruleProfile.rules[$0] : nil } ?? RoutingRule(type: values[0], value: values[1], group: values[2])
            if !rule.conditions.isEmpty || ["AND", "OR", "NOT"].contains(rule.type.uppercased()) {
                UI.alert("组合规则请使用高级 JSON 编辑。")
                return
            }
            rule.type = values[0].uppercased(); rule.value = values[1]; rule.group = values[2]; rule.rawLine = nil
            if let index = selectedID.flatMap(Int.init), profile.ruleProfile.rules.indices.contains(index) { profile.ruleProfile.rules[index] = rule }
            else { profile.ruleProfile.rules.append(rule); selectedID = String(profile.ruleProfile.rules.count - 1) }
        case .providers:
            guard values.count == 3, !values[0].isEmpty else { UI.alert("请输入规则集名称。") ; return }
            guard !profile.ruleProfile.providers.contains(where: { $0.name == values[0] && $0.id != selectedID }) else { UI.alert("规则集名称已存在。") ; return }
            var provider = profile.ruleProfile.providers.first { $0.id == selectedID } ?? RuleProvider(id: UUID().uuidString, name: values[0])
            provider.name = values[0]; provider.url = values[1]; provider.behavior = values[2].isEmpty ? "domain" : values[2]
            if provider.path.isEmpty { provider.path = "./rule-providers/\(provider.name).yaml" }
            if let index = profile.ruleProfile.providers.firstIndex(where: { $0.id == selectedID }) { profile.ruleProfile.providers[index] = provider }
            else { profile.ruleProfile.providers.append(provider) }
            selectedID = provider.id
        case .subRules:
            guard let name = values.first, !name.isEmpty else { UI.alert("请输入子规则名称。") ; return }
            guard !profile.ruleProfile.subRules.contains(where: { $0.name == name && $0.name != selectedID }) else { UI.alert("子规则名称已存在。") ; return }
            if let index = profile.ruleProfile.subRules.firstIndex(where: { $0.name == selectedID }) { profile.ruleProfile.subRules[index].name = name }
            else { profile.ruleProfile.subRules.append(SubRuleProfile(name: name)) }
            selectedID = name
        default: return
        }
        replace(profile)
    }
    @objc private func deleteItem() {
        guard let selectedID else { return }
        let alert = NSAlert(); alert.messageText = "删除所选项目？"; alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var profile = model.activeProfile
        switch kind {
        case .groups: profile.ruleProfile.groups.removeAll { $0.name == selectedID }
        case .rules: if let index = Int(selectedID), profile.ruleProfile.rules.indices.contains(index) { profile.ruleProfile.rules.remove(at: index) }
        case .providers: profile.ruleProfile.providers.removeAll { $0.id == selectedID }
        case .subRules: profile.ruleProfile.subRules.removeAll { $0.name == selectedID }
        default: return
        }
        self.selectedID = nil; replace(profile)
    }
    @objc private func refreshProvider() {
        guard let selectedID, let provider = model.activeProfile.ruleProfile.providers.first(where: { $0.id == selectedID }) else { return }
        Task { await model.refreshProvider(provider) }
    }
    private func replace(_ profile: ConfigProfile) {
        guard let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        model.state.profiles[index] = profile; model.persist()
    }
    private func renderEditor() {
        for child in editor.arrangedSubviews { editor.removeArrangedSubview(child); child.removeFromSuperview() }
        editorText = nil; fields = []
        settingsForm = nil; settingsYAMLScroll = nil; settingsYAMLText = nil
        let profile = model.activeProfile
        switch kind {
        case .diagnostics:
            let issues = RuleDiagnostics.inspect(profile, nodeIDs: Set(model.state.nodes.map(\.id)))
            editor.addArrangedSubview(UI.label(issues.isEmpty ? "配置有效" : "问题  \(issues.count)", style: .headline, weight: .semibold))
            if issues.isEmpty {
                editor.addArrangedSubview(UI.secondary("没有发现规则引用问题。"))
            } else {
                for (index, issue) in issues.enumerated() {
                    let row = UI.horizontal([UI.secondary("\(index + 1)."), UI.label(issue)])
                    row.alignment = .top
                    editor.addArrangedSubview(row)
                }
            }
            editor.addArrangedSubview(UI.separator())
            editor.addArrangedSubview(UI.label("规则模拟", style: .headline, weight: .semibold))
            addField("域名，例如 example.com", value: "", to: editor)
            editor.addArrangedSubview(UI.button("模拟", target: self, action: #selector(simulate)))
        case .settings:
            editor.addArrangedSubview(UI.label("基础配置", style: .headline, weight: .semibold))
            settingsMode.selectedSegment = 0
            settingsMode.target = self; settingsMode.action = #selector(changeSettingsMode)
            editor.addArrangedSubview(settingsMode)
            let settingsHint = UI.secondary("YAML 模式编辑 Mihomo 根参数；完整配置补充项请使用“高级 YAML”。")
            editor.addArrangedSubview(settingsHint)
            let form = UI.vertical([], spacing: 14)
            settingsForm = form
            addField("配置名称", value: profile.name, to: form)
            addField("导出文件名", value: profile.fileName, to: form)
            form.addArrangedSubview(UI.separator())
            form.addArrangedSubview(UI.label("网络", style: .headline, weight: .semibold))
            addField("混合端口", value: String(profile.mihomoSettings["mixed-port"]?.intValue ?? 7890), to: form)
            form.addArrangedSubview(UI.label("行为", style: .headline, weight: .semibold))
            addField("运行模式", value: profile.mihomoSettings["mode"]?.stringValue ?? "rule", to: form)
            allowLAN.state = (profile.mihomoSettings["allow-lan"]?.boolValue ?? false) ? .on : .off
            ipv6.state = (profile.mihomoSettings["ipv6"]?.boolValue ?? true) ? .on : .off
            form.addArrangedSubview(allowLAN)
            form.addArrangedSubview(ipv6)
            editor.addArrangedSubview(form)
            let settings = settingsValues(profile)
            let (yamlScroll, yamlText) = UI.textEditor((try? Yams.dump(object: settings)) ?? "")
            settingsYAMLScroll = yamlScroll; settingsYAMLText = yamlText
            yamlScroll.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
            yamlScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        case .yaml:
            editor.addArrangedSubview(UI.label("高级 YAML", style: .headline, weight: .semibold))
            editor.addArrangedSubview(UI.secondary("填写需要覆盖或补充的 Mihomo 根字段。"))
            let (scroll, textView) = UI.textEditor(profile.advancedYaml ?? "")
            editorText = textView; editor.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
            editor.addArrangedSubview(UI.button("校验并保存", target: self, action: #selector(saveYaml), prominent: true))
        default: break
        }
    }
    @objc private func simulate() {
        guard let input = fields.first?.stringValue else { return }
        let match = RuleSimulator.match(input, rules: model.activeProfile.ruleProfile.rules)
        UI.alert(match.map { "\($0.type), \($0.value) → \($0.group)" } ?? "未找到匹配规则。")
    }
    @objc private func saveSettings() {
        guard fields.count == 4, let port = Int(fields[2].stringValue), (1...65535).contains(port) else { UI.alert("请输入有效端口。") ; return }
        var profile = model.activeProfile
        profile.name = fields[0].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.fileName = fields[1].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty, !profile.fileName.isEmpty else { UI.alert("名称和文件名不能为空。") ; return }
        profile.mihomoSettings["mixed-port"] = .integer(Int64(port))
        profile.mihomoSettings["mode"] = .string(fields[3].stringValue)
        profile.mihomoSettings["allow-lan"] = .bool(allowLAN.state == .on)
        profile.mihomoSettings["ipv6"] = .bool(ipv6.state == .on)
        replace(profile)
    }
    @objc private func changeSettingsMode() {
        let useYAML = settingsMode.selectedSegment == 1
        let remove: [NSView?] = useYAML ? [settingsForm] : [settingsYAMLScroll]
        for view in remove.compactMap({ $0 }) {
            editor.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let insert: [NSView?] = useYAML ? [settingsYAMLScroll] : [settingsForm]
        for view in insert.compactMap({ $0 }) { editor.addArrangedSubview(view) }
        updateSettingsHeaderAction()
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()
    }
    private func updateSettingsHeaderAction() {
        for button in [settingsFormSaveButton, settingsYAMLSaveButton] {
            pageHeader?.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        guard kind == .settings, let pageHeader else { return }
        pageHeader.insertArrangedSubview(settingsMode.selectedSegment == 1 ? settingsYAMLSaveButton : settingsFormSaveButton, at: 2)
    }
    @objc private func saveSettingsYAML() {
        guard let source = settingsYAMLText?.string else { return }
        do {
            guard let parsed = try Yams.load(yaml: source) as? [String: Any] else { UI.alert("YAML 根节点必须是配置对象。"); return }
            var profile = model.activeProfile
            profile.mihomoSettings = parsed.mapValues(JSONValue.init(foundationValue:))
            replace(profile)
        } catch { UI.alert("YAML 无效：\(error.localizedDescription)") }
    }
    private func settingsValues(_ profile: ConfigProfile) -> [String: Any] {
        var values: [String: Any] = [
            "mixed-port": 7890,
            "allow-lan": false,
            "mode": "rule",
            "log-level": "info",
            "ipv6": true
        ]
        for (key, value) in profile.mihomoSettings { values[key] = value.foundationValue }
        return values
    }
    @objc private func saveYaml() {
        guard let value = editorText?.string else { return }
        do { if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { guard try Yams.load(yaml: value) is [String: Any] else { UI.alert("YAML 根节点必须是配置对象。") ; return } }
            var profile = model.activeProfile; profile.advancedYaml = value; replace(profile)
        } catch { UI.alert("YAML 无效：\(error.localizedDescription)") }
    }
}

@MainActor
final class ConfigurationPage: WorkspacePage {
    private let destination: WorkspaceDestination
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let settingsMode = NSSegmentedControl(labels: ["表单", "YAML"], trackingMode: .selectOne, target: nil, action: nil)
    private let settingsForm = NSView()
    private let settingsFormSave = UI.button("保存配置", target: nil, action: nil, prominent: true)
    private let settingsYAMLSave = UI.button("校验并保存", target: nil, action: nil, prominent: true)
    private let yamlSave = UI.button("校验并保存", target: nil, action: nil, prominent: true)
    private let allowLAN = NSButton(checkboxWithTitle: "允许局域网连接", target: nil, action: nil)
    private let ipv6 = NSButton(checkboxWithTitle: "启用 IPv6", target: nil, action: nil)
    private var settingsFields: [NSTextField] = []
    private var settingsYAMLScroll: NSScrollView?
    private var settingsYAMLText: NSTextView?
    private var advancedText: NSTextView?
    private var settingsFormContainer: NSView?
    private var issuesContainer: NSView?
    private var simulationField: NSTextField?

    init(model: AppModel, workspace: WorkspaceController, destination: WorkspaceDestination) {
        self.destination = destination
        titleLabel = UI.label(destination.title, style: .title1, weight: .semibold)
        subtitleLabel = UI.secondary(Self.subtitle(for: destination))
        super.init(model: model, workspace: workspace)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let root = NSView()
        [titleLabel, subtitleLabel].forEach(root.addSubview)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -180),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            titleLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)
        ])

        switch destination {
        case .settings: buildSettings(in: root)
        case .yaml: buildAdvancedYAML(in: root)
        case .diagnostics: buildDiagnostics(in: root)
        default: break
        }
        view = root
    }

    override func refresh() {
        switch destination {
        case .settings:
            renderSettings()
        case .yaml:
            if let text = advancedText, text.string != (model.activeProfile.advancedYaml ?? "") {
                text.string = model.activeProfile.advancedYaml ?? ""
            }
        case .diagnostics:
            renderIssues()
        default: break
        }
    }

    private func buildSettings(in root: NSView) {
        settingsMode.selectedSegment = 0
        settingsMode.target = self
        settingsMode.action = #selector(changeSettingsMode)
        settingsMode.translatesAutoresizingMaskIntoConstraints = false
        settingsFormSave.target = self
        settingsFormSave.action = #selector(saveSettingsForm)
        settingsFormSave.translatesAutoresizingMaskIntoConstraints = false
        settingsYAMLSave.target = self
        settingsYAMLSave.action = #selector(saveSettingsYAML)
        settingsYAMLSave.translatesAutoresizingMaskIntoConstraints = false
        settingsYAMLSave.isHidden = true
        settingsForm.translatesAutoresizingMaskIntoConstraints = false
        [settingsMode, settingsForm, settingsFormSave, settingsYAMLSave].forEach(root.addSubview)

        let form = NSView()
        form.translatesAutoresizingMaskIntoConstraints = false
        settingsFormContainer = form
        settingsForm.addSubview(form)
        let yaml = UI.textEditor("", editable: true)
        settingsYAMLScroll = yaml.0
        settingsYAMLText = yaml.1
        yaml.0.isHidden = true
        root.addSubview(yaml.0)
        yaml.0.isHidden = true
        NSLayoutConstraint.activate([
            settingsMode.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            settingsMode.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            settingsMode.widthAnchor.constraint(equalToConstant: 150),
            settingsForm.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            settingsForm.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            settingsForm.topAnchor.constraint(equalTo: settingsMode.bottomAnchor, constant: 12),
            settingsForm.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            form.leadingAnchor.constraint(equalTo: settingsForm.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: settingsForm.trailingAnchor),
            form.topAnchor.constraint(equalTo: settingsForm.topAnchor),
            form.bottomAnchor.constraint(equalTo: settingsForm.bottomAnchor),
            yaml.0.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            yaml.0.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            yaml.0.topAnchor.constraint(equalTo: settingsMode.bottomAnchor, constant: 12),
            yaml.0.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            settingsFormSave.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            settingsFormSave.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            settingsYAMLSave.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            settingsYAMLSave.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        ])
        form.addSubview(allowLAN)
        form.addSubview(ipv6)
    }

    private func renderSettings() {
        guard let form = settingsFormContainer else { return }
        for child in form.subviews where child !== allowLAN && child !== ipv6 {
            child.removeFromSuperview()
        }
        settingsFields = []
        let profile = model.activeProfile
        var top = form.topAnchor
        let name = addField("配置名称", value: profile.name, to: form, below: top, offset: 0)
        top = name.bottomAnchor
        let file = addField("导出文件名", value: profile.fileName, to: form, below: top, offset: 14)
        top = file.bottomAnchor
        let port = addField("混合端口", value: String(profile.mihomoSettings["mixed-port"]?.intValue ?? 7890), to: form, below: top, offset: 14)
        top = port.bottomAnchor
        let mode = addField("运行模式", value: profile.mihomoSettings["mode"]?.stringValue ?? "rule", to: form, below: top, offset: 14)
        allowLAN.state = (profile.mihomoSettings["allow-lan"]?.boolValue ?? false) ? .on : .off
        ipv6.state = (profile.mihomoSettings["ipv6"]?.boolValue ?? true) ? .on : .off
        allowLAN.translatesAutoresizingMaskIntoConstraints = false
        ipv6.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            allowLAN.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            allowLAN.topAnchor.constraint(equalTo: mode.bottomAnchor, constant: 16),
            ipv6.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            ipv6.topAnchor.constraint(equalTo: allowLAN.bottomAnchor, constant: 10)
        ])
        if let settingsYAMLText {
            settingsYAMLText.string = (try? Yams.dump(object: settingsValues(profile))) ?? ""
        }
    }

    private func addField(_ caption: String, value: String, to parent: NSView, below anchor: NSLayoutYAxisAnchor, offset: CGFloat) -> NSTextField {
        let label = UI.secondary(caption)
        let field = NSTextField(string: value)
        field.placeholderString = caption
        [label, field].forEach(parent.addSubview)
        label.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            label.topAnchor.constraint(equalTo: anchor, constant: offset),
            field.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            field.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            field.widthAnchor.constraint(equalToConstant: 420),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 22)
        ])
        settingsFields.append(field)
        return field
    }

    private func buildAdvancedYAML(in root: NSView) {
        let save = yamlSave
        save.target = self
        save.action = #selector(saveAdvancedYAML)
        save.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(save)
        let description = UI.secondary("填写需要覆盖或补充的 Mihomo 根级 YAML 字段。")
        let editor = UI.textEditor(model.activeProfile.advancedYaml ?? "")
        advancedText = editor.1
        root.addSubview(description)
        root.addSubview(editor.0)
        NSLayoutConstraint.activate([
            save.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            save.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            description.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            description.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            editor.0.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            editor.0.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            editor.0.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 10),
            editor.0.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
    }

    private func buildDiagnostics(in root: NSView) {
        let issues = NSView()
        issuesContainer = issues
        let label = UI.label("规则模拟", style: .headline, weight: .semibold)
        let domain = NSTextField(string: "")
        domain.placeholderString = "域名，例如 example.com"
        domain.translatesAutoresizingMaskIntoConstraints = false
        simulationField = domain
        let simulate = UI.button("模拟", target: self, action: #selector(simulateRule))
        simulate.translatesAutoresizingMaskIntoConstraints = false
        issues.translatesAutoresizingMaskIntoConstraints = false
        [issues, label, domain, simulate].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            issues.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            issues.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            issues.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            issues.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            label.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            label.topAnchor.constraint(equalTo: issues.bottomAnchor, constant: 20),
            domain.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            domain.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            domain.widthAnchor.constraint(equalToConstant: 420),
            simulate.leadingAnchor.constraint(equalTo: domain.trailingAnchor, constant: 8),
            simulate.centerYAnchor.constraint(equalTo: domain.centerYAnchor)
        ])
        renderIssues()
    }

    private func renderIssues() {
        guard let issuesContainer else { return }
        for child in issuesContainer.subviews { child.removeFromSuperview() }
        let issues = RuleDiagnostics.inspect(model.activeProfile, nodeIDs: Set(model.state.nodes.map(\.id)))
        let heading = UI.label(issues.isEmpty ? "配置有效" : "问题  \(issues.count)", style: .headline, weight: .semibold)
        issuesContainer.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: issuesContainer.leadingAnchor),
            heading.topAnchor.constraint(equalTo: issuesContainer.topAnchor)
        ])
        var previous = heading.bottomAnchor
        if issues.isEmpty {
            let ok = UI.secondary("没有发现规则引用问题。")
            issuesContainer.addSubview(ok)
            NSLayoutConstraint.activate([
                ok.leadingAnchor.constraint(equalTo: issuesContainer.leadingAnchor),
                ok.topAnchor.constraint(equalTo: previous, constant: 8)
            ])
            previous = ok.bottomAnchor
        } else {
            for (index, issue) in issues.enumerated() {
                let row = UI.label("\(index + 1).  \(issue)")
                issuesContainer.addSubview(row)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: issuesContainer.leadingAnchor),
                    row.trailingAnchor.constraint(lessThanOrEqualTo: issuesContainer.trailingAnchor),
                    row.topAnchor.constraint(equalTo: previous, constant: 8)
                ])
                previous = row.bottomAnchor
            }
        }
        let bottom = previous.constraint(equalTo: issuesContainer.bottomAnchor)
        bottom.priority = .defaultLow
        bottom.isActive = true
    }

    @objc private func changeSettingsMode() {
        let useYAML = settingsMode.selectedSegment == 1
        settingsForm.isHidden = useYAML
        settingsYAMLScroll?.isHidden = !useYAML
        settingsFormSave.isHidden = useYAML
        settingsYAMLSave.isHidden = !useYAML
    }

    @objc private func saveSettingsForm() {
        guard settingsFields.count == 4,
              let port = Int(settingsFields[2].stringValue), (1...65535).contains(port) else {
            UI.alert("请输入有效端口。")
            return
        }
        var profile = model.activeProfile
        profile.name = settingsFields[0].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.fileName = settingsFields[1].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty, !profile.fileName.isEmpty else { UI.alert("名称和文件名不能为空。"); return }
        profile.mihomoSettings["mixed-port"] = .integer(Int64(port))
        profile.mihomoSettings["mode"] = .string(settingsFields[3].stringValue)
        profile.mihomoSettings["allow-lan"] = .bool(allowLAN.state == .on)
        profile.mihomoSettings["ipv6"] = .bool(ipv6.state == .on)
        save(profile)
    }

    @objc private func saveSettingsYAML() {
        guard let source = settingsYAMLText?.string else { return }
        do {
            guard let parsed = try Yams.load(yaml: source) as? [String: Any] else { UI.alert("YAML 根节点必须是配置对象。"); return }
            var profile = model.activeProfile
            profile.mihomoSettings = parsed.mapValues(JSONValue.init(foundationValue:))
            save(profile)
        } catch { UI.alert("YAML 无效：\(error.localizedDescription)") }
    }

    @objc private func saveAdvancedYAML() {
        guard let source = advancedText?.string else { return }
        do {
            if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard try Yams.load(yaml: source) is [String: Any] else { UI.alert("YAML 根节点必须是配置对象。"); return }
            }
            var profile = model.activeProfile
            profile.advancedYaml = source
            save(profile)
        } catch { UI.alert("YAML 无效：\(error.localizedDescription)") }
    }

    @objc private func simulateRule() {
        guard let input = simulationField?.stringValue else { return }
        let match = RuleSimulator.match(input, rules: model.activeProfile.ruleProfile.rules)
        UI.alert(match.map { "\($0.type), \($0.value) → \($0.group)" } ?? "未找到匹配规则。")
    }

    private func save(_ profile: ConfigProfile) {
        guard let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        model.state.profiles[index] = profile
        model.persist()
    }

    private func settingsValues(_ profile: ConfigProfile) -> [String: Any] {
        var values: [String: Any] = ["mixed-port": 7890, "allow-lan": false, "mode": "rule", "log-level": "info", "ipv6": true]
        for (key, value) in profile.mihomoSettings { values[key] = value.foundationValue }
        return values
    }

    private static func subtitle(for destination: WorkspaceDestination) -> String {
        switch destination {
        case .settings: "配置端口、运行模式与网络行为"
        case .yaml: "编辑需要覆盖或补充的 Mihomo 根级 YAML 字段"
        case .diagnostics: "检查规则引用并模拟规则匹配"
        default: ""
        }
    }
}

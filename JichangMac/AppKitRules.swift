import AppKit

@MainActor
final class RulesPage: WorkspacePage, NSTableViewDataSource, NSTableViewDelegate {
    private enum Kind: Int {
        case groups, rules, providers, subRules
        var title: String { ["策略组", "分流规则", "规则集", "子规则"][rawValue] }
    }
    private let kind: Kind
    private let search = NSSearchField()
    private let table = NSTableView()
    private let inspector = UI.vertical([], spacing: 14)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rows: [(id: String, title: String)] = []
    private var selectedID: String?
    private var renderedProfile = ""
    private var renderedItem: String?
    private var form: FieldForm?
    private var memberPicker: NSPopUpButton?
    private var reloading = false
    init(model: AppModel, workspace: WorkspaceController, initialTab: Int = 0) {
        kind = Kind(rawValue: initialTab) ?? .groups
        super.init(model: model, workspace: workspace)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func loadView() {
        let add = UI.button("新增\(kind.title)", target: self, action: #selector(add), prominent: true)
        let heading = UI.horizontal([UI.header(kind.title, subtitle: "保存草稿、检查引用并生成 Mihomo 配置"), NSView(), add])
        search.placeholderString = "搜索名称、类型或匹配值"; search.target = self; search.action = #selector(filterChanged)
        search.sendsSearchStringImmediately = true; search.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let toolbar = UI.horizontal([search, NSView()])
        if kind == .rules {
            toolbar.addArrangedSubview(UI.button("上移", target: self, action: #selector(moveRuleUp)))
            toolbar.addArrangedSubview(UI.button("下移", target: self, action: #selector(moveRuleDown)))
        }
        let column = NSTableColumn(identifier: .init("name")); column.title = kind.title; column.width = 340
        table.addTableColumn(column); table.delegate = self; table.dataSource = self; table.rowHeight = 44; table.style = .inset
        let list = UI.scroll(table); UI.styleList(list)
        inspector.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let details = UI.scroll(inspector)
        inspector.widthAnchor.constraint(equalTo: details.contentView.widthAnchor).isActive = true
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin; split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(list); split.addArrangedSubview(details)
        let root = WorkspaceSurface()
        status.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .secondaryLabelColor
        [heading, toolbar, split, status].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            heading.heightAnchor.constraint(equalToConstant: 74), toolbar.heightAnchor.constraint(equalToConstant: 36), status.heightAnchor.constraint(equalToConstant: 36),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            toolbar.leadingAnchor.constraint(equalTo: heading.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: heading.trailingAnchor), toolbar.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
            split.leadingAnchor.constraint(equalTo: heading.leadingAnchor), split.trailingAnchor.constraint(equalTo: heading.trailingAnchor), split.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12), split.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor), status.trailingAnchor.constraint(equalTo: heading.trailingAnchor), status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            list.widthAnchor.constraint(greaterThanOrEqualToConstant: 260), details.widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        view = root; refresh()
    }
    override func focusSearch() { view.window?.makeFirstResponder(search) }
    override func refresh() {
        let profile = model.activeProfile
        if renderedProfile != profile.id { selectedID = nil; renderedItem = nil; renderedProfile = profile.id; form = nil }
        let all: [(id: String, title: String)]
        switch kind {
        case .groups: all = profile.ruleProfile.groups.map { ($0.name, "\($0.name)  ·  \($0.type)") }
        case .rules: all = profile.ruleProfile.rules.enumerated().map { (String($0.offset), "\($0.offset + 1).  \($0.element.type)  \($0.element.value) → \($0.element.group)") }
        case .providers: all = profile.ruleProfile.providers.map { ($0.id, "\($0.name)  ·  \($0.type) / \($0.behavior) / \($0.format)") }
        case .subRules: all = profile.ruleProfile.subRules.map { ($0.name, "\($0.name)  ·  \($0.rules.count) 条") }
        }
        rows = all.filter { search.stringValue.isEmpty || $0.title.localizedCaseInsensitiveContains(search.stringValue) }
        reloading = true; table.reloadData()
        if let id = selectedID, let index = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        reloading = false
        if form == nil { renderInspector() }
        if status.stringValue.isEmpty { status.stringValue = "\(rows.count) 项 · 修改未保存时保留为本地草稿" }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = NSTableCellView(), label = UI.label(rows[row].title)
        label.lineBreakMode = .byTruncatingMiddle; cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        renderInspector()
    }
    @objc private func filterChanged() { refresh() }
    @objc private func add() { selectedID = nil; reloading = true; table.deselectAll(nil); reloading = false; renderInspector(new: true) }
    private var key: String { "\(renderedProfile):\(kind.rawValue):\(renderedItem ?? "new")" }
    private func renderInspector(new: Bool = false) {
        inspector.arrangedSubviews.forEach { inspector.removeArrangedSubview($0); $0.removeFromSuperview() }
        form = nil; memberPicker = nil; renderedItem = selectedID
        if selectedID == nil && !new {
            inspector.addArrangedSubview(UI.secondary("选择条目查看详情，或新增条目。")); return
        }
        let profile = model.activeProfile
        var values: [String: JSONValue] = [:]
        var fields: [SettingField] = []
        let name = SettingField("name", "名称")
        switch kind {
        case .groups:
            let group = profile.ruleProfile.groups.first { $0.name == selectedID } ?? PolicyGroup(name: "")
            values = group.extra
            values["name"] = .string(group.name); values["type"] = .string(group.type)
            values["members"] = .array(group.members.map(JSONValue.string)); values["__implicit"] = .bool(!group.membersExplicit)
            fields = [name, .init("type", "策略组类型", .choice(["select", "url-test", "fallback", "load-balance", "relay"])),
                      .init("members", "成员 · 每行一个名称或 node:ID", .lines), .init("__implicit", "空成员时自动包含全部节点", .boolean),
                      .init("use", "引用代理集合 · 每行一个名称", .lines),
                      .init("url", "健康检查地址"), .init("interval", "检查间隔 · 秒", .integer(0, 86400)), .init("timeout", "检查超时 · 毫秒", .integer(0, 600000)),
                      .init("lazy", "按需检查", .boolean), .init("tolerance", "自动选择容差 · 毫秒", .integer(0, 600000)),
                      .init("filter", "包含过滤 · 正则"), .init("exclude-filter", "排除过滤 · 正则"), .init("exclude-type", "排除协议"),
                      .init("include-all", "包含全部节点与集合", .boolean), .init("include-all-proxies", "包含全部节点", .boolean), .init("include-all-providers", "包含全部集合", .boolean),
                      .init("strategy", "负载均衡策略", .choice(["consistent-hashing", "round-robin", "sticky-sessions"])), .init("disable-udp", "禁用 UDP", .boolean),
                      .init("expected-status", "健康检查预期状态"), .init("default-selected", "默认成员"), .init("empty-fallback", "空组回退节点")]
            let known = Set(fields.map(\.path))
            values["__extra"] = .object(group.extra.filter { !known.contains($0.key) })
            fields.append(.init("__extra", "其他参数 · YAML", .yaml))
        case .rules:
            let rule = selectedID.flatMap(Int.init).flatMap { profile.ruleProfile.rules.indices.contains($0) ? profile.ruleProfile.rules[$0] : nil } ?? RoutingRule(type: "DOMAIN-SUFFIX", value: "", group: "PROXY")
            if ["AND", "OR", "NOT", "SUB-RULE"].contains(rule.type) || !rule.conditions.isEmpty {
                values["__raw"] = .string((try? RuleCodec.serialize(rule)) ?? rule.rawLine ?? "")
                fields = [.init("__raw", "完整规则 · 保留括号与附加参数")]
            } else {
                let targets = Array(ConfigDocument.builtins).sorted() + profile.ruleProfile.groups.map(\.name) + model.state.nodes.filter { profile.enabledNodeIds.contains($0.id) }.map(\.name)
                values = ["type": .string(rule.type), "value": .string(rule.value), "group": .string(rule.group), "no-resolve": .bool(rule.noResolve), "src": .bool(rule.source), "__parameters": .array(rule.extraParameters.map(JSONValue.string))]
                fields = [.init("type", "规则类型", .choice(RuleCodec.types)), .init("value", "匹配值 · MATCH 可为空"), .init("group", "目标策略 / SUB-RULE 的子规则名", .choice(targets + profile.ruleProfile.subRules.map(\.name))), .init("no-resolve", "跳过 DNS 解析", .boolean), .init("src", "匹配源地址", .boolean), .init("__parameters", "其他附加参数 · 每行一个", .lines)]
            }
        case .providers:
            let provider = profile.ruleProfile.providers.first { $0.id == selectedID } ?? RuleProvider(id: UUID().uuidString, name: "")
            values = provider.extra
            values.merge(["name": .string(provider.name), "type": .string(provider.type), "url": .string(provider.url), "path": .string(provider.path), "interval": .integer(Int64(provider.interval)), "behavior": .string(provider.behavior), "format": .string(provider.format), "payload": .array(provider.payload.map(JSONValue.string)), "header": .object(provider.headers.mapValues { .array($0.map(JSONValue.string)) })]) { _, new in new }
            fields = [name, .init("type", "来源", .choice(["http", "file", "inline"])), .init("url", "HTTP 地址"), .init("path", "文件 / 缓存路径"), .init("interval", "刷新间隔 · 秒", .integer(0, Int.max)), .init("behavior", "行为", .choice(["domain", "ipcidr", "classical"])), .init("format", "格式", .choice(["yaml", "text", "mrs"])), .init("proxy", "Mihomo 下载代理"), .init("header", "请求头 · YAML，值为文本列表", .yaml), .init("payload", "内联内容 · 每行一条", .lines)]
            let known = Set(fields.map(\.path))
            values["__extra"] = .object(provider.extra.filter { !known.contains($0.key) })
            fields.append(.init("__extra", "其他参数 · YAML", .yaml))
        case .subRules:
            let sub = profile.ruleProfile.subRules.first { $0.name == selectedID } ?? SubRuleProfile(name: "")
            values = ["name": .string(sub.name), "__rules": .array(sub.rules.map { .string((try? RuleCodec.serialize($0)) ?? $0.rawLine ?? "") })]
            fields = [name, .init("__rules", "子规则 · 每行一条，按文本顺序匹配", .lines)]
        }
        let form = FieldForm(fields: fields, values: values, model: model, key: key)
        self.form = form
        if kind == .groups {
            let picker = NSPopUpButton(); picker.addItem(withTitle: "选择并添加成员…")
            for member in Array(ConfigDocument.builtins).sorted() + profile.ruleProfile.groups.map(\.name) where member != selectedID {
                picker.addItem(withTitle: member); picker.lastItem?.representedObject = member
            }
            for node in model.state.nodes where profile.enabledNodeIds.contains(node.id) {
                picker.addItem(withTitle: "节点 · " + node.name); picker.lastItem?.representedObject = "node:" + node.id
            }
            picker.target = self; picker.action = #selector(addMember); memberPicker = picker
            inspector.addArrangedSubview(picker)
        }
        inspector.addArrangedSubview(form.view)
        form.view.widthAnchor.constraint(equalTo: inspector.widthAnchor, constant: -32).isActive = true
        let actions = UI.horizontal([UI.button("保存", target: self, action: #selector(save), prominent: true), UI.button("删除", target: self, action: #selector(remove))])
        if kind == .providers, selectedID != nil { actions.addArrangedSubview(UI.button("刷新", target: self, action: #selector(refreshProvider))) }
        inspector.addArrangedSubview(actions)
    }
    @objc private func addMember() {
        guard let member = memberPicker?.selectedItem?.representedObject as? String, let form else { return }
        let old = form.text(at: "members")
        form.setText(old.isEmpty ? member : old + "\n" + member, at: "members"); form.setText("false", at: "__implicit")
        memberPicker?.selectItem(at: 0)
    }
    @objc private func save() {
        guard let form else { return }
        do {
            // Reconstruct from the displayed baseline so hidden fields remain untouched.
            let values = try form.applying(to: [:], changedOnly: false)
            var profile = model.activeProfile
            let name = values["name"]?.stringValue ?? ""
            if kind != .rules && (name.isEmpty || name.contains(",")) { throw ConfigError.message("名称不能为空或包含英文逗号。") }
            switch kind {
            case .groups:
                if profile.ruleProfile.groups.contains(where: { $0.name == name && $0.name != selectedID }) { throw ConfigError.message("策略组名称重复。") }
                let members = values["members"]?.arrayValue?.compactMap(\.stringValue) ?? []
                var extra = values["__extra"]?.objectValue ?? [:]
                extra.merge(values.filter { !["name", "type", "members", "__implicit", "__extra"].contains($0.key) }) { _, new in new }
                extra = extra.filter { !["name", "type", "proxies"].contains($0.key) && $0.value != .string("") }
                let group = PolicyGroup(name: name, type: values["type"]?.stringValue ?? "select", members: members, extra: extra, membersExplicit: values["__implicit"] != .bool(true))
                if let index = profile.ruleProfile.groups.firstIndex(where: { $0.name == selectedID }) {
                    let old = profile.ruleProfile.groups[index].name
                    profile.ruleProfile.groups[index] = group; ProfileReferences.rename(&profile, from: old, to: name, kind: "group")
                } else { profile.ruleProfile.groups.append(group) }
                selectedID = name
            case .rules:
                let rule: RoutingRule
                if let raw = values["__raw"]?.stringValue { rule = try RuleCodec.parse(raw) }
                else {
                    let candidate = RoutingRule(type: values["type"]?.stringValue ?? "", value: values["value"]?.stringValue ?? "", group: values["group"]?.stringValue ?? "", noResolve: values["no-resolve"] == .bool(true), source: values["src"] == .bool(true), extraParameters: values["__parameters"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                    rule = try RuleCodec.parse(RuleCodec.serialize(candidate))
                }
                if let index = selectedID.flatMap(Int.init), profile.ruleProfile.rules.indices.contains(index) { profile.ruleProfile.rules[index] = rule }
                else { profile.ruleProfile.rules.append(rule); selectedID = String(profile.ruleProfile.rules.count - 1) }
            case .providers:
                if profile.ruleProfile.providers.contains(where: { $0.name == name && $0.id != selectedID }) { throw ConfigError.message("规则集名称重复。") }
                var provider = profile.ruleProfile.providers.first { $0.id == selectedID } ?? RuleProvider(id: UUID().uuidString, name: name)
                let old = provider.name
                provider.name = name; provider.type = values["type"]?.stringValue ?? "http"; provider.url = values["url"]?.stringValue ?? ""; provider.path = values["path"]?.stringValue ?? ""
                provider.behavior = values["behavior"]?.stringValue ?? "domain"; provider.format = values["format"]?.stringValue ?? "yaml"; provider.interval = values["interval"]?.intValue ?? 86400
                provider.payload = values["payload"]?.arrayValue?.compactMap(\.stringValue) ?? []
                provider.headers = [:]
                for (key, value) in values["header"]?.objectValue ?? [:] {
                    guard let list = value.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else { throw ConfigError.message("请求头 \(key) 必须是文本列表。") }
                    provider.headers[key] = list.compactMap(\.stringValue)
                }
                provider.extra = values["__extra"]?.objectValue ?? [:]
                if let proxy = values["proxy"]?.stringValue, !proxy.isEmpty { provider.extra["proxy"] = .string(proxy) }
                else { provider.extra.removeValue(forKey: "proxy") }
                if let index = profile.ruleProfile.providers.firstIndex(where: { $0.id == selectedID }) { profile.ruleProfile.providers[index] = provider }
                else { profile.ruleProfile.providers.append(provider) }
                ProfileReferences.rename(&profile, from: old, to: name, kind: "provider"); selectedID = provider.id
            case .subRules:
                if profile.ruleProfile.subRules.contains(where: { $0.name == name && $0.name != selectedID }) { throw ConfigError.message("子规则名称重复。") }
                let lines = values["__rules"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "\n") ?? ""
                let sub = SubRuleProfile(name: name, rules: try RuleCodec.parseLines(lines))
                if let index = profile.ruleProfile.subRules.firstIndex(where: { $0.name == selectedID }) {
                    let old = profile.ruleProfile.subRules[index].name; profile.ruleProfile.subRules[index] = sub
                    ProfileReferences.rename(&profile, from: old, to: name, kind: "subRule")
                } else { profile.ruleProfile.subRules.append(sub) }
                selectedID = name
            }
            form.clearDraft(); replace(profile); self.form = nil; renderInspector(); refresh()
            status.stringValue = "已保存；配置错误和警告可在“校验”查看。"
        } catch { status.stringValue = "保存失败，草稿已保留：\(error.localizedDescription)" }
    }
    private func replace(_ profile: ConfigProfile) {
        guard let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        model.state.profiles[index] = profile; model.persist()
    }
    @objc private func remove() {
        guard let id = selectedID else { return }
        let alert = NSAlert(); alert.messageText = "删除所选条目？"; alert.informativeText = "依赖它的引用将显示为配置错误，方便你逐项修复。"; alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var profile = model.activeProfile
        switch kind {
        case .groups: profile.ruleProfile.groups.removeAll { $0.name == id }
        case .rules:
            if let index = Int(id), profile.ruleProfile.rules.indices.contains(index) {
                let count = profile.ruleProfile.rules.count
                profile.ruleProfile.rules.remove(at: index)
                let prefix = "\(profile.id):\(kind.rawValue):"
                for position in index..<count { model.drafts.put(prefix + String(position), position + 1 < count ? model.drafts.get(prefix + String(position + 1)) : nil) }
            }
        case .providers: profile.ruleProfile.providers.removeAll { $0.id == id }
        case .subRules: profile.ruleProfile.subRules.removeAll { $0.name == id }
        }
        if kind != .rules { model.drafts.put(key, nil) }; selectedID = nil; form = nil; replace(profile); renderInspector(); refresh()
    }
    @objc private func refreshProvider() {
        guard let id = selectedID, let provider = model.activeProfile.ruleProfile.providers.first(where: { $0.id == id }) else { return }
        Task { await model.refreshProvider(provider) }
    }
    @objc private func moveRuleUp() { move(-1) }
    @objc private func moveRuleDown() { move(1) }
    private func move(_ delta: Int) {
        guard kind == .rules, let index = selectedID.flatMap(Int.init) else { return }
        var profile = model.activeProfile; let next = index + delta
        guard profile.ruleProfile.rules.indices.contains(index), profile.ruleProfile.rules.indices.contains(next) else { return }
        // Keep index-based drafts attached to their rules when order changes.
        let prefix = "\(profile.id):\(kind.rawValue):"
        let left = model.drafts.get(prefix + String(index)), right = model.drafts.get(prefix + String(next))
        model.drafts.put(prefix + String(index), right); model.drafts.put(prefix + String(next), left)
        profile.ruleProfile.rules.swapAt(index, next); selectedID = String(next); form = nil
        replace(profile); renderInspector(); refresh()
    }
}

import AppKit

@MainActor
final class ResourcesPage: WorkspacePage, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Kind: Int {
        case sources, nodes, templates
        var title: String { ["订阅", "节点", "模板"][rawValue] }
        var subtitle: String {
            switch self {
            case .sources: "管理远程订阅及其刷新状态"
            case .nodes: "查看当前配置可用的代理节点"
            case .templates: "管理本地模板与远程模板来源"
            }
        }
    }
    private struct Entry: Equatable { let id: String; let name: String; let detail: String; let status: String }
    private let search = NSSearchField()
    private let table = NSTableView()
    private let inspector = UI.vertical([], spacing: 12)
    private let addButton = UI.button("添加", symbol: "plus", target: nil, action: nil)
    private let importButton = UI.button("从文件导入…", target: nil, action: nil)
    private let message = UI.secondary("")
    private var entries: [Entry] = []
    private var kind: Kind
    private var selectedID: String?
    private var reloading = false

    init(model: AppModel, workspace: WorkspaceController, initialTab: Int = 0) {
        kind = Kind(rawValue: initialTab) ?? .sources
        super.init(model: model, workspace: workspace)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        inspector.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        search.placeholderString = "搜索资源"; search.delegate = self
        search.target = self; search.action = #selector(filterChanged)
        addButton.target = self; addButton.action = #selector(add)
        importButton.target = self; importButton.action = #selector(importFile)
        table.headerView = nil; table.rowHeight = 40
        table.style = .inset
        table.allowsEmptySelection = true
        table.delegate = self; table.dataSource = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("resource")))
        let listScroll = UI.scroll(table)
        listScroll.borderType = .bezelBorder
        let inspectorScroll = UI.scroll(inspector)
        let split = NSSplitView()
        split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(listScroll); split.addArrangedSubview(inspectorScroll)
        split.translatesAutoresizingMaskIntoConstraints = false
        let header = UI.horizontal([UI.header(kind.title, subtitle: kind.subtitle), NSView(), addButton, importButton])
        let controls = UI.horizontal([NSView(), search])
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let root = NSView()
        [header, controls, split, message].forEach { root.addSubview($0) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), header.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            controls.leadingAnchor.constraint(equalTo: header.leadingAnchor), controls.trailingAnchor.constraint(equalTo: header.trailingAnchor), controls.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            split.leadingAnchor.constraint(equalTo: header.leadingAnchor), split.trailingAnchor.constraint(equalTo: header.trailingAnchor), split.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10), split.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -8),
            message.leadingAnchor.constraint(equalTo: header.leadingAnchor), message.trailingAnchor.constraint(equalTo: header.trailingAnchor), message.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            listScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300), inspectorScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            inspector.widthAnchor.constraint(equalTo: inspectorScroll.contentView.widthAnchor)
        ])
        view = root
    }

    override func refresh() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: [Entry]
        switch kind {
        case .sources:
            source = model.state.sources.map { Entry(id: $0.id, name: $0.name, detail: $0.url, status: $0.lastError == nil ? ($0.updatedAt == nil ? "尚未刷新" : "已更新") : "刷新失败") }
        case .nodes:
            source = model.state.nodes.map { Entry(id: $0.id, name: $0.name, detail: "\($0.type.uppercased())  ·  \($0.server):\($0.port)", status: $0.sourceId == nil ? "手动导入" : "来自订阅") }
        case .templates:
            source = model.state.templates.map { Entry(id: $0.id, name: $0.name, detail: $0.remoteURL ?? $0.fileName, status: $0.remoteURL == nil ? "本地模板" : "远程模板") }
        }
        let filtered = query.isEmpty ? source : source.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
        if entries != filtered { reloading = true; entries = filtered; table.reloadData(); reloading = false }
        if let selectedID, let index = entries.firstIndex(where: { $0.id == selectedID }) {
            if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        } else { selectedID = nil; if table.selectedRow >= 0 { table.deselectAll(nil) } }
        message.stringValue = entries.isEmpty ? "没有匹配的资源。可添加或导入。" : "\(entries.count) 项资源"
        addButton.title = ["添加订阅", "导入节点", "下载模板"][kind.rawValue]
        importButton.title = kind == .nodes ? "从文件导入…" : "导入 YAML…"
        importButton.isHidden = kind == .sources
        if !(view.window?.firstResponder is NSTextView) { renderInspector() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let cell = NSTableCellView()
        let name = UI.label(entry.name, weight: .medium)
        let detail = UI.secondary(entry.detail)
        detail.lineBreakMode = .byTruncatingMiddle
        let status = UI.secondary(entry.status)
        let stack = UI.vertical([name, detail], spacing: 2)
        cell.addSubview(stack); cell.addSubview(status)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -10), status.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10), status.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        selectedID = entries.indices.contains(table.selectedRow) ? entries[table.selectedRow].id : nil
        renderInspector()
    }
    @objc private func filterChanged() { refresh() }
    @objc private func add() {
        switch kind {
        case .sources:
            guard let values = UI.prompt("添加订阅", labels: ["名称（可选）", "HTTP 或 HTTPS 地址"]) else { return }
            Task { await model.addSource(name: values[0], url: values[1]) }
        case .nodes:
            guard let value = UI.textPrompt("导入节点", explanatory: "粘贴节点链接或 Mihomo YAML。") else { return }
            Task { await model.importNodes(value) }
        case .templates: remoteTemplate(nil)
        }
    }
    @objc private func importFile() {
        guard let (name, content) = UI.openText() else { return }
        switch kind {
        case .nodes: Task { await model.importNodes(content) }
        case .templates: model.importTemplate(rawYaml: content, fileName: name)
        case .sources: break
        }
    }
    @objc private func refreshSelected() {
        guard let selectedID else { return }
        switch kind {
        case .sources: Task { await model.refreshSource(selectedID) }
        case .templates:
            guard let template = model.state.templates.first(where: { $0.id == selectedID }) else { return }
            remoteTemplate(template)
        case .nodes: break
        }
    }
    @objc private func removeSelected() {
        guard let selectedID else { return }
        let alert = NSAlert(); alert.messageText = "删除所选资源？"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch kind {
        case .sources: model.removeSource(selectedID)
        case .nodes: model.removeNode(selectedID)
        case .templates:
            model.state.templates.removeAll { $0.id == selectedID }
            model.persist()
        }
        self.selectedID = nil
    }
    @objc private func createProfile() {
        guard let selectedID, let template = model.state.templates.first(where: { $0.id == selectedID }) else { return }
        model.createProfile(from: template)
    }
    @objc private func toggleSelected(_ sender: NSButton) {
        guard let selectedID else { return }
        var profile = model.activeProfile
        if kind == .sources {
            if sender.state == .on { profile.selectedSourceIds.insert(selectedID) }
            else { profile.selectedSourceIds.remove(selectedID) }
        } else if kind == .nodes {
            if sender.state == .on { profile.enabledNodeIds.insert(selectedID) }
            else { profile.enabledNodeIds.remove(selectedID) }
        }
        guard let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        model.state.profiles[index] = profile; model.persist()
    }

    private func renderInspector() {
        for child in inspector.arrangedSubviews { inspector.removeArrangedSubview(child); child.removeFromSuperview() }
        guard let selectedID else { inspector.addArrangedSubview(UI.secondary("选择一项以查看详情。")); return }
        let title = UI.label("详细信息", style: .headline, weight: .semibold)
        inspector.addArrangedSubview(title)
        switch kind {
        case .sources:
            guard let source = model.state.sources.first(where: { $0.id == selectedID }) else { return }
            inspector.addArrangedSubview(UI.label(source.name, weight: .medium))
            let url = UI.secondary(source.url); url.lineBreakMode = .byCharWrapping
            url.widthAnchor.constraint(equalTo: inspector.widthAnchor, constant: -32).isActive = true
            inspector.addArrangedSubview(url)
            let enabled = NSButton(checkboxWithTitle: "用于当前配置", target: self, action: #selector(toggleSelected(_:)))
            enabled.state = model.activeProfile.selectedSourceIds.contains(selectedID) ? .on : .off
            inspector.addArrangedSubview(enabled)
            if let error = source.lastError { inspector.addArrangedSubview(UI.secondary("最近错误：\(error)")) }
            inspector.addArrangedSubview(UI.button("刷新订阅", symbol: "arrow.clockwise", target: self, action: #selector(refreshSelected)))
        case .nodes:
            guard let node = model.state.nodes.first(where: { $0.id == selectedID }) else { return }
            inspector.addArrangedSubview(UI.label(node.name, weight: .medium))
            inspector.addArrangedSubview(UI.secondary("\(node.type.uppercased()) · \(node.server):\(node.port)"))
            let enabled = NSButton(checkboxWithTitle: "用于当前配置", target: self, action: #selector(toggleSelected(_:)))
            enabled.state = model.activeProfile.enabledNodeIds.contains(selectedID) ? .on : .off
            inspector.addArrangedSubview(enabled)
        case .templates:
            guard let template = model.state.templates.first(where: { $0.id == selectedID }) else { return }
            inspector.addArrangedSubview(UI.label(template.name, weight: .medium))
            inspector.addArrangedSubview(UI.secondary(template.remoteURL ?? template.fileName))
            inspector.addArrangedSubview(UI.button("用此模板创建配置", symbol: "doc.badge.plus", target: self, action: #selector(createProfile)))
            if template.remoteURL != nil { inspector.addArrangedSubview(UI.button("刷新远程模板", symbol: "arrow.clockwise", target: self, action: #selector(refreshSelected))) }
        }
        inspector.addArrangedSubview(UI.separator())
        inspector.addArrangedSubview(UI.button("删除…", symbol: "trash", target: self, action: #selector(removeSelected)))
    }

    private func remoteTemplate(_ existing: ConfigTemplate?) {
        let values: [String]?
        if let existing {
            guard let url = existing.remoteURL else { return }
            values = [existing.name, url]
        } else { values = UI.prompt("下载远程模板", labels: ["模板名称", "HTTP 或 HTTPS 模板地址"]) }
        guard let values else { return }
        message.stringValue = "正在下载模板…"
        Task {
            do {
                let download = try await model.downloadTemplate(url: values[1], name: values[0], replacing: existing)
                guard !Task.isCancelled else { return }
                let alert = NSAlert()
                alert.messageText = existing == nil ? "导入远程模板？" : (download.changed ? "应用模板更新？" : "模板内容没有变化")
                alert.informativeText = "变更字段：\(download.changedKeys.isEmpty ? "无" : download.changedKeys.joined(separator: "、"))。确认后关联配置将使用新底稿。"
                alert.addButton(withTitle: download.changed ? "应用" : "确定")
                alert.addButton(withTitle: "取消")
                let comparison = NSStackView()
                comparison.orientation = .horizontal; comparison.spacing = 8
                let (oldScroll, _) = UI.textEditor(existing?.rawYaml ?? "新模板", editable: false)
                let (newScroll, _) = UI.textEditor(download.rawYaml, editable: false)
                oldScroll.frame = NSRect(x: 0, y: 0, width: 380, height: 320)
                newScroll.frame = NSRect(x: 0, y: 0, width: 380, height: 320)
                comparison.addArrangedSubview(oldScroll); comparison.addArrangedSubview(newScroll)
                comparison.frame = NSRect(x: 0, y: 0, width: 770, height: 320)
                alert.accessoryView = comparison
                if alert.runModal() == .alertFirstButtonReturn { try model.applyTemplate(download) }
            } catch { UI.alert(error.localizedDescription) }
            refresh()
        }
    }
}

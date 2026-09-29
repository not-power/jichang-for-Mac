import AppKit
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

enum WorkspaceDestination: Int {
    case overview, settings, sources, nodes, templates, groups, rules, providers, subRules, diagnostics, yaml, share
    var title: String {
        switch self {
        case .overview: "当前配置"
        case .settings: "常规"
        case .sources: "订阅"
        case .nodes: "节点"
        case .templates: "模板"
        case .groups: "策略组"
        case .rules: "分流规则"
        case .providers: "规则集"
        case .subRules: "子规则"
        case .diagnostics: "校验"
        case .yaml: "高级 YAML"
        case .share: "分享与导出"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "doc.text"
        case .settings: "slider.horizontal.3"
        case .sources: "arrow.triangle.2.circlepath"
        case .nodes: "point.3.connected.trianglepath.dotted"
        case .templates: "doc.text"
        case .groups: "rectangle.3.group"
        case .rules: "line.3.horizontal.decrease.circle"
        case .providers: "externaldrive.connected.to.line.below"
        case .subRules: "list.bullet.indent"
        case .diagnostics: "checkmark.shield"
        case .yaml: "curlybraces"
        case .share: "square.and.arrow.up"
        }
    }
}

@MainActor
private final class SidebarNode: NSObject {
    let title: String
    let destination: WorkspaceDestination?
    let children: [SidebarNode]
    init(_ title: String, destination: WorkspaceDestination? = nil, children: [SidebarNode] = []) {
        self.title = title; self.destination = destination; self.children = children
    }
}

@MainActor
final class WorkspaceController: NSSplitViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let model: AppModel
    private let sidebar = NSViewController()
    private let detail = NSViewController()
    private let sidebarOutline = NSOutlineView()
    private let profilePicker = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var page: WorkspaceDestination = .overview
    private var pageController: WorkspacePage?
    private var queuedUpdate = false
    private var navigationRoots: [SidebarNode] = []
    var shareServer: LocalShareServer?
    var shareURL: String?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        configureSidebar()
        detail.view = NSView()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 280
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 580
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        splitView.autosaveName = "MainWorkspace"
        let overviewRow = sidebarOutline.row(forItem: navigationRoots.first { $0.destination == .overview })
        sidebarOutline.selectRowIndexes(IndexSet(integer: overviewRow), byExtendingSelection: false)
        show(.overview)
        model.didChange = { [weak self] in self?.scheduleUpdate() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func configureSidebar() {
        let root = NSView()
        sidebar.view = root
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(effect)
        NSLayoutConstraint.activate([effect.leadingAnchor.constraint(equalTo: root.leadingAnchor), effect.trailingAnchor.constraint(equalTo: root.trailingAnchor), effect.topAnchor.constraint(equalTo: root.topAnchor), effect.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        let title = UI.label("鸡场", style: .title2, weight: .semibold)
        let subtitle = UI.secondary("Mihomo 配置管理")
        let brand = UI.vertical([title, subtitle], spacing: 3)
        brand.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(brand)
        navigationRoots = [
            SidebarNode(WorkspaceDestination.overview.title, destination: .overview),
            SidebarNode("配置", children: [
                SidebarNode(WorkspaceDestination.settings.title, destination: .settings),
                SidebarNode(WorkspaceDestination.yaml.title, destination: .yaml)
            ]),
            SidebarNode("资源", children: [
                SidebarNode(WorkspaceDestination.sources.title, destination: .sources),
                SidebarNode(WorkspaceDestination.nodes.title, destination: .nodes),
                SidebarNode(WorkspaceDestination.templates.title, destination: .templates)
            ]),
            SidebarNode("规则", children: [
                SidebarNode(WorkspaceDestination.groups.title, destination: .groups),
                SidebarNode(WorkspaceDestination.rules.title, destination: .rules),
                SidebarNode(WorkspaceDestination.providers.title, destination: .providers),
                SidebarNode(WorkspaceDestination.subRules.title, destination: .subRules),
                SidebarNode(WorkspaceDestination.diagnostics.title, destination: .diagnostics)
            ]),
            SidebarNode(WorkspaceDestination.share.title, destination: .share)
        ]
        sidebarOutline.headerView = nil
        sidebarOutline.rowHeight = 27
        sidebarOutline.backgroundColor = .clear
        sidebarOutline.style = .sourceList
        sidebarOutline.selectionHighlightStyle = .regular
        sidebarOutline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("navigation")))
        sidebarOutline.outlineTableColumn = sidebarOutline.tableColumns.first
        sidebarOutline.delegate = self
        sidebarOutline.dataSource = self
        let scroll = NSScrollView()
        scroll.documentView = sidebarOutline
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        for index in navigationRoots.indices where !navigationRoots[index].children.isEmpty { sidebarOutline.expandItem(navigationRoots[index]) }
        profilePicker.target = self
        profilePicker.action = #selector(changeProfile)
        profilePicker.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(profilePicker)
        let profileCaption = UI.secondary("当前配置")
        profileCaption.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(profileCaption)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16), brand.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12), brand.topAnchor.constraint(equalTo: effect.topAnchor, constant: 22),
            profileCaption.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 17), profileCaption.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12), profileCaption.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 20),
            profilePicker.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14), profilePicker.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14), profilePicker.topAnchor.constraint(equalTo: profileCaption.bottomAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8), scroll.topAnchor.constraint(equalTo: profilePicker.bottomAnchor, constant: 16), scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),
            statusLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 17), statusLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14), statusLabel.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14),
        ])
        refreshChrome()
    }

    private func refreshChrome() {
        let selected = model.state.activeProfileId
        profilePicker.removeAllItems()
        model.state.profiles.forEach { profile in profilePicker.addItem(withTitle: profile.name); profilePicker.lastItem?.representedObject = profile.id }
        profilePicker.select(profilePicker.itemArray.first { $0.representedObject as? String == selected })
        statusLabel.stringValue = model.workingIDs.isEmpty ? (model.notice ?? "本地数据已保存") : "正在处理 \(model.workingIDs.count) 项任务…"
    }

    private func scheduleUpdate() {
        guard !queuedUpdate else { return }
        queuedUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queuedUpdate = false
            self.refreshChrome()
            self.pageController?.refresh()
        }
    }

    private func show(_ destination: WorkspaceDestination) {
        page = destination
        pageController?.view.removeFromSuperview()
        pageController?.removeFromParent()
        let next: WorkspacePage
        switch destination {
        case .overview: next = OverviewPage(model: model, workspace: self)
        case .sources: next = ResourcesPage(model: model, workspace: self, initialTab: 0)
        case .nodes: next = ResourcesPage(model: model, workspace: self, initialTab: 1)
        case .templates: next = ResourcesPage(model: model, workspace: self, initialTab: 2)
        case .groups: next = RulesPage(model: model, workspace: self, initialTab: 0)
        case .rules: next = RulesPage(model: model, workspace: self, initialTab: 1)
        case .providers: next = RulesPage(model: model, workspace: self, initialTab: 2)
        case .subRules: next = RulesPage(model: model, workspace: self, initialTab: 3)
        case .diagnostics: next = ConfigurationPage(model: model, workspace: self, destination: .diagnostics)
        case .settings: next = ConfigurationPage(model: model, workspace: self, destination: .settings)
        case .yaml: next = ConfigurationPage(model: model, workspace: self, destination: .yaml)
        case .share: next = SharePage(model: model, workspace: self)
        }
        detail.addChild(next)
        let container = detail.view
        next.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            next.view.topAnchor.constraint(equalTo: container.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        pageController = next
        next.refresh()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? navigationRoots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? navigationRoots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.children.isEmpty == false
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.destination != nil
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.destination == nil
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let cell = NSTableCellView()
        let label = UI.label(node.title, style: .body, weight: node.destination == nil ? .semibold : .regular)
        cell.textField = label
        cell.addSubview(label)
        if let destination = node.destination {
            let image = NSImageView(image: NSImage(systemSymbolName: destination.symbol, accessibilityDescription: destination.title) ?? NSImage())
            image.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            cell.imageView = image
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16), label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)])
        } else {
            label.textColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = sidebarOutline.item(atRow: sidebarOutline.selectedRow) as? SidebarNode,
              let destination = node.destination, destination != page else { return }
        show(destination)
    }
    @objc private func changeProfile() {
        guard let id = profilePicker.selectedItem?.representedObject as? String else { return }
        model.setActiveProfile(id)
    }

    func navigate(to destination: WorkspaceDestination) {
        let allNodes = navigationRoots.flatMap { [$0] + $0.children }
        let row = sidebarOutline.row(forItem: allNodes.first { $0.destination == destination })
        if row >= 0 { sidebarOutline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "jichangbackup")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let alert = NSAlert()
            alert.messageText = "替换当前数据？"
            alert.informativeText = "备份会替换本机的配置、订阅、节点、规则和规则集缓存。"
            alert.addButton(withTitle: "替换"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try model.importBackup(data)
        } catch { UI.alert(error.localizedDescription) }
    }
    func exportBackup() {
        do {
            let data = try model.exportBackup()
            let panel = NSSavePanel(); panel.nameFieldStringValue = "鸡场备份.jichangbackup"
            panel.allowedContentTypes = [.init(filenameExtension: "jichangbackup")!]
            if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic) }
        } catch { UI.alert(error.localizedDescription) }
    }
    func exportConfig() {
        guard model.generationIsCurrent, let yaml = model.generatedConfig?.yaml else { UI.alert("配置仍在生成或存在错误，请稍后重试。") ; return }
        if let unresolved = model.generatedConfig?.unresolvedTemplateProviders, !unresolved.isEmpty {
            UI.alert("请先在“分享”中绑定模板订阅：\(unresolved.joined(separator: "、"))")
            return
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = model.activeProfile.fileName + ".yaml"
        panel.allowedContentTypes = [.yaml]
        do { if panel.runModal() == .OK, let url = panel.url { try yaml.write(to: url, atomically: true, encoding: .utf8) } }
        catch { UI.alert(error.localizedDescription) }
    }
}

@MainActor
class WorkspacePage: NSViewController {
    let model: AppModel
    unowned let workspace: WorkspaceController
    init(model: AppModel, workspace: WorkspaceController) { self.model = model; self.workspace = workspace; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func refresh() {}
}

@MainActor
enum UI {
    private final class FlippedStackView: NSStackView {
        override var isFlipped: Bool { true }
    }
    static func label(_ text: String, style: NSFont.TextStyle = .body, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    static func secondary(_ text: String) -> NSTextField {
        let field = label(text, style: .subheadline)
        field.textColor = .secondaryLabelColor
        return field
    }
    static func vertical(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = FlippedStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
    static func horizontal(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
    static func button(_ title: String, symbol: String? = nil, target: AnyObject?, action: Selector?, prominent: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); button.imagePosition = .imageLeading }
        button.bezelStyle = .rounded
        if prominent { button.bezelColor = .controlAccentColor }
        return button
    }
    static func scroll(_ document: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = document; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }
    static func textEditor(_ text: String, editable: Bool = true) -> (NSScrollView, NSTextView) {
        let view = NSTextView(frame: .zero)
        view.isEditable = editable; view.isRichText = false; view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 9, height: 9)
        view.string = text
        let scroll = UI.scroll(view)
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        return (scroll, view)
    }
    static func content(_ children: [NSView]) -> NSView {
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let stack = vertical(children, spacing: 14)
        root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18)])
        return root
    }
    static func header(_ title: String, subtitle: String) -> NSView {
        let heading = label(title, style: .title1, weight: .semibold)
        let detail = secondary(subtitle)
        return vertical([heading, detail], spacing: 4)
    }
    static func section(_ title: String, _ views: [NSView]) -> NSView {
        let heading = label(title, style: .headline, weight: .semibold)
        let stack = vertical([heading] + views, spacing: 10)
        return stack
    }
    static func alert(_ message: String) { let alert = NSAlert(); alert.messageText = message; alert.runModal() }
    static func prompt(_ title: String, labels: [String], defaults: [String] = []) -> [String]? {
        let alert = NSAlert(); alert.messageText = title
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let fields = labels.enumerated().map { index, label -> NSTextField in
            let field = NSTextField(string: index < defaults.count ? defaults[index] : "")
            field.placeholderString = label
            field.widthAnchor.constraint(equalToConstant: 420).isActive = true
            return field
        }
        let stack = vertical(fields, spacing: 10); stack.frame = NSRect(x: 0, y: 0, width: 420, height: CGFloat(fields.count) * 34)
        alert.accessoryView = stack
        return alert.runModal() == .alertFirstButtonReturn ? fields.map(\.stringValue) : nil
    }
    static func textPrompt(_ title: String, initial: String = "", explanatory: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = explanatory
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let (scroll, textView) = textEditor(initial)
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 280)
        alert.accessoryView = scroll
        return alert.runModal() == .alertFirstButtonReturn ? textView.string : nil
    }
    static func openText() -> (String, String)? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, .yaml, .json]
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (url.lastPathComponent, text)
    }
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}

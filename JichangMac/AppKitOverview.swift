import AppKit

@MainActor
final class OverviewPage: WorkspacePage {
    private let profileName = UI.label("", style: .title1, weight: .bold)
    private let summary = UI.secondary("")
    private let statusLabel = UI.label("", weight: .medium)
    private let diagnostics = UI.vertical([], spacing: 10)
    private let sourceCount = UI.label("0", style: .largeTitle, weight: .semibold)
    private let nodeCount = UI.label("0", style: .largeTitle, weight: .semibold)
    private let ruleCount = UI.label("0", style: .largeTitle, weight: .semibold)

    override func loadView() {
        let header = UI.horizontal([
            UI.header("工作概览", subtitle: "从资源到分流，让每一份配置井然有序。"), NSView(),
            UI.button("新建配置", symbol: "plus", target: self, action: #selector(addProfile))
        ])
        let profileInfo = UI.vertical([UI.secondary("当前配置"), profileName, summary], spacing: 8)
        let profileRow = UI.horizontal([UI.symbol("doc.text", size: 32), profileInfo, NSView()], spacing: 18)
        let actionRow = UI.horizontal([
            UI.button("预览与导出", symbol: "square.and.arrow.up", target: self, action: #selector(openShare), prominent: true),
            UI.button("配置设置", symbol: "slider.horizontal.3", target: self, action: #selector(openSettings)),
            NSView(), statusLabel
        ])
        let heroContent = UI.vertical([profileRow, UI.separator(), actionRow], spacing: 20)
        for child in heroContent.arrangedSubviews { child.widthAnchor.constraint(equalTo: heroContent.widthAnchor).isActive = true }
        let hero = UI.panel(heroContent, padding: 24, accented: true)
        let metrics = UI.horizontal([
            metric(sourceCount, title: "已选订阅", symbol: "arrow.triangle.2.circlepath", destination: .sources),
            metric(nodeCount, title: "可用节点", symbol: "point.3.connected.trianglepath.dotted", destination: .nodes),
            metric(ruleCount, title: "分流规则", symbol: "line.3.horizontal.decrease.circle", destination: .rules)
        ], spacing: 12)
        metrics.distribution = .fillEqually
        let quickActions = UI.horizontal([
            quickAction("准备资源", detail: "订阅、节点与模板", destination: .sources),
            quickAction("整理分流", detail: "规则、策略与匹配", destination: .rules),
            quickAction("从模板开始", detail: "复用已有配置", destination: .templates)
        ], spacing: 12)
        quickActions.distribution = .fillEqually
        let checkHeader = UI.horizontal([
            UI.label("配置检查", style: .headline, weight: .semibold), NSView(),
            UI.button("查看详情", symbol: "chevron.right", target: self, action: #selector(openDiagnostics))
        ])
        let checks = UI.vertical([checkHeader, diagnostics], spacing: 14)
        checkHeader.widthAnchor.constraint(equalTo: checks.widthAnchor).isActive = true
        diagnostics.widthAnchor.constraint(equalTo: checks.widthAnchor).isActive = true
        let content = UI.vertical([
            header, hero, metrics,
            UI.label("快捷操作", style: .headline, weight: .semibold), quickActions,
            UI.panel(checks)
        ], spacing: 20)
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -56).isActive = true }
        content.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
        let root = WorkspaceSurface()
        let scroll = UI.scroll(content)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        view = root
    }

    private func metric(_ value: NSTextField, title: String, symbol: String, destination: WorkspaceDestination) -> NSView {
        let heading = UI.horizontal([UI.symbol(symbol, size: 16), UI.secondary(title), NSView()], spacing: 8)
        let content = UI.vertical([heading, UI.horizontal([value, NSView(), navButton("查看", destination: destination)])], spacing: 12)
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        return UI.panel(content, padding: 16)
    }

    private func quickAction(_ title: String, detail: String, destination: WorkspaceDestination) -> NSView {
        let button = navButton(title, destination: destination)
        button.image = NSImage(systemSymbolName: destination.symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        let text = UI.secondary(detail)
        let stack = UI.vertical([button, text], spacing: 9)
        return UI.panel(stack, padding: 16)
    }

    override func refresh() {
        let profile = model.activeProfile
        let nodes = model.state.nodes.filter { profile.enabledNodeIds.contains($0.id) && ($0.sourceId.map { profile.selectedSourceIds.contains($0) } ?? true) }
        profileName.stringValue = profile.name
        summary.stringValue = profile.fileName + ".yaml"
        sourceCount.stringValue = String(profile.selectedSourceIds.count)
        nodeCount.stringValue = String(nodes.count)
        ruleCount.stringValue = String(profile.ruleProfile.rules.count)
        let issues = model.generatedConfig?.issues.map(\.description) ?? (model.generationIsCurrent ? [model.notice ?? "配置生成失败"] : [])
        statusLabel.stringValue = !model.generationIsCurrent ? "正在生成…" : model.generatedConfig == nil ? "生成失败" : model.generatedConfig?.canExport == true ? "配置已生成" : "存在配置错误"
        statusLabel.textColor = model.generationIsCurrent && model.generatedConfig == nil ? .systemOrange : .secondaryLabelColor
        diagnostics.arrangedSubviews.forEach { diagnostics.removeArrangedSubview($0); $0.removeFromSuperview() }
        if issues.isEmpty {
            let detail = UI.secondary(nodes.isEmpty ? "本地结构检查通过。可添加订阅或节点；协议运行和远程资源尚未检查。" : "本地结构检查通过，可继续预览与导出。运行与远程资源尚未检查。")
            detail.lineBreakMode = .byWordWrapping; detail.maximumNumberOfLines = 0
            let row = UI.horizontal([UI.symbol("checkmark.shield", size: 20), detail], spacing: 12)
            diagnostics.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: diagnostics.widthAnchor).isActive = true
        } else {
            for issue in issues.prefix(3) {
                let label = NSTextField(wrappingLabelWithString: issue)
                let icon = UI.symbol("exclamationmark.circle", size: 16)
                icon.contentTintColor = .systemOrange
                let row = UI.horizontal([icon, label], spacing: 10)
                diagnostics.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: diagnostics.widthAnchor).isActive = true
            }
            if issues.count > 3 { diagnostics.addArrangedSubview(UI.secondary("另有 \(issues.count - 3) 项，请查看详情。")) }
        }
    }

    private func navButton(_ title: String, destination: WorkspaceDestination) -> NSButton {
        let button = UI.button(title, target: self, action: #selector(navigateFromButton(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(String(destination.rawValue))
        return button
    }
    @objc private func navigateFromButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let value = Int(raw), let destination = WorkspaceDestination(rawValue: value) else { return }
        workspace.navigate(to: destination)
    }
    @objc private func addProfile() {
        guard let values = UI.prompt("新建配置", labels: ["配置名称"]), let name = values.first else { return }
        model.addProfile(name: name)
    }
    @objc private func openSettings() { workspace.navigate(to: .settings) }
    @objc private func openDiagnostics() { workspace.navigate(to: .diagnostics) }
    @objc private func openShare() { workspace.navigate(to: .share) }
}

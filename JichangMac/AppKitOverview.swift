import AppKit

@MainActor
final class OverviewPage: WorkspacePage {
    private let profileName = UI.label("", style: .title2, weight: .semibold)
    private let summary = UI.secondary("")
    private let counts = UI.secondary("")
    private let diagnostics = UI.vertical([], spacing: 6)

    override func loadView() {
        let newProfile = UI.button("新建配置", symbol: "plus", target: self, action: #selector(addProfile))
        let share = UI.button("预览与导出", symbol: "square.and.arrow.up", target: self, action: #selector(openShare))
        let editSettings = UI.button("编辑常规配置", symbol: "slider.horizontal.3", target: self, action: #selector(openSettings))

        let configInfo = UI.vertical([profileName, summary, counts], spacing: 5)
        let actions = UI.horizontal([editSettings, share, newProfile], spacing: 8)
        let resourceLinks = UI.horizontal([
            navButton("订阅", destination: .sources),
            navButton("节点", destination: .nodes),
            navButton("模板", destination: .templates)
        ], spacing: 8)
        let ruleLinks = UI.horizontal([
            navButton("策略组", destination: .groups),
            navButton("分流规则", destination: .rules),
            navButton("规则集", destination: .providers),
            navButton("校验", destination: .diagnostics)
        ], spacing: 8)

        let content = UI.vertical([
            UI.header("当前配置", subtitle: "Mihomo 配置文件与生成状态"),
            configInfo,
            actions,
            UI.separator(),
            UI.section("资源", [resourceLinks]),
            UI.section("规则", [ruleLinks]),
            UI.separator(),
            UI.horizontal([UI.label("最近检查", style: .headline, weight: .semibold), NSView(), UI.button("查看全部", target: self, action: #selector(openDiagnostics))]),
            diagnostics
        ], spacing: 12)

        let scroll = UI.scroll(content)
        let root = NSView()
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        view = root
    }

    override func refresh() {
        let profile = model.activeProfile
        profileName.stringValue = profile.name
        summary.stringValue = "\(profile.fileName).yaml  ·  \(model.generationIsCurrent ? "配置已生成" : "正在生成配置")"
        counts.stringValue = "\(model.state.sources.count) 个订阅  ·  \(model.state.nodes.count) 个节点  ·  \(profile.ruleProfile.groups.count) 个策略组  ·  \(profile.ruleProfile.rules.count) 条规则"

        for child in diagnostics.arrangedSubviews {
            diagnostics.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        let issues = RuleDiagnostics.inspect(profile, nodeIDs: Set(model.state.nodes.map(\.id)))
        if issues.isEmpty {
            diagnostics.addArrangedSubview(UI.secondary("未发现规则问题。"))
        } else {
            for issue in issues.prefix(4) {
                let row = UI.horizontal([UI.secondary("!"), UI.label(issue)])
                row.alignment = .top
                diagnostics.addArrangedSubview(row)
            }
            if issues.count > 4 { diagnostics.addArrangedSubview(UI.secondary("还有 \(issues.count - 4) 个问题")) }
        }
    }

    private func navButton(_ title: String, destination: WorkspaceDestination) -> NSButton {
        let button = UI.button(title, target: self, action: #selector(navigateFromButton(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(String(destination.rawValue))
        return button
    }

    @objc private func navigateFromButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let rawValue = Int(raw), let destination = WorkspaceDestination(rawValue: rawValue) else { return }
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

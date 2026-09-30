import AppKit

@MainActor
final class ConfigurationPage: WorkspacePage, NSTextViewDelegate {
    private let destination: WorkspaceDestination
    private var text: NSTextView?
    private var diagnostics: NSStackView?
    private var hint: NSTextField?
    private var renderedProfile = ""
    private var draftKey = ""
    private var simulation: NSTextField?
    init(model: AppModel, workspace: WorkspaceController, destination: WorkspaceDestination) {
        self.destination = destination
        super.init(model: model, workspace: workspace)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func loadView() {
        let root = WorkspaceSurface()
        let heading = UI.horizontal([UI.header(destination.title, subtitle: destination == .yaml ? "模板 → 高级 YAML → 明确设置的表单字段" : "检查配置结构与引用；运行结果由使用配置的 Mihomo 决定"), NSView()])
        let content: NSView
        if destination == .yaml {
            heading.addArrangedSubview(UI.button("校验并保存", target: self, action: #selector(save), prominent: true))
            let editor = UI.textEditor(""); text = editor.1; text?.delegate = self
            let hint = NSTextField(wrappingLabelWithString: "节点、策略组、规则、规则集和子规则由管理列表生成。同名表单字段优先；未保存内容保留为草稿。")
            hint.textColor = .secondaryLabelColor; self.hint = hint
            let stack = UI.vertical([hint, editor.0], spacing: 12)
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            editor.0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            editor.0.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
            content = stack
        } else {
            let stack = UI.vertical([], spacing: 12); diagnostics = stack
            let scroll = UI.scroll(stack); stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            let input = NSTextField(string: ""); input.placeholderString = "输入域名，例如 example.com"; simulation = input
            let simulator = UI.panel(UI.vertical([UI.secondary("本地模拟仅检查域名规则；其他类型显示为未检查。"), UI.horizontal([input, UI.button("模拟", target: self, action: #selector(simulate))])]))
            let layout = UI.vertical([scroll, simulator], spacing: 16)
            scroll.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
            simulator.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
            content = layout
        }
        root.addSubview(heading); root.addSubview(content)
        NSLayoutConstraint.activate([
            heading.heightAnchor.constraint(equalToConstant: 74),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: heading.leadingAnchor), content.trailingAnchor.constraint(equalTo: heading.trailingAnchor), content.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18), content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        view = root; refresh()
    }
    override func refresh() {
        if destination == .yaml {
            if renderedProfile != model.activeProfile.id {
                renderedProfile = model.activeProfile.id; draftKey = renderedProfile + ":advanced"
                text?.string = model.drafts.get(draftKey)?["text"] ?? model.activeProfile.advancedYaml ?? ""
            }
        } else { renderIssues() }
    }
    func textDidChange(_ notification: Notification) { if let text { model.drafts.put(draftKey, ["text": text.string]) } }
    @objc private func save() {
        guard let text else { return }
        do {
            _ = try ConfigDocument.parse(text.string)
            var profile = model.activeProfile; profile.advancedYaml = text.string
            guard let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
            model.state.profiles[index] = profile; model.drafts.put(draftKey, nil); model.persist()
            hint?.stringValue = "已保存。完整结构检查与覆盖提示请查看“校验”。"
        } catch { hint?.stringValue = "保存失败，草稿已保留：\(error.localizedDescription)" }
    }
    private func renderIssues() {
        guard let stack = diagnostics else { return }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let config: GeneratedConfig
        do { config = try MihomoConfigGenerator.generate(model.state) }
        catch { stack.addArrangedSubview(UI.label("【错误】配置生成：\(error.localizedDescription)")); return }
        let errors = config.issues.filter { $0.severity == .error }.count
        stack.addArrangedSubview(UI.label("\(errors) 项错误 · \(config.issues.count - errors) 项提醒", style: .headline, weight: .semibold))
        stack.addArrangedSubview(UI.secondary(errors == 0 ? "本地结构检查通过。协议运行、远程资源与 Geo 数据尚未检查。" : "修复错误后可复制、导出或分享配置。"))
        for issue in config.issues {
            let label = NSTextField(wrappingLabelWithString: issue.description)
            label.textColor = issue.severity == .error ? .systemRed : .secondaryLabelColor
            let panel = UI.panel(label, padding: 14)
            stack.addArrangedSubview(panel); panel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for provider in config.unresolvedTemplateProviders {
            let label = NSTextField(wrappingLabelWithString: "【错误】代理集合.\(provider)：请在分享页面绑定模板订阅。")
            label.textColor = .systemRed; stack.addArrangedSubview(label)
        }
    }
    @objc private func simulate() {
        guard let input = simulation?.stringValue else { return }
        let rules = model.activeProfile.ruleProfile.rules
        let supported: Set<String> = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "MATCH"]
        let untested = rules.prefix { rule in RuleSimulator.match(input, rules: [rule]) == nil }.filter { !supported.contains($0.type) }.count
        let match = RuleSimulator.match(input, rules: rules)
        UI.alert((untested > 0 ? "前面有 \(untested) 条规则无法本地模拟，以下结果仅供参考。\n" : "") + (match.map { "\($0.type), \($0.value) → \($0.group)" } ?? "未找到可检查的匹配规则。"))
    }
}

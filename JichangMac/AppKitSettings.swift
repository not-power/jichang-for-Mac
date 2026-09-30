import AppKit

@MainActor
final class SettingsPage: WorkspacePage, NSTextViewDelegate {
    private let sections = NSSegmentedControl(labels: SettingsCatalog.sections, trackingMode: .selectOne, target: nil, action: nil)
    private let modes = NSSegmentedControl(labels: ["表单", "YAML 覆盖"], trackingMode: .selectOne, target: nil, action: nil)
    private let content = NSView()
    private let hint = NSTextField(wrappingLabelWithString: "显示模板与高级 YAML 的继承值；仅修改的字段保存为覆盖。未保存草稿会保留。")
    private var form: FieldForm?
    private var yaml: NSTextView?
    private var renderedProfile = ""
    private var draftKey = ""
    private var index: Int { max(0, sections.selectedSegment) }
    override func loadView() {
        sections.selectedSegment = 0; modes.selectedSegment = 0
        sections.target = self; sections.action = #selector(changeSection)
        modes.target = self; modes.action = #selector(changeSection)
        let save = UI.button("校验并保存", target: self, action: #selector(save), prominent: true)
        let reset = UI.button("本组恢复继承", target: self, action: #selector(resetSection))
        let heading = UI.horizontal([UI.header("常规配置", subtitle: "面向 macOS 的 Mihomo 配置"), NSView(), save])
        let toolbar = UI.horizontal([sections, NSView(), modes, reset])
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.textColor = .secondaryLabelColor
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = WorkspaceSurface()
        [heading, toolbar, hint, content].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            heading.heightAnchor.constraint(equalToConstant: 74), toolbar.heightAnchor.constraint(equalToConstant: 36), hint.heightAnchor.constraint(equalToConstant: 36),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            toolbar.leadingAnchor.constraint(equalTo: heading.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: heading.trailingAnchor), toolbar.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
            hint.leadingAnchor.constraint(equalTo: heading.leadingAnchor), hint.trailingAnchor.constraint(equalTo: heading.trailingAnchor), hint.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: heading.leadingAnchor), content.trailingAnchor.constraint(equalTo: heading.trailingAnchor), content.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 14), content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        view = root; render()
    }
    override func refresh() { if renderedProfile != model.activeProfile.id { render() } }
    @objc private func changeSection() { render() }
    private func render() {
        hint.stringValue = "表单显示继承值；仅修改的字段保存为覆盖。两种模式各自保留未保存草稿。"
        renderedProfile = model.activeProfile.id
        content.subviews.forEach { $0.removeFromSuperview() }
        form = nil; yaml = nil
        let profile = model.activeProfile
        let effective = (try? ConfigDocument.effective(model.state, profile: profile)) ?? profile.mihomoSettings
        draftKey = "\(profile.id):settings:\(index):\(modes.selectedSegment)"
        let child: NSView
        if modes.selectedSegment == 1 {
            let source = model.drafts.get(draftKey)?["text"] ?? (try? ConfigDocument.dump(SettingsCatalog.section(profile.mihomoSettings, index))) ?? ""
            let editor = UI.textEditor(source); yaml = editor.1; yaml?.delegate = self; child = editor.0
        } else {
            var values = effective
            values["__name"] = .string(profile.name); values["__file"] = .string(profile.fileName)
            let fields = (index == 0 ? [SettingField("__name", "配置名称"), SettingField("__file", "导出文件名")] : []) + SettingsCatalog.fields(index)
            let form = FieldForm(fields: fields, values: values, inherited: (try? ConfigDocument.inherited(model.state, profile: profile)) ?? [:], model: model, key: draftKey)
            self.form = form
            let document = UI.vertical([UI.panel(form.view)], spacing: 16)
            document.arrangedSubviews[0].widthAnchor.constraint(equalTo: document.widthAnchor).isActive = true
            let scroll = UI.scroll(document)
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            child = scroll
        }
        child.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(child)
        NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: content.leadingAnchor), child.trailingAnchor.constraint(equalTo: content.trailingAnchor), child.topAnchor.constraint(equalTo: content.topAnchor), child.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    }
    func textDidChange(_ notification: Notification) { if let yaml { model.drafts.put(draftKey, ["text": yaml.string]) } }
    @objc private func save() {
        do {
            var profile = model.activeProfile
            if let yaml {
                let parsed = try ConfigDocument.parse(yaml.string)
                guard ConfigDocument.managed.isDisjoint(with: parsed.keys) else { throw ConfigError.message("节点、策略组和规则等字段请在对应管理页面编辑。") }
                profile.mihomoSettings = SettingsCatalog.replacingSection(profile.mihomoSettings, index: index, values: parsed)
            } else if let form {
                var values = profile.mihomoSettings
                values["__name"] = .string(profile.name); values["__file"] = .string(profile.fileName)
                values = try form.applying(to: values)
                profile.name = values.removeValue(forKey: "__name")?.stringValue ?? profile.name
                profile.fileName = values.removeValue(forKey: "__file")?.stringValue ?? profile.fileName
                guard !profile.name.isEmpty, !profile.fileName.isEmpty, !profile.fileName.contains("/"), !profile.fileName.contains("\\") else { throw ConfigError.message("名称不能为空，文件名不能包含路径。") }
                profile.mihomoSettings = values
            }
            var state = model.state
            guard let index = state.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
            state.profiles[index] = profile
            let generated = try MihomoConfigGenerator.generate(state)
            let errors = generated.issues.filter { $0.severity == .error }
            // Field errors block this save; unrelated incomplete rules remain editable elsewhere.
            let fields = Set(SettingsCatalog.fields(self.index).map(\.path))
            if let error = errors.first(where: { fields.contains($0.location) || (self.index > 0 && $0.location == ["", "dns", "tun", "sniffer"][self.index]) }) { throw ConfigError.message(error.description) }
            model.state = state; model.drafts.put(draftKey, nil); model.persist(); render()
            hint.stringValue = "配置已保存。\(generated.issues.filter { $0.severity == .warning }.count) 项警告可在“校验”查看。"
        } catch { hint.stringValue = "保存失败，草稿已保留：\(error.localizedDescription)" }
    }
    @objc private func resetSection() {
        var profile = model.activeProfile
        profile.mihomoSettings = SettingsCatalog.replacingSection(profile.mihomoSettings, index: index, values: [:])
        if let position = model.state.profiles.firstIndex(where: { $0.id == profile.id }) { model.state.profiles[position] = profile }
        for mode in 0...1 { model.drafts.put("\(profile.id):settings:\(index):\(mode)", nil) }
        model.persist(); render(); hint.stringValue = "本组已恢复继承。"
    }
}

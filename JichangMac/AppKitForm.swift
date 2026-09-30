import AppKit

/// A field form stores text separately from the saved profile. Only edited paths become overrides.
@MainActor
final class FieldForm: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    let view = UI.vertical([], spacing: 16)
    private let fields: [SettingField]
    private let model: AppModel
    private let key: String
    private let inherited: [String: JSONValue]?
    private var controls: [String: NSView] = [:]
    private var baseline: [String: String] = [:]
    private var removed = Set<String>()
    private let onChange: (() -> Void)?

    init(fields: [SettingField], values: [String: JSONValue], inherited: [String: JSONValue]? = nil, model: AppModel, key: String, onChange: (() -> Void)? = nil) {
        self.fields = fields; self.model = model; self.key = key; self.inherited = inherited; self.onChange = onChange
        super.init()
        let draft = model.drafts.get(key)
        for field in fields {
            let initial = Self.text(ConfigDocument.value(values, at: field.path), field: field)
            baseline[field.path] = draft?["baseline:" + field.path] ?? initial
            if draft?["inherit:" + field.path] == "true" { removed.insert(field.path) }
            let text = draft?[field.path] ?? initial
            let control: NSView
            switch field.kind {
            case .boolean, .choice:
                let picker = NSPopUpButton()
                picker.addItem(withTitle: "未设置 / 继承")
                picker.lastItem?.representedObject = ""
                let choices: [String]
                if case .choice(let options) = field.kind { choices = options } else { choices = ["true", "false"] }
                for choice in choices {
                    let title: String
                    if case .boolean = field.kind { title = choice == "true" ? "开启" : "关闭" } else { title = choice }
                    picker.addItem(withTitle: title); picker.lastItem?.representedObject = choice
                }
                if !text.isEmpty, !choices.contains(text) { picker.addItem(withTitle: text); picker.lastItem?.representedObject = text }
                picker.select(picker.itemArray.first { $0.representedObject as? String == text })
                picker.target = self; picker.action = #selector(changedControl)
                control = picker
            case .lines, .yaml, .ports:
                let (scroll, editor) = UI.textEditor(text)
                editor.identifier = NSUserInterfaceItemIdentifier(field.path); editor.delegate = self
                scroll.heightAnchor.constraint(equalToConstant: field.path == "members" ? 160 : 100).isActive = true
                controls[field.path] = editor
                control = scroll
            default:
                let input: NSTextField
                if case .secret = field.kind { input = NSSecureTextField(string: text) } else { input = NSTextField(string: text) }
                input.delegate = self; input.controlSize = .large
                control = input
            }
            if controls[field.path] == nil { controls[field.path] = control }
            controls[field.path]?.identifier = NSUserInterfaceItemIdentifier(field.path)
            controls[field.path]?.setAccessibilityLabel(field.title)
            let header = UI.horizontal([UI.secondary(field.title), NSView()])
            if inherited != nil && !field.path.hasPrefix("__") {
                let reset = UI.button("恢复继承", target: self, action: #selector(resetField(_:)))
                reset.identifier = NSUserInterfaceItemIdentifier(field.path)
                header.addArrangedSubview(reset)
            }
            let row = UI.vertical([header, control], spacing: 6)
            header.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            control.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            view.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
    }
    static func text(_ value: JSONValue?, field: SettingField) -> String {
        guard let value else { return "" }
        if case .yaml = field.kind { return (try? ConfigDocument.dump(value.objectValue ?? [:])) ?? "" }
        if let string = value.stringValue { return string }
        if let boolean = value.boolValue { return boolean ? "true" : "false" }
        if let array = value.arrayValue { return array.map { $0.stringValue ?? $0.intValue.map(String.init) ?? "" }.joined(separator: "\n") }
        return value.intValue.map(String.init) ?? ""
    }
    func text(at path: String) -> String {
        if let field = controls[path] as? NSTextField { return field.stringValue }
        if let text = controls[path] as? NSTextView { return text.string }
        if let picker = controls[path] as? NSPopUpButton { return picker.selectedItem?.representedObject as? String ?? "" }
        return ""
    }
    func setText(_ text: String, at path: String) {
        if let field = controls[path] as? NSTextField { field.stringValue = text }
        else if let editor = controls[path] as? NSTextView { editor.string = text }
        else if let picker = controls[path] as? NSPopUpButton { picker.select(picker.itemArray.first { $0.representedObject as? String == text }) }
        removed.remove(path); stash(); onChange?()
    }
    func stash() {
        var draft: [String: String] = [:]
        for field in fields {
            draft[field.path] = text(at: field.path)
            draft["baseline:" + field.path] = baseline[field.path]
            if removed.contains(field.path) { draft["inherit:" + field.path] = "true" }
        }
        model.drafts.put(key, draft)
    }
    func clearDraft() { model.drafts.put(key, nil) }
    func applying(to source: [String: JSONValue], changedOnly: Bool = true) throws -> [String: JSONValue] {
        var result = source
        for field in fields {
            let text = text(at: field.path)
            if removed.contains(field.path) { ConfigDocument.set(&result, at: field.path, to: nil); continue }
            if changedOnly && text == baseline[field.path] { continue }
            let value: JSONValue?
            switch field.kind {
            case .boolean: value = text.isEmpty ? nil : .bool(text == "true")
            case .choice: value = text.isEmpty ? nil : .string(text)
            case .integer:
                if text.isEmpty { value = nil }
                else { guard let number = Int64(text) else { throw ConfigError.message("\(field.title)：需要整数。") }; value = .integer(number) }
            case .lines: value = .array(text.split(whereSeparator: \.isNewline).map { .string($0.trimmingCharacters(in: .whitespaces)) })
            case .ports: value = .array(text.split(whereSeparator: \.isNewline).map { let text = $0.trimmingCharacters(in: .whitespaces); return Int64(text).map(JSONValue.integer) ?? .string(text) })
            case .yaml: value = .object(try ConfigDocument.parse(text))
            case .text, .secret: value = .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let value, let error = field.validate(value) { throw ConfigError.message("\(field.title)：\(error)") }
            ConfigDocument.set(&result, at: field.path, to: value)
        }
        return result
    }
    func controlTextDidChange(_ notification: Notification) { edited(notification.object as? NSView) }
    func textDidChange(_ notification: Notification) { edited(notification.object as? NSView) }
    @objc private func changedControl(_ sender: NSView) { edited(sender) }
    private func edited(_ view: NSView?) {
        if let path = view?.identifier?.rawValue { removed.remove(path) }
        stash(); onChange?()
    }
    @objc private func resetField(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, let field = fields.first(where: { $0.path == path }) else { return }
        setText(Self.text(inherited.flatMap { ConfigDocument.value($0, at: path) }, field: field), at: path)
        removed.insert(path); stash()
    }
}

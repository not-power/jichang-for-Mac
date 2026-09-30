import AppKit
import UniformTypeIdentifiers

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
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: prominent ? .semibold : .medium)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setAccessibilityLabel(title)
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
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.isEditable = editable; view.isRichText = false; view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 9, height: 9)
        view.string = text
        let scroll = UI.scroll(view)
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        view.backgroundColor = .textBackgroundColor
        return (scroll, view)
    }
    static func content(_ children: [NSView]) -> NSView {
        let root = WorkspaceSurface()
        let stack = vertical(children, spacing: 14)
        root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18)])
        return root
    }
    static func header(_ title: String, subtitle: String) -> NSView {
        let heading = label(title, style: .title1, weight: .semibold)
        heading.font = .systemFont(ofSize: 26, weight: .bold)
        let detail = secondary(subtitle)
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 2
        return vertical([heading, detail], spacing: 7)
    }
    static func section(_ title: String, _ views: [NSView]) -> NSView {
        let heading = label(title, style: .headline, weight: .semibold)
        let stack = vertical([heading] + views, spacing: 10)
        return stack
    }
    static func symbol(_ name: String, size: CGFloat = 20) -> NSImageView {
        let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: size, weight: .medium)
        image.contentTintColor = .controlAccentColor
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: size + 8).isActive = true
        image.heightAnchor.constraint(equalToConstant: size + 8).isActive = true
        return image
    }
    static func panel(_ content: NSView, padding: CGFloat = 20, accented: Bool = false) -> NSView {
        let panel = WorkspaceSurface(raised: true, accented: accented)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -padding)
        ])
        return panel
    }
    static func emptyState(_ title: String, detail: String, symbol name: String) -> NSView {
        let heading = label(title, style: .headline, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: detail)
        explanation.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: 12)
        explanation.alignment = .center
        let stack = vertical([symbol(name, size: 28), heading, explanation], spacing: 12)
        stack.alignment = .centerX
        explanation.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        return panel(stack, padding: 24)
    }
    static func listContainer(_ scroll: NSScrollView, emptyState: NSView) -> NSView {
        let container = WorkspaceSurface(raised: true)
        container.addSubview(scroll)
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: container.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32)
        ])
        return container
    }
    static func styleList(_ scroll: NSScrollView) {
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.masksToBounds = true
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

/// Uses semantic AppKit colors so surfaces update with system appearance and contrast.
@MainActor
final class WorkspaceSurface: NSView {
    private let raised: Bool
    private let accented: Bool
    init(raised: Bool = false, accented: Bool = false) {
        self.raised = raised; self.accented = accented
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let canvas = dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedRed: 0.965, green: 0.973, blue: 0.985, alpha: 1)
        layer?.backgroundColor = (raised ? NSColor.controlBackgroundColor : canvas).cgColor
        layer?.cornerRadius = raised ? 14 : 0
        layer?.borderWidth = raised ? 1 : 0
        layer?.borderColor = (accented ? NSColor.controlAccentColor.withAlphaComponent(0.3) : (dark ? NSColor.white : NSColor.black).withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.4 : 0.08)).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

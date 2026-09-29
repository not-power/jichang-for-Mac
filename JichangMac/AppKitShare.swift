import AppKit
import CoreImage.CIFilterBuiltins

@MainActor
final class SharePage: WorkspacePage {
    private static let qrContext = CIContext()
    private let profileLabel = UI.label("", style: .headline, weight: .semibold)
    private let countLabel = UI.secondary("")
    private let issueLabel = UI.secondary("")
    private let sourcePicker = NSPopUpButton()
    private let exportButton = UI.button("导出 YAML…", symbol: "square.and.arrow.down", target: nil, action: nil, prominent: true)
    private let copyButton = UI.button("复制 YAML", symbol: "doc.on.doc", target: nil, action: nil)
    private let shareButton = UI.button("开启局域网分享", symbol: "wifi", target: nil, action: nil)
    private let shareLink = NSTextField(wrappingLabelWithString: "")
    private let copyShareLinkButton = UI.button("复制分享链接", symbol: "link", target: nil, action: nil)
    private let qrView = NSImageView()
    private let bindingStack = UI.vertical([], spacing: 8)
    private var cachedQRURL: String?
    private var cachedQRImage: NSImage?
    private let preview: NSTextView
    private let previewScroll: NSScrollView

    override init(model: AppModel, workspace: WorkspaceController) {
        (previewScroll, preview) = UI.textEditor("正在生成配置…", editable: false)
        super.init(model: model, workspace: workspace)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        sourcePicker.addItems(withTitles: ["内嵌节点", "引用订阅"])
        sourcePicker.target = self; sourcePicker.action = #selector(changeSourceMode)
        exportButton.target = self; exportButton.action = #selector(exportYAML)
        copyButton.target = self; copyButton.action = #selector(copyYAML)
        shareButton.target = self; shareButton.action = #selector(toggleShare)
        copyShareLinkButton.target = self; copyShareLinkButton.action = #selector(copyShareLink)
        shareLink.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shareLink.textColor = .secondaryLabelColor
        shareLink.lineBreakMode = .byCharWrapping
        shareLink.maximumNumberOfLines = 0
        shareLink.isSelectable = true
        shareLink.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        qrView.imageScaling = .scaleNone
        qrView.setAccessibilityLabel("局域网分享二维码")
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrView.widthAnchor.constraint(equalToConstant: 165).isActive = true
        qrView.heightAnchor.constraint(equalToConstant: 165).isActive = true
        let shareURLRow = UI.vertical([shareLink, copyShareLinkButton], spacing: 8)
        let left = UI.vertical([
            UI.section("输出配置", [profileLabel, countLabel, issueLabel]),
            UI.separator(),
            UI.section("节点来源", [sourcePicker, bindingStack]),
            UI.separator(),
            UI.horizontal([exportButton, copyButton]),
            UI.separator(),
            UI.section("局域网分享", [UI.secondary("其他设备需处于可互访的同一局域网。"), shareButton, shareURLRow, qrView])
        ], spacing: 11)
        shareURLRow.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -24).isActive = true
        let leftScroll = UI.scroll(left)
        let right = UI.vertical([UI.label("YAML 预览", style: .headline, weight: .semibold), previewScroll], spacing: 12)
        let split = NSSplitView()
        split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(leftScroll); split.addArrangedSubview(right)
        split.translatesAutoresizingMaskIntoConstraints = false
        let header = UI.header("分享", subtitle: "预览、导出或通过局域网分享配置")
        let root = NSView()
        root.addSubview(header); root.addSubview(split)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), header.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            split.leadingAnchor.constraint(equalTo: header.leadingAnchor), split.trailingAnchor.constraint(equalTo: header.trailingAnchor), split.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), split.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            leftScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 310), right.widthAnchor.constraint(greaterThanOrEqualToConstant: 350),
            previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 380),
            left.widthAnchor.constraint(equalTo: leftScroll.contentView.widthAnchor),
            shareLink.widthAnchor.constraint(equalTo: shareURLRow.widthAnchor)
        ])
        view = root
    }

    override func refresh() {
        let profile = model.activeProfile
        profileLabel.stringValue = profile.fileName + ".yaml"
        countLabel.stringValue = model.generationIsCurrent ? "\(model.generatedConfig?.exportedNodes ?? 0) 个节点 · \(model.generatedConfig?.referencedSubscriptions ?? 0) 个引用订阅" : "正在生成最新配置…"
        let generated = model.generatedConfig
        if model.generationIsCurrent, let yaml = generated?.yaml {
            workspace.shareServer?.update(config: yaml, fileName: profile.fileName + ".yaml")
        }
        let skipped = generated?.skippedNodes ?? 0
        let unresolved = generated?.unresolvedTemplateProviders ?? []
        issueLabel.stringValue = [skipped > 0 ? "跳过 \(skipped) 个不支持的节点" : nil, unresolved.isEmpty ? nil : "需绑定模板订阅：\(unresolved.joined(separator: "、"))"].compactMap { $0 }.joined(separator: "\n")
        sourcePicker.selectItem(at: profile.sourceMode == "REFERENCE_SUBSCRIPTIONS" ? 1 : 0)
        let ready = model.generationIsCurrent && generated != nil && unresolved.isEmpty
        exportButton.isEnabled = ready; copyButton.isEnabled = ready
        shareButton.isEnabled = ready || workspace.shareServer != nil
        shareButton.title = workspace.shareServer == nil ? "开启局域网分享" : "停止分享"
        shareLink.stringValue = workspace.shareURL ?? ""
        if cachedQRURL != workspace.shareURL {
            cachedQRURL = workspace.shareURL
            cachedQRImage = workspace.shareURL.flatMap(makeQR)
        }
        qrView.image = cachedQRImage
        qrView.isHidden = workspace.shareURL == nil
        let displayedYAML = generated?.yaml ?? (model.generationIsCurrent ? "无法生成配置。请检查 YAML。" : "正在生成配置…")
        if preview.string != displayedYAML { preview.string = displayedYAML }
        for child in bindingStack.arrangedSubviews { bindingStack.removeArrangedSubview(child); child.removeFromSuperview() }
        if !unresolved.isEmpty {
            bindingStack.addArrangedSubview(UI.secondary("为模板中的订阅选择来源："))
            for name in unresolved {
                let picker = NSPopUpButton()
                picker.addItem(withTitle: "未绑定")
                picker.item(at: 0)?.representedObject = ""
                for source in model.state.sources where source.providerCompatible == true && profile.selectedSourceIds.contains(source.id) {
                    picker.addItem(withTitle: source.name); picker.lastItem?.representedObject = source.id
                }
                picker.select(picker.itemArray.first { ($0.representedObject as? String) == (profile.templateProviderBindings[name] ?? "") })
                picker.target = self; picker.action = #selector(changeBinding(_:)); picker.identifier = NSUserInterfaceItemIdentifier(name)
                bindingStack.addArrangedSubview(UI.horizontal([UI.secondary(name), picker]))
            }
        }
    }
    @objc private func changeSourceMode() {
        var profile = model.activeProfile
        profile.sourceMode = sourcePicker.indexOfSelectedItem == 1 ? "REFERENCE_SUBSCRIPTIONS" : "EMBED_NODES"
        replace(profile)
    }
    @objc private func changeBinding(_ picker: NSPopUpButton) {
        guard let name = picker.identifier?.rawValue else { return }
        var profile = model.activeProfile
        if let id = picker.selectedItem?.representedObject as? String, !id.isEmpty { profile.templateProviderBindings[name] = id }
        else { profile.templateProviderBindings.removeValue(forKey: name) }
        replace(profile)
    }
    private func replace(_ profile: ConfigProfile) {
        guard let index = model.state.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        model.state.profiles[index] = profile; model.persist()
    }
    @objc private func exportYAML() { workspace.exportConfig() }
    @objc private func copyYAML() {
        guard model.generationIsCurrent, let yaml = model.generatedConfig?.yaml else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(yaml, forType: .string)
        model.notice = "YAML 已复制。"
    }
    @objc private func copyShareLink() {
        guard let url = workspace.shareURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
        model.notice = "分享链接已复制。"
    }
    @objc private func toggleShare() {
        if let server = workspace.shareServer {
            server.stop(); workspace.shareServer = nil; workspace.shareURL = nil; refresh(); return
        }
        guard model.generationIsCurrent, let yaml = model.generatedConfig?.yaml else { return }
        let server = LocalShareServer(config: yaml, fileName: model.activeProfile.fileName + ".yaml")
        Task {
            do { workspace.shareURL = try await server.start(); workspace.shareServer = server; refresh() }
            catch { UI.alert(error.localizedDescription) }
        }
    }
    private func makeQR(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(string.utf8); filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        // Scale by an integer so every QR module stays a crisp square in the 2x display image.
        let scale = CGFloat(10)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = Self.qrContext.createCGImage(scaled, from: scaled.extent.integral) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
    }
}

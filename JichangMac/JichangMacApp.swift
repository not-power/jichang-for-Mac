import AppKit
import UniformTypeIdentifiers

@MainActor
final class JichangMacApp: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private let model = AppModel()
    private var window: NSWindow?
    private var workspace: WorkspaceController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let workspace = WorkspaceController(model: model)
        self.workspace = workspace
        let window = NSWindow(contentViewController: workspace)
        window.title = "鸡场"
        window.setContentSize(NSSize(width: 1160, height: 760))
        window.minSize = NSSize(width: 850, height: 570)
        window.center()
        window.tabbingMode = .preferred
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "JichangToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.makeKeyAndOrderFront(nil)
        self.window = window
        installMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func installMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu(title: "鸡场")
        appMenu.addItem(withTitle: "关于鸡场", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出鸡场", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)

        let fileMenu = NSMenu(title: "文件")
        let importItem = fileMenu.addItem(withTitle: "导入备份…", action: #selector(importBackup), keyEquivalent: "i")
        importItem.keyEquivalentModifierMask = [.command, .option]
        let exportItem = fileMenu.addItem(withTitle: "导出备份…", action: #selector(exportBackup), keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "导出配置…", action: #selector(exportConfig), keyEquivalent: "e")
        let fileItem = NSMenuItem(); fileItem.submenu = fileMenu; menu.addItem(fileItem)

        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", #selector(UndoManager.undo), "z"), ("重做", #selector(UndoManager.redo), "Z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editItem = NSMenuItem(); editItem.submenu = editMenu; menu.addItem(editItem)

        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(withTitle: "显示或隐藏边栏", action: #selector(toggleSidebar), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
        let viewItem = NSMenuItem(); viewItem.submenu = viewMenu; menu.addItem(viewItem)
        NSApp.mainMenu = menu
    }

    @objc private func importBackup() { workspace?.importBackup() }
    @objc private func exportBackup() { workspace?.exportBackup() }
    @objc private func exportConfig() { workspace?.exportConfig() }
    @objc private func toggleSidebar() { workspace?.toggleSidebar(nil) }
    @objc private func refreshConfig() { model.regenerate() }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, .init("refreshConfig"), .init("exportConfig")]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, .init("refreshConfig"), .init("exportConfig")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier.rawValue {
        case "refreshConfig":
            item.label = "重新生成"; item.toolTip = "重新生成当前配置"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: item.label)
            item.target = self; item.action = #selector(refreshConfig)
        case "exportConfig":
            item.label = "导出配置"; item.toolTip = "导出 Mihomo YAML"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: item.label)
            item.target = self; item.action = #selector(exportConfig)
        default: return nil
        }
        return item
    }
}

@main
@MainActor
enum JichangMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = JichangMacApp()
        app.delegate = delegate
        app.run()
    }
}

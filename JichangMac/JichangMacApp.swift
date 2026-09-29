import SwiftUI

@main
struct JichangMacApp: App {
    var body: some Scene {
        WindowGroup("鸡场") { ContentView() }
            .defaultSize(width: 1180, height: 780)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .importExport) {
                    Button("导出设备备份…") { NotificationCenter.default.post(name: .jichangExportBackup, object: nil) }
                        .keyboardShortcut("e", modifiers: [.command, .option])
                    Button("导入设备备份…") { NotificationCenter.default.post(name: .jichangImportBackup, object: nil) }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                }
            }
    }
}

extension Notification.Name {
    static let jichangExportBackup = Notification.Name("jichang.exportBackup")
    static let jichangImportBackup = Notification.Name("jichang.importBackup")
}

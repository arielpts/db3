import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: WorkbenchModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            if model.hasUnfinishedWork, let window = sender.keyWindow ?? sender.windows.first {
                let alert = NSAlert()
                alert.messageText = "Close active database sessions?"
                alert.informativeText = "Running queries will be interrupted and uncommitted transactions will be rolled back when connections close."
                alert.addButton(withTitle: "Close Sessions & Quit")
                alert.addButton(withTitle: "Keep Working")
                let response = await alert.beginSheetModal(for: window)
                guard response == .alertFirstButtonReturn else { sender.reply(toApplicationShouldTerminate: false); return }
            }
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct DB3App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = WorkbenchModel()
    var body: some Scene {
        Window("db3", id: "workspace") {
            WorkbenchView(model: model)
                .frame(minWidth: 940, minHeight: 620)
                .task { delegate.model = model; await model.load() }
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Worksheet", action: model.addWorksheet).keyboardShortcut("n")
                Button("New Connection…", action: model.newConnection).keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Open SQL…", action: model.openSQL).keyboardShortcut("o")
                Button("Save SQL…", action: model.saveSQL).keyboardShortcut("s")
            }
            CommandMenu("Query") {
                Button("Run Statement") { model.active.run() }.keyboardShortcut(.return, modifiers: .command).disabled(!model.active.isConnected || model.active.isBusy)
                Button("Cancel Query") { model.active.cancel() }.keyboardShortcut(".").disabled(!model.active.isBusy)
                Divider()
                Button("Begin Transaction") { model.active.run(sql: "BEGIN") }.disabled(!model.active.isConnected || model.active.isBusy || model.active.isDemo || model.active.transaction != .idle)
                Button("Commit") { model.active.run(sql: "COMMIT") }.disabled(!model.active.isConnected || model.active.isBusy || model.active.isDemo || model.active.transaction != .inTransaction)
                Button("Rollback") { model.active.run(sql: "ROLLBACK") }.disabled(!model.active.isConnected || model.active.isBusy || model.active.isDemo || model.active.transaction == .idle)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Inspector") { model.showingInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        Settings { SettingsView().frame(width: 460, height: 340) }
    }
}

private struct SettingsView: View {
    var body: some View {
        Form {
            Section("Workspace") {
                LabeledContent("Database", value: "PostgreSQL")
                LabeledContent("Connections", value: "4 pinned worksheet sessions")
                LabeledContent("Credentials", value: "macOS Keychain")
            }
            Section("Results") {
                Text("Results are paged to private temporary storage and removed when the worksheet closes. Query history is not recorded.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

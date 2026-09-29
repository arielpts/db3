import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: WorkbenchModel?
    private var terminationPending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminationPending, !model.hasConnectionPrompt else { return .terminateCancel }
        terminationPending = true
        Task {
            let approved = await model.requestCloseWorkspace()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: approved)
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
                .background(WorkspaceWindowLifecycle(model: model).frame(width: 0, height: 0))
                .focusedSceneValue(\.workbench, model)
                .task { delegate.model = model; model.ensureWorkspace(); await model.load() }
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified)
        .commands { WorkbenchCommands() }
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

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
    @AppStorage("appearance.theme") private var theme: AppTheme = .system
    var body: some Scene {
        Window("db3", id: "workspace") {
            WorkbenchView(model: model)
                .frame(minWidth: 940, minHeight: 620)
                .background(WorkspaceWindowLifecycle(model: model).frame(width: 0, height: 0))
                .focusedSceneValue(\.workbench, model)
                .onChange(of: theme, initial: true) { _, value in value.apply() }
                .task { delegate.model = model; model.ensureWorkspace(); await model.load()
                await model.project.loadRecents() }
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified)
        .commands { WorkbenchCommands() }
        Settings { SettingsView().frame(width: 460, height: 410) }
    }
}

private struct SettingsView: View {
    @AppStorage("appearance.theme") private var theme: AppTheme = .system
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }.pickerStyle(.segmented)
            }
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
            .onChange(of: theme, initial: true) { _, value in value.apply() }
    }
}

private enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

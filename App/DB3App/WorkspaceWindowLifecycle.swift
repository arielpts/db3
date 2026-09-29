import AppKit
import SwiftUI

/// Intercepts the workspace's red close button without changing other windows.
/// Other delegate methods continue to reach SwiftUI's window delegate.
struct WorkspaceWindowLifecycle: NSViewRepresentable {
    let model: WorkbenchModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.attach = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }
    func updateNSView(_ view: WindowAttachmentView, context: Context) {}
    static func dismantleNSView(_ view: WindowAttachmentView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class WindowAttachmentView: NSView {
        var attach: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach?(window) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: WorkbenchModel
        weak var window: NSWindow?
        // Objective-C forwarding queries this weak reference through NSObject's
        // nonisolated hooks; attachment/mutation remain main-actor operations.
        nonisolated(unsafe) weak var previousDelegate: (any NSWindowDelegate)?
        private var closing = false
        private var approved = false

        init(model: WorkbenchModel) { self.model = model }
        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window; previousDelegate = window.delegate
            window.delegate = self
            approved = false
        }
        func detach() {
            if window?.delegate === self { window?.delegate = previousDelegate }
            window = nil; previousDelegate = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if approved { approved = false; return true }
            guard !closing, !model.hasConnectionPrompt, sender.attachedSheet == nil else { return false }
            if previousDelegate?.windowShouldClose?(sender) == false { return false }
            closing = true
            Task { [weak self, weak sender] in
                guard let self, let sender else { return }
                let accepted = await model.requestCloseWorkspace()
                closing = false
                guard accepted else { return }
                approved = true
                sender.performClose(nil)
            }
            return false
        }
        override nonisolated func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return previousDelegate?.responds(to: selector) ?? false
        }
        override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
            previousDelegate
        }
    }
}

struct WorkbenchFocusKey: FocusedValueKey { typealias Value = WorkbenchModel }
extension FocusedValues {
    var workbench: WorkbenchModel? {
        get { self[WorkbenchFocusKey.self] }
        set { self[WorkbenchFocusKey.self] = newValue }
    }
}

struct WorkbenchCommands: Commands {
    @FocusedValue(\.workbench) private var model
    private var commandsAllowed: Bool {
        model != nil && model?.hasConnectionPrompt != true && model?.isCoordinatingClose != true
            && model?.isRestoringWorkspace != true
    }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Query Tab") { model?.addWorksheet() }.keyboardShortcut("t").disabled(!commandsAllowed || model?.canAddWorksheet != true)
            Button("New Query") { model?.addWorksheet() }.keyboardShortcut("n").disabled(!commandsAllowed || model?.canAddWorksheet != true)
            Button("New Connection…") { model?.newConnection() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!commandsAllowed)
            Divider()
            Button("Open SQL…") { model?.openSQL() }.keyboardShortcut("o").disabled(!commandsAllowed)
        }
        CommandGroup(replacing: .saveItem) {
            Button(model == nil ? "Close Window" : "Close Query Tab") {
                if let model { model.requestClose(model.active) }
                else { NSApp.keyWindow?.performClose(nil) }
            }.keyboardShortcut("w").disabled(model != nil && !commandsAllowed)
            Button("Close Workspace Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift]).disabled(!commandsAllowed)
            Divider()
            Button("Save SQL") { model?.saveSQL() }.keyboardShortcut("s")
                .disabled(!commandsAllowed || model?.active.isLoading == true || model?.active.isSaving == true)
            Button("Save SQL As…") {
                guard let model else { return }
                let sheet = model.active
                Task { _ = await model.saveSQL(sheet: sheet, saveAs: true) }
            }.keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!commandsAllowed || model?.active.isLoading == true || model?.active.isSaving == true)
        }
        CommandMenu("Query") {
            Button("Run Statement") { model?.active.run() }.keyboardShortcut(.return, modifiers: .command)
                .disabled(!commandsAllowed || model?.active.isConnected != true || model?.active.isBusy == true || model?.active.canIssueCommands != true)
            Button("Cancel Query") { model?.active.cancel() }.keyboardShortcut(".")
                .disabled(!commandsAllowed || model?.active.isBusy != true || model?.active.isCancelling == true)
            Divider()
            Button("Begin Transaction") { model?.active.run(sql: "BEGIN") }.disabled(!canTransact || model?.active.transaction != .idle)
            Button("Commit") { model?.active.run(sql: "COMMIT") }.disabled(!canTransact || model?.active.transaction != .inTransaction)
            Button("Rollback") { model?.active.run(sql: "ROLLBACK") }.disabled(!canTransact || model?.active.transaction == .idle)
            Divider()
            Button("Next Query Tab") { model?.selectAdjacentTab(1) }.keyboardShortcut(.tab, modifiers: [.control])
                .disabled(!commandsAllowed || (model?.worksheets.count ?? 0) < 2)
            Button("Previous Query Tab") { model?.selectAdjacentTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(!commandsAllowed || (model?.worksheets.count ?? 0) < 2)
            Divider()
            ForEach(0..<WorkbenchModel.maximumWorksheets, id: \.self) { index in
                Button("Select Query Tab \(index + 1)") { model?.selectTab(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(!commandsAllowed || index >= (model?.worksheets.count ?? 0))
            }
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { model?.showingInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option]).disabled(!commandsAllowed)
        }
    }
    private var canTransact: Bool {
        commandsAllowed && model?.active.isConnected == true && model?.active.isBusy != true && model?.active.isDemo != true && model?.active.canIssueCommands == true
    }
}

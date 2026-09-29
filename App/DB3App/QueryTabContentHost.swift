import AppKit
import SwiftUI

/// Page hosts outlive selection and inspector visibility. Only the selected
/// native page is attached, so inactive pages cannot receive hits/accessibility.
@MainActor
final class QueryViewHosts {
    enum Kind { case worksheet, inspector }
    @MainActor final class FocusMemory { weak var responder: NSView? }
    @MainActor final class Page {
        let controller: NSHostingController<AnyView>
        let focus: FocusMemory
        init(_ content: AnyView, focus: FocusMemory) {
            controller = NSHostingController(rootView: content)
            self.focus = focus
        }
    }
    private var worksheets: [UUID: Page] = [:]
    private var inspectors: [UUID: Page] = [:]
    private var focus: [UUID: FocusMemory] = [:]

    func page(for sheet: Worksheet, model: WorkbenchModel, kind: Kind) -> Page {
        let memory = focus[sheet.id] ?? FocusMemory()
        focus[sheet.id] = memory
        switch kind {
        case .worksheet:
            if let existing = worksheets[sheet.id] { return existing }
            let page = Page(AnyView(WorksheetView(sheet: sheet, model: model)), focus: memory)
            worksheets[sheet.id] = page
            return page
        case .inspector:
            if let existing = inspectors[sheet.id] { return existing }
            let page = Page(AnyView(QueryInspectorView(sheet: sheet, model: model)), focus: memory)
            inspectors[sheet.id] = page
            return page
        }
    }

    func prune(keeping ids: Set<UUID>) {
        worksheets = worksheets.filter { ids.contains($0.key) }
        inspectors = inspectors.filter { ids.contains($0.key) }
        focus = focus.filter { ids.contains($0.key) }
    }
}

struct QueryTabContentHost: NSViewControllerRepresentable {
    let model: WorkbenchModel
    let hosts: QueryViewHosts
    var kind: QueryViewHosts.Kind = .worksheet
    // Explicit value inputs make selection/removal invalidate the representable
    // even though its model and retained-host references stay identical.
    private let selectedID: UUID?
    private let worksheetIDs: [UUID]

    init(model: WorkbenchModel, hosts: QueryViewHosts, kind: QueryViewHosts.Kind = .worksheet) {
        self.model = model; self.hosts = hosts; self.kind = kind
        self.selectedID = model.selectedID; self.worksheetIDs = model.worksheets.map(\.id)
    }

    func makeNSViewController(context: Context) -> Container { Container() }
    func updateNSViewController(_ controller: Container, context: Context) {
        hosts.prune(keeping: Set(worksheetIDs))
        guard let sheet = model.worksheets.first(where: { $0.id == selectedID }) ?? model.worksheets.first else {
            controller.clear()
            return
        }
        if !controller.show(hosts.page(for: sheet, model: model, kind: kind), id: sheet.id,
                            restoreFocus: true, defaultEditorFocus: kind == .worksheet),
           let previous = controller.selectedID {
            // A native editor can refuse resignation while validating input.
            // Keep that document visible and reconcile selection next turn.
            DispatchQueue.main.async { [weak model] in model?.selectTab(previous) }
        }
    }

    static func dismantleNSViewController(_ controller: Container, coordinator: ()) { controller.clear() }

    @MainActor
    final class Container: NSViewController {
        private(set) var selectedID: UUID?
        private var page: QueryViewHosts.Page?

        override func loadView() {
            // Frame-based child layout isolates its fitting size from the
            // outer NavigationSplitView, preserving independent dividers.
            view = NSView()
        }

        @discardableResult
        func show(_ next: QueryViewHosts.Page, id: UUID, restoreFocus: Bool, defaultEditorFocus: Bool = true) -> Bool {
            guard selectedID != id || page !== next else { return true }
            let window = view.window
            if let old = page, let responder = window?.firstResponder as? NSView,
               responder.isDescendant(of: old.controller.view) {
                old.focus.responder = responder
                // Native text input commits/resigns before a different document
                // becomes first responder; no SQL text is copied here.
                if window?.makeFirstResponder(nil) == false { return false }
            }
            clear()
            selectedID = id
            page = next
            // Inspector teardown may leave this child attached to an earlier
            // representable container. The retained page itself is unchanged.
            next.controller.view.removeFromSuperview()
            next.controller.removeFromParent()
            addChild(next.controller)
            let content = next.controller.view
            content.frame = view.bounds
            content.autoresizingMask = [.width, .height]
            view.addSubview(content)
            guard restoreFocus else { return true }
            DispatchQueue.main.async { [weak self, weak next] in
                guard let self, let next, self.page === next,
                      let window = self.view.window, window.isKeyWindow,
                      window.attachedSheet == nil else { return }
                if let responder = next.focus.responder, responder.window === window {
                    window.makeFirstResponder(responder)
                } else if defaultEditorFocus, let editor = self.editableTextView(in: next.controller.view) {
                    window.makeFirstResponder(editor)
                }
            }
            return true
        }

        func clear() {
            if let page, let responder = view.window?.firstResponder as? NSView,
               responder.isDescendant(of: page.controller.view) {
                page.focus.responder = responder
            }
            page?.controller.view.removeFromSuperview()
            page?.controller.removeFromParent()
            page = nil
            selectedID = nil
        }

        private func editableTextView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            for child in view.subviews {
                if let text = editableTextView(in: child) { return text }
            }
            return nil
        }
    }
}

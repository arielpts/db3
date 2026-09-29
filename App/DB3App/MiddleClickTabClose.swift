import AppKit
import SwiftUI

/// Intercepts only the middle mouse button inside this tab. Left-click,
/// drag-and-drop, scrolling, and context-menu events reach the SwiftUI controls.
struct MiddleClickTabClose: NSViewRepresentable {
    var isEnabled: Bool
    var onClose: () -> Void

    func makeNSView(context: Context) -> MiddleClickTabView { MiddleClickTabView() }
    func updateNSView(_ view: MiddleClickTabView, context: Context) {
        view.isEnabled = isEnabled
        view.onClose = onClose
    }
    static func dismantleNSView(_ view: MiddleClickTabView, coordinator: ()) {
        view.isEnabled = false
        view.onClose = nil
    }
}

@MainActor
final class MiddleClickTabView: NSView {
    var isEnabled = true {
        didSet { if !isEnabled { pressed = false } }
    }
    var onClose: (() -> Void)?
    private var pressed = false
    private var clickableRect: NSRect { bounds.intersection(visibleRect) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTest(point, for: NSApp.currentEvent)
    }

    // Passing the event explicitly lets offscreen tests verify hit routing
    // without posting events to the application or controlling a window.
    func hitTest(_ point: NSPoint, for event: NSEvent?) -> NSView? {
        guard isEnabled, !isHiddenOrHasHiddenAncestor, let event,
              [.otherMouseDown, .otherMouseDragged, .otherMouseUp].contains(event.type),
              event.buttonNumber == 2,
              clickableRect.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func otherMouseDown(with event: NSEvent) {
        pressed = isEnabled && event.buttonNumber == 2 && clickableRect.contains(convert(event.locationInWindow, from: nil))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        let shouldClose = pressed && isEnabled && clickableRect.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if shouldClose { onClose?() }
    }
}

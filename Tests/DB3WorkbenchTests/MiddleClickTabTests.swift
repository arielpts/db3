import AppKit
import XCTest
@testable import DB3Workbench

@MainActor
final class MiddleClickTabTests: XCTestCase {
    func testOnlyMiddleButtonHitsVisibleTabAndPressReleaseClosesOnce() throws {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 80))
        let view = MiddleClickTabView(frame: NSRect(x: 100, y: 10, width: 190, height: 32))
        parent.addSubview(view)
        let point = NSPoint(x: 120, y: 20)
        let down = try mouse(.otherMouseDown, at: point)
        let up = try mouse(.otherMouseUp, at: point)
        XCTAssertEqual(down.buttonNumber, 2)
        XCTAssertTrue(view.hitTest(point, for: down) === view)
        XCTAssertNil(view.hitTest(NSPoint(x: 80, y: 20), for: down))
        XCTAssertNil(view.hitTest(point, for: try mouse(.leftMouseDown, at: point)))
        XCTAssertNil(view.hitTest(point, for: try mouse(.rightMouseDown, at: point)))
        XCTAssertNil(view.hitTest(point, for: nil))

        var closes = 0
        view.onClose = { closes += 1 }
        view.otherMouseUp(with: up)
        XCTAssertEqual(closes, 0)
        view.otherMouseDown(with: down)
        view.otherMouseUp(with: up)
        view.otherMouseUp(with: up)
        XCTAssertEqual(closes, 1)
    }

    func testReleaseOutsideAndDisableCancelPressWithoutClosingAnotherTab() throws {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 80))
        let first = MiddleClickTabView(frame: NSRect(x: 0, y: 0, width: 190, height: 32))
        let second = MiddleClickTabView(frame: NSRect(x: 200, y: 0, width: 190, height: 32))
        parent.addSubview(first); parent.addSubview(second)
        var closes = 0
        first.onClose = { closes += 1 }; second.onClose = { closes += 1 }
        let inside = NSPoint(x: 10, y: 10)
        let outside = NSPoint(x: 210, y: 10)
        first.otherMouseDown(with: try mouse(.otherMouseDown, at: inside))
        first.otherMouseUp(with: try mouse(.otherMouseUp, at: outside))
        second.otherMouseUp(with: try mouse(.otherMouseUp, at: outside))
        XCTAssertEqual(closes, 0)
        first.otherMouseDown(with: try mouse(.otherMouseDown, at: inside))
        first.isEnabled = false
        XCTAssertNil(first.hitTest(inside, for: try mouse(.otherMouseDown, at: inside)))
        first.isEnabled = true
        first.otherMouseUp(with: try mouse(.otherMouseUp, at: inside))
        XCTAssertEqual(closes, 0)
    }

    func testMiddleClickOnInactiveDirtyTabUsesCloseConfirmationAndPreservesSelection() async throws {
        let fixture = WorkbenchFixture()
        let model = fixture.model
        let dirty = model.active
        dirty.sql = "SELECT 'unsaved';"
        model.addWorksheet()
        let selected = model.active.id
        fixture.dialogs.closeDecisions = [.keepOpen, .discard]
        let view = MiddleClickTabView(frame: NSRect(x: 0, y: 0, width: 190, height: 32))
        view.onClose = { model.requestClose(dirty) }
        let point = NSPoint(x: 10, y: 10)
        for expectedPrompts in 1...2 {
            view.otherMouseDown(with: try mouse(.otherMouseDown, at: point))
            view.otherMouseUp(with: try mouse(.otherMouseUp, at: point))
            for _ in 0..<100 {
                if fixture.dialogs.snapshots.count == expectedPrompts && !model.isCoordinatingClose { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(fixture.dialogs.snapshots.count, expectedPrompts)
            XCTAssertEqual(model.selectedID, selected)
            if expectedPrompts == 1 {
                XCTAssertTrue(model.worksheets.contains { $0.id == dirty.id })
                XCTAssertEqual(dirty.sql, "SELECT 'unsaved';")
            }
        }
        XCTAssertFalse(model.worksheets.contains { $0.id == dirty.id })
        await model.shutdown()
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        // NSEvent's factory leaves buttonNumber at zero even for otherMouseDown.
        // Correct the backing event without posting it or creating a window.
        let backingEvent = try XCTUnwrap(event.cgEvent)
        let buttonNumber: Int64
        switch type {
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged: buttonNumber = 2
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: buttonNumber = 1
        default: buttonNumber = 0
        }
        backingEvent.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
        let mouseEvent = try XCTUnwrap(NSEvent(cgEvent: backingEvent))
        XCTAssertEqual(mouseEvent.type, type)
        XCTAssertEqual(mouseEvent.buttonNumber, Int(buttonNumber))
        XCTAssertEqual(mouseEvent.locationInWindow, point)
        return mouseEvent
    }
}

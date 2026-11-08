import XCTest
import AppKit
@testable import StylePolishApp

final class ClipboardSafetyTests: XCTestCase {
    @MainActor func testReadableWholeValueEditorsRemainAutomatic() {
        XCTAssertTrue(AccessibilityAccess.supportsAutomaticWrite(value: true, selectedText: false, range: true))
        XCTAssertTrue(AccessibilityAccess.supportsAutomaticWrite(value: false, selectedText: true, range: true))
        XCTAssertFalse(AccessibilityAccess.supportsAutomaticWrite(value: false, selectedText: false, range: true))
        XCTAssertFalse(AccessibilityAccess.supportsAutomaticWrite(value: false, selectedText: true, range: false))
    }
    @MainActor func testClipboardCanNeverSynthesizeReturnOrEnter() throws {
        XCTAssertEqual(ClipboardTransaction.allowedCommandKeys, [0, 8, 9])
        for key: CGKeyCode in [36, 76, 53, 49] {
            XCTAssertThrowsError(try ClipboardTransaction.command(key))
        }
    }
    @MainActor func testReturnIsConsumedWheneverPopupIsVisibleEvenWithoutKeyFocus() throws {
        guard ProcessInfo.processInfo.environment["STYLEPOLISH_UI_TESTS"] == "1" else { throw XCTSkip("Explicit UI opt-in required") }
        _ = NSApplication.shared
        let controller = AppController()
        controller.state.phase = .loading
        controller.panel.orderFrontRegardless()
        for phase in [PanelPhase.loading, .preview, .error, .notice] {
            controller.state.phase = phase
            for key: CGKeyCode in [36, 76] {
                XCTAssertTrue(controller.key(key, []))
                XCTAssertTrue(controller.key(key, .maskCommand))
            }
        }
        controller.panel.orderOut(nil)
        XCTAssertFalse(controller.key(36, []))
    }
    @MainActor func testPopupWindowConsumesReturnWithoutDispatchingToUnderlyingEditor() throws {
        guard ProcessInfo.processInfo.environment["STYLEPOLISH_UI_TESTS"] == "1" else { throw XCTSkip("Explicit UI opt-in required") }
        _ = NSApplication.shared
        let lower = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        editor.string = "must remain unchanged"; lower.contentView = editor; lower.makeFirstResponder(editor)
        let popup = PolishPanel(model: PanelModel())
        for code: UInt16 in [36, 76] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: popup.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
            popup.sendEvent(event)
        }
        XCTAssertEqual(editor.string, "must remain unchanged")
    }
    @MainActor func testPasteValidatesBeforeChangingClipboard() async throws {
        guard ProcessInfo.processInfo.environment["STYLEPOLISH_UI_TESTS"] == "1" else { throw XCTSkip("Explicit UI opt-in required; this test changes the clipboard") }
        let saved = ClipboardTransaction.snapshot()
        defer { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(saved) }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("clipboard sentinel", forType: .string)
        do { try await ClipboardTransaction.paste("replacement", selectAll: true, validate: { false }); XCTFail("must refuse stale focus") }
        catch { XCTAssertEqual(NSPasteboard.general.string(forType: .string), "clipboard sentinel") }
    }
}

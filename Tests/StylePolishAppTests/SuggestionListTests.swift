import XCTest
import AppKit
import StylePolishCore
@testable import StylePolishApp

final class SuggestionListTests: XCTestCase {
    @MainActor private func makeOverlay() throws -> InlineOverlay {
        guard ProcessInfo.processInfo.environment["STYLEPOLISH_UI_TESTS"] == "1" else {
            throw XCTSkip("Explicit UI opt-in required; this test displays panels")
        }
        _ = NSApplication.shared
        return InlineOverlay()
    }

    private func suggestion(whole: Bool = false) -> LocatedSuggestion {
        let source = "这个方案非长好。"
        let edit = Suggestion(
            range: NSRange(location: whole ? 0 : 5, length: whole ? source.utf16.count : 1),
            original: whole ? source : "长",
            replacement: whole ? "这个方案非常好。" : "常",
            kind: whole ? .fluency : .typo,
            why: "合成验收"
        )
        return LocatedSuggestion(edit: edit, sentence: source)
    }

    @MainActor func testIndicatorListSurvivesPointerTravelAndUnchangedRender() throws {
        let overlay = try makeOverlay()
        defer { overlay.hide() }
        let field = CGRect(x: 100, y: 300, width: 500, height: 200)
        let anchor = CGRect(x: field.maxX - 24, y: field.minY, width: 24, height: 24)
        let item = suggestion()
        // Inline marks suppress the old fallback badge. The status indicator remains.
        let mark = WaveMark(id: item.id, rect: CGRect(x: 150, y: 460, width: 14, height: 16), kind: .typo)
        overlay.show(items: [item], field: field, marks: [mark])
        overlay.showList(from: anchor)
        XCTAssertTrue(overlay.popupVisible)
        let popup = overlay.popupFrame
        overlay.trackHover(at: CGPoint(x: anchor.midX, y: anchor.midY))
        XCTAssertTrue(overlay.popupVisible, "Clicking the indicator must not immediately dismiss its list")
        overlay.show(items: [item], field: field, marks: [mark])
        XCTAssertTrue(overlay.popupVisible, "Polling the same input must preserve the open list")
        overlay.trackHover(at: CGPoint(x: (anchor.midX + popup.midX) / 2, y: (anchor.midY + popup.midY) / 2))
        XCTAssertTrue(overlay.popupVisible, "The mouse must be able to reach the list")
        overlay.trackHover(at: CGPoint(x: popup.midX, y: popup.midY))
        XCTAssertTrue(overlay.popupVisible)
        overlay.trackHover(at: CGPoint(x: -10_000, y: -10_000))
        XCTAssertFalse(overlay.popupVisible)
    }

    @MainActor func testWholeRewriteAppearsInListWithoutInlineMarksAndExpires() throws {
        let overlay = try makeOverlay()
        defer { overlay.hide() }
        let field = CGRect(x: 100, y: 300, width: 500, height: 200)
        let item = suggestion(whole: true)
        overlay.show(items: [], field: field, marks: [], listItems: [item])
        overlay.showList(from: field)
        XCTAssertTrue(overlay.popupVisible, "Whole rewrites still contribute to the indicator count")
        overlay.show(items: [], field: field, marks: [], listItems: [item])
        XCTAssertTrue(overlay.popupVisible)
        overlay.show(items: [], field: field, marks: [], listItems: [])
        XCTAssertFalse(overlay.popupVisible, "Expired suggestions must not remain actionable")
        overlay.showList(from: field)
        XCTAssertFalse(overlay.popupVisible)
    }

    @MainActor func testChangedInputAndHideInvalidateList() throws {
        let overlay = try makeOverlay()
        defer { overlay.hide() }
        let field = CGRect(x: 100, y: 300, width: 500, height: 200)
        overlay.show(items: [suggestion()], field: field, marks: nil)
        overlay.showList()
        XCTAssertTrue(overlay.popupVisible)
        overlay.show(items: [suggestion()], field: field, marks: nil)
        XCTAssertFalse(overlay.popupVisible, "New suggestion IDs invalidate the previous list")
        overlay.showList()
        XCTAssertTrue(overlay.popupVisible)
        overlay.hide()
        overlay.showList()
        XCTAssertFalse(overlay.popupVisible, "Switching away must clear list contents")
    }
    @MainActor func testMouseOpensListAndCanReachItsButtons() async throws {
        let overlay = try makeOverlay()
        let indicator = InputIndicator()
        let item = suggestion()
        let field = CGRect(x: 300, y: 300, width: 500, height: 160)
        let window = NSWindow(contentRect: field, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "StylePolish · 合成输入框验收"
        let editor = NSTextView(frame: CGRect(origin: .zero, size: field.size))
        editor.string = item.sentence
        editor.font = .systemFont(ofSize: 20)
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let originalPointer = NSEvent.mouseLocation
        func processMouseEvents() async throws {
            let deadline = Date().addingTimeInterval(0.3)
            while Date() < deadline {
                while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func move(_ point: CGPoint, click: Bool = false) {
            let point = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            if click {
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
        defer {
            overlay.hide()
            indicator.hide()
            window.orderOut(nil)
            move(originalPointer)
        }
        overlay.show(items: [item], field: field, marks: [])
        var accepted: UUID?
        var ignored: UUID?
        overlay.accept = { accepted = $0 }
        overlay.ignore = { ignored = $0 }
        var clicked = false
        indicator.click = {
            clicked = true
            overlay.showList(from: indicator.frame)
        }
        indicator.show(.suggestions(1), rawField: AccessibilityAccess.appKitRect(field))
        try await processMouseEvents()
        move(CGPoint(x: indicator.frame.midX, y: indicator.frame.midY), click: true)
        try await processMouseEvents()
        XCTAssertTrue(clicked, "The synthetic click must reach the indicator")
        XCTAssertTrue(overlay.popupVisible, "The real indicator click must leave its list open")
        guard overlay.popupVisible else { return }
        let popup = overlay.popupFrame
        move(CGPoint(x: (indicator.frame.midX + popup.midX) / 2, y: (indicator.frame.midY + popup.midY) / 2))
        try await processMouseEvents()
        XCTAssertTrue(overlay.popupVisible)
        move(CGPoint(x: popup.midX, y: popup.midY))
        try await processMouseEvents()
        XCTAssertTrue(overlay.popupVisible)
        if let path = ProcessInfo.processInfo.environment["STYLEPOLISH_LIST_SCREENSHOT"] {
            // Capture only our list window; never include other applications behind it.
            let panel = try XCTUnwrap(NSApp.windows.first { $0.frame == popup })
            let screenshot = Process()
            screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            screenshot.arguments = ["-x", "-o", "-l", String(panel.windowNumber), path]
            try screenshot.run()
            screenshot.waitUntilExit()
            XCTAssertEqual(screenshot.terminationStatus, 0)
        }
        // The synthetic one-row list uses the existing 280pt layout.
        move(CGPoint(x: popup.maxX - 98, y: popup.maxY - 50), click: true)
        try await processMouseEvents()
        XCTAssertEqual(accepted, item.id)
        move(CGPoint(x: popup.maxX - 40, y: popup.maxY - 50), click: true)
        try await processMouseEvents()
        XCTAssertEqual(ignored, item.id)

    }

}

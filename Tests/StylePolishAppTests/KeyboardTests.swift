import XCTest
import AppKit
import Carbon
import StylePolishCore
@testable import StylePolishApp

final class KeyboardTests: XCTestCase {
    @MainActor func testConsumedShortcutKeepsRepeatAndKeyUpTogether() {
        let keyboard = KeyboardController(frontmostBundleID: { SupportedApps.wechat })
        var actionable = true, calls = 0
        keyboard.handle = { _, _ in calls += 1; return actionable }
        XCTAssertTrue(keyboard.consumeKey(type: .keyDown, code: 36, flags: .maskAlternate))
        actionable = false
        XCTAssertTrue(keyboard.consumeKey(type: .keyDown, code: 36, flags: .maskAlternate))
        XCTAssertTrue(keyboard.consumeKey(type: .keyUp, code: 36, flags: .maskAlternate))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(keyboard.consumeKey(type: .keyDown, code: 36, flags: .maskAlternate))
        XCTAssertFalse(keyboard.consumeKey(type: .keyUp, code: 36, flags: .maskAlternate))
    }

    @MainActor func testStartingKeyboardDoesNotReserveOptionReturnGlobally() throws {
        guard ProcessInfo.processInfo.environment["STYLEPOLISH_UI_TESTS"] == "1" else { throw XCTSkip("Explicit UI opt-in required") }
        _ = NSApplication.shared
        var competing: EventHotKeyRef?
        func reserve() -> OSStatus {
            RegisterEventHotKey(36, UInt32(optionKey), EventHotKeyID(signature: 0x54455354, id: 1), GetApplicationEventTarget(), 0, &competing)
        }
        guard reserve() == noErr else { throw XCTSkip("Another running app already owns Option+Return; quit it before isolated acceptance") }
        UnregisterEventHotKey(competing); competing = nil
        defer { if let competing { UnregisterEventHotKey(competing) } }
        let keyboard = KeyboardController()
        keyboard.start()
        XCTAssertEqual(reserve(), noErr, "An idle StylePolish must leave the global shortcut available")
        withExtendedLifetime(keyboard) {}
    }

    @MainActor func testStalePreviewDoesNotConsumeAcceptanceShortcut() throws {
        guard ProcessInfo.processInfo.environment["STYLEPOLISH_UI_TESTS"] == "1" else { throw XCTSkip("Explicit UI opt-in required") }
        _ = NSApplication.shared
        let suite = "StylePolish-key-test-" + UUID().uuidString
        let defaults = MemoryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let automatic = AutomaticPolish(access: AccessibilityAccess(), settings: SettingsStore(defaults: defaults, credentialHome: home), history: HistoryStore(directory: home))
        defer { automatic.stop() }
        let source = "这个方案非长好。"
        let edit = Suggestion(range: NSRange(location: 0, length: source.utf16.count), original: source, replacement: "这个方案非常好。", kind: .fluency, why: "合成")
        automatic.overlay.showPreview(SuggestionPreview(source: source, edits: [edit]), field: CGRect(x: 300, y: 300, width: 500, height: 180))
        // A visible snapshot alone is not a valid capture/session.
        XCTAssertFalse(automatic.key(36, .maskAlternate))
        XCTAssertFalse(automatic.key(76, .maskAlternate))
        automatic.enabled = false
        XCTAssertFalse(automatic.key(36, .maskAlternate))
        XCTAssertFalse(automatic.key(36, [.maskAlternate, .maskCommand]))
    }
}

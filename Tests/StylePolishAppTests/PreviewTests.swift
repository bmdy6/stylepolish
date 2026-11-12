import XCTest
import AppKit
import StylePolishCore
@testable import StylePolishApp

final class PreviewTests: XCTestCase {
    func testAtomicRewriteAndPreviewPreserveUnicode() throws {
        let source = "🙂这次要确认的是这个书架如何固定。"
        let raw = #"{"edits":[{"original":"这次要确认的是这个书架如何固定","replacement":"这次要确认的是如何固定这个书架","kind":"fluency","why":"调顺语序"}]}"#
        let edits = SuggestionParser.parse(raw, source: source)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.kind, .fluency)
        XCTAssertEqual(SuggestionPreview(source: source, edits: edits)?.output, "🙂这次要确认的是如何固定这个书架。")
        XCTAssertNil(SuggestionPreview(source: source + "新输入", edits: [Suggestion(range: NSRange(location: 0, length: 1), original: "失效", replacement: "错", kind: .typo, why: "")]))
        XCTAssertNil(SuggestionPreview(source: source, edits: edits + edits))
        XCTAssertTrue(Strictness.standard.includes(.fluency))
        XCTAssertFalse(Strictness.relaxed.includes(.fluency))
        XCTAssertFalse(Strictness.standard.includes(.tone))
    }
    @MainActor func testPreviewNeverTakesFocusAndDismissesBeforeTyping() throws {
        guard ProcessInfo.processInfo.environment["STYLEPOLISH_UI_TESTS"] == "1" else { throw XCTSkip("Explicit UI opt-in required; this test displays panels") }
        let settings = SettingsStore(defaults: MemoryDefaults())
        let automatic = AutomaticPolish(access: AccessibilityAccess(), settings: settings, history: HistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let edit = Suggestion(range: NSRange(location: 0, length: 1), original: "错", replacement: "对", kind: .typo, why: "")
        let preview = SuggestionPreview(source: "错字", edits: [edit])!
        let keyWindow = NSApp.keyWindow
        let field = CGRect(x: 100, y: 300, width: 400, height: 100)
        automatic.overlay.showPreview(preview, field: field)
        XCTAssertTrue(automatic.overlay.previewVisible)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertFalse(automatic.key(0, [])) // A must reach the editor.
        XCTAssertFalse(automatic.overlay.previewVisible)
        automatic.overlay.showPreview(preview, field: field)
        XCTAssertTrue(automatic.key(53, []))
        XCTAssertFalse(automatic.overlay.previewVisible)
        let panel = InlinePanel(frame: field)
        XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
    }
    func testStrictPromptAllowsFormalExpression() throws {
        var config = PolishConfiguration(base: "https://example.com/v1", model: "synthetic", key: "synthetic", profile: "")
        func prompt() throws -> String {
            let request = try PolishClient().makeRequest("这个事儿咱们得赶紧弄完", config: config, structured: true)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            return (body["messages"] as! [[String: String]])[0]["content"]!
        }
        XCTAssertTrue(try prompt().contains("当前标准档：只返回 typo、filler、fluency"))
        config.level = .strict
        XCTAssertTrue(try prompt().contains("tone 可以适度调整原有口语表达"))
    }
    @MainActor func testConfiguredPauseActuallyDelaysCheck() async throws {
        let debouncer = SuggestionDebouncer(delay: 1)
        debouncer.setDelay(seconds: 0.5)
        var fired = false
        let completed = expectation(description: "configured pause elapsed")
        debouncer.schedule { fired = true; completed.fulfill() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(fired)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(fired)
    }
    @MainActor func testPausePersistsAndClamps() {
        let suite = UUID().uuidString
        let defaults = MemoryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.pauseSeconds, 1.5)
        settings.pauseSeconds = 0.2; XCTAssertEqual(settings.pauseSeconds, 0.5)
        settings.pauseSeconds = 4; XCTAssertEqual(settings.pauseSeconds, 3)
        settings.pauseSeconds = 2.1
        XCTAssertEqual(SettingsStore(defaults: defaults).pauseSeconds, 2.1)
        defaults.set(-1.0, forKey: "pauseSeconds")
        XCTAssertEqual(SettingsStore(defaults: defaults).pauseSeconds, 0.5)
    }
}

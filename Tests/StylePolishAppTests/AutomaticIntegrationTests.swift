import XCTest
import AppKit
import StylePolishCore
@testable import StylePolishApp

final class AutomaticIntegrationTests: XCTestCase {
    private let source = "这个方案非长好，我们明天在讨论。"
    @MainActor private func until(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        guard predicate() else {
            XCTFail("Synthetic editor condition timed out; front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")", file: file, line: line)
            throw PolishFailure(message: "Synthetic editor condition timed out")
        }
    }
    @MainActor private func run(mode: String, model: String = "local", body: (AutomaticPolish, AccessibilityAccess, CapturedInput, URL) async throws -> Void) async throws {
        guard ProcessInfo.processInfo.environment["STYLEPOLISH_ISOLATED_DESKTOP"] == "1",
              let path = ProcessInfo.processInfo.environment["STYLEPOLISH_EDITOR"],
              let base = ProcessInfo.processInfo.environment["STYLEPOLISH_TEST_BASE"] else { throw XCTSkip("Run scripts/tests/run-writeback-acceptance.sh for isolated real AX/paste acceptance") }
        _ = NSApplication.shared
        XCTAssertTrue(AccessibilityAccess.trusted())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StylePolish-integration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launch = NSWorkspace.OpenConfiguration()
        launch.createsNewApplicationInstance = true
        launch.arguments = [mode, root.appendingPathComponent("events").path]
        // Wait for the previous test process to exit before activating the next one.
        // Otherwise its late termination can reactivate the browser behind the fixture.
        try await until { NSRunningApplication.runningApplications(withBundleIdentifier: "org.bmdy6.StylePolish.SyntheticEditor").isEmpty }
        let fixture = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: launch)
        let defaults = UserDefaults(suiteName: root.lastPathComponent)!
        let settings = SettingsStore(defaults: defaults, credentialHome: root)
        settings.apps = ["org.bmdy6.StylePolish.SyntheticEditor"]; settings.pauseSeconds = 0.5
        let access = AccessibilityAccess()
        let automatic = AutomaticPolish(access: access, settings: settings, history: HistoryStore(directory: root))
        automatic.configurationProvider = { PolishConfiguration(base: base, model: model, key: "synthetic", profile: "") }
        defer {
            automatic.stop(); fixture.terminate()
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        fixture.activate(options: [])
        access.activateAccessibility(for: fixture)
        try await until { access.automaticCapture(enabled: settings.apps)?.input == self.source }
        if access.automaticCapture(enabled: settings.apps) == nil {
            let focus = access.focused()
            print("FIXTURE capture failed: front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none") expectedPID=\(fixture.processIdentifier) focusPID=\(focus?.0.processIdentifier ?? -1)")
        }
        let capture = try XCTUnwrap(access.automaticCapture(enabled: settings.apps))
        XCTAssertEqual(capture.pid, fixture.processIdentifier)
        automatic.start()
        try await until { automatic.session.suggestions.count == (model == "whole" ? 1 : 2) }
        try await body(automatic, access, capture, root)
    }
    @MainActor func testNativeAXSingleThenAllCommitsOnlyConfirmedHistory() async throws {
        try await checkSingleThenAll(mode: "native")
    }
    @MainActor func testRejectedAXSingleThenAllUsesRealClipboardAndRestoresIt() async throws {
        try await checkSingleThenAll(mode: "reject-ax")
    }
    @MainActor private func checkSingleThenAll(mode: String) async throws {
        try await run(mode: mode) { automatic, access, capture, root in
            let saved = ClipboardTransaction.snapshot()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("synthetic clipboard sentinel", forType: .string)
            defer { ClipboardTransaction.restore(saved, ifOwned: NSPasteboard.general.changeCount) }
            let first = try XCTUnwrap(automatic.session.suggestions.first)
            let accepted = await automatic.accept(first.id, reschedule: false)
            XCTAssertTrue(accepted)
            XCTAssertTrue(access.isCurrent(capture, text: "这个方案非常好，我们明天在讨论。"))
            XCTAssertEqual(automatic.session.suggestions.count, 1)
            let acceptedAll = await automatic.acceptAll()
            XCTAssertTrue(acceptedAll)
            XCTAssertTrue(access.isCurrent(capture, text: "这个方案非常好，我们明天再讨论。"))
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "synthetic clipboard sentinel")
            let history = try String(contentsOf: root.appendingPathComponent("history.jsonl"))
            XCTAssertEqual(history.components(separatedBy: "\"action\":\"accept\"").count - 1, 2)
        }
    }
    @MainActor func testIgnoredPasteDoesNotRecordAcceptanceAndCanRetrySameSuggestion() async throws {
        try await run(mode: "ignore-paste") { automatic, access, capture, root in
            let first = try XCTUnwrap(automatic.session.suggestions.first)
            let accepted = await automatic.accept(first.id, reschedule: false)
            XCTAssertFalse(accepted)
            XCTAssertTrue(access.isCurrent(capture, text: self.source))
            XCTAssertEqual(automatic.session.suggestions.count, 2)
            let all = await automatic.acceptAll()
            XCTAssertFalse(all)
            XCTAssertTrue(access.isCurrent(capture, text: self.source))
            let history = (try? String(contentsOf: root.appendingPathComponent("history.jsonl"))) ?? ""
            XCTAssertFalse(history.contains("\"action\":\"accept\""))
            automatic.sample(force: true)
            try await self.until { automatic.session.suggestions.count == 2 && automatic.canAcceptAll }
        }
    }
    @MainActor func testEscReopenThenRealOptionReturnAcceptsOnce() async throws {
        try await run(mode: "reject-ax", model: "whole") { automatic, access, capture, root in
            let keyboard = KeyboardController()
            keyboard.handle = { automatic.key($0, $1) }
            keyboard.start()
            defer { withExtendedLifetime(keyboard) {} }
            XCTAssertTrue(keyboard.interceptionAvailable)
            XCTAssertTrue(automatic.overlay.previewVisible)
            XCTAssertTrue(automatic.key(53, []))
            XCTAssertFalse(automatic.canAcceptAll)
            automatic.indicator.click?()
            XCTAssertTrue(automatic.canAcceptAll)
            for down in [true, true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)!
                event.flags = .maskAlternate; event.post(tap: .cghidEventTap)
            }
            try await self.until { access.isCurrent(capture, text: "这个方案很好，明天我们再一起讨论。") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events").path), "Consumed acceptance must not reach the editor")
            try await self.until { automatic.session.suggestions.isEmpty }
            // No suggestion: the same real key event reaches the underlying editor.
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)!
                event.flags = .maskAlternate; event.post(tap: .cghidEventTap)
            }
            try await self.until { FileManager.default.fileExists(atPath: root.appendingPathComponent("events").path) }
            let history = try String(contentsOf: root.appendingPathComponent("history.jsonl"))
            XCTAssertEqual(history.components(separatedBy: "\"action\":\"accept\"").count - 1, 1)
        }
    }
}

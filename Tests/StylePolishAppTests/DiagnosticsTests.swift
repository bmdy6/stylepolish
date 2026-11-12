import XCTest
import StylePolishCore
@testable import StylePolishApp

final class DiagnosticsTests: XCTestCase {
    func testResultPreviewFieldsAreContentFreeForAllKinds() throws {
        let source = "敏感正文非长好"
        let local = Suggestion(range: NSRange(location: 5, length: 1), original: "长", replacement: "常", kind: .typo, why: "")
        let whole = Suggestion(range: NSRange(location: 0, length: source.utf16.count), original: source, replacement: "另一个表达", kind: .fluency, why: "")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Diagnostics(directory: directory)
        for suggestions in [[], [local], [whole]] {
            log.record(DiagnosticEvent(event: "result", bundleID: "synthetic", traceID: "test-trace")
                .includingPreview(source: source, suggestions: suggestions))
        }
        log.flush()
        let jsonl = try String(contentsOf: log.url)
        XCTAssertFalse(jsonl.contains(source))
        XCTAssertFalse(jsonl.contains(whole.replacement))
        let events = try jsonl.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(events.map { $0["suggestionCount"] as? Int }, [0, 1, 1])
        XCTAssertEqual(events.map { $0["previewKind"] as? String }, ["none", "inline", "whole"])
        XCTAssertEqual(events.map { $0["previewMode"] as? String }, ["diff", "diff", "twoLine"])
        XCTAssertEqual(events.map { $0["insertedChars"] as? Int }, [0, 1, whole.replacement.count])
        XCTAssertEqual(events.map { $0["deletedChars"] as? Int }, [0, 1, source.count])
        for event in events {
            XCTAssertNil(event["source"]); XCTAssertNil(event["output"]); XCTAssertNil(event["text"])
            XCTAssertEqual(event["traceID"] as? String, "test-trace")
        }
    }
    func testJSONLinesAndRestrictedPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Diagnostics(directory: directory)
        log.record(DiagnosticEvent(event: "capture", bundleID: "com.linear", role: "AXTextArea", textLength: 12, readable: true, hasPosition: false))
        log.record(DiagnosticEvent(event: "ax_activation", bundleID: "com.linear", axAttribute: "AXManualAccessibility", axResult: -25205, error: "ax_set_failed"))
        log.flush()
        let lines = try String(contentsOf: log.url).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(first["textLength"] as? Int, 12)
        XCTAssertNil(first["text"]); XCTAssertNil(first["key"])
        let mode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue, 0o600)
    }
    @MainActor func testPointerPlacement() {
        let screen = CGRect(x: -1200, y: -800, width: 1200, height: 800)
        let point = CGPoint(x: -600, y: -400)
        let placement = OverlayPlacement.resolve(rawField: nil, screens: [screen], preferredPoint: point)!
        XCTAssertLessThan(abs(placement.field.midX - point.x), 50)
        XCTAssertLessThan(abs(placement.field.midY - point.y), 50)
        XCTAssertTrue(screen.contains(placement.field))
        let edge = OverlayPlacement.resolve(rawField: nil, screens: [screen], preferredPoint: CGPoint(x: -1, y: -799))!
        XCTAssertTrue(screen.contains(edge.field))
    }
    @MainActor func testFallbackIsPerAppAndIndicatorsExplainStates() {
        let access = AccessibilityAccess()
        access.useClipboard(for: "com.tencent.xinWeChat")
        XCTAssertTrue(access.fallbackApps.contains("com.tencent.xinWeChat"))
        XCTAssertFalse(access.fallbackApps.contains("com.linear"))
        XCTAssertEqual(InputIndicatorState.suggestions(3).help, "有 3 条建议，点击打开列表")
        XCTAssertEqual(InputIndicatorState.warning("reason").help, "reason")
    }
}

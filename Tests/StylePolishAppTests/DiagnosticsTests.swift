import XCTest
@testable import StylePolishApp

final class DiagnosticsTests: XCTestCase {
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
    @MainActor func testActivationPolicyAndPointerPlacement() {
        XCTAssertEqual(AccessibilityAccess.activationAttribute(bundleID: "com.linear"), "AXManualAccessibility")
        XCTAssertEqual(AccessibilityAccess.activationAttribute(bundleID: "com.electron.lark"), "AXManualAccessibility")
        XCTAssertEqual(AccessibilityAccess.activationAttribute(bundleID: "com.anthropic.claudefordesktop"), "AXManualAccessibility")
        XCTAssertEqual(AccessibilityAccess.activationAttribute(bundleID: "com.google.Chrome"), "AXEnhancedUserInterface")
        XCTAssertNil(AccessibilityAccess.activationAttribute(bundleID: "com.apple.Notes"))
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

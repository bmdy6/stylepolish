import XCTest
@testable import StylePolishApp
final class IndicatorTests: XCTestCase {
    @MainActor func testValidatedSuggestionsAppearImmediatelyAndCancelPendingChecking() async throws {
        guard ProcessInfo.processInfo.environment["STYLEPOLISH_UI_TESTS"] == "1" else { throw XCTSkip("Explicit UI opt-in required; indicator panels are displayed") }
        let indicator = InputIndicator()
        let bounds = CGRect(x: 100, y: 100, width: 400, height: 200)
        indicator.show(.checking, rawField: bounds)
        indicator.show(.suggestions(1), rawField: bounds)
        XCTAssertEqual(indicator.state, .suggestions(1))
        indicator.show(.suggestions(2), rawField: bounds)
        XCTAssertEqual(indicator.state, .suggestions(2))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(indicator.state, .suggestions(2))
        indicator.hide()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(indicator.state)
    }
    func testOnlyContinuousUnreadableFieldWarnsAfterTwoSeconds() {
        var gate = InputReadGate()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(gate.warning(enabled: true, ordinary: true, readable: false, now: start))
        XCTAssertFalse(gate.warning(enabled: true, ordinary: true, readable: false, now: start.addingTimeInterval(2)))
        XCTAssertTrue(gate.warning(enabled: true, ordinary: true, readable: false, now: start.addingTimeInterval(2.01)))
        XCTAssertFalse(gate.warning(enabled: true, ordinary: false, readable: false, now: start.addingTimeInterval(3)))
        XCTAssertFalse(gate.warning(enabled: true, ordinary: true, readable: false, now: start.addingTimeInterval(4)))
        XCTAssertFalse(gate.warning(enabled: true, ordinary: true, readable: true, now: start.addingTimeInterval(7)))
        XCTAssertFalse(gate.warning(enabled: false, ordinary: true, readable: false, now: start.addingTimeInterval(10)))
    }
    @MainActor func testDebounceCancelsTransientFocusAndFailureTransitions() async throws {
        guard ProcessInfo.processInfo.environment["STYLEPOLISH_UI_TESTS"] == "1" else { throw XCTSkip("Explicit UI opt-in required; indicator panels are displayed") }
        let indicator = InputIndicator()
        let bounds = CGRect(x: 100, y: 100, width: 400, height: 200)
        indicator.show(.watching, rawField: bounds)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(indicator.state, .watching)
        indicator.hide()
        try await Task.sleep(nanoseconds: 80_000_000)
        indicator.show(.watching, rawField: bounds)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(indicator.state, .watching)
        indicator.show(.modelFailure("参数不支持"), rawField: bounds)
        XCTAssertEqual(indicator.state, .watching)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(indicator.state?.help, "模型请求失败：参数不支持")
        indicator.hide()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(indicator.state)
    }
}

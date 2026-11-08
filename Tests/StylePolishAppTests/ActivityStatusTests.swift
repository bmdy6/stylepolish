import XCTest
@testable import StylePolishApp

final class ActivityStatusTests: XCTestCase {
    @MainActor func testMissingFieldBoundsStillPlacesBadgeOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let placement = OverlayPlacement.resolve(rawField: nil, screens: [screen], preferredPoint: CGPoint(x: 600, y: 400))
        XCTAssertNotNil(placement)
        XCTAssertFalse(placement!.canUnderline)
        XCTAssertTrue(screen.contains(placement!.field))
        XCTAssertNil(OverlayPlacement.resolve(rawField: nil, screens: [], preferredPoint: .zero))
    }
    @MainActor func testMissingBoundsUsesScreenWherePointerIs() {
        let left = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let right = CGRect(x: 1200, y: 0, width: 1200, height: 800)
        let placement = OverlayPlacement.resolve(rawField: nil, screens: [left, right], preferredPoint: CGPoint(x: 1600, y: 400))
        XCTAssertTrue(right.contains(placement!.field))
    }
    func testStatesHaveDistinctAccessibleTextAndSymbols() {
        let states: [ActivityStatus] = [.disabled, .idle, .checking, .suggestions(3), .failure("Key 无效")]
        XCTAssertEqual(Set(states.map(\.symbol)).count, states.count)
        XCTAssertEqual(states[3].title, "有 3 条建议")
        XCTAssertEqual(states[4].title, "失败：Key 无效")
    }
}

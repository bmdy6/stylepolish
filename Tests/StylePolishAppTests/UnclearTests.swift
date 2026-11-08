import XCTest
import StylePolishCore
@testable import StylePolishApp

final class UnclearTests: XCTestCase {
    func testUnclearResponseAndLegacyCompatibility() throws {
        let source = "13萨地方发生地方"
        let unclear = try WholePolishResult(raw: #"{"text":"13萨地方发生地方","edits":[],"unclear":true}"#, source: source)
        XCTAssertTrue(unclear.unclear)
        XCTAssertEqual(unclear.text, source)
        XCTAssertTrue(unclear.suggestions.isEmpty)
        for suffix in ["", ",\"unclear\":false"] {
            let legacy = try WholePolishResult(raw: "{\"text\":\"明天见\",\"edits\":[]" + suffix + "}", source: "明天见")
            XCTAssertFalse(legacy.unclear)
            XCTAssertTrue(legacy.suggestions.isEmpty)
        }
    }

    func testUnclearDoesNotDiscardIndependentSuggestions() throws {
        let source = "我以经到了。13萨地方发生地方"
        let result = try WholePolishResult(raw: #"{"text":"我已经到了。13萨地方发生地方","edits":[{"original":"以经","replacement":"已经"}],"unclear":true}"#, source: source)
        XCTAssertTrue(result.unclear)
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(InputIndicatorState.completed(count: 1, unclear: result.unclear), .suggestions(1))
        XCTAssertEqual(ActivityStatus.completed(count: 1, unclear: result.unclear), .suggestions(1))
    }

    func testLegacyResponseStillProducesCorrections() throws {
        let result = try WholePolishResult(raw: #"{"text":"我已经到了","edits":[{"original":"以经","replacement":"已经"}]}"#, source: "我以经到了")
        XCTAssertFalse(result.unclear)
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(InputIndicatorState.completed(count: result.suggestions.count, unclear: result.unclear), .suggestions(1))
    }

    func testCompletedStateMapping() {
        XCTAssertEqual(InputIndicatorState.completed(count: 0, unclear: true), .unclear)
        XCTAssertEqual(ActivityStatus.completed(count: 0, unclear: true), .unclear)
        XCTAssertEqual(InputIndicatorState.completed(count: 0, unclear: false), .clean)
        XCTAssertEqual(ActivityStatus.completed(count: 0, unclear: false), .idle)
        XCTAssertEqual(InputIndicatorState.unclear.help, "这句读不通，检查一下？")
        XCTAssertEqual(ActivityStatus.unclear.title, "读不通")
        XCTAssertEqual(ActivityStatus.unclear.help, "这句读不通，检查一下？")
        XCTAssertEqual(ActivityStatus.unclear.symbol, "questionmark.circle")
    }

    func testCachedUnclearIsRetainedAndSettledTextIsClean() {
        var cache = SentenceCache()
        cache.store([], for: "乱码", unclear: true)
        XCTAssertEqual(cache.result(for: "乱码")?.unclear, true)
        XCTAssertEqual(cache.edits(for: "乱码")?.count, 0)
        XCTAssertNil(cache.result(for: "新输入"))
        cache.store([], for: "旧接口")
        XCTAssertEqual(cache.result(for: "旧接口")?.unclear, false)
        cache.settle("乱码")
        XCTAssertEqual(cache.result(for: "乱码")?.unclear, false)
    }
}

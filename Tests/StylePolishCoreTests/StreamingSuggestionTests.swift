import XCTest
@testable import StylePolishCore
final class StreamingSuggestionTests: XCTestCase {
    func testCompleteEditBeforeEnvelopeEnds() {
        let partial = #"{"edits":[{"original":"非长","replacement":"非常","kind":"typo","why":"错字"},"#
        let edits = SuggestionParser.partial(partial, source: "非长好。")
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.original, "长")
        XCTAssertEqual(edits.first?.kind, .typo)
        XCTAssertEqual(SuggestionParser.partial(String(partial.dropLast(2)), source: "非长好。").count, 0)
    }
    func testQuotesBracesUnicodeAndUnsafeRanges() {
        let raw = #"{"edits":[{"original":"a\"}😀","replacement":"b","kind":"typo","why":"引号\"{"}]}"#
        let edits = SuggestionParser.partial(raw, source: "a\"}😀")
        XCTAssertEqual(edits.count, 1)
        XCTAssertTrue(edits[0].matches("a\"}😀"))
        let ambiguous = #"{"edits":[{"original":"好","replacement":"行","kind":"tone","why":""}]}"#
        XCTAssertTrue(SuggestionParser.parse(ambiguous, source: "好好。").isEmpty)
        XCTAssertTrue(SuggestionParser.parse(ambiguous, source: "没有该片段").isEmpty)
    }
    func testAtMostThreeAndNoOverlappingEdits() {
        let edits = ["甲", "乙", "丙", "丁"].map { ["original": $0, "replacement": "X", "kind": "typo", "why": ""] }
        let raw = String(data: try! JSONSerialization.data(withJSONObject: ["edits": edits]), encoding: .utf8)!
        XCTAssertEqual(SuggestionParser.parse(raw, source: "甲乙丙丁").count, 3)
        let overlap = #"{"edits":[{"original":"甲乙","replacement":"X","kind":"typo","why":""},{"original":"乙","replacement":"Y","kind":"typo","why":""}]}"#
        XCTAssertEqual(SuggestionParser.parse(overlap, source: "甲乙丙").count, 1)
    }
}

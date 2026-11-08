import XCTest
import StylePolishCore
@testable import StylePolishApp

final class PlainTextPolishTests: XCTestCase {
    func testPureFormattingDoesNotSuggest() throws {
        let source = "用ruby读yaml，稍后见🙂"
        let result = try PlainTextCandidateResult(output: "用Ruby读YAML。稍后见🙂！", source: source)
        XCTAssertEqual(result.text, source)
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertFalse(result.isRewrite)
    }
    func testThreeShortCorrectionsAreLocalWithoutMetadata() throws {
        let source = "这以经发货了，快递放门扣，我稍候去拿"
        let result = try PlainTextCandidateResult(output: "这已经发货了，快递放门口，我稍后去拿", source: source)
        XCTAssertFalse(result.isRewrite)
        XCTAssertEqual(result.suggestions.count, 3)
        XCTAssertEqual(SuggestionPreview(source: source, edits: result.suggestions)?.output, result.text)
        XCTAssertNil(SuggestionPreview.wholeRewrite(source: source, edits: result.suggestions))
    }
    func testFourthCorrectionOrLongChangeUsesWholePreview() throws {
        for (source, output) in [("以经，门扣，稍候，非长", "已经，门口，稍后，非常"), ("那片完全不同的风景", "一座静静矗立的城堡")] {
            let result = try PlainTextCandidateResult(output: output, source: source)
            XCTAssertTrue(result.isRewrite)
            XCTAssertEqual(result.suggestions.count, 1)
            XCTAssertEqual(SuggestionPreview.wholeRewrite(source: source, edits: result.suggestions)?.output, output)
        }
    }
    func testMovedPhraseCannotBeAcceptedInTwoHalves() throws {
        let source = "先收书再擦桌子"
        let result = try PlainTextCandidateResult(output: "先擦桌子再收书", source: source)
        XCTAssertTrue(result.isRewrite)
        XCTAssertEqual(result.suggestions.first?.original, source)
    }
    func testRepeatedEnglishCorrectionsAndInsertionKeepUTF16Ranges() throws {
        let source = "🙂用gti，再看GTI，最后运行gti"
        let result = try PlainTextCandidateResult(output: "🙂用git，再看git，最后运行Git", source: source)
        XCTAssertFalse(result.isRewrite)
        XCTAssertEqual(result.suggestions.count, 3)
        XCTAssertTrue(result.suggestions.allSatisfy { $0.matches(source) })
        XCTAssertEqual(PolishTextComparison.key(result.text), PolishTextComparison.key("🙂用git，再看git，最后运行Git"))
        let insert = try PlainTextCandidateResult(output: "🙂先想清楚", source: "🙂先清楚")
        XCTAssertFalse(insert.isRewrite)
        XCTAssertEqual(insert.suggestions.first?.range, NSRange(location: 3, length: 0))
    }
    func testOnlyCompletedPlainTextDrivesSuggestions() throws {
        XCTAssertThrowsError(try PlainTextCandidateResult(output: "  ", source: "还有文字"))
        XCTAssertThrowsError(try PlainTextCandidateResult(output: String(repeating: "字", count: 40_000), source: "还有文字"))
        let result = try PlainTextCandidateResult(output: "明天见。", source: "明天见")
        XCTAssertTrue(result.suggestions.isEmpty)
    }
}

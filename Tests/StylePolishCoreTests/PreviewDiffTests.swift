import XCTest
@testable import StylePolishCore

final class PreviewDiffTests: XCTestCase {
    private func preview(_ source: String, _ output: String) throws -> SuggestionPreview {
        try XCTUnwrap(SuggestionPreview(source: source, edits: [Suggestion(
            range: NSRange(location: 0, length: source.utf16.count),
            original: source, replacement: output, kind: .fluency, why: ""
        )]))
    }

    func testDeletionRemainsInDisplayedSegments() throws {
        let snapshot = try preview("然后然后我觉得", "我觉得")
        XCTAssertEqual(snapshot.segments.map(\.text).joined(), "然后然后我觉得")
        XCTAssertEqual(snapshot.segments.map(\.kind), [.deleted, .unchanged])
        XCTAssertEqual(snapshot.deletedChars, 4)
        XCTAssertEqual(snapshot.insertedChars, 0)
        XCTAssertEqual(snapshot.mode, .diff)
    }

    func testInsertionAndReplacement() throws {
        let added = try preview("明天讨论", "明天再讨论")
        XCTAssertEqual(added.segments.map(\.text), ["明天", "再", "讨论"])
        XCTAssertEqual(added.segments.map(\.kind), [.unchanged, .inserted, .unchanged])
        XCTAssertEqual(added.insertedChars, 1)
        XCTAssertEqual(added.deletedChars, 0)
        let replaced = try preview("这个方案非长好", "这个方案非常好")
        XCTAssertEqual(replaced.segments.map(\.text), ["这个方案非", "长", "常", "好"])
        XCTAssertEqual(replaced.segments.map(\.kind), [.unchanged, .deleted, .inserted, .unchanged])
        XCTAssertEqual(replaced.deletedChars, 1)
        XCTAssertEqual(replaced.insertedChars, 1)
    }

    func testTwoLineThresholdIsStrictlyGreaterThanSixtyPercent() throws {
        XCTAssertEqual(SuggestionPreview.twoLineThreshold, 0.6)
        let boundary = try preview("甲乙丙丁戊己庚辛壬癸", "丁戊己庚辛壬癸XYZ")
        XCTAssertEqual(boundary.insertedChars + boundary.deletedChars, 6)
        XCTAssertEqual(boundary.mode, .diff)
        let above = try preview("甲乙丙丁戊己庚辛壬癸", "戊己庚辛壬癸XYZ")
        XCTAssertEqual(above.insertedChars + above.deletedChars, 7)
        XCTAssertEqual(above.mode, .twoLine)
        XCTAssertEqual(above.displayText, "原 甲乙丙丁戊己庚辛壬癸\n改 戊己庚辛壬癸XYZ")
    }

    func testUnicodeCountsGraphemesAndKeepsOutputFormatting() throws {
        let snapshot = try preview("İ👨‍👩‍👧‍👦旧盒子收好", "İ👨‍👩‍👧‍👦新盒子收好！")
        XCTAssertEqual(snapshot.segments.filter { $0.kind == .deleted }.map(\.text), ["旧"])
        XCTAssertEqual(snapshot.insertedChars, 1)
        XCTAssertEqual(snapshot.deletedChars, 1)
        XCTAssertEqual(snapshot.segments.filter { $0.kind != .deleted }.map(\.text).joined(), snapshot.output)
        let emoji = try preview("🙂🙃留下文字", "🙂留下文字")
        XCTAssertEqual(emoji.deletedChars, 1)
        XCTAssertEqual(emoji.displayText, "🙂🙃留下文字")
        let folded = try preview("Straße旧", "STRASSE新")
        XCTAssertEqual(folded.segments.filter { $0.kind == .deleted }.map(\.text), ["旧"])
        XCTAssertEqual(folded.segments.filter { $0.kind != .deleted }.map(\.text).joined(), folded.output)
    }

    func testEmptySidesAndFormattingOnlyChanges() throws {
        let removed = try preview("要删掉", "")
        XCTAssertEqual(removed.segments.map(\.kind), [.deleted])
        XCTAssertEqual(removed.deletedChars, 3)
        XCTAssertEqual(removed.mode, .twoLine)
        let added = try preview("", "新增")
        XCTAssertEqual(added.insertedChars, 2)
        XCTAssertEqual(added.mode, .twoLine)
        let formatting = try preview("Ruby，明天见", "ruby。明天见！")
        XCTAssertEqual(formatting.insertedChars + formatting.deletedChars, 0)
        XCTAssertEqual(formatting.displayText, formatting.output)
    }

    func testFoldedUnicodeRangesNeverOverlapOrLoseOutput() throws {
        let samples = ["", "ß", "ss", "sXs", "ßXß", "sXsXs", "ﬃ", "fXfYi", "İ🙂旧", "i̇🙂新！", "旧，盒子", "盒子。新"]
        for source in samples {
            for output in samples {
                var end = 0
                for change in PolishTextComparison.changes(source: source, output: output) {
                    // Range safety matters because these UTF-16 ranges feed NSString.
                    guard change.after.location >= end else {
                        XCTFail("Overlapping output ranges: \(source) → \(output)")
                        return
                    }
                    end = NSMaxRange(change.after)
                }
                let snapshot = try preview(source, output)
                XCTAssertEqual(snapshot.segments.filter { $0.kind != .deleted }.map(\.text).joined(), output)
            }
        }
    }
}

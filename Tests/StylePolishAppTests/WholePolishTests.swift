import XCTest
import StylePolishCore
@testable import StylePolishApp

final class WholePolishTests: XCTestCase {
    private func response(_ output: String, edits: [[String: String]] = []) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["text": output, "edits": edits]), as: UTF8.self)
    }
    func testRewriteKeepsTypedSpacingAroundEnglish() throws {
        let source = "之需要花一些token，但是token，如果充值pro，有免费的api"
        let result = try WholePolishResult(raw: response("只需要花一些 token，但是如果充值 pro，就有免费的 api"), source: source)
        XCTAssertTrue(result.isRewrite)
        XCTAssertEqual(result.text, "只需要花一些token，但是如果充值pro，就有免费的api")
    }
    func testRewriteLeavesSpacingWhenSourceAlreadySpacesEnglish() throws {
        let source = "那个就是 X 上的Grok它分析的时间要50秒钟"
        let result = try WholePolishResult(raw: response("X 上的 Grok 分析需要50秒钟"), source: source)
        XCTAssertEqual(result.text, "X 上的 Grok 分析需要50秒钟")
    }
    func testCaseAndPunctuationAloneNeverSuggestOrRewrite() throws {
        let source = "用ruby读yaml，稍后见🙂"
        let result = try WholePolishResult(raw: response("用Ruby读YAML。稍后见🙂！", edits: [
            ["original": "ruby", "replacement": "Ruby", "kind": "typo", "why": "大小写"]
        ]), source: source)
        XCTAssertEqual(result.text, source)
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertFalse(result.isRewrite)
    }
    func testSeveralExplainedCorrectionsIgnoreUnrelatedFormatting() throws {
        let source = "用rubby读yml，再运行gitt，名字写成nummpy"
        let edits = [("rubby", "Ruby"), ("gitt", "git"), ("nummpy", "numpy")].map {
            ["original": $0.0, "replacement": $0.1, "kind": "typo", "why": "拼写"]
        }
        let result = try WholePolishResult(raw: response("用Ruby读YML。再运行git，名字写成NumPy", edits: edits), source: source)
        XCTAssertFalse(result.isRewrite)
        XCTAssertEqual(result.suggestions.count, 3)
        XCTAssertEqual(result.text, "用Ruby读yml，再运行git，名字写成numpy")
        XCTAssertEqual(SuggestionPreview(source: source, edits: result.suggestions)?.output, result.text)
    }
    func testUnexplainedMeaningfulChangeStaysAtomic() throws {
        let source = "先查目录，再用gitt"
        let result = try WholePolishResult(raw: response("先用git，再查目录", edits: [
            ["original": "gitt", "replacement": "git", "kind": "typo", "why": "拼写"]
        ]), source: source)
        XCTAssertTrue(result.isRewrite)
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions[0].original, source)
    }
    func testMissingOrConflictingLocalMetadataCannotExplainRewrite() throws {
        let source = "红色盒子"
        let missing = try WholePolishResult(raw: response("蓝色盒子"), source: source)
        XCTAssertTrue(missing.isRewrite)
        let conflicting = try WholePolishResult(raw: response("蓝色盒子", edits: [
            ["original": "红色", "replacement": "蓝色", "kind": "typo"],
            ["original": "红色", "replacement": "绿色", "kind": "typo"]
        ]), source: source)
        XCTAssertTrue(conflicting.isRewrite)
    }
    func testPreviewColorsOnlyMeaningfulInsertedCharacters() throws {
        let source = "先用ruby，把旧盒子收好"
        let output = "先用Ruby。把新盒子收好！"
        let edit = Suggestion(range: NSRange(location: 0, length: source.utf16.count), original: source, replacement: output, kind: .fluency, why: "")
        let preview = try XCTUnwrap(SuggestionPreview.wholeRewrite(source: source, edits: [edit]))
        XCTAssertEqual(preview.segments.filter { $0.kind == .inserted }.map(\.text).joined(), "新")
        XCTAssertEqual(preview.segments.filter { $0.kind == .deleted }.map(\.text).joined(), "旧")
        XCTAssertEqual(preview.segments.filter { $0.kind != .deleted }.map(\.text).joined(), output)
    }
    func testCaseInsensitiveEditLocationPreservesUTF16Snapshot() throws {
        let source = "🙂用GITT，再看gitt"
        let result = try WholePolishResult(raw: response("🙂用Git，再看git", edits: [
            ["original": "gitt", "replacement": "git"]
        ]), source: source)
        XCTAssertFalse(result.isRewrite)
        XCTAssertEqual(result.suggestions.map(\.original), ["GITT", "gitt"])
        XCTAssertEqual(result.suggestions.first?.range, NSRange(location: 3, length: 4))
        XCTAssertTrue(result.suggestions.allSatisfy { $0.matches(source) })
    }
    func testUnicodeCaseFoldingDoesNotShiftHighlightRanges() {
        let source = "İ🙂旧"
        let output = "İ🙂新！"
        XCTAssertEqual(PolishTextComparison.insertedRanges(source: source, output: output), [NSRange(location: 3, length: 1)])
        XCTAssertEqual(PolishTextComparison.key("Ä,🙂"), PolishTextComparison.key("ä！🙂"))
        XCTAssertNotEqual(PolishTextComparison.key("🙂"), PolishTextComparison.key("🙃"))
        XCTAssertEqual(PolishTextComparison.insertedRanges(source: "Straße旧", output: "STRASSE新"), [NSRange(location: 7, length: 1)])
    }
    func testEquivalentRepeatedMetadataDoesNotForceRewrite() throws {
        let source = "用gitt"
        let result = try WholePolishResult(raw: response("用Git", edits: [
            ["original": "gitt", "replacement": "git"],
            ["original": "GITT", "replacement": "Git"]
        ]), source: source)
        XCTAssertFalse(result.isRewrite)
        XCTAssertEqual(result.suggestions.count, 1)
    }
    func testWholeResponseKeepsLocalCorrectionsLocal() throws {
        let source = "用gitt拉取仓库，再检查分支列表"
        let raw = #"{"text":"用git拉取仓库，再检查分支列表","edits":[{"original":"gitt","replacement":"git","kind":"typo","why":"名称"}]}"#
        let result = try WholePolishResult(raw: raw, source: source)
        XCTAssertFalse(result.isRewrite)
        XCTAssertFalse(result.suggestions.isEmpty)
        XCTAssertEqual(SuggestionPreview(source: source, edits: result.suggestions)?.output, result.text)
    }
    func testRepeatedWrongTermAndMissingCharacterUseMinimalDiff() throws {
        let source = "先运行gitt，再检查gitt的输出"
        let raw = #"{"text":"先运行git，再检查git的输出","edits":[{"original":"gitt","replacement":"git"}]}"#
        let result = try WholePolishResult(raw: raw, source: source)
        XCTAssertFalse(result.isRewrite)
        XCTAssertEqual(result.suggestions.count, 2)
        XCTAssertEqual(SuggestionPreview(source: source, edits: result.suggestions)?.output, result.text)
    }
    func testRewriteIsOneAtomicSuggestion() throws {
        let source = "那个相册我想先把重复照片挑出来，然后再按年份排一下，就是先别着急打印，主要还是把重复的找出来，不然印出来又得扔"
        let raw = #"{"text":"我想先挑出相册里重复的照片，再按年份排好，先别着急打印，不然印出来又得扔","edits":[]}"#
        let result = try WholePolishResult(raw: raw, source: source)
        XCTAssertTrue(result.isRewrite)
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.original, source)
    }
    func testSeveralRepeatedTyposStayLocal() throws {
        let source = "gitt、gitt、gitt、gitt"
        let result = try WholePolishResult(raw: #"{"text":"git、git、git、git","edits":[{"original":"gitt","replacement":"git","kind":"typo","why":"命令拼写"}]}"#, source: source)
        XCTAssertFalse(result.isRewrite)
        XCTAssertEqual(result.suggestions.count, 4)
        XCTAssertNil(SuggestionPreview.wholeRewrite(source: source, edits: result.suggestions))
    }
    func testScatteredFluencyChangesNeedWholePreview() throws {
        let source = "那个抽屉我想先整理，就是坏掉的笔先扔掉，然后剩下的笔我想按颜色放，其实主要就是找起来方便，但柜子先别挪，因为墙上的漆还没干，我就是觉得东西全混在一起不好找"
        let output = "我想先整理抽屉，把坏掉的笔扔掉，剩下的按颜色放，找起来方便。柜子先别挪，因为墙上的漆还没干。我觉得东西全混在一起不好找"
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["text": output, "edits": []]), as: UTF8.self)
        let result = try WholePolishResult(raw: raw, source: source)
        XCTAssertTrue(result.isRewrite)
        XCTAssertEqual(SuggestionPreview.wholeRewrite(source: source, edits: result.suggestions)?.output, output)
    }
    func testInsertionUnderlineAnchorsWholeGrapheme() {
        let edit = Suggestion(range: NSRange(location: 2, length: 0), original: "", replacement: "想", kind: .typo, why: "")
        XCTAssertEqual(edit.underlineRange(in: "🙂"), NSRange(location: 0, length: 2))
        XCTAssertNil(edit.underlineRange(in: ""))
    }
    func testRoutingAndColoredRuns() throws {
        let local = try WholePolishResult(raw: #"{"text":"想学会游泳","edits":[{"original":"学会","replacement":"想学会"}]}"#, source: "学会游泳")
        XCTAssertNil(SuggestionPreview.wholeRewrite(source: "学会游泳", edits: local.suggestions))
        let source = "这次要确认的是这个书架如何固定"
        let moved = try WholePolishResult(raw: #"{"text":"这次要确认的是如何固定这个书架","edits":[]}"#, source: source)
        XCTAssertTrue(moved.isRewrite)
        let preview = try XCTUnwrap(SuggestionPreview.wholeRewrite(source: source, edits: moved.suggestions))
        XCTAssertTrue(preview.segments.contains { $0.kind == .unchanged })
        XCTAssertTrue(preview.segments.contains { $0.kind == .inserted })
        XCTAssertTrue(preview.segments.contains { $0.kind == .deleted })
        XCTAssertEqual(preview.segments.filter { $0.kind != .deleted }.map(\.text).joined(), moved.text)
        XCTAssertTrue(try WholePolishResult(raw: #"{"text":"明天见。","edits":[]}"#, source: "明天见").suggestions.isEmpty)
    }
    func testCleanAndInvalidResponses() throws {
        XCTAssertTrue(try WholePolishResult(raw: #"{"text":"明天见","edits":[]}"#, source: "明天见").suggestions.isEmpty)
        for raw in [#"{"edits":[]}"#, #"{"text":"","edits":[]}"#, #"{"text":"新内容"}"#] {
            XCTAssertThrowsError(try WholePolishResult(raw: raw, source: "明天见"))
        }
    }
}

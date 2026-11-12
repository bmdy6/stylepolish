import XCTest
@testable import StylePolishCore

final class SuggestionTests: XCTestCase {
    func testUTF16DiffAndPairing() {
        let edits = SuggestionParser.parse(#"{"text":"😀非常好。","edits":[{"original":"非长","replacement":"非常","kind":"typo","why":"错别字"}]}"#, source: "😀非长好。")
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0].range, NSRange(location: 3, length: 1))
        XCTAssertEqual(edits[0].kind, .typo)
        XCTAssertEqual(edits[0].why, "错别字")
    }
    func testCanonicalEquivalentTextExpiresSuggestionsAndRejectsWrite() {
        let source = "😀é错字" // U+00E9 occupies one UTF-16 code unit.
        let current = "😀e\u{0301}错字"
        let edit = Suggestion(range: NSRange(location: 3, length: 1), original: "错", replacement: "措", kind: .typo, why: "")
        var session = SuggestionSession()
        session.set([edit], text: source, sentence: source, offset: 0)
        session.reconcile(current)
        XCTAssertTrue(session.suggestions.isEmpty)
        XCTAssertEqual(session.drainExpired().map(\.id), [edit.id])
        XCTAssertTrue(session.text.utf16.elementsEqual(current.utf16))
        XCTAssertNil(edit.relocated(from: source, to: current))
        XCTAssertFalse(edit.matches(current))

        struct Mock: FocusProviding {
            let snapshot: FocusSnapshot
            func currentFocus() -> FocusSnapshot? { snapshot }
        }
        let original = FocusSnapshot(pid: 12, element: "one", text: source, selection: edit.range)
        let changed = FocusSnapshot(pid: 12, element: "one", text: current, selection: edit.range)
        XCTAssertTrue(WriteGuard.canWrite(original, provider: Mock(snapshot: original)))
        XCTAssertFalse(WriteGuard.canWrite(original, provider: Mock(snapshot: changed)))

        // Equal UTF-16 lengths can still conceal different code-unit sequences.
        let selection = Suggestion(range: NSRange(location: 2, length: 3), original: "ée\u{0301}", replacement: "", kind: .filler, why: "")
        XCTAssertTrue(selection.matches("😀ée\u{0301}"))
        XCTAssertFalse(selection.matches("😀e\u{0301}é"))
        let edits = SuggestionParser.parse("😀e\u{0301}措字", source: source)
        var rewritten = source
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            XCTAssertTrue(edit.matches(rewritten))
            rewritten = (rewritten as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        }
        XCTAssertTrue(rewritten.utf16.elementsEqual("😀e\u{0301}措字".utf16))
    }
    func testStructuredWholeSentenceDeletion() {
        let edits = SuggestionParser.parse(#"{"text":"","edits":[{"original":"然后就是的话","replacement":"","kind":"filler","why":"整句都是赘词"}]}"#, source: "然后就是的话")
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.original, "然后就是的话")
        XCTAssertEqual(edits.first?.replacement, "")
        XCTAssertTrue(SuggestionParser.parse("", source: "不可误删").isEmpty)
    }
    func testFallbackAndUnpaired() {
        let fallback = SuggestionParser.parse("我看了一下", source: "我看了一下的话")
        XCTAssertEqual(fallback.first?.kind, .filler)
        XCTAssertEqual(fallback.first?.why, "")
        XCTAssertEqual(SuggestionParser.parse(#"{"text":"很好","edits":[]}"#, source: "非长好").first?.kind, .filler)
        XCTAssertTrue(SuggestionParser.parse("{broken", source: "你好啊啊").isEmpty)
    }
    func testRelocateOrExpireWithoutGuessing() {
        let edit = Suggestion(range: NSRange(location: 2, length: 2), original: "的话", replacement: "", kind: .filler, why: "")
        XCTAssertEqual(edit.relocated(from: "这个的话很好", to: "😀这个的话很好")?.range.location, 4)
        XCTAssertNil(edit.relocated(from: "这个的话很好", to: "这个的话的话很好"))
        XCTAssertNil(edit.relocated(from: "这个的话很好", to: "这个的确很好"))
    }
    func testSentencesCacheAndOffsets() {
        let parts = Sentence.split("😀你好。再见！\n下一句？")
        XCTAssertEqual(parts.map(\.text), ["😀你好。", "再见！", "\n", "下一句？"])
        XCTAssertEqual(parts.map(\.range.location), [0, 5, 8, 9])
        var cache = SentenceCache(); cache.store([], for: "没问题。")
        XCTAssertNotNil(cache.edits(for: "没问题。")); XCTAssertNil(cache.edits(for: "变了。"))
    }
    func testAcceptedTextIsSettledAndNeverRechecked() {
        // Issue #6: after accepting, every polished sentence must be a cache hit with no edits.
        var cache = SentenceCache()
        cache.settle("我改好了。第二句也好了！\n尾巴")
        XCTAssertEqual(cache.edits(for: "我改好了。第二句也好了！\n尾巴")?.count, 0)
        XCTAssertEqual(cache.edits(for: "我改好了。")?.count, 0)
        XCTAssertEqual(cache.edits(for: "第二句也好了！")?.count, 0)
        XCTAssertEqual(cache.edits(for: "尾巴")?.count, 0)
        XCTAssertNil(cache.edits(for: "新写的。"))
    }
    func testPreviewSegmentsRetainDeletionsWithoutChangingFinalText() throws {
        let source = "🙂这个风险如何规避。好的"
        let edits = [Suggestion(range: NSRange(location: 2, length: 8), original: "这个风险如何规避", replacement: "如何规避这个风险", kind: .fluency, why: ""),
                     Suggestion(range: NSRange(location: 11, length: 2), original: "好的", replacement: "好", kind: .tone, why: "")]
        let preview = try XCTUnwrap(SuggestionPreview(source: source, edits: edits))
        XCTAssertEqual(preview.segments.filter { $0.kind != .deleted }.map(\.text).joined(), preview.output)
        XCTAssertEqual(preview.segments.filter { $0.kind == .deleted }.map(\.text).joined(), "这个风险的")
        XCTAssertEqual(preview.segments.filter { $0.kind == .inserted }.map(\.text).joined(), "这个风险")
    }
    func testLevelsIgnoreAndExpiredEvents() throws {
        let e = Suggestion(range: NSRange(location: 0, length: 1), original: "错", replacement: "措", kind: .typo, why: "")
        var session = SuggestionSession()
        session.set([e], text: "错误句子", sentence: "错误句子", offset: 0)
        session.reconcile("新的句子")
        XCTAssertEqual(session.drainExpired().count, 1)
        XCTAssertTrue(session.suggestions.isEmpty)
        session.ignore(e, sentence: "错误句子")
        XCTAssertTrue(session.isIgnored(e, sentence: "错误句子"))
        XCTAssertFalse(Strictness.relaxed.includes(.filler)); XCTAssertTrue(Strictness.standard.includes(.filler))
        XCTAssertTrue(Strictness.standard.includes(.order)); XCTAssertTrue(Strictness.strict.includes(.tone))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        try store.append(SuggestionEvent(appBundleID: "test.app", sentence: "错误句子", suggestion: e, action: .hidden, level: .standard, model: "test"))
        let data = try Data(contentsOf: store.file)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
        XCTAssertEqual(json["action"] as? String, "hidden"); XCTAssertEqual(json["kind"] as? String, "typo")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    @MainActor func testDebounceOnlyLatestAndCancel() async throws {
        let debounce = SuggestionDebouncer(delay: 30_000_000)
        var values: [Int] = []
        let latest = expectation(description: "latest debounce callback runs")
        debounce.schedule { values.append(1) }
        debounce.schedule { values.append(2); latest.fulfill() }
        await fulfillment(of: [latest], timeout: 2)
        XCTAssertEqual(values, [2])
        let cancelled = expectation(description: "cancelled callback must not run")
        cancelled.isInverted = true
        debounce.schedule { values.append(3); cancelled.fulfill() }
        debounce.cancel()
        await fulfillment(of: [cancelled], timeout: 0.15)
        XCTAssertEqual(values, [2])
    }
}

extension SuggestionTests {
    func testMalformedMetadataRetainsUsableTextAndNoJSONIsInserted() {
        let edits = SuggestionParser.parse(#"{"text":"很好。","edits":[{"kind":"unknown"}]}"#, source: "很好啊。")
        XCTAssertEqual(edits.first?.original, "啊")
        XCTAssertEqual(edits.first?.kind, .filler)
        XCTAssertTrue(SuggestionParser.parse(#"{"edits":[]}"#, source: "测试文本").isEmpty)
    }
    func testInsertDeleteAndGraphemeRangesRoundtrip() {
        for (before, after) in [("😀很好。", "😀真的很好。"), ("👨‍👩‍👧‍👦的话很好", "👨‍👩‍👧‍👦很好"), ("非长好然后再确认", "非常好再确认")] {
            let edits = SuggestionParser.parse(after, source: before)
            var text = before
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                XCTAssertTrue(edit.matches(text))
                text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            }
            XCTAssertEqual(text, after)
        }
    }
    func testAcceptAllShiftsRangesAndDoesNotExpireOtherEdits() {
        var session = SuggestionSession()
        let first = Suggestion(range: NSRange(location: 2, length: 2), original: "的话", replacement: "", kind: .filler, why: "")
        let second = Suggestion(range: NSRange(location: 4, length: 2), original: "非长", replacement: "非常", kind: .typo, why: "")
        session.set([first, second], text: "这个的话非长好", sentence: "这个的话非长好", offset: 0)
        session.remove(first.id); session.didAccept(first, updated: "这个非长好")
        XCTAssertEqual(session.suggestions.first?.edit.range.location, 2)
        XCTAssertTrue(session.drainExpired().isEmpty)
        session.reconcile("这个非常好")
        XCTAssertEqual(session.drainExpired().count, 1)
        XCTAssertTrue(session.drainExpired().isEmpty)
    }
    func testDuplicateSentenceOccurrencesHaveIndependentRanges() {
        let edit = Suggestion(range: NSRange(location: 0, length: 1), original: "错", replacement: "措", kind: .typo, why: "")
        var session = SuggestionSession()
        session.set([edit], text: "错了。错了。", sentence: "错了。", offset: 0)
        let second = Suggestion(range: edit.range, original: edit.original, replacement: edit.replacement, kind: edit.kind, why: edit.why)
        session.set([second], text: "错了。错了。", sentence: "错了。", offset: 3)
        XCTAssertEqual(session.suggestions.map(\.edit.range.location), [0, 3])
        XCTAssertNotEqual(session.suggestions[0].id, session.suggestions[1].id)
        session.ignore(edit, sentence: "错了。")
        XCTAssertTrue(session.isIgnored(second, sentence: "错了。"))
    }
}

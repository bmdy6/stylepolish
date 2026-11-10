import XCTest
@testable import StylePolishApp

final class SuggestionWriterTests: XCTestCase {
    @MainActor func testIgnoredPasteIsNotConfirmed() async {
        var pasted = 0
        let writer = SuggestionWriter(isCurrent: { $0 == "source" }, writeAX: { false }, paste: { _, valid in
            XCTAssertTrue(valid()); pasted += 1
        }, pause: {})
        let result = await writer.write(source: "source", output: "output", valid: { true })
        XCTAssertEqual(result, .unverified)
        XCTAssertFalse(result.confirmed)
        XCTAssertEqual(pasted, 1, "Uncertain paste must never be retried")
    }
    @MainActor func testAXSuccessDoesNotPaste() async {
        var text = "source"
        let writer = SuggestionWriter(isCurrent: { $0 == text }, writeAX: { text = "output"; return true }, paste: { _, _ in XCTFail("no fallback") }, pause: {})
        let result = await writer.write(source: "source", output: "output", valid: { true })
        XCTAssertEqual(result, .ax)
        XCTAssertTrue(result.confirmed)
    }
    @MainActor func testLateAXReadbackDoesNotPasteTwice() async {
        var text = "source", ticks = 0
        let writer = SuggestionWriter(isCurrent: { $0 == text }, writeAX: { false }, paste: { _, _ in XCTFail("AX was already applied") }, pause: {
            ticks += 1; if ticks == 2 { text = "output" }
        })
        let result = await writer.write(source: "source", output: "output", valid: { true })
        XCTAssertEqual(result, .axLate)
    }
    @MainActor func testRejectedAXPastesOnlyRequestedOutput() async {
        var text = "A typo. Another typo.", writes = 0
        let source = text, output = "A correction. Another typo."
        let writer = SuggestionWriter(isCurrent: { $0 == text }, writeAX: { false }, paste: { value, valid in
            XCTAssertTrue(valid()); XCTAssertEqual(value, output); text = value; writes += 1
        }, pause: {})
        let result = await writer.write(source: source, output: output, valid: { true })
        XCTAssertEqual(result, .clipboard)
        XCTAssertEqual(text, output)
        XCTAssertEqual(writes, 1)
    }
    @MainActor func testChangedSourceOrFocusPreventsFallback() async {
        for changedText in ["user typed", "other field"] {
            var text = "source"
            let writer = SuggestionWriter(isCurrent: { $0 == text }, writeAX: { false }, paste: { _, _ in XCTFail("stale editor must not receive paste") }, pause: { text = changedText })
            let result = await writer.write(source: "source", output: "output", valid: { true })
            XCTAssertEqual(result, .failed)
        }
    }
    @MainActor func testPauseDuringAXWaitPreventsPaste() async {
        var enabled = true
        let writer = SuggestionWriter(isCurrent: { $0 == "source" }, writeAX: { false }, paste: { _, _ in XCTFail("paused") }, pause: { enabled = false })
        let result = await writer.write(source: "source", output: "output", valid: { enabled })
        XCTAssertFalse(result.confirmed)
    }
    @MainActor func testPasteRevalidatesImmediatelyBeforeDispatch() async {
        var text = "source"
        let writer = SuggestionWriter(isCurrent: { $0 == text }, writeAX: { false }, paste: { _, valid in
            text = "new typing"
            XCTAssertFalse(valid())
            throw CancellationError()
        }, pause: {})
        let result = await writer.write(source: "source", output: "output", valid: { true })
        XCTAssertFalse(result.confirmed)
        XCTAssertEqual(text, "new typing")
    }
    @MainActor func testDelayedPasteIsConfirmedByReadback() async {
        var text = "source", pasted = false
        let writer = SuggestionWriter(isCurrent: { $0 == text }, writeAX: { false }, paste: { _, _ in pasted = true }, pause: {
            if pasted { text = "output" }
        })
        let result = await writer.write(source: "source", output: "output", valid: { true })
        XCTAssertEqual(result, .clipboard)
    }
    @MainActor func testCanceledTaskNeverWrites() async {
        let task = Task { @MainActor in
            let writer = SuggestionWriter(isCurrent: { _ in true }, writeAX: { XCTFail("canceled AX"); return true }, paste: { _, _ in XCTFail("canceled paste") }, pause: {})
            return await writer.write(source: "source", output: "output", valid: { true })
        }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result.confirmed)
    }
}

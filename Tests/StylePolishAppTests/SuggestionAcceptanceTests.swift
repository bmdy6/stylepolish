import XCTest
import StylePolishCore
@testable import StylePolishApp

final class SuggestionAcceptanceTests: XCTestCase {
    @MainActor func testWriterAndCommitBoundaryForAllReadbackOutcomes() async throws {
        // A synthetic input field: dispatch may succeed while the target ignores,
        // delays, normalizes the paste, or changes focus. No AX or real clipboard.
        for mode in ["ax", "ax-late", "paste", "paste-late", "ignore", "timeout", "normalized", "focus"] {
            for all in [true, false] {
                var text = "非长好", current = true, ticks = 0, pasted = false, pasteCount = 0
                let writer = SuggestionWriter(isCurrent: { current && $0 == text }, writeAX: {
                    if mode == "ax" { text = "非常好"; return true }; return false
                }, paste: { output, valid in
                    XCTAssertTrue(valid()); pasted = true; pasteCount += 1
                    if mode == "paste" { text = output }
                    if mode == "normalized" { text = output + " " }
                    if mode == "focus" { current = false }
                }, pause: {
                    ticks += 1
                    if mode == "ax-late", ticks == 2 { text = "非常好" }
                    if mode == "paste-late", pasted { text = "非常好" }
                    if mode == "timeout", ticks == 14 { text = "非常好" }
                })
                let outcome = await writer.write(source: "非长好", output: "非常好", valid: { current })
                let confirmed = ["ax", "ax-late", "paste", "paste-late"].contains(mode)
                XCTAssertEqual(outcome.confirmed, confirmed, mode)
                XCTAssertLessThanOrEqual(pasteCount, 1)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let history = HistoryStore(directory: root)
                let edit = Suggestion(range: NSRange(location: 0, length: 2), original: "非长", replacement: "非常", kind: .typo, why: "fixture")
                var session = SuggestionSession(), cache = SentenceCache()
                session.set([edit], text: "非长好", sentence: "非长好", offset: 0)
                let items = session.suggestions
                let snapshot = try XCTUnwrap(SuggestionPreview(source: session.text, edits: [edit]))
                let committed = SuggestionAcceptance.commit(outcome: outcome, accepted: items, snapshot: snapshot, all: all, settle: true, unclear: false, session: &session, cache: &cache) {
                    try! history.append(SuggestionEvent(appBundleID: "fixture", sentence: $0.sentence, suggestion: $0.edit, action: .accept, level: .standard, model: "offline"))
                }
                XCTAssertEqual(committed, confirmed)
                XCTAssertEqual(history.habits.eventCount, confirmed ? 1 : 0, mode)
                XCTAssertEqual(session.text, confirmed ? "非常好" : "非长好", mode)
                XCTAssertEqual(session.suggestions.count, confirmed ? 0 : 1, mode)
                XCTAssertEqual(cache.result(for: "非常好") != nil, confirmed, mode)
                if !confirmed { XCTAssertTrue(items[0].edit.matches(session.text), "Still retryable: \(mode)") }
            }
        }
    }
}

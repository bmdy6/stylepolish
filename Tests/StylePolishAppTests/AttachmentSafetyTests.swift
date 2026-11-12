import XCTest
import AppKit
@testable import StylePolishApp

final class AttachmentSafetyTests: XCTestCase {
    @MainActor func testPlaceholderNeverUsesWholeAXOrPasteFallback() async {
        let source = "\u{FFFC}非长好", output = "\u{FFFC}非常好"
        var writes = 0
        let writer = SuggestionWriter(isCurrent: { $0 == source }, writeAX: { writes += 1; return false },
            paste: { _, _ in writes += 1 }, pause: {}, copyResult: { XCTAssertEqual($0, "非常好") })
        let result = await writer.write(source: source, output: output, valid: { true })
        XCTAssertEqual(writes, 0, "Attachment input must never reach plain whole-field callbacks")
        XCTAssertEqual(result.rawValue, "attachment_copy")
    }
}

extension AttachmentSafetyTests {
    private func evidence(_ text: String) -> AttachmentEvidence {
        AttachmentEvidence.inspect(text: text, attributed: NSAttributedString(string: text))
    }
    func testPlainRichTextKeepsExistingWritePolicy() {
        XCTAssertEqual(evidence("普通文字🙂"), .plain)
        XCTAssertFalse(evidence("普通文字").requiresProtection)
    }
    func testMissingOrMismatchedRichTextIsUnknown() {
        for rich in [nil, NSAttributedString(string: "different")] {
            let result = AttachmentEvidence.inspect(text: "文字", attributed: rich)
            XCTAssertFalse(result.complete)
            XCTAssertTrue(result.requiresProtection)
            XCTAssertNil(AttachmentSafety.plan(source: "文字", output: "改动", evidence: result))
        }
    }
    func testAttachmentAttributeWithoutPlaceholderRefusesRangeMapping() {
        let rich = NSAttributedString(string: "图片非长好", attributes: [NSAttributedString.Key("AXAttachment"): true])
        let result = AttachmentEvidence.inspect(text: rich.string, attributed: rich)
        XCTAssertTrue(result.hasAttachment)
        XCTAssertFalse(result.complete)
        XCTAssertNil(AttachmentSafety.plan(source: rich.string, output: "图片非常好", evidence: result))
    }
    func testEmbeddedImageNotRepresentedInTextIsProtected() {
        let result = AttachmentEvidence.inspect(text: "非长好", attributed: NSAttributedString(string: "非长好"), embeddedChildren: 1)
        XCTAssertTrue(result.hasAttachment)
        XCTAssertFalse(result.complete)
    }
    func testIncompleteChildTraversalIsProtected() {
        XCTAssertTrue(AttachmentEvidence.inspect(text: "text", attributed: NSAttributedString(string: "text"), childrenComplete: false).requiresProtection)
    }
    func testFalseAttachmentFlagIsNotAnAttachment() {
        let rich = NSAttributedString(string: "text", attributes: [NSAttributedString.Key("AXAttachment"): false])
        XCTAssertEqual(AttachmentEvidence.inspect(text: rich.string, attributed: rich), .plain)
    }
    func testPlanPreservesMultipleAttachmentsAndUTF16Order() throws {
        let source = "🙂非长\u{FFFC}中间文字\u{FFFC}明天在讨论", output = "🙂非常\u{FFFC}中间的话\u{FFFC}明天再讨论"
        let edits = try XCTUnwrap(AttachmentSafety.plan(source: source, output: output, evidence: evidence(source)))
        XCTAssertEqual(edits.count, 3)
        var text = source
        for edit in edits {
            XCTAssertFalse(edit.original.contains("\u{FFFC}"))
            XCTAssertFalse(edit.replacement.contains("\u{FFFC}"))
            XCTAssertEqual((text as NSString).substring(with: edit.range), edit.original)
            text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        }
        XCTAssertEqual(text, output)
        XCTAssertEqual(text.filter { $0 == "\u{FFFC}" }.count, 2)
        XCTAssertEqual(text.components(separatedBy: "\u{FFFC}"), ["🙂非常", "中间的话", "明天再讨论"])
    }
    func testAttachmentDeletionDuplicationOrUnknownMappingIsRejected() {
        let source = "\u{FFFC}非长\u{FFFC}"
        for output in ["非常", "\u{FFFC}非常", "\u{FFFC}\u{FFFC}非常\u{FFFC}"] {
            XCTAssertNil(AttachmentSafety.plan(source: source, output: output, evidence: evidence(source)))
        }
        XCTAssertNil(AttachmentSafety.plan(source: source, output: "\u{FFFC}非常\u{FFFC}", evidence: .unknown))
    }
    func testAdjacentAttachmentsAndInsertDeleteAreSafe() throws {
        for (source, output) in [("\u{FFFC}\u{FFFC}文字", "之前\u{FFFC}\u{FFFC}"), ("\u{FFFC}的话\u{FFFC}", "\u{FFFC}\u{FFFC}")] {
            let edits = try XCTUnwrap(AttachmentSafety.plan(source: source, output: output, evidence: evidence(source)))
            var text = source
            for edit in edits { text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) }
            XCTAssertEqual(text, output)
        }
    }
    func testGraphemeAndCanonicalDifferencesDoNotSplitOrDisappear() throws {
        let source = "\u{FFFC}👨‍👩‍👦 e\u{301} 非长", output = "\u{FFFC}👨‍👩‍👦 é 非常"
        let edits = try XCTUnwrap(AttachmentSafety.plan(source: source, output: output, evidence: evidence(source)))
        var text = source
        for edit in edits { text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) }
        XCTAssertTrue(text.utf16.elementsEqual(output.utf16))
    }
    func testPreflightFailureDoesNotMutateText() throws {
        let source = "非长\u{FFFC}在讨论", output = "非常\u{FFFC}再讨论"
        let edits = try XCTUnwrap(AttachmentSafety.plan(source: source, output: output, evidence: evidence(source)))
        var selections = 0, writes = 0
        let ok = AttachmentSafety.apply(edits, source: source, output: output, valid: { true }, read: { source }, select: { _ in selections += 1; return selections == 1 }, selectedText: { edits[0].original }, replace: { _ in writes += 1; return true })
        XCTAssertFalse(ok); XCTAssertEqual(writes, 0)
    }
    @MainActor func testUnknownEvidenceCopiesAndNeverAttemptsAXOrPaste() async {
        var copied = ""
        let writer = SuggestionWriter(isCurrent: { $0 == "source" }, writeAX: { XCTFail("AX"); return false }, paste: { _, _ in XCTFail("paste") }, pause: {}, attachmentEvidence: { .unknown }, copyResult: { copied = $0 })
        let result = await writer.write(source: "source", output: "output", valid: { true })
        XCTAssertEqual(result, .attachmentCopy); XCTAssertEqual(copied, "output")
        XCTAssertFalse(result.confirmed)
        XCTAssertTrue(AttachmentSafety.copyMessage.contains("请手动粘贴"))
    }
    @MainActor func testSingleAndAllUseProtectedRangesWithoutWholeWrite() async {
        for output in ["非常\u{FFFC}在讨论", "非常\u{FFFC}再讨论"] {
            var text = "非长\u{FFFC}在讨论"
            let source = text
            let writer = SuggestionWriter(isCurrent: { $0 == text }, writeAX: { XCTFail("whole AX"); return false }, paste: { _, _ in XCTFail("paste") }, pause: {}, attachmentEvidence: { self.evidence(text) }, writeProtected: { source, output in
                guard let edits = AttachmentSafety.plan(source: source, output: output, evidence: self.evidence(source)) else { return false }
                for edit in edits { text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) }
                return true
            }, copyResult: { _ in XCTFail("should write ranges") })
            let result = await writer.write(source: source, output: output, valid: { true })
            XCTAssertEqual(result, .attachmentAX); XCTAssertEqual(text, output)
        }
    }
    @MainActor func testRejectedProtectedWriteCopiesWithoutPaste() async {
        let source = "\u{FFFC}source"
        var copied = ""
        let writer = SuggestionWriter(isCurrent: { $0 == source }, writeAX: { XCTFail("whole AX"); return false }, paste: { _, _ in XCTFail("paste") }, pause: {}, attachmentEvidence: { self.evidence(source) }, writeProtected: { _, _ in false }, copyResult: { copied = $0 })
        let result = await writer.write(source: source, output: "\u{FFFC}output", valid: { true })
        XCTAssertEqual(result, .attachmentCopy); XCTAssertEqual(copied, "output")
    }
    @MainActor func testAttachmentAppearingWhileAXWaitsPreventsPaste() async {
        var fresh = AttachmentEvidence.plain, copied = ""
        let writer = SuggestionWriter(isCurrent: { $0 == "source" }, writeAX: { false }, paste: { _, _ in XCTFail("new opaque image must block paste") }, pause: { fresh = .unknown }, attachmentEvidence: { fresh }, copyResult: { copied = $0 })
        let result = await writer.write(source: "source", output: "output", valid: { true })
        XCTAssertEqual(result, .attachmentCopy); XCTAssertEqual(copied, "output")
    }
    @MainActor func testStaleAttachmentFieldDoesNotWriteOrCopy() async {
        let writer = SuggestionWriter(isCurrent: { _ in false }, writeAX: { XCTFail("AX"); return false }, paste: { _, _ in XCTFail("paste") }, pause: {}, copyResult: { _ in XCTFail("stale") })
        let result = await writer.write(source: "\u{FFFC}source", output: "output", valid: { true })
        XCTAssertEqual(result, .failed)
    }
    func testAttachmentDiagnosticsAreContentFree() throws {
        let event = DiagnosticEvent(event: "accept_all", bundleID: "synthetic", hasAttachment: true, writeMethod: "copy_only")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertEqual(object["hasAttachment"] as? Bool, true)
        XCTAssertEqual(object["writeMethod"] as? String, "copy_only")
        XCTAssertNil(object["text"]); XCTAssertNil(object["source"]); XCTAssertNil(object["output"])
    }
}

extension AttachmentSafetyTests {
    @MainActor func testNewAttachmentAtPasteDispatchCopiesInsteadOfRetrying() async {
        var state = AttachmentEvidence.plain, copied = ""
        let writer = SuggestionWriter(isCurrent: { $0 == "source" }, writeAX: { false }, paste: { _, valid in
            state = AttachmentEvidence(hasAttachment: true, ranges: [], complete: false)
            XCTAssertFalse(valid())
            throw CancellationError()
        }, pause: {}, attachmentEvidence: { state }, copyResult: { copied = $0 })
        let result = await writer.write(source: "source", output: "output", valid: { true })
        XCTAssertEqual(result, .attachmentCopy); XCTAssertEqual(copied, "output")
    }
    func testMutationDuringRangePreflightStopsBeforeTextWrite() throws {
        let source = "\u{FFFC}非长", output = "\u{FFFC}非常"
        let evidence = AttachmentEvidence.inspect(text: source, attributed: NSAttributedString(string: source))
        let edits = try XCTUnwrap(AttachmentSafety.plan(source: source, output: output, evidence: evidence))
        var text = source, writes = 0
        let ok = AttachmentSafety.apply(edits, source: source, output: output, valid: { true }, read: { text }, select: { _ in text = "\u{FFFC}new typing"; return true }, selectedText: { "长" }, replace: { _ in writes += 1; return true })
        XCTAssertFalse(ok); XCTAssertEqual(writes, 0)
        XCTAssertEqual(text, "\u{FFFC}new typing")
    }
    @MainActor func testPartialOrUnconfirmedRangeWriteNeverTriggersWholeFallback() async {
        var text = "非长\u{FFFC}在讨论", copied = ""
        let writer = SuggestionWriter(isCurrent: { $0 == text }, writeAX: { XCTFail("AX whole"); return false }, paste: { _, _ in XCTFail("paste"); }, pause: {}, attachmentEvidence: { AttachmentEvidence.inspect(text: text, attributed: NSAttributedString(string: text)) }, writeProtected: { _, _ in
            text = "非长\u{FFFC}再讨论"; return false
        }, copyResult: { copied = $0 })
        let result = await writer.write(source: "非长\u{FFFC}在讨论", output: "非常\u{FFFC}再讨论", valid: { true })
        XCTAssertEqual(result, .attachmentCopy); XCTAssertFalse(result.confirmed)
        XCTAssertEqual(text, "非长\u{FFFC}再讨论"); XCTAssertEqual(copied, "非常再讨论")
    }
}

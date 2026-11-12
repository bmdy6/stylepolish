import Foundation
import StylePolishCore

/// Retained across presentation and writeback; task generation may change independently.
@MainActor final class DiagnosticTrace {
    let id: String
    let bundleID: String
    let log: Diagnostics
    private var response: String?
    private var invalidated = false
    private var textLength: Int?
    private var shown = Set<String>()
    init(id: String = UUID().uuidString, bundleID: String, log: Diagnostics = .shared) {
        self.id = id; self.bundleID = bundleID; self.log = log
    }
    static func permitsCapture(enabled: Bool, ordinary: Bool) -> Bool { enabled && ordinary }
    func record(_ name: String, _ configure: (inout DiagnosticEvent) -> Void = { _ in }) {
        var event = DiagnosticEvent(event: name, bundleID: bundleID, traceID: id)
        configure(&event); log.record(event)
    }
    func capture(text: String?, role: String?, writable: Bool, selection: NSRange?, attachment: AttachmentEvidence, hasPosition: Bool) {
        textLength = text?.utf16.count
        record("capture") {
            $0.textLength = text?.utf16.count; $0.source = text; $0.role = role; $0.readable = text != nil
            $0.writable = writable; $0.selectionLocation = selection?.location; $0.selectionLength = selection?.length
            $0.hasAttachment = attachment.hasAttachment; $0.attachmentEvidenceComplete = attachment.complete; $0.hasPosition = hasPosition
            $0.error = text == nil ? "ax_value_unavailable" : writable ? nil : "ax_not_writable"
        }
    }
    func started(engine: PolishEngine, level: Strictness, cacheHit: Bool, debounceMS: Int = 0) {
        record("check_started") { $0.textLength = textLength; $0.engine = engine.rawValue; $0.level = level.rawValue; $0.cacheHit = cacheHit; $0.debounceMS = debounceMS; $0.fallback = FallbackReason.none }
    }
    func metrics(_ timing: RequestMetrics, model: String, engine: PolishEngine = .ai) {
        response = timing.modelResponse
        record("request_metrics") {
            $0.textLength = textLength; $0.fallback = FallbackReason.none
            $0.model = model; $0.engine = engine.rawValue; $0.requestMS = timing.totalMS; $0.firstTokenMS = timing.firstTokenMS
            $0.promptTokens = timing.promptTokens; $0.completionTokens = timing.completionTokens; $0.reasoningTokens = timing.reasoningTokens; $0.totalTokens = timing.totalTokens
            $0.httpStatus = timing.httpStatus; $0.error = timing.errorCategory
        }
    }
    func result(source: String, suggestions: [Suggestion], engine: PolishEngine, fallback: FallbackReason, unclear: Bool?, requestMS: Int, resultMS: Int, debounceMS: Int? = nil) {
        var event = DiagnosticEvent(event: "result", bundleID: bundleID, traceID: id, requestMS: requestMS, resultMS: resultMS, engine: engine.rawValue, fallback: fallback)
            .includingPreview(source: source, suggestions: suggestions)
        event.debounceMS = debounceMS
        event.kindCounts = Dictionary(grouping: suggestions, by: { $0.kind.rawValue }).mapValues(\.count)
        event.wholeRewrite = event.previewKind == "whole"; event.unclear = unclear
        event.modelResponse = response
        event.output = SuggestionPreview(source: source, edits: suggestions)?.output ?? source
        log.record(event)
    }
    func presented(_ presentation: String, mode: String? = nil, hasPosition: Bool, count: Int, state: String? = nil) {
        // AX polling must not append the same visible state every 350 ms.
        let signature = "\(state ?? ""):\(presentation):\(mode ?? ""):\(hasPosition):\(count)"
        guard shown.insert(signature).inserted else { return }
        record(["preview_bar", "shortcut_panel"].contains(presentation) ? "preview_shown" : "indicator_shown") {
            $0.indicatorState = state; $0.presentation = presentation; $0.previewMode = mode; $0.hasPosition = hasPosition; $0.suggestionCount = count
        }
    }
    func action(_ action: String, count: Int = 0) {
        if action == "typing_invalidated" { guard !invalidated else { return }; invalidated = true }
        record("user_action") { $0.action = action; $0.suggestionCount = count }
    }
    func write(source: String, expected: String, readback: String?, method: String, attachment: AttachmentEvidence, error: String? = nil) {
        record("write") {
            $0.writeMethod = method; $0.beforeLength = source.utf16.count; $0.afterLength = readback?.utf16.count; $0.expectedLength = expected.utf16.count
            $0.readable = readback != nil; $0.readbackMatches = readback.map { $0.utf16.elementsEqual(expected.utf16) }
            $0.hasAttachment = attachment.hasAttachment; $0.attachmentEvidenceComplete = attachment.complete
            if let error { $0.error = error }
            else if let readback { $0.error = readback.utf16.elementsEqual(expected.utf16) ? nil : "write_readback_mismatch" }
            else { $0.error = "readback_unavailable" }
            $0.source = source; $0.output = readback
        }
    }
}

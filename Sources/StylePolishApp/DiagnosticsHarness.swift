#if DEBUG
import AppKit
import StylePolishCore

/// Offscreen NSTextView editor using production checking, write confirmation and trace helpers.
/// No windows, external AX queries or clipboard transactions.
@MainActor enum DiagnosticsHarness {
    struct Result { let source: String; let output: String; let traceID: String; let suggestions: Int }
    static func run(log: Diagnostics) async throws -> Result {
        let source = "我因该明天回复"
        let editor = NSTextView(frame: .zero)
        editor.string = source
        let trace = DiagnosticTrace(bundleID: "org.bmdy6.StylePolish.SyntheticEditor", log: log)
        trace.capture(text: editor.string, role: "synthetic_text_area", writable: true, selection: NSRange(location: editor.string.utf16.count, length: 0), attachment: .plain, hasPosition: false)
        trace.started(engine: .local, level: .standard, cacheHit: false)
        let config = PolishConfiguration(base: "https://example.invalid/v1", model: "local-rules", key: "", profile: "")
        let result = try await CheckEngine(client: PolishClient(lexiconURL: URL(fileURLWithPath: "/nonexistent/synthetic-lexicon.json"))).check(editor.string, engine: .local, config: config)
        trace.result(source: editor.string, suggestions: result.suggestions, engine: .local, fallback: result.fallback, unclear: result.unclear, requestMS: 0, resultMS: 0)
        trace.presented("badge", hasPosition: false, count: result.suggestions.count)
        guard let preview = SuggestionPreview(source: editor.string, edits: result.suggestions) else { throw PolishFailure(message: "Synthetic check produced no suggestions") }
        trace.action("accept_all", count: result.suggestions.count)
        let writer = SuggestionWriter(isCurrent: { editor.string.utf16.elementsEqual($0.utf16) }, writeAX: {
            guard let storage = editor.textStorage else { return false }
            for edit in result.suggestions.sorted(by: { $0.range.location > $1.range.location }) {
                storage.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            return true
        }, paste: { _, _ in throw PolishFailure(message: "Synthetic AX write should succeed") })
        let outcome = await writer.write(source: preview.source, output: preview.output, valid: { true })
        trace.write(source: preview.source, expected: preview.output, readback: editor.string, method: "selected_range", attachment: .plain, error: outcome.confirmed ? nil : outcome.rawValue)
        guard outcome.confirmed else { throw PolishFailure(message: "Synthetic write not confirmed") }
        log.flush()
        return Result(source: source, output: editor.string, traceID: trace.id, suggestions: result.suggestions.count)
    }
}
#endif

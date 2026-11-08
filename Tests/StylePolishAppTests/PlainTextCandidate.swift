// Experimental B candidate. Production stays on A after the frozen quality gate failed.
import Foundation
import StylePolishCore
@testable import StylePolishApp

/// The model supplies only prose. Routing and safe source ranges belong here.
struct PlainTextCandidateResult {
    let text: String
    let suggestions: [Suggestion]
    let isRewrite: Bool

    init(output raw: String, source: String) throws {
        var output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output.utf8.count <= 100_000 else {
            throw PolishFailure(message: "模型返回正文无效，请重试")
        }
        if !source.hasSuffix("。"), output.hasSuffix("。") { output.removeLast() }
        if PolishTextComparison.key(source) == PolishTextComparison.key(output) {
            text = source; suggestions = []; isRewrite = false
            return
        }
        let edits = PolishTextComparison.edits(source: source, output: output)
        // A moved phrase is a coupled deletion/insertion: accepting half breaks it.
        let moved = edits.contains { deletion in
            let removed = Array(PolishTextComparison.key(deletion.original))
            guard deletion.replacement.isEmpty, removed.count >= 2 else { return false }
            return edits.contains { insertion in
                guard insertion.original.isEmpty else { return false }
                let inserted = PolishTextComparison.key(insertion.replacement)
                return (0..<(removed.count - 1)).contains { inserted.contains(String(removed[$0...($0 + 1)])) }
            }
        }
        let small = !edits.isEmpty && edits.count <= 3 && !moved && edits.allSatisfy {
            max(PolishTextComparison.key($0.original).count, PolishTextComparison.key($0.replacement).count) <= 4
        }
        if small, let patched = SuggestionPreview(source: source, edits: edits)?.output,
           PolishTextComparison.key(patched) == PolishTextComparison.key(output) {
            text = patched; suggestions = edits; isRewrite = false
        } else {
            text = output; isRewrite = true
            suggestions = [Suggestion(range: NSRange(location: 0, length: source.utf16.count), original: source, replacement: output,
                kind: .fluency, why: "理顺整段表达，保留本人口吻")]
        }
    }
}

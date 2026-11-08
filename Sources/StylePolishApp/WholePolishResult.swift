import Foundation
import StylePolishCore

/// A full-field rewrite stays atomic unless bounded local edits reproduce all
/// meaningful character changes. Punctuation and case alone never suggest work.
struct WholePolishResult {
    let text: String
    let suggestions: [Suggestion]
    let isRewrite: Bool
    let unclear: Bool

    init(raw: String, source: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              var output = object["text"] as? String, object["edits"] is [Any],
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              output.utf8.count <= 100_000 else {
            throw PolishFailure(message: "模型建议格式无效，请重试")
        }
        unclear = object["unclear"] as? Bool ?? false
        if !source.hasSuffix("。"), output.hasSuffix("。") { output.removeLast() }
        if PolishTextComparison.key(source) == PolishTextComparison.key(output) {
            text = source; suggestions = []; isRewrite = false
            return
        }
        let original = source as NSString
        var local: [Suggestion] = []
        for edit in object["edits"] as? [[String: Any]] ?? [] {
            guard let before = edit["original"] as? String, let after = edit["replacement"] as? String,
                  !before.isEmpty, max(before.count, after.count) <= 12,
                  PolishTextComparison.key(before) != PolishTextComparison.key(after) else { continue }
            var search = NSRange(location: 0, length: original.length)
            while search.length > 0 {
                let range = original.range(of: before, options: [.caseInsensitive, .literal], range: search)
                if range.location == NSNotFound { break }
                let suggestion = Suggestion(range: range, original: original.substring(with: range), replacement: after,
                    kind: .typo, why: edit["why"] as? String ?? "修正错字、漏字或用词")
                if !local.contains(where: { $0.range == range && PolishTextComparison.key($0.replacement) == PolishTextComparison.key(after) }) { local.append(suggestion) }
                search = NSRange(location: NSMaxRange(range), length: original.length - NSMaxRange(range))
            }
        }
        local.sort { $0.range.location < $1.range.location }
        // SuggestionPreview validates ranges, overlap, and the exact source snapshot.
        if let patched = SuggestionPreview(source: source, edits: local)?.output,
           PolishTextComparison.key(patched) == PolishTextComparison.key(output) {
            text = patched; suggestions = local; isRewrite = false
        } else {
            text = output; isRewrite = true
            suggestions = [Suggestion(range: NSRange(location: 0, length: source.utf16.count), original: source, replacement: output,
                kind: .fluency, why: "理顺整段表达，保留本人口吻")]
        }
    }
}

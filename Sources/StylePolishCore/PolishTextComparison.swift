import Foundation

/// Chat formatting does not count as a correction. Keep original grapheme ranges
/// so case folding (which can expand Unicode characters) never shifts highlights.
public enum PolishTextComparison {
    private static func tokens(_ text: String) -> [(key: String, range: NSRange)] {
        var offset = 0
        return text.flatMap { character -> [(key: String, range: NSRange)] in
            let value = String(character)
            let range = NSRange(location: offset, length: value.utf16.count)
            offset += range.length
            let ignored = character.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
            }
            guard !ignored else { return [] }
            return value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).map { (String($0), range) }
        }
    }

    public static func key(_ text: String) -> String { tokens(text).map(\.key).joined() }

    /// Run Core's CharacterDiff on meaningful characters, then map both sides
    /// back to the actual strings. Formatting elsewhere is left untouched.
    public static func edits(source: String, output: String) -> [Suggestion] {
        let old = tokens(source), new = tokens(output)
        func range(_ tokens: [(key: String, range: NSRange)], offset: Int, length: Int) -> NSRange {
            var position = 0, hits: [NSRange] = []
            for token in tokens {
                let end = position + token.key.utf16.count
                if length == 0, position >= offset { return NSRange(location: token.range.location, length: 0) }
                if end > offset && position < offset + length { hits.append(token.range) }
                position = end
            }
            guard let first = hits.first, let last = hits.last else {
                return NSRange(location: tokens.last.map { NSMaxRange($0.range) } ?? 0, length: 0)
            }
            return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        }
        func boundary(_ tokens: [(key: String, range: NSRange)], offset: Int) -> (left: Int, right: Int) {
            var position = 0, previousEnd = 0
            for token in tokens {
                if position >= offset { return (previousEnd, max(previousEnd, token.range.location)) }
                position += token.key.utf16.count
                previousEnd = NSMaxRange(token.range)
            }
            return (previousEnd, previousEnd)
        }
        let oldKey = old.map(\.key).joined(), newKey = new.map(\.key).joined()
        guard !newKey.isEmpty else { return [] }
        var blocks: [(range: NSRange, replacementLength: Int)] = []
        var offset = 0, start = 0, removed = 0, inserted = 0
        func flush() {
            if removed > 0 || inserted > 0 { blocks.append((NSRange(location: start, length: removed), inserted)) }
            removed = 0; inserted = 0
        }
        for part in CharacterDiff(oldKey, newKey).parts {
            let length = part.text.utf16.count
            if part.kind == .equal { flush(); offset += length }
            else {
                if removed == 0 && inserted == 0 { start = offset }
                if part.kind == .delete { removed += length; offset += length }
                else { inserted += length }
            }
        }
        flush()
        let before = source as NSString, after = output as NSString
        var shift = 0
        var changes: [(before: NSRange, after: NSRange)] = []
        for edit in blocks {
            var oldRange = range(old, offset: edit.range.location, length: edit.range.length)
            let newRange = range(new, offset: edit.range.location + shift, length: edit.replacementLength)
            if edit.range.length == 0, edit.replacementLength > 0 {
                // A zero-width insertion may sit on either side of ignored punctuation.
                // Match the punctuation's side in the result instead of moving it into a word.
                let oldBoundary = boundary(old, offset: edit.range.location)
                let left = boundary(new, offset: edit.range.location + shift)
                let right = boundary(new, offset: edit.range.location + shift + edit.replacementLength)
                let gap = before.substring(with: NSRange(location: oldBoundary.left, length: oldBoundary.right - oldBoundary.left))
                let leftGap = after.substring(with: NSRange(location: left.left, length: left.right - left.left))
                let rightGap = after.substring(with: NSRange(location: right.left, length: right.right - right.left))
                if gap == rightGap && gap != leftGap { oldRange.location = oldBoundary.left }
            }
            shift += edit.replacementLength - edit.range.length
            // A transposition inside one ASCII word is one spelling correction.
            // Never merge across separators or across different words.
            if let previous = changes.last,
               oldRange.location >= NSMaxRange(previous.before), newRange.location >= NSMaxRange(previous.after) {
                let oldGap = before.substring(with: NSRange(location: NSMaxRange(previous.before), length: oldRange.location - NSMaxRange(previous.before)))
                let newGap = after.substring(with: NSRange(location: NSMaxRange(previous.after), length: newRange.location - NSMaxRange(previous.after)))
                func asciiWord(_ value: String) -> Bool {
                    value.count <= 2 && value.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) }
                }
                if asciiWord(oldGap), asciiWord(newGap), !oldGap.isEmpty || !newGap.isEmpty {
                    changes[changes.count - 1] = (NSRange(location: previous.before.location, length: NSMaxRange(oldRange) - previous.before.location), NSRange(location: previous.after.location, length: NSMaxRange(newRange) - previous.after.location))
                    continue
                }
            }
            changes.append((oldRange, newRange))
        }
        return changes.map { change in
            Suggestion(range: change.before, original: before.substring(with: change.before), replacement: after.substring(with: change.after), kind: .typo, why: "可能是错字")
        }
    }

    public static func insertedRanges(source: String, output: String) -> [NSRange] {
        let old = tokens(source), new = tokens(output)
        return new.map(\.key).difference(from: old.map(\.key)).compactMap { change in
            if case let .insert(offset, _, _) = change { return new[offset].range }
            return nil
        }
    }
}

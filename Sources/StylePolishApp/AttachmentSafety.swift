import Foundation

/// AX plain text alone cannot prove that a rich editor contains no attachments.
struct AttachmentEvidence: Equatable {
    var hasAttachment: Bool
    var ranges: [NSRange]
    var complete: Bool
    static let plain = Self(hasAttachment: false, ranges: [], complete: true)
    static let unknown = Self(hasAttachment: false, ranges: [], complete: false)
    var requiresProtection: Bool { hasAttachment || !complete }

    static func inspect(text: String, attributed: NSAttributedString?, embeddedChildren: Int = 0,
                        childrenComplete: Bool = true) -> Self {
        let ns = text as NSString
        var ranges = (0..<ns.length).filter { ns.character(at: $0) == 0xFFFC }.map { NSRange(location: $0, length: 1) }
        var complete = childrenComplete && attributed?.string.utf16.elementsEqual(text.utf16) == true
        var found = !ranges.isEmpty || embeddedChildren > 0
        if let attributed, attributed.length == ns.length {
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
                let attachment = attrs.contains { key, value in
                    let key = key.rawValue.lowercased()
                    guard key.contains("attachment") || key.contains("embeddedobject") else { return false }
                    if let flag = value as? NSNumber, flag == false { return false }
                    return true
                }
                if attachment {
                    found = true
                    // Non-placeholder attachment representations have no safe plain-text coordinates.
                    if range.length == 1, ns.character(at: range.location) == 0xFFFC {
                        if !ranges.contains(range) { ranges.append(range) }
                    } else { complete = false }
                }
            }
        }
        if embeddedChildren > ranges.count { complete = false }
        return Self(hasAttachment: found, ranges: ranges.sorted { $0.location < $1.location }, complete: complete)
    }
}

struct AttachmentReplacement: Equatable {
    var range: NSRange
    var original: String
    var replacement: String
}

/// Keeps every U+FFFC anchor in the editor; no planned range contains an attachment.
enum AttachmentSafety {
    static let copyMessage = "输入框里有图片，已复制润色结果，请手动粘贴"
    static let unknownMessage = "无法确认输入框里的图片是否安全，已复制润色结果，请手动粘贴"
    static func clipboardText(_ output: String) -> String { output.replacingOccurrences(of: "\u{FFFC}", with: "") }

    static func plan(source: String, output: String, evidence: AttachmentEvidence) -> [AttachmentReplacement]? {
        guard evidence.complete, evidence.hasAttachment, source.utf16.count <= 100_000, output.utf16.count <= 100_000 else { return nil }
        let before = source.components(separatedBy: "\u{FFFC}"), after = output.components(separatedBy: "\u{FFFC}")
        guard before.count > 1, before.count == after.count, evidence.ranges.count == before.count - 1 else { return nil }
        var offset = 0, edits: [AttachmentReplacement] = []
        for index in before.indices {
            let old = before[index], new = after[index]
            if index < evidence.ranges.count, evidence.ranges[index] != NSRange(location: offset + old.utf16.count, length: 1) { return nil }
            if !old.utf16.elementsEqual(new.utf16) {
                // Trim only complete Characters, so UTF-16 AX ranges never split a surrogate or grapheme.
                let a = Array(old), b = Array(new)
                var prefix = 0, suffix = 0
                while prefix < min(a.count, b.count), String(a[prefix]).utf16.elementsEqual(String(b[prefix]).utf16) { prefix += 1 }
                while suffix < min(a.count, b.count) - prefix, String(a[a.count - suffix - 1]).utf16.elementsEqual(String(b[b.count - suffix - 1]).utf16) { suffix += 1 }
                let original = String(a[prefix..<(a.count - suffix)])
                edits.append(AttachmentReplacement(range: NSRange(location: offset + String(a.prefix(prefix)).utf16.count, length: original.utf16.count), original: original, replacement: String(b[prefix..<(b.count - suffix)])))
            }
            offset += old.utf16.count + 1
        }
        guard edits.count <= 256 else { return nil }
        return edits.reversed()
    }

    /// The caller supplies editor operations; also used by the windowless synthetic NSTextView harness.
    /// All selections are preflighted before the first text mutation. No rollback/whole-field fallback.
    static func apply(_ edits: [AttachmentReplacement], source: String, output: String,
                      valid: () -> Bool, read: () -> String?, select: (NSRange) -> Bool,
                      selectedText: () -> String?, replace: (String) -> Bool) -> Bool {
        func current(_ expected: String) -> Bool { valid() && read()?.utf16.elementsEqual(expected.utf16) == true }
        guard current(source) else { return false }
        for edit in edits {
            guard current(source), select(edit.range), current(source), selectedText()?.utf16.elementsEqual(edit.original.utf16) == true else { return false }
        }
        var expected = source
        for edit in edits {
            guard current(expected), select(edit.range), current(expected), selectedText()?.utf16.elementsEqual(edit.original.utf16) == true else { return false }
            guard replace(edit.replacement) else { return false }
            expected = (expected as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            guard current(expected) else { return false }
        }
        return current(output)
    }
}

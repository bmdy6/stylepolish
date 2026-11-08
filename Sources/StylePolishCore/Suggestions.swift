import Foundation
import CryptoKit

public enum SuggestionKind: String, Codable, CaseIterable { case typo, filler, fluency, order, tone
    public var title: String { switch self { case .typo: return "错别字修正"; case .filler: return "赘词"; case .fluency: return "通顺"; case .order: return "通顺（语序）"; case .tone: return "书面表达" } }
}
public enum Strictness: String, Codable, CaseIterable { case relaxed, standard, strict
    public var title: String { switch self { case .relaxed: return "宽松"; case .standard: return "标准"; case .strict: return "严格" } }
    public func includes(_ kind: SuggestionKind) -> Bool { self == .strict || kind == .typo || (self == .standard && [.filler, .fluency, .order].contains(kind)) }
}
public struct Suggestion: Identifiable, Equatable {
    public let id: UUID
    public var range: NSRange
    public let original: String, replacement: String, kind: SuggestionKind, why: String
    public init(id: UUID = UUID(), range: NSRange, original: String, replacement: String, kind: SuggestionKind, why: String) {
        self.id = id; self.range = range; self.original = original; self.replacement = replacement; self.kind = kind; self.why = why
    }
    public func matches(_ text: String) -> Bool {
        let ns = text as NSString
        return range.location >= 0 && range.length >= 0 && range.location <= ns.length && range.length <= ns.length - range.location && ns.substring(with: range).utf16.elementsEqual(original.utf16)
    }
    /// Insertions underline a neighboring grapheme; AX caret bounds can have zero width.
    public func underlineRange(in text: String) -> NSRange? {
        guard matches(text) else { return nil }
        if range.length > 0 { return range }
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        return ns.rangeOfComposedCharacterSequence(at: min(range.location, ns.length - 1))
    }
    public func relocated(from old: String, to new: String) -> Suggestion? {
        guard matches(old) else { return nil }
        if old.utf16.elementsEqual(new.utf16) { return self }
        // Only an unchanged, unambiguous context may move. Never search for a bare repeated word.
        let ns = old as NSString
        let start = max(0, range.location - 12), end = min(ns.length, NSMaxRange(range) + 12)
        let context = ns.substring(with: NSRange(location: start, length: end - start))
        let target = new as NSString
        let first = target.range(of: context, options: .literal)
        guard first.location != NSNotFound else { return nil }
        let tail = NSMaxRange(first)
        if tail < target.length, target.range(of: context, options: .literal, range: NSRange(location: first.location + 1, length: target.length - first.location - 1)).location != NSNotFound { return nil }
        var moved = self; moved.range.location = first.location + range.location - start
        return moved.matches(new) ? moved : nil
    }
}
public enum SuggestionParser {
    private struct Response: Decodable { let text: String; let edits: [Edit] }
    private struct Edit: Decodable { let original: String, replacement: String, kind: SuggestionKind, why: String }
    // Extract only closed edit objects. Strings may contain escaped quotes/braces.
    // An unfinished envelope or following object does not delay a completed suggestion.
    public static func partial(_ raw: String, source: String) -> [Suggestion] {
        guard let range = raw.range(of: #"\"edits\"\s*:\s*\["#, options: .regularExpression) else { return [] }
        var objects: [[String: Any]] = [], depth = 0, quoted = false, escaped = false, buffer = ""
        for char in raw[range.upperBound...] {
            if depth == 0 {
                if char == "]" { break }
                if char != "{" { continue }
            }
            buffer.append(char)
            if quoted {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { quoted = false }
            } else {
                if char == "\"" { quoted = true }
                else if char == "{" { depth += 1 }
                else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        if let value = (try? JSONSerialization.jsonObject(with: Data(buffer.utf8))) as? [String: Any] { objects.append(value) }
                        buffer = ""
                    }
                }
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["edits": objects]), let json = String(data: data, encoding: .utf8) else { return [] }
        return parse(json, source: source)
    }
    private static func located(_ edits: [Edit], source: String) -> [Suggestion] {
        let ns = source as NSString
        var result: [Suggestion] = []
        var occupied: [NSRange] = []
        for edit in edits {
            guard !edit.original.isEmpty, edit.original != edit.replacement else { continue }
            let range = ns.range(of: edit.original, options: .literal)
            guard range.location != NSNotFound else { continue }
            let next = NSMaxRange(range)
            // A repeated original is ambiguous. Ask the model for a longer unique context.
            if next < ns.length, ns.range(of: edit.original, options: .literal, range: NSRange(location: range.location + 1, length: ns.length - range.location - 1)).location != NSNotFound { continue }
            guard !occupied.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
            occupied.append(range)
            if [.fluency, .order, .tone].contains(edit.kind) {
                // Keep a rewrite atomic: splitting a moved phrase into deletion/insertion
                // would allow a single-card acceptance to leave a broken sentence.
                result.append(Suggestion(range: range, original: edit.original, replacement: edit.replacement, kind: edit.kind, why: edit.why))
                if result.count >= 3 { break }
                continue
            }
            let output = ns.replacingCharacters(in: range, with: edit.replacement)
            // Keep the existing minimal character diff and metadata behavior.
            let object: [String: Any] = ["text": output, "edits": [["original": edit.original, "replacement": edit.replacement, "kind": edit.kind.rawValue, "why": edit.why]]]
            if let data = try? JSONSerialization.data(withJSONObject: object), let raw = String(data: data, encoding: .utf8) {
                result.append(contentsOf: parse(raw, source: source).prefix(3 - result.count))
            }
            if result.count >= 3 { break }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }
    public static func parse(_ raw: String, source: String) -> [Suggestion] {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```") { clean = clean.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n") }
        if let object = (try? JSONSerialization.jsonObject(with: Data(clean.utf8))) as? [String: Any], object["text"] == nil,
           let array = object["edits"] as? [Any] {
            let edits = array.compactMap { value -> Edit? in
                guard value is [String: Any], let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                return try? JSONDecoder().decode(Edit.self, from: data)
            }
            return located(edits, source: source)
        }
        let response = try? JSONDecoder().decode(Response.self, from: Data(clean.utf8))
        // A malformed edits array may still contain a usable text field. Never diff JSON syntax.
        let object = (try? JSONSerialization.jsonObject(with: Data(clean.utf8))) as? [String: Any]
        let output = response?.text ?? object?["text"] as? String ?? (clean.hasPrefix("{") || clean.hasPrefix("[") ? source : clean)
        let hasStructuredText = response != nil || object?["text"] is String
        guard (!output.isEmpty || hasStructuredText), output.utf8.count <= 100_000 else { return [] }
        var result: [Suggestion] = [], offset = 0, original = "", replacement = "", blockStart = 0, modelIndex = 0
        func flush() {
            guard !original.isEmpty || !replacement.isEmpty else { return }
            var kind = SuggestionKind.filler, why = ""
            if let edits = response?.edits, modelIndex < edits.count {
                let edit = edits[modelIndex]
                if (original.isEmpty || edit.original.contains(original)) && (replacement.isEmpty || edit.replacement.contains(replacement)) {
                    kind = edit.kind; why = edit.why; modelIndex += 1
                }
            }
            result.append(Suggestion(range: NSRange(location: blockStart, length: original.utf16.count), original: original, replacement: replacement, kind: kind, why: why))
            original = ""; replacement = ""
        }
        for part in CharacterDiff(source, output).parts {
            if part.kind == .equal { flush(); offset += part.text.utf16.count }
            else {
                if original.isEmpty && replacement.isEmpty { blockStart = offset }
                if part.kind == .delete { original += part.text; offset += part.text.utf16.count } else { replacement += part.text }
            }
        }
        flush(); return result
    }
}
public struct Sentence {
    public let text: String, range: NSRange
    public static func split(_ text: String) -> [Sentence] {
        var result: [Sentence] = [], buffer = "", offset = 0
        for char in text {
            buffer.append(char)
            if "。！？\n".contains(char) {
                result.append(Sentence(text: buffer, range: NSRange(location: offset, length: buffer.utf16.count)))
                offset += buffer.utf16.count; buffer = ""
            }
        }
        if !buffer.isEmpty { result.append(Sentence(text: buffer, range: NSRange(location: offset, length: buffer.utf16.count))) }
        return result
    }
}
public struct SentenceCheckResult {
    public let edits: [Suggestion]
    public let unclear: Bool
}
public struct SentenceCache {
    private var storage: [String: SentenceCheckResult] = [:]
    public init() {}
    private func key(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    public func result(for text: String) -> SentenceCheckResult? { storage[key(text)] }
    public func edits(for text: String) -> [Suggestion]? { result(for: text)?.edits }
    public mutating func store(_ edits: [Suggestion], for text: String, unclear: Bool = false) {
        if storage.count >= 500 { storage.removeAll() }; storage[key(text)] = SentenceCheckResult(edits: edits, unclear: unclear)
    }
    /// Marks every sentence of already-polished text as final so it is never sent again.
    public mutating func settle(_ text: String) {
        store([], for: text)
        for sentence in Sentence.split(text) where !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { store([], for: sentence.text) }
    }
}
public struct LocatedSuggestion: Identifiable {
    public var edit: Suggestion
    public let sentence: String
    public var id: UUID { edit.id }
    public init(edit: Suggestion, sentence: String) { self.edit = edit; self.sentence = sentence }
}
public struct SuggestionSession {
    public private(set) var suggestions: [LocatedSuggestion] = []
    public private(set) var text = ""
    private var ignored = Set<String>()
    private var expired: [LocatedSuggestion] = []
    public init() {}
    public mutating func set(_ edits: [Suggestion], text: String, sentence: String, offset: Int) {
        self.text = text
        for var edit in edits {
            edit.range.location += offset
            if edit.matches(text) && !isIgnored(edit, sentence: sentence) {
                suggestions.append(LocatedSuggestion(edit: edit, sentence: sentence))
            }
        }
    }
    public mutating func replaceSuggestions() { suggestions.removeAll() }
    public mutating func reconcile(_ updated: String) {
        guard !updated.utf16.elementsEqual(text.utf16) else { return }
        suggestions = suggestions.compactMap { item in
            guard let moved = item.edit.relocated(from: text, to: updated) else { expired.append(item); return nil }
            return LocatedSuggestion(edit: moved, sentence: item.sentence)
        }
        text = updated
    }
    public mutating func didAccept(_ accepted: Suggestion, updated: String) {
        let delta = accepted.replacement.utf16.count - accepted.range.length
        suggestions = suggestions.compactMap { item in
            var moved = item
            if moved.edit.range.location >= NSMaxRange(accepted.range) { moved.edit.range.location += delta }
            return moved.edit.matches(updated) ? moved : nil
        }
        text = updated
    }
    public mutating func drainExpired() -> [LocatedSuggestion] { defer { expired.removeAll() }; return expired }
    public mutating func remove(_ id: UUID) { suggestions.removeAll { $0.id == id } }
    private func key(_ edit: Suggestion, _ sentence: String) -> String { [sentence, edit.original, edit.replacement, edit.kind.rawValue].joined(separator: "\u{0}") }
    public mutating func ignore(_ edit: Suggestion, sentence: String) { ignored.insert(key(edit, sentence)) }
    public func isIgnored(_ edit: Suggestion, sentence: String) -> Bool { ignored.contains(key(edit, sentence)) }
}
public struct SuggestionEvent: Encodable {
    public enum Action: String, Encodable { case accept, ignore, expired, hidden }
    public let ts: String, app_bundle_id: String, sentence: String, original: String, replacement: String
    public let kind: SuggestionKind, action: Action, level: Strictness, model: String
    public init(appBundleID: String, sentence: String, suggestion: Suggestion, action: Action, level: Strictness, model: String) {
        ts = ISO8601DateFormatter().string(from: Date()); app_bundle_id = appBundleID; self.sentence = sentence
        original = suggestion.original; replacement = suggestion.replacement; kind = suggestion.kind
        self.action = action; self.level = level; self.model = model
    }
}
@MainActor public final class SuggestionDebouncer {
    private var delay: UInt64
    private var task: Task<Void, Never>?
    public init(delay: UInt64 = 1_500_000_000) { self.delay = delay }
    public func setDelay(seconds: Double) { delay = UInt64(min(3, max(0.5, seconds.isFinite ? seconds : 1.5)) * 1_000_000_000) }
    public func cancel() { task?.cancel(); task = nil }
    public func schedule(_ action: @escaping @MainActor () async -> Void) {
        cancel(); let delay = delay
        task = Task { do { try await Task.sleep(nanoseconds: delay); try Task.checkCancellation(); await action() } catch {} }
    }
}

/// The same validated snapshot drives the preview and a single safe write.
public struct SuggestionPreview: Equatable {
    public let source: String
    public let output: String
    public init?(source: String, edits: [Suggestion]) {
        guard !edits.isEmpty else { return nil }
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        var end = 0
        for edit in sorted {
            guard edit.matches(source), edit.range.location >= end else { return nil }
            end = NSMaxRange(edit.range)
        }
        var output = source
        for edit in sorted.reversed() { output = (output as NSString).replacingCharacters(in: edit.range, with: edit.replacement) }
        var segments: [Segment] = []
        let changedRanges = Set(PolishTextComparison.insertedRanges(source: source, output: output).map(\.location))
        var offset = 0
        for character in output {
            let value = String(character)
            let changed = changedRanges.contains(offset)
            offset += value.utf16.count
            if let last = segments.last, last.changed == changed { segments[segments.count - 1].text += value }
            else { segments.append(Segment(text: value, changed: changed)) }
        }
        self.source = source; self.output = output; self.segments = segments
    }
    /// Automatic previews are reserved for atomic full-field rewrites.
    public static func wholeRewrite(source: String, edits: [Suggestion]) -> SuggestionPreview? {
        guard edits.contains(where: { [.fluency, .order].contains($0.kind) && $0.original == source && $0.range == NSRange(location: 0, length: source.utf16.count) }) else { return nil }
        return SuggestionPreview(source: source, edits: edits)
    }
    /// Final text split into unchanged and rewritten runs; deletions are not shown.
    public struct Segment: Equatable { public var text: String; public let changed: Bool }
    public let segments: [Segment]
}

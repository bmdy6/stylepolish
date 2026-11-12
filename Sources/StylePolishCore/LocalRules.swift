import Foundation

/// Deterministic, offline checks. All offsets use NSString/UTF-16 like Suggestion.
public enum LocalRules {
    public static let typos: [String: String] = {
        // SwiftPM tests/CLI use the resource bundle; packaged apps use Resources.
        let url = Bundle.main.url(forResource: "local-typos", withExtension: "json")
            ?? Bundle.module.url(forResource: "local-typos", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let pairs = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return pairs
    }()
    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static func alternatives(_ values: [String]) -> String {
        values.sorted { $0.utf16.count == $1.utf16.count ? $0 < $1 : $0.utf16.count > $1.utf16.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    }
    private static let typoPattern = regex(alternatives(Array(typos.keys)))
    private static let particles = regex("[的了是在我你他她和就也都把被给]{2,}")
    private static let words = regex("(然后|就是|那个|这个|因为|所以|但是|可以|我们|已经)(?:\\1)+")
    private static let punctuation = regex("，{2,}|；{2,}|：{2,}|、{2,}|(?<!。)。{2}(?!。)")
    private static let comma = regex("(?<=[\\p{Han}]),(?=[\\p{Han}])")
    // Deliberately narrow discourse templates. Unknown uses stay untouched rather
    // than treating every occurrence of a common Chinese word as dispensable.
    private static let fillers = regex("就是|其实|然后|的话|那个")
    private static let vagueEndings = regex("(?:啥的|什么的|之类的)(?=[。！？!?；;\\s]*$|[。！？!?；;])")
    private static let unpunctuated = regex("[^\\p{P}\\p{S}\\r\\n]+")
    private static let han = regex("\\p{Han}")
    private static let sentenceBoundary = regex("[。！？!?；;\\r\\n]")
    private static let clauseBoundary = regex("[，,。！？!?；;：:\\r\\n]")
    private static let conditional = regex("如果|要是|假如|假使|倘若")
    private static let topic = regex("(?:今天|明天|后天|现在|这(?:个|件)(?:接口|功能|方案|问题|需求|事情|事))$")
    private static func isFiller(_ word: String, before: String, after: String) -> Bool {
        let ns = before as NSString
        let sentenceStart = sentenceBoundary.matches(in: before, range: NSRange(location: 0, length: ns.length)).last.map { NSMaxRange($0.range) } ?? 0
        let sentence = ns.substring(from: sentenceStart)
        let clauseStart = clauseBoundary.matches(in: before, range: NSRange(location: 0, length: ns.length)).last.map { NSMaxRange($0.range) } ?? 0
        let clause = ns.substring(from: clauseStart).trimmingCharacters(in: .whitespaces)
        switch word {
        case "然后":
            // Only a discourse-leading 然后 is removed. Any preceding sentence
            // context may describe a real sequence, even without an explicit 先.
            return before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ["我觉得", "我想", "我们觉得", "我已经", "那个文件我已经", "这个方案我觉得"].contains(where: after.hasPrefix)
        case "的话":
            guard conditional.firstMatch(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length)) == nil else { return false }
            return topic.firstMatch(in: clause, range: NSRange(location: 0, length: (clause as NSString).length)) != nil
        case "那个":
            // Never remove a demonstrative directly before a noun. Only the
            // explicit hesitation between a subject and a temporal/mental phrase.
            return ["我", "我们", "你", "你们", "他", "她"].contains(clause)
                && ["昨天", "今天", "明天", "刚才", "本来", "觉得", "想说"].contains(where: after.hasPrefix)
        case "就是":
            if clause.isEmpty { return ["我觉得", "我们觉得", "我想", "我认为"].contains(where: after.hasPrefix) }
            return (["我", "我们"].contains(where: clause.hasSuffix) && after.hasPrefix("说"))
                || (["我那个昨天", "我昨天", "我今天"].contains(clause) && after.hasPrefix("去"))
        case "其实":
            return (clause.isEmpty && ["我想说的是", "我觉得", "我认为"].contains(where: after.hasPrefix))
                || (!clause.isEmpty && ["还可以", "有点"].contains(where: after.hasPrefix))
        default: return false
        }
    }
    // Literal examples and code often discuss a misspelling rather than use it.
    private static let naturalRepeats = regex("的的确|是是非非|卿卿我我|和和气气|和和美美|你你我我")
    private static let literals = regex("「[^」]*」|『[^』]*』|“[^”]*”|\"[^\"]*\"|`[^`]*`")
    // 因｜该 is valid at the start of a causal phrase (因该设备故障…).
    // Only offer this ambiguous spelling after a standalone personal pronoun.
    private static let typoSubjects: Set<String> = ["我", "你", "您", "他", "她", "它", "我们", "你们", "他们", "她们", "它们", "咱们"]

    public static func check(_ text: String, level: Strictness, aliases: [String: String] = [:], personalTypos: [String: String] = [:]) -> [Suggestion] {
        let ns = text as NSString, full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0 else { return [] }
        let protected = (literals.matches(in: text, range: full) + naturalRepeats.matches(in: text, range: full)).map(\.range)
        var result: [Suggestion] = []
        func add(_ range: NSRange, _ replacement: String, _ kind: SuggestionKind, _ why: String) {
            let original = ns.substring(with: range)
            guard original != replacement, !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                  !result.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
            result.append(Suggestion(range: range, original: original, replacement: replacement, kind: kind, why: why))
        }
        // Explicit personal aliases take priority; longer matches win deterministically.
        for key in aliases.keys.filter({ !$0.isEmpty }).sorted(by: { $0.utf16.count == $1.utf16.count ? $0 < $1 : $0.utf16.count > $1.utf16.count }) {
            var start = 0
            while start < ns.length {
                let range = ns.range(of: key, options: .literal, range: NSRange(location: start, length: ns.length - start))
                guard range.location != NSNotFound else { break }
                add(range, aliases[key]!, .typo, "个人词表别名")
                start = NSMaxRange(range)
            }
        }
        // Tokenize once for the whole built-in dictionary, including legacy and
        // multiword entries. A spelling may span words, but must not split one.
        // Use UTF-16 offsets, matching regex ranges and Suggestion coordinates.
        var wordBoundaries = Set<Int>()
        var subjectEnds = Set<Int>()
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            let utf16 = NSRange(range, in: text)
            wordBoundaries.insert(utf16.location)
            wordBoundaries.insert(NSMaxRange(utf16))
            if let word, typoSubjects.contains(word) { subjectEnds.insert(NSMaxRange(utf16)) }
        }
        let learned = personalTypos.filter { !$0.key.isEmpty && $0.key != $0.value }
        let dictionary = typos.merging(learned) { _, personal in personal }
        let pattern = learned.isEmpty ? typoPattern : regex(alternatives(Array(dictionary.keys)))
        for match in pattern.matches(in: text, range: full) {
            guard wordBoundaries.contains(match.range.location), wordBoundaries.contains(NSMaxRange(match.range)) else { continue }
            let spelling = ns.substring(with: match.range)
            guard spelling != "因该" || subjectEnds.contains(match.range.location) else { continue }
            if let replacement = dictionary[spelling] { add(match.range, replacement, .typo, "修正常见错别字") }
        }
        for match in particles.matches(in: text, range: full) {
            // The character-class run may contain different particles: split into equal runs.
            let chars = Array(ns.substring(with: match.range)), base = match.range.location
            var i = 0
            while i < chars.count {
                var j = i + 1
                while j < chars.count && chars[j] == chars[i] { j += 1 }
                let range = NSRange(location: base + i, length: j - i)
                if range.length >= 2 {
                    let tail = ns.substring(from: NSMaxRange(range))
                    let natural = (chars[i] == "的" && tail.hasPrefix("确")) || (chars[i] == "是" && tail.hasPrefix("非非"))
                    if !natural { add(range, String(chars[i]), .typo, "去掉重复的虚词") }
                }
                i = j
            }
        }
        if level != .relaxed {
            for match in words.matches(in: text, range: full) { add(match.range, ns.substring(with: match.range(at: 1)), .filler, "去掉重复的词") }
        }
        for match in punctuation.matches(in: text, range: full) { add(match.range, String(ns.substring(with: match.range).prefix(1)), .typo, "去掉重复标点") }
        if level == .strict { for match in comma.matches(in: text, range: full) { add(match.range, "，", .typo, "中文间使用全角逗号") } }
        if level == .strict {
            for match in fillers.matches(in: text, range: full) {
                guard wordBoundaries.contains(match.range.location), wordBoundaries.contains(NSMaxRange(match.range)) else { continue }
                let word = ns.substring(with: match.range)
                if isFiller(word, before: ns.substring(to: match.range.location), after: ns.substring(from: NSMaxRange(match.range))) {
                    add(match.range, "", .filler, "去掉口头禅")
                }
            }
            for match in vagueEndings.matches(in: text, range: full) { add(match.range, "", .filler, "去掉含糊收尾") }
            for match in unpunctuated.matches(in: text, range: full) {
                let fragment = ns.substring(with: match.range)
                guard han.numberOfMatches(in: fragment, range: NSRange(location: 0, length: (fragment as NSString).length)) > 25,
                      !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                // Advice may overlap a concrete typo/filler. It never participates
                // in replacement or blocks a safe concrete edit in the same span.
                result.append(Suggestion(range: match.range, original: fragment, replacement: fragment, kind: .fluency, why: "这句较长，可以断开", canApply: false))
            }
        }
        return result.sorted { $0.range.location == $1.range.location ? $0.range.length < $1.range.length : $0.range.location < $1.range.location }
    }
}

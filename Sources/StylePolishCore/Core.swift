import Foundation

public func postprocess(_ text: String) -> String {
    var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.last == "。" || result.last == "." { result.removeLast() }
    return result
}

/// Product boundary shared by automatic checks, shortcuts and diagnostics.
public enum SupportedApps {
    public static let wechat = "com.tencent.xinWeChat"
    public static let all = [wechat]
    public static func contains(_ bundleID: String?) -> Bool { bundleID == wechat }
}

public struct FocusSnapshot: Equatable {
    public let pid: Int32
    public let element: String
    public let text: String
    public let selection: NSRange?
    public init(pid: Int32, element: String, text: String, selection: NSRange?) {
        self.pid = pid; self.element = element; self.text = text; self.selection = selection
    }
    // UTF-16 offsets are valid only for the exact captured code-unit sequence.
    public static func == (lhs: FocusSnapshot, rhs: FocusSnapshot) -> Bool {
        lhs.pid == rhs.pid && lhs.element == rhs.element && lhs.selection == rhs.selection
            && lhs.text.utf16.elementsEqual(rhs.text.utf16)
    }
}
public protocol FocusProviding { func currentFocus() -> FocusSnapshot? }
public enum WriteGuard {
    public static func canWrite(_ original: FocusSnapshot, provider: FocusProviding) -> Bool {
        provider.currentFocus() == original
    }
}

public struct CharacterDiff {
    public enum Kind { case equal, insert, delete }
    public struct Part { public let kind: Kind; public var text: String }
    public let parts: [Part]
    public var changeCount: Int {
        var count = 0, changing = false
        for part in parts {
            if part.kind == .equal { changing = false }
            else if !changing { count += 1; changing = true }
        }
        return count
    }
    public init(_ before: String, _ after: String) {
        // Swift's CollectionDifference uses Myers. Character elements retain grapheme clusters.
        let old = Array(before), new = Array(after)
        let difference = new.difference(from: old, by: { String($0).utf16.elementsEqual(String($1).utf16) })
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Part] = [], i = 0, j = 0
        func add(_ kind: Kind, _ char: Character) {
            if result.last?.kind == kind { result[result.count - 1].text.append(char) }
            else { result.append(Part(kind: kind, text: String(char))) }
        }
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) { add(.delete, old[i]); i += 1 }
            else if j < new.count, inserted.contains(j) { add(.insert, new[j]); j += 1 }
            else if i < old.count, j < new.count { add(.equal, old[i]); i += 1; j += 1 }
            else { break }
        }
        parts = result
    }
}

public struct HistoryEntry: Encodable {
    public enum Action: String, Encodable { case accept, edit, cancel }
    let ts: String, appBundleID: String, input: String, output: String
    let final: String?
    let action: Action
    let model: String
    let latencyMS: Int
    enum CodingKeys: String, CodingKey {
        case ts, input, output, final, action, model
        case appBundleID = "app_bundle_id", latencyMS = "latency_ms"
    }
    public init(appBundleID: String, input: String, output: String, final: String?, action: Action, model: String, latencyMS: Int) {
        ts = ISO8601DateFormatter().string(from: Date()); self.appBundleID = appBundleID
        self.input = input; self.output = output; self.final = final; self.action = action
        self.model = model; self.latencyMS = latencyMS
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts); try c.encode(appBundleID, forKey: .appBundleID)
        try c.encode(input, forKey: .input); try c.encode(output, forKey: .output)
        if let final { try c.encode(final, forKey: .final) } else { try c.encodeNil(forKey: .final) }
        try c.encode(action, forKey: .action); try c.encode(model, forKey: .model); try c.encode(latencyMS, forKey: .latencyMS)
    }
}
public final class HistoryStore {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("history.jsonl") }
    public var overridesFile: URL { directory.appendingPathComponent("habits-overrides.json") }
    public private(set) var habits = HabitProfile()
    public var habitsChanged: (() -> Void)?
    public init(directory: URL = RuntimeStorage.history) {
        self.directory = directory
        // One startup scan, tolerant of mixed v1/v2 and damaged rows.
        if let data = try? Data(contentsOf: file) {
            for line in data.split(separator: 0x0A) { habits.ingest(line: Data(line)) }
        }
        if let data = try? Data(contentsOf: overridesFile), let ids = try? JSONDecoder().decode(Set<String>.self, from: data) { habits.excludedIDs = ids }
    }
    public func setHabit(_ id: String, deleted: Bool) throws {
        var ids = habits.excludedIDs
        if deleted { ids.insert(id) } else { ids.remove(id) }
        try prepare()
        // Set permissions on the staging file before atomic replacement; no public-readable interval.
        let temporary = directory.appendingPathComponent(".habits-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(ids), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: overridesFile.path, isDirectory: &isDirectory), isDirectory.boolValue { throw CocoaError(.fileWriteInvalidFileName) }
        if FileManager.default.fileExists(atPath: overridesFile.path) { _ = try FileManager.default.replaceItemAt(overridesFile, withItemAt: temporary, options: .usingNewMetadataOnly) }
        else { try FileManager.default.moveItem(at: temporary, to: overridesFile) }
        habits.excludedIDs = ids; habitsChanged?()
    }
    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func append<Entry: Encodable>(_ entry: Entry) throws {
        try prepare()
        var data = try JSONEncoder().encode(entry); data.append(0x0A)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
        if let event = entry as? SuggestionEvent {
            habits.ingest(event)
            if event.action == .accept || event.action == .ignore { habitsChanged?() }
        }
    }
    public func clear() throws {
        try prepare(); let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        defer { habits = HabitProfile(); habitsChanged?() }
        if FileManager.default.fileExists(atPath: overridesFile.path) { try FileManager.default.removeItem(at: overridesFile) }
    }
}

public struct SSEParser {
    public private(set) var isDone = false
    public init() {}
    public mutating func consume(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" { isDone = true; return nil }
        return try parseContent(data)
    }
    public func parseContent(_ text: String) throws -> String? {
        struct Chunk: Decodable {
            struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta }
            let choices: [Choice]
        }
        return try JSONDecoder().decode(Chunk.self, from: Data(text.utf8)).choices.first?.delta.content
    }
}

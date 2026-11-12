import Foundation
import StylePolishCore

// Body fields are removed centrally unless local debug logging is explicitly enabled.
struct DiagnosticEvent: Codable {
    var ts = Date()
    var event: String
    var bundleID: String
    var role: String? = nil
    var textLength: Int? = nil
    var readable: Bool? = nil
    var hasPosition: Bool? = nil
    var hasAttachment: Bool? = nil
    var attachmentEvidenceComplete: Bool? = nil
    var writeMethod: String? = nil
    var axAttribute: String? = nil
    var axResult: Int32? = nil
    var traceID: String? = nil
    var debounceMS: Int? = nil
    var requestMS: Int? = nil
    var resultMS: Int? = nil
    var suggestionCount: Int? = nil
    var previewKind: String? = nil
    var insertedChars: Int? = nil
    var deletedChars: Int? = nil
    var previewMode: String? = nil
    var firstTokenMS: Int? = nil
    var completionTokens: Int? = nil
    var reasoningTokens: Int? = nil
    var error: String? = nil
    var httpStatus: Int? = nil
    var errorCode: String? = nil
    var parameter: String? = nil
    var engine: String? = nil
    var fallback: FallbackReason? = nil

    var writable: Bool? = nil
    var selectionLocation: Int? = nil
    var selectionLength: Int? = nil
    var level: String? = nil
    var cacheHit: Bool? = nil
    var model: String? = nil
    var promptTokens: Int? = nil
    var totalTokens: Int? = nil
    var kindCounts: [String: Int]? = nil
    var wholeRewrite: Bool? = nil
    var unclear: Bool? = nil
    var indicatorState: String? = nil
    var presentation: String? = nil
    var action: String? = nil
    var beforeLength: Int? = nil
    var afterLength: Int? = nil
    var expectedLength: Int? = nil
    var readbackMatches: Bool? = nil
    var version: String? = nil
    var commit: String? = nil
    var signing: String? = nil
    var installationPath: String? = nil
    var macOS: String? = nil
    var translocated: Bool? = nil
    var trusted: Bool? = nil
    var previousTrusted: Bool? = nil
    var debugEnabled: Bool? = nil
    var setting: String? = nil
    var credentialSource: String? = nil
    var keySuffix: String? = nil
    var step: Int? = nil
    var source: String? = nil
    var modelResponse: String? = nil
    var output: String? = nil

    func includingPreview(source: String, suggestions: [Suggestion]) -> DiagnosticEvent {
        var event = self
        let preview = SuggestionPreview(source: source, edits: suggestions)
        event.suggestionCount = suggestions.count
        event.previewKind = preview == nil ? "none" : (SuggestionPreview.wholeRewrite(source: source, edits: suggestions) == nil ? "inline" : "whole")
        event.insertedChars = preview?.insertedChars ?? 0
        event.deletedChars = preview?.deletedChars ?? 0
        event.previewMode = preview?.mode.rawValue ?? "diff"
        return event
    }
}
final class Diagnostics {
    static let shared = Diagnostics()
    let directory: URL
    var url: URL { directory.appendingPathComponent("diagnostics.jsonl") }
    private let queue = DispatchQueue(label: "org.bmdy6.StylePolish.diagnostics")
    private var debug = false
    private var secrets = Set<String>()
    private var permission: Bool?
    private let maxFileBytes: Int
    init(directory: URL = RuntimeStorage.logs, maxFileBytes: Int = 5 * 1024 * 1024) {
        self.directory = directory; self.maxFileBytes = maxFileBytes
    }
    func configure(debug: Bool, secrets: [String]) {
        queue.sync { self.debug = debug; self.secrets.formUnion(secrets.filter { !$0.isEmpty }) }
    }
    func permissionChanged(_ trusted: Bool) {
        queue.sync {
            defer { permission = trusted }
            guard let previous = permission, previous != trusted else { return }
            var event = DiagnosticEvent(event: "permission_changed", bundleID: "org.bmdy6.StylePolish")
            event.trusted = trusted; event.previousTrusted = previous
            append(event)
        }
    }
    func record(_ event: DiagnosticEvent) { queue.async { self.append(event) } }
    private func redacted(_ value: String) -> String {
        secrets.sorted { $0.count > $1.count }.reduce(value) { $0.replacingOccurrences(of: $1, with: "[REDACTED]") }
    }
    private func append(_ original: DiagnosticEvent) {
        do {
            var event = original
            if !debug { event.source = nil; event.modelResponse = nil; event.output = nil }
            let bodyLimit = min(100_000, maxFileBytes / 12)
            event.source = event.source.map { String(redacted($0).prefix(bodyLimit)) }
            event.modelResponse = event.modelResponse.map { String(redacted($0).prefix(bodyLimit)) }
            event.output = event.output.map { String(redacted($0).prefix(bodyLimit)) }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let object = try JSONSerialization.jsonObject(with: encoder.encode(event))
            func scrub(_ value: Any) -> Any {
                if let string = value as? String { return redacted(string) }
                if let list = value as? [Any] { return list.map(scrub) }
                if let map = value as? [String: Any] { return map.mapValues(scrub) }
                return value
            }
            var data = try JSONSerialization.data(withJSONObject: scrub(object), options: [.sortedKeys]); data.append(10)
            guard data.count <= maxFileBytes else { return }
            try prepare()
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > maxFileBytes { try rotate() }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } catch { NSLog("StylePolish diagnostics write failed") }
    }
    private func archive(_ index: Int) -> URL { directory.appendingPathComponent("diagnostics.\(index).jsonl") }
    private func rotate() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: archive(4).path) { try fm.removeItem(at: archive(4)) }
        for index in stride(from: 3, through: 0, by: -1) {
            let source = index == 0 ? url : archive(index)
            if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: archive(index + 1)) }
        }
        try prepare()
    }
    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Queue-consistent snapshot of diagnostics and an explicitly Key-free summary only.
    func export(to destination: URL, summary: [String: String]) throws -> URL {
        try queue.sync {
            try prepare()
            let fm = FileManager.default
            let temporary = fm.temporaryDirectory.appendingPathComponent("StylePolish-diagnostics-" + UUID().uuidString)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: temporary) }
            for file in [url] + (1...4).map(archive) where fm.fileExists(atPath: file.path) {
                let contents = redacted(try String(contentsOf: file, encoding: .utf8))
                let copy = temporary.appendingPathComponent(file.lastPathComponent)
                try Data(contents.utf8).write(to: copy)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            }
            let summaryURL = temporary.appendingPathComponent("summary.json")
            try JSONSerialization.data(withJSONObject: summary.mapValues(redacted), options: [.prettyPrinted, .sortedKeys]).write(to: summaryURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: summaryURL.path)
            let zip = destination.appendingPathComponent(temporary.lastPathComponent + ".zip")
            guard fm.createFile(atPath: zip.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", temporary.path, zip.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do {
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zip.path)
                return zip
            } catch { try? fm.removeItem(at: zip); throw error }
        }
    }
    func flush() { queue.sync {} }
}

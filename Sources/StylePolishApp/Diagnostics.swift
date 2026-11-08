import Foundation

// Typed, content-free schema. Never accepts field text, credentials, URLs or server bodies.
struct DiagnosticEvent: Codable {
    var ts = Date()
    var event: String
    var bundleID: String
    var role: String? = nil
    var textLength: Int? = nil
    var readable: Bool? = nil
    var hasPosition: Bool? = nil
    var axAttribute: String? = nil
    var axResult: Int32? = nil
    var traceID: String? = nil
    var debounceMS: Int? = nil
    var requestMS: Int? = nil
    var resultMS: Int? = nil
    var firstTokenMS: Int? = nil
    var completionTokens: Int? = nil
    var reasoningTokens: Int? = nil
    var error: String? = nil
    var httpStatus: Int? = nil
    var errorCode: String? = nil
    var parameter: String? = nil
}
final class Diagnostics {
    static let shared = Diagnostics()
    let directory: URL
    var url: URL { directory.appendingPathComponent("diagnostics.jsonl") }
    private let queue = DispatchQueue(label: "org.bmdy6.StylePolish.diagnostics")
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StylePolish")) { self.directory = directory }
    func record(_ event: DiagnosticEvent) {
        queue.async { [self] in
            do {
                try prepare()
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                var data = try encoder.encode(event); data.append(10)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            } catch { NSLog("StylePolish diagnostics write failed") }
        }
    }
    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func flush() { queue.sync {} }
}

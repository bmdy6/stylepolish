import Foundation

public struct SupportedApp: Codable, Equatable, Identifiable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    public var verified: Bool
    public var enabledByDefault: Bool
    public var axActivation: String?
    public var clipboardWhole: Bool
    /// Reserved for future per-app options; no behavior consumes these values yet.
    public var extensions: [String: String]?
    public var enabled: Bool?
    public var removed: Bool?
    public var isEnabled: Bool { removed != true && (enabled ?? enabledByDefault) }
}

/// One policy shared by capture, keyboard dispatch, writeback and settings.
/// User JSON is an array of partial entries, merged by exact, case-sensitive bundle ID.
public final class SupportedApps {
    public static let wechat = "com.tencent.xinWeChat"
    private static let builtIn: [SupportedApp] = {
        let url = Bundle.main.url(forResource: "apps", withExtension: "json")
            ?? Bundle.module.url(forResource: "apps", withExtension: "json")!
        // A malformed shipped resource is a build error, not a user configuration error.
        return try! JSONDecoder().decode([SupportedApp].self, from: Data(contentsOf: url))
    }()
    public let file: URL
    private let defaults: [SupportedApp]
    private var values: [SupportedApp]
    public var entries: [SupportedApp] { values.filter { $0.removed != true } }
    public var enabledBundleIDs: [String] { values.filter(\.isEnabled).map(\.bundleID) }
    public func app(_ bundleID: String?) -> SupportedApp? { values.first { $0.bundleID == bundleID && $0.removed != true } }
    public func isEnabled(_ bundleID: String?) -> Bool { app(bundleID)?.isEnabled == true }

    public convenience init(home: URL = RuntimeStorage.home, diagnostic: (String) -> Void = { _ in }) {
        self.init(home: home, builtIn: Self.builtIn, diagnostic: diagnostic)
    }
    init(home: URL, builtIn: [SupportedApp], diagnostic: (String) -> Void = { _ in }) {
        defaults = builtIn
        values = builtIn
        let url = home.appendingPathComponent(".config/stylepolish/apps.json")
        file = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            values = try Self.merged(Data(contentsOf: url), builtIn: builtIn)
        } catch { diagnostic("invalid_app_configuration") }
    }
    private static func merged(_ data: Data, builtIn: [SupportedApp]) throws -> [SupportedApp] {
        guard let overrides = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ConfigurationError.invalid }
        let allowed: Set<String> = ["bundleID", "name", "verified", "enabledByDefault", "axActivation", "clipboardWhole", "extensions", "enabled", "removed"]
        var result = builtIn
        var seen = Set<String>()
        for override in overrides {
            guard Set(override.keys).isSubset(of: allowed), let id = override["bundleID"] as? String,
                  !id.isEmpty, !id.contains(where: { $0.isWhitespace }), seen.insert(id).inserted else { throw ConfigurationError.invalid }
            let index = result.firstIndex { $0.bundleID == id }
            let base = index.map { result[$0] } ?? SupportedApp(bundleID: id, name: id, verified: false, enabledByDefault: false, clipboardWhole: false)
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
            object.merge(override) { _, new in new }
            let entry = try JSONDecoder().decode(SupportedApp.self, from: JSONSerialization.data(withJSONObject: object))
            guard !entry.name.isEmpty else { throw ConfigurationError.invalid }
            if let index { result[index] = entry } else { result.append(entry) }
        }
        return result
    }
    public func setEnabled(_ bundleID: String, enabled: Bool) throws {
        guard let index = values.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        var next = values; next[index].enabled = enabled; next[index].removed = false
        try save(next)
    }
    public func remove(_ bundleID: String) throws {
        guard let index = values.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        var next = values; next[index].removed = true; next[index].enabled = false
        try save(next)
    }
    public func add(bundleID: String, name: String) throws {
        guard !bundleID.isEmpty, !bundleID.contains(where: { $0.isWhitespace }) else { throw ConfigurationError.invalid }
        var next = values
        if let index = next.firstIndex(where: { $0.bundleID == bundleID }) {
            next[index].removed = false; next[index].enabled = true
        } else {
            next.append(SupportedApp(bundleID: bundleID, name: name.isEmpty ? bundleID : name, verified: false, enabledByDefault: false, clipboardWhole: false, enabled: true))
        }
        try save(next)
    }
    private func save(_ next: [SupportedApp]) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var objects: [[String: Any]] = []
        for entry in next {
            var object = try Self.object(entry)
            if let base = defaults.first(where: { $0.bundleID == entry.bundleID }) {
                // Keep only user differences so future shipped policy changes still apply.
                let original = try Self.object(base)
                object = object.filter { key, value in
                    key == "bundleID" || (value as? NSObject)?.isEqual(original[key]) != true
                }
                // UI actions clear the tombstone; false need not override an absent one.
                if entry.removed == false && base.removed != true { object.removeValue(forKey: "removed") }
                guard object.count > 1 else { continue }
            }
            objects.append(object)
        }
        try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        values = next
    }
    private static func object(_ entry: SupportedApp) throws -> [String: Any] {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        // JSONEncoder omits nil; explicit null must survive for optional policy fields.
        if entry.axActivation == nil { object["axActivation"] = NSNull() }
        if entry.extensions == nil { object["extensions"] = NSNull() }
        return object
    }
    private enum ConfigurationError: Error { case invalid }
}

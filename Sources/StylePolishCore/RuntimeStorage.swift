import Foundation

/// Resolve sandbox paths before any singleton or AppController is constructed.
/// XCTest and developer harnesses must never inherit the running user's state.
public enum RuntimeStorage {
    public static let isolated: Bool = {
        let args = CommandLine.arguments
        return args.first?.contains(".xctest") == true
            || NSClassFromString("XCTestCase") != nil
            || args.dropFirst().contains { $0.contains("harness") || $0.hasPrefix("--render-") || ["--capture-fixtures", "--latency-editor"].contains($0) }
    }()
    public static let root = FileManager.default.temporaryDirectory.appendingPathComponent("StylePolish-isolated-" + UUID().uuidString)
    public static var home: URL { isolated ? root : FileManager.default.homeDirectoryForCurrentUser }
    public static var logs: URL { isolated ? root.appendingPathComponent("logs") : home.appendingPathComponent("Library/Logs/StylePolish") }
    public static var history: URL { isolated ? root.appendingPathComponent("history") : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StylePolish") }
    public static let defaults: UserDefaults = isolated ? MemoryDefaults() : .standard
}

/// No preferences daemon or persistent domain is used by default in test/harness processes.
public final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private let lock = NSRecursiveLock()
    public init() { super.init(suiteName: "StylePolish-memory-" + UUID().uuidString)! }
    public override func object(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public override func set(_ value: Any?, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
    public override func removeObject(forKey key: String) { set(nil, forKey: key) }
    public override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    public override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    public override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    public override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    public override func removePersistentDomain(forName domainName: String) { lock.lock(); defer { lock.unlock() }; values.removeAll() }
    public override func dictionaryRepresentation() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return values }
}

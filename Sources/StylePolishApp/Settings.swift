import SwiftUI
import StylePolishCore
import AppKit

final class SettingsStore: ObservableObject {
    @Published var pauseSeconds: Double { didSet {
        let bounded = Self.boundedPause(pauseSeconds)
        if pauseSeconds != bounded { pauseSeconds = bounded }
        save()
    } }
    static func boundedPause(_ value: Double) -> Double { value.isFinite ? min(3, max(0.5, value)) : 1.5 }
    @Published var base: String { didSet { save() } }
    @Published var serviceTier: String { didSet { save() } }
    @Published var model: String { didSet { save() } }
    @Published var profile: String { didSet { save() } }
    @Published var apps: [String] { didSet { save() } }
    @Published var level: Strictness { didSet { save() } }
    @Published var legacyShortcut: Bool { didSet { save() } }
    @Published var disabledKindsByLevel: [String: [String]] { didSet { save() } }
    @Published private var credentialRevision = 0
    func credentialsChanged() { credentialRevision += 1 }
    var disabledKinds: [String] {
        get { disabledKindsByLevel[level.rawValue] ?? [] }
        set { disabledKindsByLevel[level.rawValue] = newValue }
    }
    let credentials: CredentialStore
    @Published var vaultKeyName: String { didSet { defaults.set(vaultKeyName, forKey: "vaultKeyName") } }
    func reloadCredentials() { credentials.reload(keyName: vaultKeyName); credentialsChanged() }
    func saveKey(_ key: String) throws { try credentials.saveLocal(key, keyName: vaultKeyName); credentialsChanged() }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard, credentialHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        let name = defaults.string(forKey: "vaultKeyName") ?? "OPENAI_PLATFORM_API_KEY"
        vaultKeyName = name
        credentials = CredentialStore(home: credentialHome, keyName: name)
        pauseSeconds = Self.boundedPause(defaults.object(forKey: "pauseSeconds") as? Double ?? 1.5)
        base = defaults.string(forKey: "base") ?? "https://api.openai.com/v1"
        serviceTier = defaults.string(forKey: "serviceTier") ?? "priority"
        model = defaults.string(forKey: "model") ?? "gpt-6-luna"
        profile = defaults.string(forKey: "profile") ?? ""
        level = Strictness(rawValue: defaults.string(forKey: "strictness") ?? "") ?? .standard
        legacyShortcut = defaults.bool(forKey: "legacyShortcut")
        disabledKindsByLevel = defaults.dictionary(forKey: "disabledKindsByLevel") as? [String: [String]] ?? [:]
        apps = defaults.stringArray(forKey: "apps") ?? ["com.tencent.xinWeChat", "com.tencent.qq", "com.electron.lark", "com.anthropic.claudefordesktop", "com.linear"]
    }
    private func save() {
        defaults.set(pauseSeconds, forKey: "pauseSeconds")
        defaults.set(level.rawValue, forKey: "strictness"); defaults.set(legacyShortcut, forKey: "legacyShortcut")
        defaults.set(disabledKindsByLevel, forKey: "disabledKindsByLevel")
        defaults.set(serviceTier, forKey: "serviceTier")
        defaults.set(base, forKey: "base"); defaults.set(model, forKey: "model")
        defaults.set(profile, forKey: "profile"); defaults.set(apps, forKey: "apps")
    }
}

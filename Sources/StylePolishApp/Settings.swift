import SwiftUI
import StylePolishCore
import AppKit

final class SettingsStore: ObservableObject {
    private var initialized = false
    private var normalizingPause = false
    let history: HistoryStore
    @Published private(set) var habitRevision = 0
    @Published var habitsEnabled: Bool { didSet {
        guard initialized, habitsEnabled != oldValue else { return }
        defaults.set(habitsEnabled, forKey: "habitsEnabled"); changed("habitsEnabled")
    } }
    var effectiveHabits: HabitProfile { history.habits.effective(enabled: habitsEnabled) }
    let invite: InviteAccess
    @Published var relayBase: String { didSet {
        guard initialized, relayBase != oldValue else { return }
        defaults.set(relayBase, forKey: "relayBase"); invite.resetVerification(); changed("relayBase")
    } }
    let diagnostics: Diagnostics
    @Published var debugMode: Bool { didSet { guard initialized, debugMode != oldValue else { return }; syncDiagnostics(); defaults.set(debugMode, forKey: "debugMode"); changed("debugMode") } }
    @Published var onboarded: Bool { didSet { guard initialized, onboarded != oldValue else { return }; defaults.set(onboarded, forKey: "onboarded"); changed("onboarded") } }
    @Published var engine: PolishEngine { didSet { guard initialized else { return }; save("engine", recordChange: engine != oldValue) } }
    @Published var pauseSeconds: Double { didSet {
        guard initialized, !normalizingPause else { return }
        let previous = oldValue
        let bounded = Self.boundedPause(pauseSeconds)
        if pauseSeconds != bounded {
            normalizingPause = true
            pauseSeconds = bounded
            normalizingPause = false
        }
        save("pauseSeconds", recordChange: bounded != previous)
    } }
    static func boundedPause(_ value: Double) -> Double { value.isFinite ? min(3, max(0.5, value)) : 1.5 }
    @Published var base: String { didSet { guard initialized, base != oldValue else { return }; save("base") } }
    @Published var serviceTier: String { didSet { guard initialized, serviceTier != oldValue else { return }; save("serviceTier") } }
    @Published var model: String { didSet { guard initialized, model != oldValue else { return }; save("model") } }
    @Published var profile: String { didSet { guard initialized, profile != oldValue else { return }; save("profile") } }
    var apps: [String] { SupportedApps.all }
    @Published var level: Strictness { didSet { guard initialized, level != oldValue else { return }; save("level") } }
    @Published var legacyShortcut: Bool { didSet { guard initialized, legacyShortcut != oldValue else { return }; save("legacyShortcut") } }
    @Published var disabledKindsByLevel: [String: [String]] { didSet { guard initialized, disabledKindsByLevel != oldValue else { return }; save("disabledKindsByLevel") } }
    @Published private var credentialRevision = 0
    func credentialsChanged() {
        syncDiagnostics(); credentialRevision += 1
        let current = credentials.current
        guard initialized else { return }
        var event = DiagnosticEvent(event: "settings_changed", bundleID: "org.bmdy6.StylePolish")
        event.setting = "credentials"; event.credentialSource = current.source.hasPrefix("ai-vault") ? "ai-vault" : current.key.isEmpty ? "missing" : "local_file"
        event.keySuffix = current.key.count > 4 ? String(current.key.suffix(4)) : nil
        diagnostics.record(event)
    }
    var disabledKinds: [String] {
        get { disabledKindsByLevel[level.rawValue] ?? [] }
        set { disabledKindsByLevel[level.rawValue] = newValue }
    }
    let credentials: CredentialStore
    @Published var vaultKeyName: String { didSet { guard initialized, vaultKeyName != oldValue else { return }; defaults.set(vaultKeyName, forKey: "vaultKeyName"); changed("vaultKeyName") } }
    func reloadCredentials() { let previous = credentials.current; credentials.reload(keyName: vaultKeyName); if credentials.current != previous { credentialsChanged() } }
    func saveKey(_ key: String) throws { let previous = credentials.current; diagnostics.configure(debug: debugMode, secrets: [key]); try credentials.saveLocal(key, keyName: vaultKeyName); if credentials.current != previous { credentialsChanged() } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = RuntimeStorage.defaults, credentialHome: URL = RuntimeStorage.home, diagnostics: Diagnostics = .shared, history: HistoryStore = HistoryStore()) {
        self.defaults = defaults; self.diagnostics = diagnostics; self.history = history
        habitsEnabled = defaults.object(forKey: "habitsEnabled") as? Bool ?? true
        invite = InviteAccess(home: credentialHome)
        relayBase = defaults.string(forKey: "relayBase") ?? InviteService.defaultBase
        debugMode = defaults.bool(forKey: "debugMode")
        onboarded = defaults.bool(forKey: "onboarded")
        let name = defaults.string(forKey: "vaultKeyName") ?? "OPENAI_PLATFORM_API_KEY"
        vaultKeyName = name
        credentials = CredentialStore(home: credentialHome, keyName: name)
        engine = PolishEngine(rawValue: defaults.string(forKey: "engine") ?? "") ?? (credentials.current.key.isEmpty ? .local : .ai)
        pauseSeconds = Self.boundedPause(defaults.object(forKey: "pauseSeconds") as? Double ?? 1.5)
        base = defaults.string(forKey: "base") ?? "https://api.openai.com/v1"
        serviceTier = defaults.string(forKey: "serviceTier") ?? "priority"
        model = defaults.string(forKey: "model") ?? "gpt-6-luna"
        profile = defaults.string(forKey: "profile") ?? ""
        level = Strictness(rawValue: defaults.string(forKey: "strictness") ?? "") ?? .standard
        legacyShortcut = defaults.bool(forKey: "legacyShortcut")
        disabledKindsByLevel = defaults.dictionary(forKey: "disabledKindsByLevel") as? [String: [String]] ?? [:]
        // Ignore historical/custom lists and persist the fixed product boundary.
        defaults.set(SupportedApps.all, forKey: "apps")
        syncDiagnostics()
        initialized = true
        history.habitsChanged = { [weak self] in self?.habitRevision += 1 }
    }
    func configureSecrets() { diagnostics.configure(debug: debugMode, secrets: [credentials.current.key, invite.code, invite.deviceID]) }
    private func syncDiagnostics() { configureSecrets() }
    func configuration(engine selected: PolishEngine? = nil) -> PolishConfiguration {
        if (selected ?? engine) == .invite {
            let endpoint = (try? InviteService.endpoint(relayBase).absoluteString) ?? relayBase
            return PolishConfiguration(base: endpoint, model: model, key: invite.code, profile: profile, serviceTier: serviceTier, level: level,
                                       inviteDeviceID: invite.deviceID, inviteBlocked: invite.block(for: relayBase), habits: effectiveHabits)
        }
        return PolishConfiguration(base: base, model: model, key: credentials.current.key, profile: profile, serviceTier: serviceTier, credentialError: credentials.current.warnings.first, level: level, habits: effectiveHabits)
    }
    @MainActor func checked(_ result: CheckResult, config: PolishConfiguration) {
        guard config.inviteDeviceID != nil, config.key == invite.code else { return }
        invite.checked(fallback: result.fallback, code: config.key, base: config.base)
        if result.fallback == .none, invite.canUse(base: relayBase) { Task { await invite.refresh(base: relayBase) } }
    }
    private func changed(_ name: String) {
        guard initialized else { return }
        var event = DiagnosticEvent(event: "settings_changed", bundleID: "org.bmdy6.StylePolish")
        event.setting = name
        if name == "debugMode" { event.debugEnabled = debugMode }
        diagnostics.record(event)
    }
    /// Deliberate allowlist: no credentials, endpoint URLs, profile contents or paths.
    var diagnosticSummary: [String: String] {
        ["engine": engine.rawValue, "level": level.rawValue, "model": model, "serviceTier": serviceTier,
         "pauseSeconds": String(pauseSeconds), "debugMode": String(debugMode), "legacyShortcut": String(legacyShortcut),
         "enabledApps": apps.joined(separator: ","), "disabledKinds": disabledKinds.sorted().joined(separator: ","), "profileConfigured": String(!profile.isEmpty)]
    }
    private func save(_ name: String, recordChange: Bool = true) {
        if recordChange { changed(name) }
        defaults.set(engine.rawValue, forKey: "engine")
        defaults.set(pauseSeconds, forKey: "pauseSeconds")
        defaults.set(level.rawValue, forKey: "strictness"); defaults.set(legacyShortcut, forKey: "legacyShortcut")
        defaults.set(disabledKindsByLevel, forKey: "disabledKindsByLevel")
        defaults.set(serviceTier, forKey: "serviceTier")
        defaults.set(base, forKey: "base"); defaults.set(model, forKey: "model")
        defaults.set(profile, forKey: "profile"); defaults.set(apps, forKey: "apps")
    }
}

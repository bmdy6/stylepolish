import XCTest
import StylePolishCore
@testable import StylePolishApp

final class SettingsTests: XCTestCase {
    func testLegacyAppListsMigrateToWeChatOnly() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for legacy in [["com.tencent.xinWeChat", "com.tencent.qq", "com.linear"], ["com.apple.Safari"], []] {
            let defaults = MemoryDefaults()
            defaults.set(legacy, forKey: "apps")
            defaults.set(true, forKey: "legacyShortcut")
            let settings = SettingsStore(defaults: defaults, credentialHome: root, diagnostics: Diagnostics(directory: root))
            XCTAssertEqual(settings.apps, ["com.tencent.xinWeChat"])
            XCTAssertEqual(defaults.stringArray(forKey: "apps"), ["com.tencent.xinWeChat"])
            XCTAssertTrue(settings.legacyShortcut)
            XCTAssertEqual(SettingsStore(defaults: defaults, credentialHome: root, diagnostics: Diagnostics(directory: root)).apps, ["com.tencent.xinWeChat"])
        }
    }

    func testNewJSONOptInSurvivesLegacyMigrationAndRestart() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = MemoryDefaults()
        defaults.set(["com.apple.Safari", "com.linear"], forKey: "apps")
        let settings = SettingsStore(defaults: defaults, credentialHome: home, diagnostics: Diagnostics(directory: home))
        XCTAssertEqual(settings.apps, [SupportedApps.wechat])
        settings.setAppEnabled("com.linear", enabled: true)
        let restored = SettingsStore(defaults: defaults, credentialHome: home, diagnostics: Diagnostics(directory: home))
        XCTAssertEqual(restored.apps, [SupportedApps.wechat, "com.linear"])
        XCTAssertEqual(defaults.stringArray(forKey: "apps"), restored.apps)
    }

    func testInvalidJSONRecordsConfigurationDiagnostic() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".config/stylepolish/apps.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid JSON".utf8).write(to: file)
        let diagnostics = Diagnostics(directory: home.appendingPathComponent("logs"))
        let settings = SettingsStore(defaults: MemoryDefaults(), credentialHome: home, diagnostics: diagnostics)
        XCTAssertEqual(settings.apps, [SupportedApps.wechat])
        diagnostics.flush()
        let log = try String(contentsOf: diagnostics.url)
        XCTAssertTrue(log.contains("app_configuration"))
        XCTAssertTrue(log.contains("invalid_app_configuration"))
    }

    @MainActor func testDefaultsAndPerLevelDisabledKindsPersist() async {
        let name = "org.bmdy6.StylePolish.tests." + UUID().uuidString
        let defaults = MemoryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("existing-model", forKey: "model")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = SettingsStore(defaults: defaults, credentialHome: home)
        settings.vaultKeyName = "CUSTOM_OPENAI_KEY"
        XCTAssertEqual(SettingsStore(defaults: defaults, credentialHome: home).vaultKeyName, "CUSTOM_OPENAI_KEY")
        try? settings.saveKey("synthetic-settings-key")
        XCTAssertEqual(settings.credentials.current.key, "synthetic-settings-key")
        XCTAssertNil(defaults.string(forKey: "apiKey"))
        XCTAssertEqual(settings.model, "existing-model")
        XCTAssertEqual(settings.serviceTier, "priority")
        settings.serviceTier = "default"
        XCTAssertEqual(SettingsStore(defaults: defaults, credentialHome: home).serviceTier, "default")
        XCTAssertEqual(settings.level, .standard); XCTAssertFalse(settings.legacyShortcut)
        settings.disabledKinds.append("filler")
        settings.level = .strict; XCTAssertTrue(settings.disabledKinds.isEmpty)
        settings.disabledKinds.append("tone"); settings.legacyShortcut = true
        let restored = SettingsStore(defaults: defaults, credentialHome: home)
        XCTAssertEqual(restored.disabledKinds, ["tone"]); XCTAssertTrue(restored.legacyShortcut)
        restored.level = .standard; XCTAssertEqual(restored.disabledKinds, ["filler"])
    }
}

extension SettingsTests {
    func testInitializationReloadAndEqualAssignmentsAreSilent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Diagnostics(directory: root)
        let defaults = MemoryDefaults()
        defaults.set(0.1, forKey: "pauseSeconds") // migration/clamping during load is silent
        let settings = SettingsStore(defaults: defaults, credentialHome: root, diagnostics: log)
        settings.model = settings.model
        settings.pauseSeconds = settings.pauseSeconds
        settings.debugMode = false
        settings.pauseSeconds = -1 // bounded back to the current minimum; no effective change
        settings.reloadCredentials()
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url.path))
        settings.model = "new-model"
        settings.pauseSeconds = 2
        log.flush()
        let lines = try String(contentsOf: log.url).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let restored = SettingsStore(defaults: defaults, credentialHome: root, diagnostics: log)
        XCTAssertEqual(restored.model, "new-model")
        log.flush()
        XCTAssertEqual(try String(contentsOf: log.url).split(separator: "\n").count, 2)
    }
}

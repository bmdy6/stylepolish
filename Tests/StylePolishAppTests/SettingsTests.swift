import XCTest
import StylePolishCore
@testable import StylePolishApp

final class SettingsTests: XCTestCase {
    @MainActor func testDefaultsAndPerLevelDisabledKindsPersist() async {
        let name = "org.bmdy6.StylePolish.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
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

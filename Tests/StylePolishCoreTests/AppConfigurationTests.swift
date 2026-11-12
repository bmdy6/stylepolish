import XCTest
@testable import StylePolishCore

final class AppConfigurationTests: XCTestCase {
    private func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }
    private func write(_ json: String, home: URL) throws {
        let file = home.appendingPathComponent(".config/stylepolish/apps.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)
    }
    func testBuiltInDefaultsAndActivationAttributes() throws {
        try withHome { home in
            let apps = SupportedApps(home: home)
            XCTAssertEqual(apps.enabledBundleIDs, [SupportedApps.wechat])
            XCTAssertEqual(apps.entries.count, 7)
            XCTAssertEqual(apps.app("com.google.Chrome")?.axActivation, "AXEnhancedUserInterface")
            for id in ["com.linear", "com.electron.lark", "com.anthropic.claudefordesktop"] {
                XCTAssertEqual(apps.app(id)?.axActivation, "AXManualAccessibility")
                XCTAssertFalse(apps.isEnabled(id))
            }
            XCTAssertTrue(apps.app(SupportedApps.wechat)!.clipboardWhole)
            XCTAssertFalse(apps.isEnabled("com.tencent.xinWeChat.evil"))
        }
    }
    func testPartialOverridesMergeAndNewAppsCanBeAdded() throws {
        try withHome { home in
            try write("""
            [{"bundleID":"com.tencent.xinWeChat","enabled":false},
             {"bundleID":"com.linear","enabled":true,"axActivation":null},
             {"bundleID":"org.example.Editor","name":"Editor","enabled":true,"clipboardWhole":true,"extensions":{"future":"reserved"}}]
            """, home: home)
            let apps = SupportedApps(home: home)
            XCTAssertEqual(apps.enabledBundleIDs, ["com.linear", "org.example.Editor"])
            XCTAssertFalse(apps.app("com.linear")!.verified)
            XCTAssertNil(apps.app("com.linear")!.axActivation)
            XCTAssertTrue(apps.app("org.example.Editor")!.clipboardWhole)
            XCTAssertFalse(apps.isEnabled("org.example.Editor.evil"))
            try apps.setEnabled("org.example.Editor", enabled: false)
            XCTAssertNil(SupportedApps(home: home).app("com.linear")!.axActivation, "Explicit null survives later UI saves")
            let mode = try FileManager.default.attributesOfItem(atPath: apps.file.path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(mode.intValue, 0o600)
        }
    }
    func testInvalidAndUnknownFieldsFallBackWithDiagnostic() throws {
        for json in ["{bad", "{}", "[{\"bundleID\":\"com.linear\",\"enabled\":true,\"enabld\":true}]", "[{\"bundleID\":\"com.linear\",\"enabled\":\"yes\"}]"] {
            try withHome { home in
                try write(json, home: home)
                var events: [String] = []
                let apps = SupportedApps(home: home, diagnostic: { events.append($0) })
                XCTAssertEqual(apps.enabledBundleIDs, [SupportedApps.wechat])
                XCTAssertEqual(events, ["invalid_app_configuration"])
            }
        }
    }
    func testToggleRemoveAndAddPersistWithoutChangingOtherPolicies() throws {
        try withHome { home in
            let apps = SupportedApps(home: home)
            try apps.setEnabled("com.linear", enabled: true)
            try apps.remove(SupportedApps.wechat)
            try apps.add(bundleID: "org.example.Editor", name: "Editor")
            let restored = SupportedApps(home: home)
            XCTAssertEqual(restored.enabledBundleIDs, ["com.linear", "org.example.Editor"])
            XCTAssertFalse(restored.entries.contains { $0.bundleID == SupportedApps.wechat })
            XCTAssertEqual(restored.app("com.linear")?.axActivation, "AXManualAccessibility")
            XCTAssertFalse(restored.app("org.example.Editor")!.verified)
            try restored.add(bundleID: SupportedApps.wechat, name: "微信")
            XCTAssertTrue(SupportedApps(home: home).isEnabled(SupportedApps.wechat))
        }
    }
    func testSaveFailureKeepsCurrentPolicy() throws {
        try withHome { home in
            let apps = SupportedApps(home: home)
            try FileManager.default.createDirectory(at: apps.file, withIntermediateDirectories: true)
            XCTAssertThrowsError(try apps.setEnabled("com.linear", enabled: true))
            XCTAssertEqual(apps.enabledBundleIDs, [SupportedApps.wechat])
        }
    }

    func testSaveOnlyWritesBuiltInUserChoices() throws {
        try withHome { home in
            let apps = SupportedApps(home: home)
            try apps.setEnabled("com.electron.lark", enabled: false)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: apps.file)) as! [[String: Any]]
            XCTAssertEqual(saved.count, 1)
            let lark = try XCTUnwrap(saved.first { $0["bundleID"] as? String == "com.electron.lark" })
            XCTAssertEqual(Set(lark.keys), ["bundleID", "enabled"])
            XCTAssertEqual(lark["enabled"] as? Bool, false)
        }
    }

    func testLegacyFullEntriesArePrunedOnNextSave() throws {
        try withHome { home in
            try write("""
            [{"bundleID":"com.electron.lark","name":"飞书","verified":false,
              "enabledByDefault":false,"axActivation":"AXManualAccessibility",
              "clipboardWhole":false,"extensions":{},"enabled":false,"removed":false},
             {"bundleID":"com.linear","name":"Linear","verified":false,
              "enabledByDefault":false,"axActivation":null,"clipboardWhole":false,"extensions":{}},
             {"bundleID":"com.google.Chrome","name":"Chrome","verified":false,
              "enabledByDefault":false,"axActivation":"AXEnhancedUserInterface","clipboardWhole":false,"extensions":{}}]
            """, home: home)
            let apps = SupportedApps(home: home)
            try apps.setEnabled(SupportedApps.wechat, enabled: false)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: apps.file)) as! [[String: Any]]
            XCTAssertEqual(saved.count, 3)
            let lark = try XCTUnwrap(saved.first { $0["bundleID"] as? String == "com.electron.lark" })
            XCTAssertEqual(Set(lark.keys), ["bundleID", "enabled"])
            let linear = try XCTUnwrap(saved.first { $0["bundleID"] as? String == "com.linear" })
            XCTAssertEqual(Set(linear.keys), ["bundleID", "axActivation"])
            XCTAssertTrue(linear["axActivation"] is NSNull)
            XCTAssertNil(SupportedApps(home: home).app("com.linear")?.axActivation)
        }
    }

    func testDisabledBuiltInUsesUpdatedPoliciesAfterRestart() throws {
        try withHome { home in
            let apps = SupportedApps(home: home)
            try apps.setEnabled("com.electron.lark", enabled: false)
            var updated = apps.entries
            let index = try XCTUnwrap(updated.firstIndex { $0.bundleID == "com.electron.lark" })
            updated[index] = SupportedApp(bundleID: "com.electron.lark", name: "Feishu", verified: true,
                                          enabledByDefault: true, axActivation: "AXEnhancedUserInterface",
                                          clipboardWhole: true, extensions: ["future": "updated"])
            let restored = SupportedApps(home: home, builtIn: updated)
            let lark = try XCTUnwrap(restored.app("com.electron.lark"))
            XCTAssertTrue(lark.verified)
            XCTAssertFalse(lark.isEnabled)
            XCTAssertEqual(lark.name, "Feishu")
            XCTAssertEqual(lark.axActivation, "AXEnhancedUserInterface")
            XCTAssertTrue(lark.clipboardWhole)
            XCTAssertEqual(lark.extensions, ["future": "updated"])
            try restored.setEnabled("com.linear", enabled: true)
            XCTAssertEqual(SupportedApps(home: home, builtIn: updated).app("com.electron.lark"), lark)
        }
    }

    func testBuiltInRemovalAndRestorationOnlyPersistChoices() throws {
        try withHome { home in
            let apps = SupportedApps(home: home)
            try apps.remove(SupportedApps.wechat)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: apps.file)) as! [[String: Any]]
            XCTAssertEqual(saved.count, 1)
            let removed = try XCTUnwrap(saved.first)
            XCTAssertEqual(Set(removed.keys), ["bundleID", "enabled", "removed"])
            XCTAssertEqual(removed["removed"] as? Bool, true)
            let restored = SupportedApps(home: home)
            XCTAssertNil(restored.app(SupportedApps.wechat))
            try restored.add(bundleID: SupportedApps.wechat, name: "微信")
            let savedAgain = try JSONSerialization.jsonObject(with: Data(contentsOf: apps.file)) as! [[String: Any]]
            XCTAssertEqual(Set(try XCTUnwrap(savedAgain.first).keys), ["bundleID", "enabled"])
            XCTAssertTrue(SupportedApps(home: home).isEnabled(SupportedApps.wechat))
        }
    }

    func testCustomAppFullConfigurationSurvivesRestartAndLaterSave() throws {
        try withHome { home in
            try write("""
            [{"bundleID":"org.example.Editor","name":"Editor","verified":true,
              "enabledByDefault":true,"axActivation":null,"clipboardWhole":true,
              "extensions":{"future":"reserved"},"enabled":true}]
            """, home: home)
            let apps = SupportedApps(home: home)
            let original = try XCTUnwrap(apps.app("org.example.Editor"))
            try apps.setEnabled("com.linear", enabled: true)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: apps.file)) as! [[String: Any]]
            let custom = try XCTUnwrap(saved.first { $0["bundleID"] as? String == "org.example.Editor" })
            XCTAssertEqual(Set(custom.keys), ["bundleID", "name", "verified", "enabledByDefault", "axActivation", "clipboardWhole", "extensions", "enabled"])
            XCTAssertEqual(SupportedApps(home: home).app("org.example.Editor"), original)
        }
    }

}

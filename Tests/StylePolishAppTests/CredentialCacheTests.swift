import XCTest
@testable import StylePolishApp

final class CredentialCacheTests: XCTestCase {
    var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    func writeVault(_ json: String, mode: Int = 0o600) throws {
        let url = home.appendingPathComponent(".config/ai-vault/vault.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    let vault = #"{"personal-infra":{"openai":{"OPENAI_PLATFORM_API_KEY":{"value":"synthetic-vault-1234","description":"test"}}}}"#
    func testVaultFindsKeyAcrossTreeAndConfigurableName() throws {
        try writeVault(vault)
        let store = CredentialStore(home: home)
        XCTAssertEqual(store.current.key, "synthetic-vault-1234")
        XCTAssertEqual(store.current.status, "Key 来源：ai-vault · OPENAI_PLATFORM_API_KEY ✓ · …1234")
        XCTAssertTrue(store.current.warnings.isEmpty)
        try writeVault(#"{"other":{"deep":{"nested":{"CUSTOM":{"value":"synthetic-custom"}}}}}"#)
        store.reload(keyName: "CUSTOM")
        XCTAssertEqual(store.current.key, "synthetic-custom")
    }
    func testMissingKeyAndCorruptJSONFallBackToLocal() throws {
        let store = CredentialStore(home: home)
        try store.saveLocal("synthetic-local", keyName: "OPENAI_PLATFORM_API_KEY")
        for json in [#"{"group":{"service":{"OTHER":{"value":"unused"}}}}"#, "{broken", "[]"] {
            try writeVault(json)
            store.reload(keyName: "OPENAI_PLATFORM_API_KEY")
            XCTAssertEqual(store.current.key, "synthetic-local")
            XCTAssertEqual(store.current.source, "本地文件")
            XCTAssertFalse(store.current.warnings.isEmpty)
        }
    }
    func testPriorityVaultThenLocalThenUnconfigured() throws {
        let store = CredentialStore(home: home)
        XCTAssertEqual(store.current.status, "填一次 Key 即可")
        try store.saveLocal("synthetic-local", keyName: "OPENAI_PLATFORM_API_KEY")
        XCTAssertEqual(store.current.source, "本地文件")
        try writeVault(vault)
        store.reload(keyName: "OPENAI_PLATFORM_API_KEY")
        XCTAssertEqual(store.current.key, "synthetic-vault-1234")
        try store.saveLocal("synthetic-new-local", keyName: "OPENAI_PLATFORM_API_KEY")
        XCTAssertEqual(store.current.key, "synthetic-vault-1234")
        try FileManager.default.removeItem(at: store.vaultURL)
        store.reload(keyName: "OPENAI_PLATFORM_API_KEY")
        XCTAssertEqual(store.current.key, "synthetic-new-local")
        try FileManager.default.removeItem(at: store.localURL)
        store.reload(keyName: "OPENAI_PLATFORM_API_KEY")
        XCTAssertTrue(store.current.key.isEmpty)
    }
    func testPermissionsWarnButStillLoad() throws {
        try writeVault(vault, mode: 0o644)
        let store = CredentialStore(home: home)
        XCTAssertEqual(store.current.key, "synthetic-vault-1234")
        XCTAssertTrue(store.current.warnings.contains { $0.contains("权限不是 600") })
        try FileManager.default.removeItem(at: store.vaultURL)
        try store.saveLocal("synthetic-local", keyName: "OPENAI_PLATFORM_API_KEY")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.localURL.path)
        store.reload(keyName: "OPENAI_PLATFORM_API_KEY")
        XCTAssertEqual(store.current.key, "synthetic-local")
        XCTAssertTrue(store.current.warnings.contains { $0.contains("权限不是 600") })
    }
    func testSavePermissionsAndMemoryUntilExplicitReload() throws {
        let store = CredentialStore(home: home)
        try store.saveLocal(" synthetic-local \n", keyName: "OPENAI_PLATFORM_API_KEY")
        let fm = FileManager.default
        XCTAssertEqual((try fm.attributesOfItem(atPath: store.localURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try fm.attributesOfItem(atPath: store.localURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try writeVault(vault)
        XCTAssertEqual(store.current.key, "synthetic-local")
        store.reload(keyName: "OPENAI_PLATFORM_API_KEY")
        XCTAssertEqual(store.current.key, "synthetic-vault-1234")
        XCTAssertThrowsError(try store.saveLocal(" \n", keyName: "OPENAI_PLATFORM_API_KEY"))
    }
    func testFailuresAreCachedUntilReload() throws {
        try writeVault("broken")
        let store = CredentialStore(home: home)
        try writeVault(vault)
        XCTAssertTrue(store.current.key.isEmpty)
        XCTAssertFalse(store.current.warnings.isEmpty)
        store.reload(keyName: "OPENAI_PLATFORM_API_KEY")
        XCTAssertFalse(store.current.key.isEmpty)
        XCTAssertTrue(store.current.warnings.isEmpty)
    }
}

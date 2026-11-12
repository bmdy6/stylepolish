import XCTest
import StylePolishCore
@testable import StylePolishApp

final class InviteTests: XCTestCase {
    private var server: Process!
    private var base: String!
    private var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", root.appendingPathComponent("scripts/tests/invite-fake-server.py").path]
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run()
        let data = pipe.fileHandleForReading.availableData
        let port = try XCTUnwrap(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertNotNil(Int(port)); base = "http://127.0.0.1:" + port
    }
    override func tearDown() {
        if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
        try? FileManager.default.removeItem(at: home)
    }
    private func code(_ group: String) -> String { "SP-\(group)-2345" }
    private func configuration(_ group: String, base: String? = nil) throws -> PolishConfiguration {
        PolishConfiguration(base: try InviteService.endpoint(base ?? self.base).absoluteString, model: "ignored-by-relay", key: code(group), profile: "", inviteDeviceID: UUID().uuidString)
    }
    private func requests() async throws -> [[String: String]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/stats")!)
        return try JSONDecoder().decode([[String: String]].self, from: data)
    }
    func testFormatEndpointAndPlaceholderMakeZeroRequests() async throws {
        for value in ["SP-7K2M-9QXD", code("AAAA")] { XCTAssertTrue(InviteService.validCode(value)) }
        for value in ["SP-0000-2222", "SP-OOOO-2222", "SP-1111-2222", "SP-IIII-2222", "SP-abcd-2222", "SP-ABCD-2222\n", "SP-ABCD-22222"] { XCTAssertFalse(InviteService.validCode(value), value) }
        XCTAssertEqual(try InviteService.endpoint(base).path, "/v1")
        XCTAssertEqual(try InviteService.endpoint(base + "/v1/").path, "/v1")
        for bad in ["http://example.com", "https://user:pass@example.com", "https://example.com?q=1", "https://example.com#x"] { XCTAssertThrowsError(try InviteService.endpoint(bad)) }
        let invite = InviteAccess(home: home)
        await invite.verify(code("GGGG"), base: InviteService.defaultBase)
        XCTAssertEqual(invite.message, "试用服务还没开放")
        XCTAssertFalse(invite.canUse(base: InviteService.defaultBase))
        let config = PolishConfiguration(base: InviteService.defaultBase, model: "unused", key: code("GGGG"), profile: "", inviteDeviceID: invite.deviceID)
        XCTAssertThrowsError(try PolishClient().makeRequest("我因该回复。", config: config, structured: true)) { XCTAssertEqual(($0 as? PolishFailure)?.message, "试用服务还没开放") }
        let rows = try await requests(); XCTAssertTrue(rows.isEmpty)
    }
    @MainActor func testDeviceAndInvitePersistWithPrivatePermissionsAndNoAuthorKey() async throws {
        let defaults = MemoryDefaults()
        let settings = SettingsStore(defaults: defaults, credentialHome: home)
        try settings.saveKey("synthetic-author-key-must-not-arrive")
        settings.engine = .invite; settings.relayBase = base
        await settings.invite.verify(" sp-gggg-2345 ", base: base)
        let config = settings.configuration()
        XCTAssertEqual(config.key, code("GGGG")); XCTAssertEqual(config.inviteDeviceID, settings.invite.deviceID)
        XCTAssertEqual(URL(string: config.base)?.path, "/v1")
        let request = try PolishClient().makeRequest("我因该回复。", config: config, structured: true)
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + code("GGGG"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-StylePolish-Device"), settings.invite.deviceID)
        let reloaded = InviteAccess(home: home)
        XCTAssertEqual(reloaded.deviceID, settings.invite.deviceID)
        XCTAssertEqual(reloaded.code, code("GGGG")); XCTAssertEqual(reloaded.remainingPercent, 92)
        for file in [reloaded.codeURL, reloaded.deviceURL] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: reloaded.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertNil(defaults.string(forKey: "inviteCode"))
        let rows = try await requests()
        XCTAssertTrue(rows.allSatisfy { $0["authorization"] == "Bearer " + code("GGGG") && $0["device"] == reloaded.deviceID })
        settings.engine = .ai
        XCTAssertEqual(settings.configuration().key, "synthetic-author-key-must-not-arrive")
        XCTAssertNil(settings.configuration().inviteDeviceID)
    }
    @MainActor func testAllSixGetErrorsHaveContractTextAndSafeBodies() async throws {
        let values = [("AAAA", "邀请码无效"), ("BBBB", "试用额度用完"), ("CCCC", "本月试用已满"),
                      ("DDDD", "稍后再试（这次用本地规则）"), ("EEEE", "这段太长，用本地规则"), ("FFFF", "网络不通（这次用本地规则）")]
        for (group, text) in values {
            let invite = InviteAccess(home: home.appendingPathComponent(group))
            await invite.verify(code(group), base: base)
            XCTAssertEqual(invite.message, text, group)
            XCTAssertFalse(invite.canUse(base: base))
            XCTAssertFalse(invite.message.contains("UNTRUSTED"))
        }
    }
    @MainActor func testAllSixPostErrorsFallbackAndTerminalFailuresStopFuturePosts() async throws {
        let groups = ["AAAA", "BBBB", "CCCC", "DDDD", "EEEE", "FFFF"]
        let reasons: [FallbackReason] = [.inviteInvalid, .inviteExhausted, .monthlyCap, .rateLimited, .inputTooLong, .network]
        for (group, reason) in zip(groups, reasons) {
            let settings = SettingsStore(defaults: MemoryDefaults(), credentialHome: home.appendingPathComponent(group))
            settings.engine = .invite; settings.relayBase = base + "/post"
            await settings.invite.verify(code(group), base: settings.relayBase)
            XCTAssertTrue(settings.invite.canUse(base: settings.relayBase))
            let config = settings.configuration()
            let result = try await CheckEngine().check("我因该回复。", engine: .invite, config: config)
            XCTAssertEqual(result.fallback, reason, group)
            XCTAssertEqual(result.suggestions.count, 1, group)
            XCTAssertEqual(result.suggestions.first?.replacement, "应该", group)
            XCTAssertEqual(result.suggestions.first?.range, NSRange(location: 1, length: 2), group)
            XCTAssertFalse(result.failureSummary?.contains("UNTRUSTED") == true)
            settings.checked(result, config: config)
            let before = try await requests().filter { $0["method"] == "POST" }.count
            let next = try await CheckEngine().check("我因该回复。", engine: .invite, config: settings.configuration())
            XCTAssertEqual(next.fallback, reason, group)
            XCTAssertEqual(next.suggestions.first?.replacement, "应该", group)
            XCTAssertEqual(next.suggestions.first?.range, NSRange(location: 1, length: 2), group)
            let after = try await requests().filter { $0["method"] == "POST" }.count
            XCTAssertEqual(after - before, reason.blocksInvite ? 0 : 1, group)
            let restored = InviteAccess(home: home.appendingPathComponent(group))
            XCTAssertEqual(restored.canUse(base: settings.relayBase), !reason.blocksInvite, group)
        }
    }
    @MainActor func testActiveStreamingUsageAndStatusRefresh() async throws {
        let invite = InviteAccess(home: home)
        await invite.verify(code("GGGG"), base: base)
        var config = try configuration("GGGG"); config.inviteDeviceID = invite.deviceID
        var metrics = RequestMetrics()
        let result = try await CheckEngine().check("我因该回复。", engine: .invite, config: config, metrics: { metrics = $0 })
        XCTAssertEqual(result.fallback, .none)
        XCTAssertEqual(result.suggestions.first?.replacement, "应该")
        XCTAssertEqual(result.suggestions.first?.range, NSRange(location: 1, length: 2))
        XCTAssertEqual(metrics.totalTokens, 20); XCTAssertEqual(metrics.completionTokens, 8)
        await invite.refresh(base: base)
        XCTAssertEqual(invite.remainingPercent, 92)
        let rows = try await requests()
        XCTAssertTrue(rows.contains { $0["path"] == "/v1/chat/completions" && $0["device"] == invite.deviceID })
    }
    @MainActor func testStatusVariantsLowQuotaOnceAndEndpointChangeInvalidatesVerification() async throws {
        let settings = SettingsStore(defaults: MemoryDefaults(), credentialHome: home)
        settings.relayBase = base; settings.engine = .invite
        await settings.invite.verify(code("HHHH"), base: base)
        XCTAssertEqual(settings.invite.remainingPercent, 9)
        XCTAssertNotNil(settings.invite.consumeLowQuotaWarning())
        XCTAssertNil(settings.invite.consumeLowQuotaWarning())
        XCTAssertNil(InviteAccess(home: home).consumeLowQuotaWarning())
        await settings.invite.refresh(base: base)
        XCTAssertNil(settings.invite.consumeLowQuotaWarning())
        settings.relayBase = base + "/post"
        XCTAssertFalse(settings.invite.canUse(base: settings.relayBase))
        for (group, reason) in [("JJJJ", FallbackReason.inviteExhausted), ("KKKK", .inviteInvalid)] {
            await settings.invite.verify(code(group), base: base)
            XCTAssertEqual(settings.invite.blockedReason, reason)
            XCTAssertFalse(settings.invite.canUse(base: base))
        }
        await settings.invite.verify(code("MMMM"), base: base)
        XCTAssertFalse(settings.invite.canUse(base: base))
        XCTAssertEqual(settings.invite.message, "试用服务响应无效")
    }
    @MainActor func testStaleVerificationAndCancellationCannotActivateCode() async throws {
        let invite = InviteAccess(home: home)
        let old = Task { await invite.verify(code("AAAA"), base: base + "/slow") }
        try await Task.sleep(nanoseconds: 50_000_000)
        invite.resetVerification()
        await invite.verify(code("GGGG"), base: base)
        await old.value
        XCTAssertEqual(invite.code, code("GGGG")); XCTAssertTrue(invite.canUse(base: base))
        let task = Task { await invite.verify(code("GGGG"), base: base + "/slow") }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel(); await task.value
        XCTAssertFalse(invite.canUse(base: base + "/slow"))
        XCTAssertEqual(invite.message, "验证已取消")
    }

    @MainActor func testVerificationFailuresKeepTheirFallbackReasonAfterRestart() async throws {
        for (group, reason) in [("AAAA", FallbackReason.inviteInvalid), ("BBBB", .inviteExhausted), ("CCCC", .monthlyCap)] {
            let directory = home.appendingPathComponent(group)
            let invite = InviteAccess(home: directory)
            await invite.verify(code(group), base: base)
            XCTAssertEqual(invite.block(for: base), reason)
            XCTAssertEqual(InviteAccess(home: directory).block(for: base), reason)
        }
    }

    @MainActor func testInFlightQuotaRefreshCannotUndoTerminalPostFailure() async throws {
        let invite = InviteAccess(home: home)
        let endpoint = base + "/slow"
        await invite.verify(code("GGGG"), base: endpoint)
        XCTAssertTrue(invite.canUse(base: endpoint))
        let before = try await requests().count
        let refresh = Task { await invite.refresh(base: endpoint) }
        for _ in 0..<100 {
            if try await requests().count > before { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(invite.validating)
        invite.checked(fallback: .inviteExhausted, code: code("GGGG"), base: endpoint)
        await refresh.value
        XCTAssertEqual(invite.block(for: endpoint), .inviteExhausted)
        XCTAssertEqual(InviteAccess(home: home).block(for: endpoint), .inviteExhausted)
        XCTAssertFalse(invite.validating)
    }

    @MainActor func testLowQuotaReminderAndOnboardingCannotUseAnExhaustedInvite() async throws {
        let settings = SettingsStore(defaults: MemoryDefaults(), credentialHome: home)
        settings.engine = .invite; settings.relayBase = base
        let model = OnboardingModel(settings: settings, trusted: true)
        XCTAssertFalse(model.canContinue)
        await settings.invite.verify(code("HHHH"), base: base)
        XCTAssertTrue(model.canContinue)
        settings.invite.checked(fallback: .inviteExhausted, code: code("HHHH"), base: base)
        XCTAssertFalse(model.canContinue)
        XCTAssertNil(settings.invite.consumeLowQuotaWarning())
        XCTAssertNil(InviteAccess(home: home).consumeLowQuotaWarning())
    }
}

import XCTest
import AppKit
import ApplicationServices
import StylePolishCore
@testable import StylePolishApp

final class SupportedAppsTests: XCTestCase {
    private let excluded: [String?] = [
        nil, "", "com.tencent.qq", "com.electron.lark", "com.anthropic.claudefordesktop",
        "com.linear", "com.apple.Notes", "com.apple.Safari", "com.google.Chrome",
        "com.tencent.xinWeChat.evil", "COM.TENCENT.XINWECHAT", "org.bmdy6.StylePolish.SyntheticEditor"
    ]

    @MainActor func testAutomaticCapturePolicyRejectsEveryOtherBundleEvenForFallback() {
        let access = AccessibilityAccess()
        XCTAssertEqual(SupportedApps.all, [SupportedApps.wechat])
        XCTAssertTrue(access.supports(SupportedApps.wechat))
        access.useClipboard(for: SupportedApps.wechat)
        for bundleID in excluded {
            XCTAssertFalse(access.supports(bundleID), "Automatic capture must exclude \(bundleID ?? "nil")")
            if let bundleID { access.useClipboard(for: bundleID) }
        }
        XCTAssertEqual(access.fallbackApps, [SupportedApps.wechat], "Fallback discovery cannot expand the whitelist")
    }

    @MainActor func testSyntheticHarnessPolicyCannotTouchWeChatOrOtherApps() {
        let fixture = "org.bmdy6.StylePolish.SyntheticEditor"
        let access = AccessibilityAccess(testingApp: fixture)
        XCTAssertTrue(access.supports(fixture))
        XCTAssertFalse(access.supports(SupportedApps.wechat))
        XCTAssertFalse(access.supports("com.linear"))
        XCTAssertFalse(AccessibilityAccess().supports(fixture))
    }

    @MainActor func testUnsupportedFrontAppReturnsBeforeAXOrClipboardCapture() async throws {
        // The XCTest process is deliberately not WeChat. No window, event tap or AX fixture.
        XCTAssertFalse(SupportedApps.contains(NSRunningApplication.current.bundleIdentifier))
        for front in [NSRunningApplication.current, nil] {
            let access = AccessibilityAccess(frontmostApplication: { front })
            XCTAssertFalse(access.targetSupported)
            XCTAssertNil(access.focused())
            XCTAssertNil(access.automaticCapture())
            do {
                _ = try await access.capture(forceWholeClipboard: true)
                XCTFail("Manual capture must reject unsupported foreground, even when forced")
            } catch {
                XCTAssertEqual(error.localizedDescription, "目前只支持微信")
            }
        }
    }

    @MainActor func testUnsupportedForegroundCannotWriteOldWeChatCaptureOrProbeOtherApp() async throws {
        let access = AccessibilityAccess(frontmostApplication: { NSRunningApplication.current })
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let capture = CapturedInput(pid: ProcessInfo.processInfo.processIdentifier, bundleID: SupportedApps.wechat,
                                    appName: "synthetic", element: element, input: "旧的合成输入", fullText: nil,
                                    range: nil, selected: false, clipboard: true, bounds: nil)
        XCTAssertFalse(access.unchanged(capture))
        XCTAssertFalse(access.isCurrent(capture, text: capture.input))
        let suggestion = Suggestion(range: NSRange(location: 0, length: 1), original: "旧", replacement: "新", kind: .typo, why: "")
        XCTAssertFalse(access.writeSuggestion(suggestion, source: capture.input, to: capture))
        do {
            _ = try await access.write("合成结果", to: capture)
            XCTFail("A stale WeChat capture cannot authorize writes from another foreground app")
        } catch { XCTAssertEqual(error.localizedDescription, "目前只支持微信") }
        XCTAssertThrowsError(try InputProbe.write(access: access, target: .current)) {
            XCTAssertEqual($0.localizedDescription, "目前只支持微信")
        }
        do {
            try await InputProbe.modelCheck(access: access, target: .current,
                                            config: PolishConfiguration(base: "https://fixture.invalid", model: "synthetic", key: "", profile: ""))
            XCTFail("Diagnostics must reject a non-WeChat target before AX or network")
        } catch { XCTAssertEqual(error.localizedDescription, "目前只支持微信") }
    }

    @MainActor func testOtherAppsCannotDispatchManualProbeOrAcceptanceShortcuts() {
        var front: String? = SupportedApps.wechat
        let keyboard = KeyboardController(frontmostBundleID: { front })
        var triggers = 0, probes = 0, handles = 0
        keyboard.trigger = { triggers += 1 }
        keyboard.probe = { probes += 1 }
        keyboard.handle = { _, _ in handles += 1; return true }
        for bundleID in excluded {
            front = bundleID
            XCTAssertFalse(keyboard.targetSupported)
            XCTAssertFalse(keyboard.dispatchHotkey(1)) // legacy/manual Option+Space
            XCTAssertFalse(keyboard.dispatchHotkey(3)) // diagnostic Control+Option+P
            for code: CGKeyCode in [36, 76, 49] {
                XCTAssertFalse(keyboard.consumeKey(type: .keyDown, code: code, flags: .maskAlternate))
                XCTAssertFalse(keyboard.consumeKey(type: .keyUp, code: code, flags: .maskAlternate))
            }
        }
        XCTAssertEqual(triggers, 0); XCTAssertEqual(probes, 0); XCTAssertEqual(handles, 0)
        front = SupportedApps.wechat
        XCTAssertTrue(keyboard.dispatchHotkey(1)); XCTAssertTrue(keyboard.dispatchHotkey(3))
        XCTAssertTrue(keyboard.consumeKey(type: .keyDown, code: 36, flags: .maskAlternate))
        XCTAssertEqual(triggers, 1); XCTAssertEqual(probes, 1); XCTAssertEqual(handles, 1)
        // A key accepted in WeChat must pass through after an application switch.
        front = "com.linear"
        XCTAssertFalse(keyboard.consumeKey(type: .keyDown, code: 36, flags: .maskAlternate))
        XCTAssertFalse(keyboard.consumeKey(type: .keyUp, code: 36, flags: .maskAlternate))
        XCTAssertEqual(handles, 1)
    }

    func testFreshSettingsPersistWeChatAndIgnoreLaterExternalPreferenceChanges() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = MemoryDefaults()
        let settings = SettingsStore(defaults: defaults, credentialHome: root, diagnostics: Diagnostics(directory: root))
        XCTAssertEqual(settings.apps, SupportedApps.all)
        XCTAssertEqual(defaults.stringArray(forKey: "apps"), SupportedApps.all)
        defaults.set(["com.linear"], forKey: "apps")
        settings.legacyShortcut = true
        XCTAssertEqual(settings.apps, SupportedApps.all)
        XCTAssertEqual(defaults.stringArray(forKey: "apps"), SupportedApps.all)
    }
}

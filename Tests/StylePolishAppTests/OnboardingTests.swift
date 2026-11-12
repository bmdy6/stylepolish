import XCTest
import AppKit
import StylePolishCore
@testable import StylePolishApp

final class OnboardingTests: XCTestCase {
    func testPermissionWaitsOneSecondThenAdvances() {
        var state = OnboardingState(trusted: false, hasKey: false)
        XCTAssertEqual(state.step, .permission)
        state.permissionChanged(true, now: 10)
        XCTAssertTrue(state.trusted); XCTAssertEqual(state.step, .permission)
        state.permissionChanged(true, now: 10.9)
        XCTAssertEqual(state.step, .permission)
        state.permissionChanged(true, now: 11)
        XCTAssertEqual(state.step, .engine)
        state.permissionChanged(false, now: 12)
        XCTAssertEqual(state.step, .permission); XCTAssertFalse(state.trusted)
    }
    func testAlreadyTrustedSkipsPermissionAndKeySelectsDefault() {
        let local = OnboardingState(trusted: true, hasKey: false)
        XCTAssertEqual(local.step, .engine); XCTAssertEqual(local.engine, .local)
        let ai = OnboardingState(trusted: true, hasKey: true)
        XCTAssertEqual(ai.step, .engine); XCTAssertEqual(ai.engine, .ai)
    }
    func testTrialRequiresActualCorrectionsNotIgnoring() {
        var state = OnboardingState(trusted: true, hasKey: false)
        state.step = .trial
        state.didCheck = true
        state.pending = LocalRules.check(state.text, level: .standard)
        XCTAssertEqual(state.pending.count, 4); XCTAssertFalse(state.canFinish)
        state.pending = [] // ignoring is not accepting
        XCTAssertFalse(state.canFinish)
        state.text = "我应该明天在给你回复，文件已经发了"
        XCTAssertTrue(state.canFinish)
        state.checking = true; XCTAssertFalse(state.canFinish)
    }
    @MainActor func testTrialAcceptOneIgnoreAndAcceptAll() async throws {
        let name = UUID().uuidString
        let defaults = MemoryDefaults()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: home) }
        let settings = SettingsStore(defaults: defaults, credentialHome: home)
        let model = OnboardingModel(settings: settings, trusted: true)
        model.state.step = .trial
        await model.checkTrial()
        XCTAssertEqual(model.state.pending.count, 4)
        let first = try XCTUnwrap(model.state.pending.first)
        model.accept(first.id)
        XCTAssertTrue(model.state.text.contains("应该")); XCTAssertEqual(model.state.pending.count, 3)
        model.acceptAll()
        XCTAssertTrue(model.state.canFinish)
        model.state.text = OnboardingState.sample
        await model.checkTrial()
        for edit in model.state.pending { model.ignore(edit.id) }
        XCTAssertFalse(model.state.canFinish)
        await model.checkTrial()
        XCTAssertTrue(model.state.pending.isEmpty) // ignored cache
    }
    @MainActor func testClosePersistsOnboardedWithoutShowingWindow() {
        let name = UUID().uuidString
        let defaults = MemoryDefaults()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: home) }
        let settings = SettingsStore(defaults: defaults, credentialHome: home)
        let controller = OnboardingController(settings: settings, permission: { XCTFail("No permission prompt in unit test") })
        XCTAssertFalse(controller.isVisible); XCTAssertFalse(settings.onboarded)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertTrue(SettingsStore(defaults: defaults, credentialHome: home).onboarded)
        XCTAssertFalse(controller.isVisible)
    }

}

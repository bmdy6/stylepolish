import XCTest
@testable import StylePolishCore

final class HabitStorageTests: XCTestCase {
    func testSingleCharacterReminderDeletionPersistsWithExistingTypoID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(directory: root)
        let edit = Suggestion(range: NSRange(location: 0, length: 1), original: "在", replacement: "再", kind: .typo, why: "")
        let event = SuggestionEvent(appBundleID: "fixture", sentence: "fixture", suggestion: edit, action: .accept, level: .standard, model: "local")
        try store.append(event); try store.append(event)
        let reminder = try XCTUnwrap(store.habits.reminderCandidates.first)
        XCTAssertEqual(reminder.id, HabitEntry.id(["typo", "在", "再", "typo"]))
        try store.setHabit(reminder.id, deleted: true)
        let reloaded = HistoryStore(directory: root)
        XCTAssertTrue(reloaded.habits.personalTypos.isEmpty)
        XCTAssertTrue(reloaded.habits.promptLines.isEmpty)
        XCTAssertEqual(reloaded.habits.reminderCandidates.first?.group, .reminder)
        try reloaded.setHabit(reminder.id, deleted: false)
        XCTAssertEqual(reloaded.habits.promptLines.count, 1)
        XCTAssertTrue(reloaded.habits.personalTypos.isEmpty)
    }
    func testStartupIncrementalDeleteRestorePermissionsAndClear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let edit = Suggestion(range: NSRange(location: 0, length: 2), original: "非长", replacement: "非常", kind: .typo, why: "")
        let event = SuggestionEvent(appBundleID: "fixture", sentence: "fixture", suggestion: edit, action: .accept, level: .standard, model: "local")
        let store = HistoryStore(directory: root)
        try store.append(event); XCTAssertEqual(store.habits.eventCount, 1)
        try store.append(event); XCTAssertEqual(store.habits.typos.count, 1)
        let id = try XCTUnwrap(store.habits.typos.first?.id)
        try store.setHabit(id, deleted: true)
        XCTAssertTrue(store.habits.personalTypos.isEmpty)
        let reloaded = HistoryStore(directory: root)
        XCTAssertTrue(reloaded.habits.personalTypos.isEmpty)
        XCTAssertEqual(reloaded.habits.eventCount, 2)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.overridesFile.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.overridesFile.path)
        try reloaded.setHabit(id, deleted: false); XCTAssertEqual(reloaded.habits.typos.count, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.overridesFile.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // An external replacement is not rescanned on append: startup is the only full read.
        try Data().write(to: store.file)
        try store.append(event); XCTAssertEqual(store.habits.eventCount, 3)
        try store.clear(); XCTAssertEqual(store.habits.eventCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.overridesFile.path))
        XCTAssertEqual(try Data(contentsOf: store.file).count, 0)
    }
    func testFailedOverrideWriteDoesNotChangeInMemoryProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(directory: root)
        try store.prepare()
        try FileManager.default.createDirectory(at: store.overridesFile, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.setHabit("synthetic", deleted: true))
        XCTAssertTrue(store.habits.excludedIDs.isEmpty)
    }
}

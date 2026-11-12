import XCTest
import StylePolishCore
@testable import StylePolishApp

final class StorageIsolationTests: XCTestCase {
    func testDefaultStoresCannotReachUserData() throws {
        XCTAssertTrue(RuntimeStorage.isolated)
        let temporary = FileManager.default.temporaryDirectory.path
        XCTAssertTrue(Diagnostics.shared.directory.path.hasPrefix(temporary))
        XCTAssertTrue(HistoryStore().directory.path.hasPrefix(temporary))
        XCTAssertTrue(CredentialStore().localURL.path.hasPrefix(temporary))
        XCTAssertTrue(RuntimeStorage.defaults is MemoryDefaults)
    }

    /// Run the entire test executable in a child, comparing only file metadata (no user contents).
    func testFullSuiteLeavesRealLogsHistoryAndPreferencesUnchanged() throws {
        guard ProcessInfo.processInfo.environment["STYLEPOLISH_ISOLATION_CHILD"] != "1" else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ["Library/Logs/StylePolish/diagnostics.jsonl", "Library/Application Support/StylePolish/history.jsonl",
                     "Library/Preferences/org.bmdy6.StylePolish.plist", "Library/Application Support/StylePolish/habits-overrides.json"]
        func snapshot() -> [String: String] {
            Dictionary(uniqueKeysWithValues: paths.map { path in
                let attrs = try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(path).path)
                return (path, attrs.map { "\($0[.size]!)|\(($0[.modificationDate] as! Date).timeIntervalSinceReferenceDate.bitPattern)" } ?? "absent")
            })
        }
        let before = snapshot()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [Bundle(for: StorageIsolationTests.self).bundleURL.path]
        var env = ProcessInfo.processInfo.environment
        env["STYLEPOLISH_ISOLATION_CHILD"] = "1"
        child.environment = env; child.standardOutput = handle; child.standardError = handle
        try child.run(); child.waitUntilExit()
        let childOutput = try Data(contentsOf: output)
        guard child.terminationStatus == 0 else {
            return XCTFail(String(decoding: childOutput.suffix(6000), as: UTF8.self))
        }
        XCTAssertEqual(snapshot(), before, "Complete suite must preserve real diagnostics, history and UserDefaults size/mtime/existence")
        print("Full-suite user-data guard: diagnostics.jsonl, history.jsonl, habits-overrides.json, UserDefaults unchanged (size + mtime + existence)")
    }
}

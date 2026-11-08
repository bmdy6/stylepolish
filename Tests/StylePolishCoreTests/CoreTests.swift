import XCTest
@testable import StylePolishCore
final class CoreTests: XCTestCase {
    func testDiffBlocks() {
        XCTAssertEqual(CharacterDiff("abc", "abc").changeCount, 0)
        XCTAssertEqual(CharacterDiff("abc", "axc").changeCount, 1)
        XCTAssertEqual(CharacterDiff("abcde", "axcye").changeCount, 2)
        XCTAssertEqual(CharacterDiff("", "你好👨‍👩‍👧").changeCount, 1)
        let diff = CharacterDiff("你好吗", "你好呀")
        XCTAssertEqual(diff.parts.filter { $0.kind != .insert }.map(\.text).joined(), "你好吗")
        XCTAssertEqual(diff.parts.filter { $0.kind != .delete }.map(\.text).joined(), "你好呀")
    }
    func testPostprocess() {
        XCTAssertEqual(postprocess("  你好。\n"), "你好")
        XCTAssertEqual(postprocess("Hi.."), "Hi.")
        XCTAssertEqual(postprocess("你好？！"), "你好？！")
        XCTAssertEqual(postprocess(" \n"), "")
    }
    func testWhitelist() {
        XCTAssertTrue(AppWhitelist.contains("com.tencent.xinWeChat", in: ["com.tencent.xinWeChat"]))
        XCTAssertFalse(AppWhitelist.contains("com.tencent.xinWeChat.evil", in: ["com.tencent.xinWeChat"]))
        XCTAssertFalse(AppWhitelist.contains(nil, in: ["*"]))
    }
    func testWriteGuardWithMock() {
        let initial = FocusSnapshot(pid: 12, element: "one", text: "abc", selection: NSRange(location: 1, length: 1))
        struct Mock: FocusProviding { let snapshot: FocusSnapshot?; func currentFocus() -> FocusSnapshot? { snapshot } }
        XCTAssertTrue(WriteGuard.canWrite(initial, provider: Mock(snapshot: initial)))
        for current in [FocusSnapshot(pid: 13, element: "one", text: "abc", selection: initial.selection),
                        FocusSnapshot(pid: 12, element: "two", text: "abc", selection: initial.selection),
                        FocusSnapshot(pid: 12, element: "one", text: "changed", selection: initial.selection),
                        FocusSnapshot(pid: 12, element: "one", text: "abc", selection: NSRange(location: 0, length: 0))] {
            XCTAssertFalse(WriteGuard.canWrite(initial, provider: Mock(snapshot: current)))
        }
        XCTAssertFalse(WriteGuard.canWrite(initial, provider: Mock(snapshot: nil)))
    }
    func testHistoryPermissionsAndNull() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryStore(directory: dir)
        try history.append(HistoryEntry(appBundleID: "test.app", input: "原文", output: "结果", final: nil, action: .cancel, model: "test", latencyMS: 12))
        let attributes = try FileManager.default.attributesOfItem(atPath: history.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let data = try Data(contentsOf: history.file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["final"] is NSNull)
        XCTAssertEqual(Set(object.keys), ["ts", "app_bundle_id", "input", "output", "final", "action", "model", "latency_ms"])
        try history.clear()
        XCTAssertEqual(try Data(contentsOf: history.file).count, 0)
    }
    func testSSE() throws {
        var parser = SSEParser()
        XCTAssertEqual(try parser.consume("data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}"), "你好")
        XCTAssertNil(try parser.consume(": ping"))
        XCTAssertNil(try parser.consume("data: [DONE]"))
        XCTAssertTrue(parser.isDone)
        XCTAssertThrowsError(try SSEParser().parseContent("bad json"))
    }
}

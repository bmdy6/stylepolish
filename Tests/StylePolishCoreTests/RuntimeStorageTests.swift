import XCTest

final class RuntimeStorageTests: XCTestCase {
    /// Compile the production source in a separate process without XCTest loaded,
    /// so XCTest's automatic isolation cannot conceal an argv[0] regression.
    func testIsolationArgumentsInARealNonXCTestProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = directory.appendingPathComponent("main.swift")
        try "import Foundation\nprint(RuntimeStorage.isolated)\n".write(to: main, atomically: true, encoding: .utf8)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/StylePolishCore/RuntimeStorage.swift")
        let executable = directory.appendingPathComponent("StylePolish")
        let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", source.path, main.path, "-o", executable.path]
        try compile.run(); compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)
        func isolated(_ binary: URL, _ arguments: [String] = []) throws -> String {
            let process = Process(); process.executableURL = binary; process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try isolated(executable), "false")
        let harnessPath = directory.appendingPathComponent("harness-production-StylePolish")
        try FileManager.default.copyItem(at: executable, to: harnessPath)
        XCTAssertEqual(try isolated(harnessPath), "false", "Executable path alone must not isolate production settings")
        for argument in ["--local-rules-harness", "--render-preview", "--capture-fixtures", "--latency-editor"] {
            XCTAssertEqual(try isolated(executable, [argument]), "true", argument)
        }
        let testPath = directory.appendingPathComponent("StylePolish.xctest")
        try FileManager.default.copyItem(at: executable, to: testPath)
        XCTAssertEqual(try isolated(testPath), "true")
    }
}

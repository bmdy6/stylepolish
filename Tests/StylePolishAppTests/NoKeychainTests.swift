import XCTest

final class NoKeychainTests: XCTestCase {
    func testAppSourcesNeverAccessKeychainOrLaunchCredentialTools() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        let forbidden = #"\b(SecItem\w*|SecKeychain\w*|kSec\w*|KeychainStore)\b|import\s+Security|/usr/bin/security|\b(Process|NSTask|dlopen|dlsym)\s*\("#
        for case let file as URL in files where file.pathExtension == "swift" {
            var source = try String(contentsOf: file, encoding: .utf8)
            // The existing fixture generator launches only screencapture, never a credential tool.
            if file.lastPathComponent == "FixtureCapture.swift" {
                let capture = "let process = Process(); process.executableURL = URL(fileURLWithPath: \"/usr/sbin/screencapture\")"
                XCTAssertTrue(source.contains(capture))
                source = source.replacingOccurrences(of: capture, with: "")
            }
            XCTAssertNil(source.range(of: forbidden, options: .regularExpression), file.lastPathComponent)
        }
    }
}

import XCTest
import AppKit
import SwiftUI
import StylePolishCore
@testable import StylePolishApp

final class PreviewRenderingTests: XCTestCase {
    private func preview(_ source: String, _ output: String) throws -> SuggestionPreview {
        try XCTUnwrap(SuggestionPreview.wholeRewrite(source: source, edits: [Suggestion(
            range: NSRange(location: 0, length: source.utf16.count),
            original: source, replacement: output, kind: .fluency, why: ""
        )]))
    }

    @MainActor func testHeightIncludesDeletedTextAndTwoLineLabels() throws {
        let output = String(repeating: "留", count: 30)
        let source = String(repeating: "删", count: 25) + output
        let deleted = try preview(source, output)
        let unchanged = try preview(output, output)
        XCTAssertEqual(deleted.mode, .diff)
        XCTAssertGreaterThan(AutomaticPreviewBar(preview: deleted, width: 500).textHeight,
                             AutomaticPreviewBar(preview: unchanged, width: 500).textHeight)
        let twoLine = try preview("原文", "重写")
        XCTAssertEqual(twoLine.mode, .twoLine)
        XCTAssertGreaterThan(AutomaticPreviewBar(preview: twoLine).textHeight,
                             AutomaticPreviewBar(preview: unchanged).textHeight)
        let long = try preview(String(repeating: "原文", count: 100), "重写")
        XCTAssertEqual(AutomaticPreviewBar(preview: long, width: 500).textHeight, 100)
    }

    /// Cache the production hosting view directly to a bitmap. ImageRenderer
    /// omits macOS ScrollView content, so it cannot validate this preview.
    /// No NSWindow, app installation, screen capture, or desktop access is used.
    @MainActor func testOffscreenPreviewFixtures() throws {
        let destination = ProcessInfo.processInfo.environment["STYLEPOLISH_PREVIEW_PNG_DIR"]
        let directory = destination.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if destination == nil { try? FileManager.default.removeItem(at: directory) } }
        let fixtures: [(String, String, String, SuggestionPreview.Mode)] = [
            ("deletion", "然后然后我觉得这个方案很好。", "我觉得这个方案很好。", .diff),
            ("replacement", "这个方案非长好，我们明天再讨论。", "这个方案非常好，我们明天再讨论。", .diff),
            ("two-line", "这个的话我看了一下，然后明天再确认。", "我看过了，明天确认。", .twoLine)
        ]
        for (name, source, output, mode) in fixtures {
            let snapshot = try preview(source, output)
            XCTAssertEqual(snapshot.mode, mode, name)
            let bar = AutomaticPreviewBar(preview: snapshot, width: 850)
            let host = NSHostingView(rootView: bar.frame(width: 850).environment(\.colorScheme, .light))
            host.frame = NSRect(x: 0, y: 0, width: 850, height: bar.textHeight + 20)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), name)
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var red = 0, green = 0, dark = 0
            // Check the text area, excluding the keyboard hint and border.
            for y in 4..<(bitmap.pixelsHigh - 4) {
                for x in 4..<Int(bar.textWidth) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.redComponent > 0.6 && color.greenComponent < 0.5 { red += 1 }
                    if color.greenComponent > color.redComponent * 1.5 && color.greenComponent > color.blueComponent * 1.2 { green += 1 }
                    if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.3 { dark += 1 }
                }
            }
            XCTAssertGreaterThan(dark, 0, "Missing preview text: \(name)")
            if mode == .diff { XCTAssertGreaterThan(red, 0, name) }
            if name == "replacement" { XCTAssertGreaterThan(green, 0, name) }
            if mode == .twoLine { XCTAssertEqual(red + green, 0, name) }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}

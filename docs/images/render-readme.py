#!/usr/bin/env python3
"""Render real AppKit/SwiftUI views in a disposable SwiftPM copy on macOS.

No app bundle, installation, on-screen windows, AX access or model requests.
Usage: python3 docs/images/render-readme.py --output /tmp/stylepolish-readme
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

SWIFT = r'''
#if DEBUG
import AppKit
import SwiftUI
import StylePolishCore

extension FixtureCapture {
    @MainActor static func captureReadme(directory: String) throws {
        precondition(RuntimeStorage.isolated)
        defer { try? FileManager.default.removeItem(at: RuntimeStorage.root) }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try readmeInline(to: output.appendingPathComponent("inline-suggestions.png"))

        let source = "这个方案的话，我们明天在讨论一下。"
        let target = "这个方案，我们明天再讨论。"
        let edit = Suggestion(range: NSRange(location: 0, length: source.utf16.count), original: source,
                              replacement: target, kind: .fluency, why: "删去赘词，修正错字")
        let preview = SuggestionPreview(source: source, edits: [edit])!
        try render(AutomaticPreviewBar(preview: preview, width: 800), size: NSSize(width: 800, height: 48),
                   to: output.appendingPathComponent("sentence-preview.png"))

        let root = RuntimeStorage.root.appendingPathComponent("readme")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().date(from: "2026-11-12T04:00:00Z")!
        var records = Data()
        func events(_ original: String, _ replacement: String, _ kind: String, _ action: String,
                    _ count: Int, sentence: String, days: Double = 0) throws {
            for _ in 0..<count {
                let row = ["ts": ISO8601DateFormatter().string(from: now.addingTimeInterval(-days * 86400)),
                           "original": original, "replacement": replacement, "kind": kind,
                           "action": action, "sentence": sentence]
                records.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                records.append(0x0A)
            }
        }
        try events("在", "再", "typo", "accept", 5, sentence: "我们明天在聊吧。")
        try events("非长", "非常", "typo", "accept", 2, sentence: "这个安排我非长期待。")
        try events("之需要", "只需要", "typo", "accept", 2, sentence: "你之需要带一把伞。")
        try events("的话", "", "filler", "ignore", 2, sentence: "周末的话，我们去散步吧。")
        try events("这个书架我想确认一下怎么固定。", "我想确认一下这个书架怎么固定。", "fluency", "accept", 6,
                   sentence: "这个书架我想确认一下怎么固定。")
        try events("在", "再", "typo", "accept", 8, sentence: "我们明天在聊吧。", days: 8)
        try events("非长", "非常", "typo", "accept", 2, sentence: "这个安排我非长期待。", days: 8)
        try events("之需要", "只需要", "typo", "accept", 2, sentence: "你之需要带一把伞。", days: 8)
        let history = HistoryStore(directory: root)
        try records.write(to: history.file)
        let settings = SettingsStore(defaults: MemoryDefaults(), credentialHome: root,
                                     history: HistoryStore(directory: root))
        try render(HabitsView(settings: settings), size: NSSize(width: 560, height: 590),
                   to: output.appendingPathComponent("my-habits.png"))
        var reportProfile = HabitProfile(now: now)
        for line in records.split(separator: 0x0A) { reportProfile.ingest(line: Data(line)) }
        try render(WeeklyReportView(report: reportProfile.report(now: now)),
                   size: NSSize(width: 720, height: 740), to: output.appendingPathComponent("weekly-report.png"))
    }

    @MainActor private static func readmeInline(to url: URL) throws {
        let size = NSSize(width: 800, height: 270)
        let drawing = WaveView(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: drawing.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = drawing; window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        drawing.wantsLayer = true; drawing.layer?.backgroundColor = NSColor.white.cgColor
        let examples: [(String, String, String, SuggestionKind, String)] = [
            ("明天的安排我非长期待。", "非长", "非常", .typo, "「非长」应写作「非常」"),
            ("这个书架我想确认一下怎么固定。", "这个书架我想确认一下怎么固定。",
             "我想确认一下这个书架怎么固定。", .fluency, "调顺语序")
        ]
        for (index, example) in examples.enumerated() {
            let (sentence, original, replacement, kind, why) = example
            let x = CGFloat(index * 400 + 20)
            let font = NSFont.systemFont(ofSize: 18)
            let field = NSTextField(labelWithString: sentence)
            field.font = font; field.textColor = .black
            field.frame = NSRect(x: x, y: 22, width: 370, height: 28)
            drawing.addSubview(field)
            let range = (sentence as NSString).range(of: original)
            let prefix = (sentence as NSString).substring(to: range.location)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let left = (prefix as NSString).size(withAttributes: attributes).width
            let width = (original as NSString).size(withAttributes: attributes).width
            drawing.marks.append(WaveMark(id: UUID(), rect: NSRect(x: x + 2 + left, y: 24, width: width, height: 23), kind: kind))
            let suggestion = Suggestion(range: range, original: original, replacement: replacement, kind: kind, why: why)
            let card = NSHostingView(rootView: SuggestionCard(suggestion: suggestion, accept: {}, ignore: {}, disable: {}))
            card.frame = NSRect(x: x, y: 63, width: 240, height: 195)
            drawing.addSubview(card)
        }
        drawing.layoutSubtreeIfNeeded()
        guard let bitmap = drawing.bitmapImageRepForCachingDisplay(in: drawing.bounds) else { throw CocoaError(.fileWriteUnknown) }
        drawing.cacheDisplay(in: drawing.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url); window.orderOut(nil)
    }
}
#endif
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo, output = args.repo.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    inputs = [repo / "Package.swift", *sorted(p for p in (repo / "Sources").rglob("*") if p.is_file())]
    receipt = {"data": "Natural synthetic dialogue and accept/ignore events; fixed date 2026-11-12",
               "modelCalls": 0, "capture": "Offscreen AppKit cacheDisplay / FixtureCapture.render",
               "inputs": {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}}
    with tempfile.TemporaryDirectory(prefix="stylepolish-readme-") as directory:
        scratch = Path(directory)
        shutil.copy2(repo / "Package.swift", scratch / "Package.swift")
        shutil.copytree(repo / "Sources", scratch / "Sources")
        # SwiftPM validates test target locations even when only building the executable.
        shutil.copytree(repo / "Tests", scratch / "Tests")
        entry = scratch / "Sources/StylePolishApp/StylePolishMain.swift"
        text = entry.read_text()
        old = "try FixtureCapture.run(directory: CommandLine.arguments[i + 1])"
        assert text.count(old) == 1
        entry.write_text(text.replace(old, "try FixtureCapture.captureReadme(directory: CommandLine.arguments[i + 1])"))
        (scratch / "Sources/StylePolishApp/ReadmeCapture.swift").write_text(SWIFT)
        build = ["swift", "build", "--package-path", str(scratch), "--product", "StylePolish"]
        subprocess.run(build, check=True)
        subprocess.run([str(scratch / ".build/debug/StylePolish"), "--capture-fixtures", str(output)], check=True)
    receipt["images"] = {p.name: {"sha256": hashlib.sha256(p.read_bytes()).hexdigest(), "bytes": p.stat().st_size}
                         for p in sorted(output.glob("*.png"))}
    (output / "capture-receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(receipt["images"], ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

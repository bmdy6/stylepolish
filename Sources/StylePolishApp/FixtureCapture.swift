#if DEBUG
import AppKit
import SwiftUI
import StylePolishCore

@MainActor enum FixtureCapture {
    static func run(directory: String) throws {
        guard let prompt = PolishClient.promptURL, FileManager.default.fileExists(atPath: prompt.path) else { throw CocoaError(.fileReadNoSuchFile) }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try captureHabits(to: url)
        if CommandLine.arguments.contains("--habits-only") { return }
        let indicators: [InputIndicatorState] = [.watching, .checking, .clean, .suggestions(3), .warning("模拟：读不到 AXValue，使用 ⌥ Space")]
        for (index, indicator) in indicators.enumerated() {
            let demo = VStack(alignment: .leading, spacing: 20) {
                Text("StylePolish · 状态模拟（非真实 App 验收）").font(.headline)
                Text("这个的话我觉得然后明天在做吧").font(.system(size: 18))
                HStack { Text(indicator.help).font(.caption); Spacer(); IndicatorView(state: indicator, click: {}) }
            }.padding(20).frame(width: 500, height: 150).background(Color(nsColor: .windowBackgroundColor))
            try render(demo, size: NSSize(width: 500, height: 150), to: url.appendingPathComponent("simulated-state-\(index + 1).png"))
        }
        let previewSource = "这次要确认的是这个书架如何固定。"
        let previewEdit = Suggestion(range: NSRange(location: 0, length: previewSource.utf16.count), original: previewSource, replacement: "这次要确认的是如何固定这个书架。", kind: .fluency, why: "调顺语序")
        let preview = SuggestionPreview(source: previewSource, edits: [previewEdit])!
        try render(AutomaticPreviewBar(preview: preview).frame(width: 850), size: NSSize(width: 850, height: 48), to: url.appendingPathComponent("automatic-preview-rendered.png"))
        let deletion = Suggestion(range: NSRange(location: 2, length: 2), original: "的话", replacement: "", kind: .filler, why: "删掉更干脆")
        let typo = Suggestion(range: NSRange(location: 0, length: 2), original: "非长", replacement: "非常", kind: .typo, why: "修正错别字")
        try render(SuggestionCard(suggestion: deletion, accept: {}, ignore: {}, disable: {}), size: NSSize(width: 240, height: 180), to: url.appendingPathComponent("inline-delete.png"))
        try render(SuggestionCard(suggestion: typo, accept: {}, ignore: {}, disable: {}), size: NSSize(width: 240, height: 155), to: url.appendingPathComponent("inline-typo.png"))
        let items = [LocatedSuggestion(edit: deletion, sentence: "这个的话很好"), LocatedSuggestion(edit: typo, sentence: "非长好")]
        try render(SuggestionList(suggestions: items, accept: { _ in }, ignore: { _ in }, acceptAll: {}), size: NSSize(width: 280, height: 230), to: url.appendingPathComponent("inline-list.png"))
        try captureWaves(to: url.appendingPathComponent("inline-waves.png"))
        let state = PanelModel(); state.appName = "示例 App"
        state.input = "这个的话我看了一下，然后明天再确认。"
        state.output = "我看了一下，明天我再确认"; state.edited = state.output; state.latencyMS = 1800
        for (name, phase) in [("preview", PanelPhase.preview), ("edit", .edit), ("error", .error), ("loading", .loading)] {
            state.phase = phase; state.message = "润色失败：接口超时（30s）。原文没动。"
            try render(PanelView(state: state), size: NSSize(width: 440, height: phase == .edit ? 240 : 210), to: url.appendingPathComponent(name + ".png"))
        }
        let defaults = MemoryDefaults()
        defaults.removePersistentDomain(forName: "org.bmdy6.StylePolish.fixture")
        let settings = SettingsStore(defaults: defaults)
        try render(SettingsView(settings: settings, openHistory: {}, clearHistory: {}, permission: {}, fixture: true), size: NSSize(width: 614, height: 650), to: url.appendingPathComponent("settings.png"))
        defaults.removePersistentDomain(forName: "org.bmdy6.StylePolish.fixture")
        if CommandLine.arguments.contains("--capture-menu") { captureMenu(to: url.appendingPathComponent("menu.png")) }
    }
    private static func captureWaves(to url: URL) throws {
        let field = NSTextField(labelWithString: "这个的话我看了一下，然后明天再确认")
        field.font = NSFont.systemFont(ofSize: 17); field.frame = NSRect(x: 20, y: 30, width: 400, height: 26)
        let wave = WaveView(frame: NSRect(x: 0, y: 0, width: 440, height: 90))
        let window = NSWindow(contentRect: wave.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = wave; window.backgroundColor = .white; wave.addSubview(field)
        wave.wantsLayer = true; wave.layer?.backgroundColor = NSColor.white.cgColor
        let first = UUID(), second = UUID()
        wave.marks = [WaveMark(id: first, rect: CGRect(x: 54, y: 31, width: 34, height: 23), kind: .filler), WaveMark(id: second, rect: CGRect(x: 224, y: 31, width: 34, height: 23), kind: .order)]
        wave.highlighted = first; wave.layoutSubtreeIfNeeded()
        guard let bitmap = wave.bitmapImageRepForCachingDisplay(in: wave.bounds) else { throw CocoaError(.fileWriteUnknown) }
        wave.cacheDisplay(in: wave.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url); window.orderOut(nil)
    }
    static func screenshot(to url: URL, rect: CGRect) -> Int32 {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(top - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))", url.path]
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return -1 }
    }
    private static func captureMenu(to url: URL) {
        // Capture the actual NSMenu over an app-owned blank window, never the user's desktop.
        let backdrop = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor(calibratedWhite: 0.93, alpha: 1); backdrop.level = .floating
        backdrop.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true)
        let controller = AppController()
        let menu = controller.makeMenu()
        var captured = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let frame = backdrop.frame
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-R\(Int(frame.minX)),\(Int(top - frame.maxY)),400,320", url.path]
            try? process.run(); process.waitUntilExit(); captured = true; menu.cancelTracking()
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 24, y: 290), in: backdrop.contentView)
        while !captured { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        backdrop.orderOut(nil)
    }
    static func render<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.appearance = NSAppearance(named: .aqua)
        let fitted = NSSize(width: size.width == 614 ? host.fittingSize.width : size.width, height: size.width == 614 ? host.fittingSize.height : size.height)
        window.setContentSize(fitted); host.frame = NSRect(origin: .zero, size: fitted); host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url); window.orderOut(nil)
    }
}

#endif

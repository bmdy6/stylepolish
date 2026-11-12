#if DEBUG
import AppKit
import SwiftUI
import StylePolishCore

/// Actual production views in hidden windows. No AX, key vault, model or desktop capture.
@MainActor enum V4Capture {
    static func run(directory: String) throws {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let name = "org.bmdy6.StylePolish.render." + UUID().uuidString
        let defaults = MemoryDefaults()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: home) }
        let settings = SettingsStore(defaults: defaults, credentialHome: home)
        func onboarding(_ model: OnboardingModel, _ filename: String) throws {
            try render(OnboardingView(model: model, settings: settings, permission: {}, finish: {}, fixture: true), height: 560, to: output.appendingPathComponent(filename))
        }
        try onboarding(OnboardingModel(settings: settings, trusted: false), "A1-authorization.png")
        try onboarding(OnboardingModel(settings: settings, trusted: true), "A2-no-key.png")
        try settings.saveKey("synthetic-render-a1b2")
        try onboarding(OnboardingModel(settings: settings, trusted: true), "A2-with-key.png")
        let trial = OnboardingModel(settings: settings, trusted: true)
        trial.state.engine = .local; trial.state.step = .trial; trial.state.didCheck = true
        trial.state.pending = LocalRules.check(trial.state.text, level: .standard)
        trial.selected = trial.state.pending.first?.id
        try onboarding(trial, "A3-trial.png")
        try render(SettingsView(settings: settings, openHistory: {}, clearHistory: {}, permission: {}, fixture: true, fixtureTrusted: true), to: output.appendingPathComponent("C-settings-collapsed.png"))
        try render(SettingsView(settings: settings, openHistory: {}, clearHistory: {}, permission: {}, fixture: true, fixtureTrusted: true, advanced: true), to: output.appendingPathComponent("C-settings-expanded.png"))
    }
    static func render<V: View>(_ view: V, height: CGFloat? = nil, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        let fitted = NSSize(width: 560, height: height ?? ceil(host.fittingSize.height))
        // An unshown backing window is needed to lay out AppKit's real NSTextView.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fitted), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: fitted); host.layoutSubtreeIfNeeded()
        guard !window.isVisible, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        print("Rendered \(url.lastPathComponent): \(Int(fitted.width))×\(Int(fitted.height)) pt, visible=\(window.isVisible)")
        window.close()
    }
}
#endif

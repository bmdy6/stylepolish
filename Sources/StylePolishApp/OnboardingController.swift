import AppKit
import SwiftUI

@MainActor final class OnboardingController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private var model: OnboardingModel?
    private var window: NSWindow?
    private var completed = false
    private var keyMonitor: Any?
    var permission: () -> Void
    var closed: () -> Void = {}
    init(settings: SettingsStore, permission: @escaping () -> Void) { self.settings = settings; self.permission = permission }
    var isVisible: Bool { window?.isVisible == true }
    var isKeyWindow: Bool { window?.isKeyWindow == true }
    func show() {
        if let window, window.isVisible { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let model = OnboardingModel(settings: settings, trusted: AccessibilityAccess.trusted())
        self.model = model; completed = false; model.opened()
        let host = NSHostingView(rootView: OnboardingView(model: model, settings: settings, permission: permission, finish: { [weak self] in self?.complete() }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "StylePolish"; window.contentView = host; window.delegate = self
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.center(); self.window = window
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isKeyWindow, self.model?.state.step == .trial,
                  [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.option, .command, .control, .shift]) == .option else { return event }
            self.model?.acceptAll(); return nil
        }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private func complete() {
        guard model?.state.canFinish == true else { return }
        completed = true; window?.close()
    }
    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        settings.onboarded = true
        model?.closed(completed: completed); model?.stop(); model = nil; closed()
    }
}

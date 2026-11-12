import AppKit
import ApplicationServices
import StylePolishCore

extension AccessibilityAccess {
    static func supportsAutomaticWrite(value: Bool, selectedText: Bool, range: Bool) -> Bool { value || (selectedText && range) }
    func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var writable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &writable) == .success && writable.boolValue
    }
    func automaticCapture() -> CapturedInput? {
        guard targetSupported, Self.trusted(), let (app, element) = focused(), allowed(element),
              let text = attribute(element, kAXValueAttribute) as? String, text.utf8.count <= 100_000 else { return nil }
        guard Self.supportsAutomaticWrite(value: settable(element, kAXValueAttribute), selectedText: settable(element, kAXSelectedTextAttribute), range: settable(element, kAXSelectedTextRangeAttribute)) else { return nil }
        return CapturedInput(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "App", element: element, input: text, fullText: text, range: selection(element), selected: false, clipboard: false, bounds: bounds(element), attachments: attachmentEvidence(element, text: text))
    }
    func rangeBounds(_ range: NSRange, in element: AXUIElement) -> CGRect? {
        var r = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &r) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(result, to: AXValue.self), .cgRect, &rect), rect.width > 0, rect.height > 0,
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
        return rect
    }
    func isCurrent(_ capture: CapturedInput, text: String) -> Bool {
        guard supports(capture.bundleID), let (app, element) = focused(), app.processIdentifier == capture.pid, CFEqual(capture.element, element), allowed(element) else { return false }
        guard let current = attribute(element, kAXValueAttribute) as? String else { return false }
        return current.utf16.elementsEqual(text.utf16)
    }
    func writeSuggestion(_ suggestion: Suggestion, source: String, to capture: CapturedInput, traceID: String? = nil, methodReported: (String) -> Void = { _ in }) -> Bool {
        guard isCurrent(capture, text: source), suggestion.matches(source) else { return false }
        let evidence = attachmentEvidence(capture.element, text: source)
        if capture.attachments.requiresProtection || evidence.requiresProtection || source.contains("\u{FFFC}") {
            let output = (source as NSString).replacingCharacters(in: suggestion.range, with: suggestion.replacement)
            methodReported("attachment_ranges")
            return writeAttachmentText(source: source, output: output, to: capture, traceID: traceID)
        }
        let expected = (source as NSString).replacingCharacters(in: suggestion.range, with: suggestion.replacement)
        if !settable(capture.element, kAXSelectedTextAttribute) || !settable(capture.element, kAXSelectedTextRangeAttribute) {
            methodReported("whole_value")
            guard settable(capture.element, kAXValueAttribute), isCurrent(capture, text: source),
                  AXUIElementSetAttributeValue(capture.element, kAXValueAttribute as CFString, expected as CFString) == .success else { return false }
            let current = attribute(capture.element, kAXValueAttribute) as? String
            let succeeded = current?.utf16.elementsEqual(expected.utf16) == true
            Diagnostics.shared.record(DiagnosticEvent(event: "whole_value_write", bundleID: capture.bundleID, readable: current != nil, hasAttachment: false, writeMethod: "whole_value", traceID: traceID, error: succeeded ? nil : "write_readback_mismatch"))
            return succeeded
        }
        methodReported("selected_range")
        let oldSelection = selection(capture.element)
        var range = CFRange(location: suggestion.range.location, length: suggestion.range.length)
        guard let value = AXValueCreate(.cfRange, &range), AXUIElementSetAttributeValue(capture.element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
        // Selecting may trigger the target app's own code. Re-read before changing text.
        guard isCurrent(capture, text: source), selection(capture.element) == suggestion.range,
              AXUIElementSetAttributeValue(capture.element, kAXSelectedTextAttribute as CFString, suggestion.replacement as CFString) == .success else {
            if let oldSelection { var old = CFRange(location: oldSelection.location, length: oldSelection.length); if let v = AXValueCreate(.cfRange, &old) { _ = AXUIElementSetAttributeValue(capture.element, kAXSelectedTextRangeAttribute as CFString, v) } }
            return false
        }
        guard let current = attribute(capture.element, kAXValueAttribute) as? String else { return false }
        return current.utf16.elementsEqual(expected.utf16)
    }
    // AX uses top-left coordinates in the primary screen's coordinate space.
    static func appKitRect(_ rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
}

@MainActor final class InputObserver {
    private var observer: AXObserver?
    private var registrations: [(AXUIElement, String)] = []
    private var activation: NSObjectProtocol?
    private var timer: Timer?
    private var pid: pid_t?
    private var element: AXUIElement?
    var changed: (() -> Void)?
    func start() {
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed?() }
        }
        // Reconnect after permission changes and cover apps which omit focus/scroll notifications.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.changed?() } }
    }
    func watch(_ capture: CapturedInput?) {
        guard let capture else { stopWatching(); return }
        if pid == capture.pid, let element, CFEqual(element, capture.element) { return }
        stopWatching(); pid = capture.pid; element = capture.element
        var created: AXObserver?
        guard AXObserverCreate(capture.pid, { _, _, _, context in
            guard let context else { return }
            let owner = Unmanaged<InputObserver>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.changed?() }
        }, &created) == .success, let created else { return }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        let app = AXUIElementCreateApplication(capture.pid)
        let access = AccessibilityAccess()
        var elements = [app, capture.element]
        if let raw = access.attribute(capture.element, kAXWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() { elements.append(unsafeBitCast(raw, to: AXUIElement.self)) }
        // Scroll containers may be ancestors between field and window.
        var current = capture.element
        for _ in 0..<8 {
            guard let parent = access.attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeBitCast(parent, to: AXUIElement.self); elements.append(current)
        }
        for target in elements {
            for name in [kAXFocusedUIElementChangedNotification, kAXValueChangedNotification, kAXMovedNotification, kAXResizedNotification, kAXSelectedTextChangedNotification] {
                if AXObserverAddNotification(created, target, name as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success { registrations.append((target, name)) }
            }
        }
    }
    private func stopWatching() {
        if let observer {
            for (target, name) in registrations { AXObserverRemoveNotification(observer, target, name as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil; registrations.removeAll(); pid = nil; element = nil
    }
    func stop() {
        stopWatching(); timer?.invalidate(); timer = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }; activation = nil
    }
}

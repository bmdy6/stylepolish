import AppKit
import ApplicationServices
import StylePolishCore

struct CapturedInput {
    let pid: pid_t
    let bundleID: String
    let appName: String
    let element: AXUIElement
    let input: String
    let fullText: String?
    let range: NSRange?
    let selected: Bool
    let clipboard: Bool
    let bounds: CGRect?
    var clipboardWhole = false
}

@MainActor final class AccessibilityAccess {
    private var pendingFallback: (pid_t, AXUIElement)?
    private(set) var fallbackApps = Set<String>()
    func useClipboard(for bundleID: String) { fallbackApps.insert(bundleID) }
    static func activationAttribute(bundleID: String) -> String? {
        if bundleID.hasPrefix("com.google.Chrome") { return "AXEnhancedUserInterface" }
        if ["com.linear", "com.electron.lark", "com.anthropic.claudefordesktop"].contains(bundleID) { return "AXManualAccessibility" }
        return nil
    }
    func activateAccessibility(for app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, let name = Self.activationAttribute(bundleID: id) else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        let result = AXUIElementSetAttributeValue(element, name as CFString, kCFBooleanTrue)
        Diagnostics.shared.record(DiagnosticEvent(event: "ax_activation", bundleID: id, axAttribute: name, axResult: result.rawValue, error: result == .success ? nil : "ax_set_failed"))
    }
    static func trusted(prompt: Bool = false) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
    }
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    func focused() -> (NSRunningApplication, AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute),
              CFGetTypeID(element) == AXUIElementGetTypeID(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        return (app, unsafeBitCast(element, to: AXUIElement.self))
    }
    func allowed(_ element: AXUIElement) -> Bool {
        let role = attribute(element, kAXRoleAttribute) as? String
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "") && subrole != kAXSecureTextFieldSubrole && role != kAXSecureTextFieldSubrole
    }
    func selection(_ element: AXUIElement) -> NSRange? {
        guard let v = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    func bounds(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point), AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    func windowBounds(_ element: AXUIElement) -> CGRect? {
        guard let raw = attribute(element, kAXWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return bounds(unsafeBitCast(raw, to: AXUIElement.self))
    }
    func capture(enabled: [String], forceWholeClipboard: Bool = false) async throws -> CapturedInput {
        guard Self.trusted() else { throw PolishFailure(message: "没有辅助功能权限，请在设置中授权") }
        guard let (app, element) = focused() else { throw PolishFailure(message: "找不到当前输入框") }
        guard AppWhitelist.contains(app.bundleIdentifier, in: enabled) else { throw PolishFailure(message: "这个 App 未启用") }
        guard allowed(element) else { throw PolishFailure(message: "只支持普通文字输入框，不读取密码框") }
        let selectedText = attribute(element, kAXSelectedTextAttribute) as? String ?? ""
        let fullText = attribute(element, kAXValueAttribute) as? String
        var range = selection(element)
        let wholeClipboard = forceWholeClipboard || app.bundleIdentifier == "com.tencent.xinWeChat"
        var input = selectedText.isEmpty ? (fullText ?? "") : selectedText
        let fallback = wholeClipboard || (input.isEmpty && fullText == nil)
        if fallback {
            let detected = fallbackApps.contains(app.bundleIdentifier ?? "")
            guard wholeClipboard || detected || (pendingFallback.map { $0.0 == app.processIdentifier && CFEqual($0.1, element) } ?? false) else {
                pendingFallback = (app.processIdentifier, element)
                throw PolishFailure(message: "这个输入框读不到，请先选中文字再按快捷键")
            }
            // Explicit shortcut on an ordinary AX text role; WeChat copies the entire editor.
            input = try await ClipboardTransaction.copySelection(selectAll: wholeClipboard, validate: {
                guard let (currentApp, currentElement) = self.focused() else { return false }
                return currentApp.processIdentifier == app.processIdentifier && CFEqual(element, currentElement)
            })
            if wholeClipboard { range = selection(element) }
            guard let (currentApp, currentElement) = focused(), currentApp.processIdentifier == app.processIdentifier, CFEqual(element, currentElement), selection(currentElement) == range else {
                throw PolishFailure(message: "输入框已变化，请重新按快捷键")
            }
        }
        pendingFallback = nil
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PolishFailure(message: "输入框或选区没有文字") }
        guard input.utf8.count <= 100_000 else { throw PolishFailure(message: "原文过长，请选中较短的一段") }
        return CapturedInput(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "App", element: element, input: input, fullText: fallback ? nil : fullText, range: range, selected: !selectedText.isEmpty || fallback, clipboard: fallback, bounds: bounds(element), clipboardWhole: wholeClipboard)
    }
    func snapshot(_ capture: CapturedInput) -> FocusSnapshot? {
        guard let (app, element) = focused(), allowed(element) else { return nil }
        let text = capture.clipboard ? nil : attribute(element, kAXValueAttribute) as? String
        let selected = capture.clipboard ? nil : attribute(element, kAXSelectedTextAttribute) as? String
        return FocusSnapshot(pid: app.processIdentifier, element: CFEqual(element, capture.element) ? "original" : "different", text: text ?? selected ?? "", selection: selection(element))
    }
    func unchanged(_ capture: CapturedInput) -> Bool {
        struct Provider: FocusProviding { let value: FocusSnapshot?; func currentFocus() -> FocusSnapshot? { value } }
        let original = FocusSnapshot(pid: capture.pid, element: "original", text: capture.fullText ?? (capture.clipboard ? "" : capture.input), selection: capture.range)
        return WriteGuard.canWrite(original, provider: Provider(value: snapshot(capture)))
    }
    // Returns false for stale input. Caller copies result, with no field writes.
    func write(_ text: String, to capture: CapturedInput) async throws -> Bool {
        guard unchanged(capture) else { return false }
        if capture.clipboard {
            let current = try await ClipboardTransaction.copySelection(selectAll: capture.clipboardWhole, validate: { self.unchanged(capture) })
            guard current.utf16.elementsEqual(capture.input.utf16), unchanged(capture) else { return false }
            try await ClipboardTransaction.paste(text, selectAll: capture.clipboardWhole, validate: { self.unchanged(capture) })
            return true
        }
        if !capture.selected {
            var range = CFRange(location: 0, length: (capture.fullText! as NSString).length)
            guard let value = AXValueCreate(.cfRange, &range), AXUIElementSetAttributeValue(capture.element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { throw PolishFailure(message: "输入框不允许设置选区，原文没动") }
        }
        guard AXUIElementSetAttributeValue(capture.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            // Restore the original selection if AX refused the replacement.
            if !capture.selected, let original = capture.range { var r = CFRange(location: original.location, length: original.length); if let v = AXValueCreate(.cfRange, &r) { _ = AXUIElementSetAttributeValue(capture.element, kAXSelectedTextRangeAttribute as CFString, v) } }
            throw PolishFailure(message: "输入框拒绝写回，原文没动")
        }
        return true
    }
}

@MainActor enum ClipboardTransaction {
    static func snapshot() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }
    static func restore(_ items: [NSPasteboardItem], ifOwned count: Int) {
        let pb = NSPasteboard.general
        guard pb.changeCount == count else { return }
        pb.clearContents(); if !items.isEmpty { pb.writeObjects(items) }
    }
    static let allowedCommandKeys: Set<CGKeyCode> = [0, 8, 9]
    static func command(_ key: CGKeyCode) throws {
        // Only A, C and V are legal here. Never synthesize Return or other app actions.
        guard allowedCommandKeys.contains(key), let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { throw PolishFailure(message: "无法发送复制／粘贴快捷键") }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    static func copySelection(selectAll: Bool = false, validate: () -> Bool = { true }) async throws -> String {
        let pb = NSPasteboard.general, saved = snapshot()
        pb.clearContents(); let baseline = pb.changeCount
        var owned = baseline
        defer { restore(saved, ifOwned: owned) }
        guard validate() else { throw PolishFailure(message: "输入框已变化") }
        if selectAll {
            try command(0)
            try await Task.sleep(nanoseconds: 60_000_000)
            // Selection changes deliberately; caller validates field identity here.
        }
        guard validate() else { throw PolishFailure(message: "输入框已变化") }
        try command(8)
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if pb.changeCount != baseline { owned = pb.changeCount; break }
        }
        guard owned != baseline, let text = pb.string(forType: .string), !text.isEmpty else { throw PolishFailure(message: "没有读到选中文字，请先选中再按快捷键") }
        return text
    }
    static func paste(_ text: String, selectAll: Bool = false, validate: () -> Bool) async throws {
        let pb = NSPasteboard.general, saved = snapshot()
        guard validate() else { throw PolishFailure(message: "输入框已变化，请重新润色") }
        pb.clearContents(); pb.setString(text, forType: .string); let owned = pb.changeCount
        defer { restore(saved, ifOwned: owned) }
        if selectAll { try command(0) }
        guard validate() else { throw PolishFailure(message: "输入框已变化") }
        try command(9)
        // Apps consume the pasteboard asynchronously. This path requires real-app acceptance.
        try await Task.sleep(nanoseconds: 300_000_000)
    }
    static func copyResult(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

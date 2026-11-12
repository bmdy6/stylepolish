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
    var attachments: AttachmentEvidence = .unknown
}

@MainActor final class AccessibilityAccess {
    let supportedApps: SupportedApps
    private var activatedPID: pid_t?
    private let frontmostApplication: () -> NSRunningApplication?
    private var pendingFallback: (pid_t, AXUIElement)?
    private(set) var fallbackApps = Set<String>()
    #if DEBUG
    // Explicit synthetic editors only; absent from release and never loaded from settings.
    private var testingApp: String?
    init(testingApp: String) {
        precondition(testingApp == "org.bmdy6.StylePolish" || testingApp.hasPrefix("org.bmdy6.StylePolish."))
        self.supportedApps = SupportedApps()
        self.testingApp = testingApp
        self.frontmostApplication = { NSWorkspace.shared.frontmostApplication }
    }
    #endif
    init(supportedApps: SupportedApps = SupportedApps(), frontmostApplication: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }) {
        self.supportedApps = supportedApps
        self.frontmostApplication = frontmostApplication
    }
    func supports(_ bundleID: String?) -> Bool {
        #if DEBUG
        if let testingApp { return bundleID == testingApp }
        #endif
        return supportedApps.isEnabled(bundleID)
    }
    func activationAttribute(bundleID: String) -> String? {
        supports(bundleID) ? supportedApps.app(bundleID)?.axActivation : nil
    }
    func activateAccessibility(for app: NSRunningApplication) {
        guard frontmostApplication()?.processIdentifier == app.processIdentifier,
              let id = app.bundleIdentifier, let name = activationAttribute(bundleID: id) else { return }
        guard activatedPID != app.processIdentifier else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        let result = AXUIElementSetAttributeValue(element, name as CFString, kCFBooleanTrue)
        if result == .success { activatedPID = app.processIdentifier }
        Diagnostics.shared.record(DiagnosticEvent(event: "ax_activation", bundleID: id, axAttribute: name, axResult: result.rawValue, error: result == .success ? nil : "ax_set_failed"))
    }
    var targetSupported: Bool { supports(frontmostApplication()?.bundleIdentifier) }
    func isForeground(_ capture: CapturedInput) -> Bool {
        guard let app = frontmostApplication() else { return false }
        return matchesForeground(capture, bundleID: app.bundleIdentifier, pid: app.processIdentifier)
    }
    func matchesForeground(_ capture: CapturedInput, bundleID: String?, pid: pid_t) -> Bool {
        supports(capture.bundleID) && bundleID == capture.bundleID && pid == capture.pid
    }
    func useClipboard(for bundleID: String) {
        guard supports(bundleID) else { return }
        fallbackApps.insert(bundleID)
    }
    static func trusted(prompt: Bool = false) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
    }
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    func focused() -> (NSRunningApplication, AXUIElement)? {
        guard let app = frontmostApplication(), supports(app.bundleIdentifier) else { return nil }
        activateAccessibility(for: app)
        guard let element = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute),
              CFGetTypeID(element) == AXUIElementGetTypeID(),
              frontmostApplication()?.processIdentifier == app.processIdentifier else { return nil }
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
    func capture(forceWholeClipboard: Bool = false) async throws -> CapturedInput {
        guard targetSupported else { throw PolishFailure(message: "这个 App 未启用") }
        guard Self.trusted() else { throw PolishFailure(message: "没有辅助功能权限，请在设置中授权") }
        guard let (app, element) = focused() else { throw PolishFailure(message: "找不到当前输入框") }
        guard allowed(element) else { throw PolishFailure(message: "只支持普通文字输入框，不读取密码框") }
        let selectedText = attribute(element, kAXSelectedTextAttribute) as? String ?? ""
        let fullText = attribute(element, kAXValueAttribute) as? String
        var range = selection(element)
        let wholeClipboard = forceWholeClipboard || supportedApps.app(app.bundleIdentifier)?.clipboardWhole == true
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
        return CapturedInput(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "App", element: element, input: input, fullText: fallback ? nil : fullText, range: range, selected: !selectedText.isEmpty || fallback, clipboard: fallback, bounds: bounds(element), clipboardWhole: wholeClipboard, attachments: attachmentEvidence(element, text: fullText ?? input))
    }
    func snapshot(_ capture: CapturedInput) -> FocusSnapshot? {
        guard isForeground(capture), let (app, element) = focused(), allowed(element) else { return nil }
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
    func write(_ text: String, to capture: CapturedInput, diagnostics: DiagnosticTrace? = nil) async throws -> Bool {
        guard isForeground(capture) else { throw PolishFailure(message: "这个 App 未启用") }
        let source = capture.fullText ?? capture.input
        let expected: String
        if capture.selected, let range = capture.range, let full = capture.fullText, NSMaxRange(range) <= full.utf16.count {
            expected = (full as NSString).replacingCharacters(in: range, with: text)
        } else { expected = text }
        guard unchanged(capture) else {
            diagnostics?.write(source: source, expected: expected, readback: nil, method: "copy_only", attachment: capture.attachments, error: "stale_input")
            return false
        }
        var evidence = attachmentEvidence(capture.element, text: attribute(capture.element, kAXValueAttribute) as? String ?? capture.input)
        var method = "none"
        var failure: String?
        defer {
            let readback = allowed(capture.element) ? attribute(capture.element, kAXValueAttribute) as? String : nil
            diagnostics?.write(source: source, expected: expected, readback: readback, method: method, attachment: evidence, error: failure ?? (method == "copy_only" ? "attachment_protected" : method == "none" ? "write_failed" : nil))
            Diagnostics.shared.record(DiagnosticEvent(event: "manual_write", bundleID: capture.bundleID, hasAttachment: evidence.hasAttachment || capture.attachments.hasAttachment, attachmentEvidenceComplete: evidence.complete, writeMethod: method, traceID: diagnostics?.id))
        }
        func copyOnly() throws -> Never {
            guard unchanged(capture) else { throw PolishFailure(message: "输入框已变化，请重新按快捷键") }
            method = "copy_only"
            ClipboardTransaction.copyResult(AttachmentSafety.clipboardText(text))
            throw PolishFailure(message: evidence.hasAttachment || capture.attachments.hasAttachment ? AttachmentSafety.copyMessage : AttachmentSafety.unknownMessage)
        }
        if capture.attachments.requiresProtection || evidence.requiresProtection || capture.input.contains("\u{FFFC}") {
            // Clipboard capture does not preserve a trustworthy full rich-text coordinate system.
            if !capture.clipboard, !capture.selected, let source = capture.fullText,
               writeAttachmentText(source: source, output: text, to: capture, traceID: diagnostics?.id) { method = "attachment_ranges"; return true }
            try copyOnly()
        }
        if capture.clipboard {
            let current = try await ClipboardTransaction.copySelection(selectAll: capture.clipboardWhole, validate: { self.unchanged(capture) })
            guard current.utf16.elementsEqual(capture.input.utf16), unchanged(capture) else { failure = "stale_input"; return false }
            evidence = attachmentEvidence(capture.element, text: attribute(capture.element, kAXValueAttribute) as? String ?? current)
            if evidence.requiresProtection { try copyOnly() }
            do {
                try await ClipboardTransaction.paste(text, selectAll: capture.clipboardWhole, validate: { self.unchanged(capture) && !self.attachmentEvidence(capture.element, text: self.attribute(capture.element, kAXValueAttribute) as? String ?? current).requiresProtection })
            } catch {
                evidence = attachmentEvidence(capture.element, text: attribute(capture.element, kAXValueAttribute) as? String ?? current)
                if evidence.requiresProtection { try copyOnly() }
                failure = "paste_failed"; throw error
            }
            method = "clipboard"
            return true
        }
        if !capture.selected {
            var range = CFRange(location: 0, length: (capture.fullText! as NSString).length)
            guard let value = AXValueCreate(.cfRange, &range), AXUIElementSetAttributeValue(capture.element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { failure = "selection_rejected"; throw PolishFailure(message: "输入框不允许设置选区，原文没动") }
        }
        evidence = attachmentEvidence(capture.element, text: attribute(capture.element, kAXValueAttribute) as? String ?? capture.input)
        if evidence.requiresProtection {
            if let original = capture.range {
                var r = CFRange(location: original.location, length: original.length)
                if let v = AXValueCreate(.cfRange, &r) { _ = AXUIElementSetAttributeValue(capture.element, kAXSelectedTextRangeAttribute as CFString, v) }
            }
            try copyOnly()
        }
        guard AXUIElementSetAttributeValue(capture.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            // Restore the original selection if AX refused the replacement.
            if !capture.selected, let original = capture.range { var r = CFRange(location: original.location, length: original.length); if let v = AXValueCreate(.cfRange, &r) { _ = AXUIElementSetAttributeValue(capture.element, kAXSelectedTextRangeAttribute as CFString, v) } }
            failure = "range_write_rejected"; throw PolishFailure(message: "输入框拒绝写回，原文没动")
        }
        method = "selected_range"
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
        guard validate() else { throw PolishFailure(message: "输入框已变化") }
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
        guard validate() else { throw PolishFailure(message: "输入框已变化") }
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

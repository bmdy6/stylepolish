import AppKit
import ApplicationServices
import StylePolishCore

// No text, titles, URLs or attribute values are serialized; only structural metadata.
@MainActor enum InputProbe {
    // Explicit CLI-only acceptance: read an existing field, never focus/type/copy/write.
    static func modelCheck(access: AccessibilityAccess, target: NSRunningApplication, config: PolishConfiguration) async throws {
        guard access.supports(target.bundleIdentifier) else { throw PolishFailure(message: "这个 App 未启用") }
        let root = AXUIElementCreateApplication(target.processIdentifier)
        var candidates: [AXUIElement] = []
        if let raw = access.attribute(root, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            candidates.append(unsafeBitCast(raw, to: AXUIElement.self))
        }
        if let windows = access.attribute(root, kAXWindowsAttribute) as? [AXUIElement] { candidates += windows }
        var visited = Set<CFHashCode>(), count = 0
        var field: AXUIElement?
        while !candidates.isEmpty, count < 3000 {
            let element = candidates.removeFirst(); count += 1
            guard visited.insert(CFHash(element)).inserted else { continue }
            let role = access.attribute(element, kAXRoleAttribute) as? String
            if role == kAXTextAreaRole, access.allowed(element), access.attribute(element, kAXValueAttribute) is String, access.settable(element, kAXValueAttribute) || access.settable(element, kAXSelectedTextAttribute) {
                field = element; break
            }
            if let children = access.attribute(element, kAXChildrenAttribute) as? [AXUIElement] { candidates += children }
        }
        guard let field, let text = access.attribute(field, kAXValueAttribute) as? String else { throw PolishFailure(message: "未找到可编辑的普通输入框") }
        let started = Date()
        let edits = text.isEmpty ? [] : try await PolishClient().wholeResult(text, config: config).suggestions
        let unchanged = (access.attribute(field, kAXValueAttribute) as? String)?.utf16.elementsEqual(text.utf16) == true
        let report: [String: Any] = ["bundleID": target.bundleIdentifier ?? "", "role": access.attribute(field, kAXRoleAttribute) as? String ?? "", "readable": true, "hasPosition": access.bounds(field) != nil, "modelSkippedEmptyInput": text.isEmpty, "writes": 0, "textLength": text.utf16.count, "suggestions": edits.count, "requestMS": Int(Date().timeIntervalSince(started)*1000), "unchanged": unchanged, "model": config.model, "serviceTier": config.serviceTier]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
        guard unchanged else { throw PolishFailure(message: "输入框在测试期间发生变化") }
    }
    static func write(access: AccessibilityAccess, target: NSRunningApplication? = nil) throws -> URL {
        guard access.supports((target ?? NSWorkspace.shared.frontmostApplication)?.bundleIdentifier) else { throw PolishFailure(message: "这个 App 未启用") }
        let focus: (NSRunningApplication, AXUIElement)?
        if let target, let raw = access.attribute(AXUIElementCreateApplication(target.processIdentifier), kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            focus = (target, unsafeBitCast(raw, to: AXUIElement.self))
        } else if target != nil { focus = nil } else { focus = access.focused() }
        guard let (app, element) = focus else { throw PolishFailure(message: "没有当前焦点元素") }
        func names(_ element: AXUIElement, parameterized: Bool = false) -> [String] {
            var values: CFArray?
            if parameterized { _ = AXUIElementCopyParameterizedAttributeNames(element, &values) }
            else { _ = AXUIElementCopyAttributeNames(element, &values) }
            return values as? [String] ?? []
        }
        func rect(_ value: CGRect?) -> Any {
            guard let value else { return NSNull() }
            return ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
        }
        var parents: [[String: Any]] = []; var current = element
        for _ in 0..<5 {
            guard let raw = access.attribute(current, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
            current = unsafeBitCast(raw, to: AXUIElement.self)
            parents.append(["role": access.attribute(current, kAXRoleAttribute) as? String ?? "unknown", "titleLength": (access.attribute(current, kAXTitleAttribute) as? String)?.utf16.count ?? 0])
        }
        let value = access.attribute(element, kAXValueAttribute) as? String
        let selection = access.selection(element)
        let range = selection ?? NSRange(location: 0, length: 0)
        var probeRange = CFRange(location: range.location, length: range.length)
        var rangeValue: CFTypeRef?
        let rangeResult = AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, AXValueCreate(.cfRange, &probeRange)!, &rangeValue)
        func settable(_ name: String) -> Bool {
            var result: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
        }
        let report: [String: Any] = ["bundleID": app.bundleIdentifier ?? "", "role": access.attribute(element, kAXRoleAttribute) as? String ?? "unknown", "subrole": access.attribute(element, kAXSubroleAttribute) as? String ?? "", "attributes": names(element), "parameterizedAttributes": names(element, parameterized: true), "AXValueReadable": value != nil, "textLength": value?.utf16.count as Any? ?? NSNull(), "AXSelectedTextRange": selection.map { ["location": $0.location, "length": $0.length] } as Any? ?? NSNull(), "AXFrame": rect(access.bounds(element)), "parents": parents, "AXBoundsForRange": rect(access.rangeBounds(range, in: element)), "AXBoundsForRangeResult": rangeResult.rawValue, "AXValueSettable": settable(kAXValueAttribute), "AXSelectedTextSettable": settable(kAXSelectedTextAttribute), "AXSelectedTextRangeSettable": settable(kAXSelectedTextRangeAttribute)]
        let directory = Diagnostics.shared.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("probe-\(Int(Date().timeIntervalSince1970 * 1000)).json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        Diagnostics.shared.record(DiagnosticEvent(event: "probe", bundleID: app.bundleIdentifier ?? "", textLength: value?.utf16.count, readable: value != nil, hasPosition: access.bounds(element) != nil))
        return url
    }
}

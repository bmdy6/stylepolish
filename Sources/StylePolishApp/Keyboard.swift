import AppKit
import Carbon
import StylePolishCore

@MainActor final class KeyboardController {
    private let supportedApps: SupportedApps
    private let frontmostBundleID: () -> String?
    init(supportedApps: SupportedApps = SupportedApps(), frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.supportedApps = supportedApps
        self.frontmostBundleID = frontmostBundleID
    }
    var targetSupported: Bool { supportedApps.isEnabled(frontmostBundleID()) }
    private var hotkey: EventHotKeyRef?
    private var probeHotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var pointer: ((CGPoint) -> Bool)?
    var scrolled: (() -> Void)?
    var probe: (() -> Void)?
    var trigger: (() -> Void)?
    var handle: ((CGKeyCode, CGEventFlags) -> Bool)?
    var interceptionAvailable: Bool { tap != nil }
    func start(legacyEnabled: Bool = false) {
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<KeyboardController>.fromOpaque(context).takeUnretainedValue()
                var id = EventHotKeyID()
                if let event { GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) }
                return MainActor.assumeIsolated { controller.dispatchHotkey(id.id) ? noErr : OSStatus(eventNotHandledErr) }
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let legacyEnabled = legacyEnabled && targetSupported
        if legacyEnabled, hotkey == nil { RegisterEventHotKey(49, UInt32(optionKey), EventHotKeyID(signature: 0x53504F4C, id: 1), GetApplicationEventTarget(), 0, &hotkey) }
        if !legacyEnabled, let old = hotkey { UnregisterEventHotKey(old); hotkey = nil }
        if !targetSupported, let old = probeHotkey { UnregisterEventHotKey(old); probeHotkey = nil }
        if targetSupported, probeHotkey == nil { RegisterEventHotKey(35, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x53504F4C, id: 3), GetApplicationEventTarget(), 0, &probeHotkey) }
        guard tap == nil else { return }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.scrollWheel.rawValue), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<KeyboardController>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = controller.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return Unmanaged.passUnretained(event)
                    }
                    guard controller.targetSupported else {
                        controller.suppressedMouse = false; controller.suppressed.removeAll()
                        return Unmanaged.passUnretained(event)
                    }
                    if type == .scrollWheel { controller.scrolled?(); return Unmanaged.passUnretained(event) }
                    if type == .leftMouseUp, controller.suppressedMouse { controller.suppressedMouse = false; return nil }
                    if type == .leftMouseDown {
                        let top = NSScreen.screens.first?.frame.maxY ?? 0
                        if controller.pointer?(CGPoint(x: event.location.x, y: top - event.location.y)) == true { controller.suppressedMouse = true; return nil }
                        return Unmanaged.passUnretained(event)
                    }
                    let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                    if controller.consumeKey(type: type, code: code, flags: event.flags) { return nil }
                    return Unmanaged.passUnretained(event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    @discardableResult func dispatchHotkey(_ id: UInt32) -> Bool {
        guard targetSupported else { return false }
        if id == 3 { probe?() } else { trigger?() }
        return true
    }
    func consumeKey(type: CGEventType, code: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard targetSupported else { suppressed.removeAll(); return false }
        if type == .keyUp { return suppressed.remove(code) != nil }
        guard type == .keyDown else { return false }
        if suppressed.contains(code) { return true }
        guard handle?(code, flags) == true else { return false }
        suppressed.insert(code); return true
    }
    private var suppressedMouse = false
    private var suppressed = Set<CGKeyCode>()
    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let probeHotkey { UnregisterEventHotKey(probeHotkey) }
        if let handler { RemoveEventHandler(handler) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}

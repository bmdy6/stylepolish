import AppKit

// A separate AX server; all text and events belong to this synthetic editor.
final class Editor: NSTextView {
    var mode = "native"
    var eventFile = ""
    override func setAccessibilityValue(_ value: Any?) {
        if mode == "native" { super.setAccessibilityValue(value) }
    }
    override func setAccessibilitySelectedText(_ value: String?) {
        if mode == "native" { super.setAccessibilitySelectedText(value) }
    }
    override func paste(_ sender: Any?) {
        if mode != "ignore-paste" { super.paste(sender) }
    }
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.option, .command, .control, .shift]) == .option {
            let old = (try? String(contentsOfFile: eventFile)) ?? ""
            try? (old + "option-return\n").write(toFile: eventFile, atomically: true, encoding: .utf8)
            return
        }
        super.keyDown(with: event)
    }
}
#if ATTACHMENT_HARNESS
// Reuse this editor with real NSTextAttachment objects, without NSApplication, windows,
// activation, pasteboard or external AX writes. Compile with AttachmentSafety.swift.
if CommandLine.arguments.contains("--headless-attachments") {
    var passed = 0, failed = 0
    func check(_ value: Bool, _ name: String) {
        print("\(value ? "PASS" : "FAIL") \(name)")
        if value { passed += 1 } else { failed += 1 }
    }
    func fixture() -> (Editor, [NSTextAttachment]) {
        let editor = Editor(frame: NSRect(x: 0, y: 0, width: 620, height: 180))
        editor.isRichText = true; editor.importsGraphics = true
        let content = NSMutableAttributedString(string: "🙂非长好")
        let attachments = (0..<2).map { _ in NSTextAttachment(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jr1cAAAAASUVORK5CYII="), ofType: "public.png") }
        content.append(NSAttributedString(attachment: attachments[0]))
        content.append(NSAttributedString(string: "明天在讨论"))
        content.append(NSAttributedString(attachment: attachments[1]))
        content.append(NSAttributedString(string: "的话"))
        editor.textStorage!.setAttributedString(content)
        return (editor, attachments)
    }
    func imageObjects(_ editor: Editor) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        editor.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: editor.textStorage!.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }
    for all in [false, true] {
        let (editor, originals) = fixture()
        let source = editor.string
        let output = all ? "🙂非常好\u{FFFC}明天再讨论\u{FFFC}" : "🙂非常好\u{FFFC}明天在讨论\u{FFFC}的话"
        let evidence = AttachmentEvidence.inspect(text: source, attributed: editor.textStorage!)
        let edits = AttachmentSafety.plan(source: source, output: output, evidence: evidence)!
        let applied = AttachmentSafety.apply(edits, source: source, output: output, valid: { true }, read: { editor.string }, select: { range in
            editor.setSelectedRange(range); return editor.selectedRange() == range
        }, selectedText: { (editor.string as NSString).substring(with: editor.selectedRange()) }, replace: { text in
            editor.setAccessibilitySelectedText(text); return true
        })
        check(applied && editor.string == output, all ? "accept all range writes" : "accept one range write")
        let images = imageObjects(editor)
        check(images.count == 2 && images[0] === originals[0] && images[1] === originals[1], all ? "all preserves image identity/order" : "one preserves image identity/order")
    }
    let (editor, originals) = fixture()
    let source = editor.string
    let evidence = AttachmentEvidence.inspect(text: source, attributed: editor.textStorage!)
    check(AttachmentSafety.plan(source: source, output: "非常好，明天再讨论", evidence: evidence) == nil && editor.string == source && imageObjects(editor).count == originals.count, "missing anchors refuses before editing")
    let edits = AttachmentSafety.plan(source: source, output: "🙂非常好\u{FFFC}明天再讨论\u{FFFC}的话", evidence: evidence)!
    let refused = AttachmentSafety.apply(edits, source: source, output: "unused", valid: { true }, read: { editor.string }, select: { _ in false }, selectedText: { nil }, replace: { _ in fatalError("must not mutate") })
    check(!refused && editor.string == source && imageObjects(editor).count == 2, "unsupported range refuses before editing")
    editor.setAccessibilityValue("🙂非常好\u{FFFC}明天再讨论\u{FFFC}的话")
    check(imageObjects(editor).isEmpty, "old whole AXValue assignment loses real attachments")
    print("RESULT passed=\(passed) failed=\(failed) skipped=0 windows=0 externalWrites=0")
    exit(failed == 0 ? 0 : 1)
}
#endif
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
item.submenu = editMenu; menu.addItem(item); app.mainMenu = menu
let editor = Editor(frame: NSRect(x: 0, y: 0, width: 620, height: 180))
editor.mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "native"
editor.eventFile = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/dev/null"
editor.font = .systemFont(ofSize: 22)
editor.string = "这个方案非长好，我们明天在讨论。"
let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 620, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "StylePolish · 合成写回验收"
window.contentView = editor
window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
app.activate(ignoringOtherApps: true)
app.run()

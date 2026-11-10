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

import AppKit

/// AppKit 菜单栏应用也需要标准编辑菜单，系统才能把 ⌘V 等快捷键交给当前文本编辑器。
@MainActor
enum EditMenu {
    static func make() -> NSMenu {
        let menu = NSMenu(title: L("编辑", "Edit"))
        for (title, selector, key) in [
            (L("撤销", "Undo"), "undo:", "z"),
            (L("重做", "Redo"), "redo:", "Z"),
            (L("剪切", "Cut"), "cut:", "x"),
            (L("复制", "Copy"), "copy:", "c"),
            (L("粘贴", "Paste"), "paste:", "v"),
            (L("全选", "Select All"), "selectAll:", "a")
        ] {
            let item = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key.lowercased())
            item.keyEquivalentModifierMask = key == "Z" ? [.command, .shift] : [.command]
            // nil target 使用 responder chain，支持 TextField 与 SwiftUI TextEditor。
            item.target = nil
            menu.addItem(item)
        }
        return menu
    }
    static func install() {
        let main = NSApp.mainMenu ?? NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu(title: "ServerIsland")
        app.submenu?.addItem(withTitle: L("退出 ServerIsland", "Quit ServerIsland"),
                            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(app)
        let edit = NSMenuItem(title: L("编辑", "Edit"), action: nil, keyEquivalent: "")
        edit.submenu = make()
        main.addItem(edit)
        NSApp.mainMenu = main
    }
}

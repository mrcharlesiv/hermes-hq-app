// [mac-audit K] DEBUG: `-HQDebugMacShotsMenus` writes the menu bar as AppKit built it (every menu, item, key and
// modifier mask) and the Dock menu's items to `<name>-menus.txt`, then photographs Help › Keyboard Shortcuts and the
// Tool Calls sheet (each a window of its own on the Mac), with their sizes in the log.

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

extension MacShots {
    @MainActor static func menusTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(0.8))
        if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
        try? await Task.sleep(for: .seconds(2.5))
        let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject
        if let main = app?.value(forKey: "mainMenu") as? NSObject {
            log += "menu bar:\n" + menuTree(main, depth: 0)
        } else {
            log += "menu bar: none\n"
        }
        log += "dock menu: " + MacDockMenu.shared.titles().map { $0 ?? "—" }.joined(separator: " | ") + "\n"

        func sheetShot(_ label: String) {
            var top = window.rootViewController
            while let next = top?.presentedViewController { top = next }
            let nav = top as? UINavigationController
            log += "\(label): \(top.map { String(describing: type(of: $0)) } ?? "-") wants \(nav?.preferredContentSize ?? .zero) "
                + "frame \(top?.view.frame.size ?? .zero) window \(top?.viewIfLoaded?.window?.bounds.size ?? .zero)\n"
            let target = top?.viewIfLoaded?.window ?? window
            shoot(target, to: folder.appending(path: "\(name)-\(label).png"))
        }
        func dismissAll() async {
            var top = window.rootViewController
            while let next = top?.presentedViewController { top = next }
            if top !== window.rootViewController { top?.presentingViewController?.dismiss(animated: false) }
            try? await Task.sleep(for: .seconds(0.8))
        }

        log += "shortcuts sheet rows:\n" + KeyShortcutsSheet.sections().map { section in
            section.title + "\n" + section.rows.map { "  \($0.title)  \($0.keys.joined(separator: " "))" }.joined(separator: "\n")
        }.joined(separator: "\n") + "\n"
        // Help › Keyboard Shortcuts, as the menu item sends it.
        (UIApplication.shared.delegate as? AppDelegate)?.hqKeyboardShortcuts(nil)
        try? await Task.sleep(for: .seconds(2.5))
        sheetShot("shortcuts")
        await dismissAll()

        // The chat ⋯'s DEBUG Tool Calls sheet (AppModel.debugActivityItems).
        if let chat = find(ChatViewController.self, in: window.rootViewController) {
            // Its ⋯ item, as choosing it runs it.
            guard let item = AppModel.debugActivityItems(chat).first as? UIAction,
                  let block = item.value(forKey: "handler") else { return }
            typealias Handler = @convention(block) (UIAction) -> Void
            unsafeBitCast(block as AnyObject, to: Handler.self)(item)
            try? await Task.sleep(for: .seconds(2.5))
            sheetShot("toolcalls")
            await dismissAll()
        } else {
            log += "no chat\n"
        }
        // The Dock's New Chat, as choosing it runs it.
        MacDockMenu.shared.debugChoose("New Chat")
        try? await Task.sleep(for: .seconds(2.5))
        var top = window.rootViewController
        while let next = top?.presentedViewController { top = next }
        log += "dock New Chat: chat on show \(tabs.chatOnShow.map { "“\($0.title ?? "")”" } ?? "none"), on top \(top.map { String(describing: type(of: $0)) } ?? "-")\n"
        shoot(window, to: folder.appending(path: "\(name)-dock-newchat.png"))
        let file = folder.appending(path: "\(name)-menus.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(1.5))
    }

    private static func printable(_ key: String) -> String {
        key.unicodeScalars.map { $0.value < 0x21 || $0.value >= 0x7f ? String(format: "U+%04X", $0.value) : String($0).uppercased() }.joined()
    }

    /// An NSMenu's items, indented by depth: title, key (with ⌃⌥⇧⌘ from the mask), and off / hidden.
    private static func menuTree(_ menu: NSObject, depth: Int) -> String {
        guard let items = menu.value(forKey: "itemArray") as? [NSObject] else { return "" }
        var out = ""
        let pad = String(repeating: "  ", count: depth)
        for item in items {
            if item.value(forKey: "separatorItem") as? Bool == true { out += pad + "---\n"; continue }
            let title = item.value(forKey: "title") as? String ?? "?"
            let key = item.value(forKey: "keyEquivalent") as? String ?? ""
            let mask = (item.value(forKey: "keyEquivalentModifierMask") as? UInt) ?? 0
            var mods = ""
            if mask & (1 << 18) != 0 { mods += "⌃" }
            if mask & (1 << 19) != 0 { mods += "⌥" }
            if mask & (1 << 17) != 0 { mods += "⇧" }
            if mask & (1 << 20) != 0 { mods += "⌘" }
            let shown = key.isEmpty ? "" : " [\(mods)\(printable(key))]"
            let hidden = item.value(forKey: "hidden") as? Bool == true ? " (hidden)" : ""
            out += pad + title + shown + hidden + "\n"
            if let sub = item.value(forKey: "submenu") as? NSObject, depth < 3 { out += menuTree(sub, depth: depth + 1) }
        }
        return out
    }
}
#endif

// [mac] Stress test 2026-10-28 #35, #36: the Dock icon's menu (right-click or hold it). The iPhone's Home Screen quick
// actions ("New memo to …", the two most recent chats, Search Chats: `QuickActions.shown`), and while Talk runs its Mute
// and End, so a conversation with the window hidden can be stopped without finding the window. UIKit has no Dock menu,
// so AppKit's application delegate (Catalyst's own) is given an `applicationDockMenu:` at launch, and the menu is made
// from AppKit's classes by name.
// [mac-audit K] Owner 2026-11-02: New Chat comes first, as in Mail's and Messages' Dock menus, and the items say what the
// menu bar says: "Record Voice Memo" (the Chat menu's) and "Search Sessions" (Edit's ⇧⌘F). The iPhone's Home Screen
// items keep their own words (`QuickActions.plan`).

#if targetEnvironment(macCatalyst)
import UIKit
import ObjectiveC

@MainActor final class MacDockMenu: NSObject {
    static let shared = MacDockMenu()

    private var entries: [() -> Void] = []
    /// The menu last handed to AppKit, kept until the next one.
    private var made: NSObject?

    /// Adds `applicationDockMenu:` to the application delegate's class, once.
    static func install() {
        guard let app = application, let delegate = app.value(forKey: "delegate") as? NSObject else {
            AppLog.note("mac", "dock menu: no application delegate")
            return
        }
        let selector = NSSelectorFromString("applicationDockMenu:")
        guard !delegate.responds(to: selector) else { return }
        let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { _, _ in
            MainActor.assumeIsolated { UnsafeTransfer(shared.menu()) }.value   // AppKit asks on the main thread
        }
        let added = class_addMethod(type(of: delegate), selector, imp_implementationWithBlock(block), "@@:@")
        AppLog.note("mac", "dock menu \(added ? "installed" : "refused")")
    }

    private static var application: NSObject? {
        (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject
    }

    /// What the menu holds now, by title (the MacShots tour reads it).
    func titles() -> [String?] { plan().map { $0?.title } }

    #if DEBUG
    /// [mac-audit K] The MacShots tour chooses an item by its title, as the Dock menu runs it.
    func debugChoose(_ title: String) { plan().compactMap { $0 }.first { $0.title == title }?.run() }
    #endif

    private func plan() -> [(title: String, run: () -> Void)?] {
        var out: [(title: String, run: () -> Void)?] = []
        let talk = TalkController.shared
        if talk.isLive {
            let name = talk.liveName ?? ""
            out.append((talk.isMuted ? "Unmute Talk" : "Mute Talk", { talk.toggleMute() }))
            out.append((name.isEmpty ? "End Talk" : "End Talk with \(name)", { talk.end() }))
            out.append(nil)
        }
        // [cmd-n] Owner 2026-11-02: File › New Chat (⌘N) from the Dock, the window brought forward first.
        if let app = UIApplication.shared.delegate as? AppDelegate {
            out.append((NewChatKeyBot.mode == .botChat ? "Open Bot Chat" : "New Chat", {
                Self.bringForward()
                // A closed window comes back first: the key waits for its tabs (up to 3 s).
                @MainActor func run(_ tries: Int) {
                    if KeyCommands.root != nil || tries == 0 { app.hqNewChat(nil); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { run(tries - 1) } }
                }
                run(12)
            }))
        }
        for item in QuickActions.shown {
            out.append((Self.title(item), {
                Self.bringForward()
                _ = QuickActions.perform(action: item.action, id: item.id ?? "", epoch: ShortcutPolicy.epoch(.standard))
            }))
        }
        if out.last == nil, !out.isEmpty { out.removeLast() }
        return out
    }

    private static func title(_ item: QuickActions.Planned) -> String {
        switch item.action {
        case "memo": item.title.replacingOccurrences(of: IntentsText.newMemo(""), with: "Record Voice Memo for ")
        case "search": "Search Sessions"
        default: item.title
        }
    }

    private func menu() -> AnyObject? {
        guard let menuClass = NSClassFromString("NSMenu") as? NSObject.Type,
              let itemClass = NSClassFromString("NSMenuItem") as? NSObject.Type else { return nil }
        let menu = menuClass.init()
        let setAction = NSSelectorFromString("setAction:"), addItem = NSSelectorFromString("addItem:")
        typealias SetAction = @convention(c) (AnyObject, Selector, Selector) -> Void
        entries = []
        for entry in plan() {
            guard let entry else {
                if let separator = (itemClass as AnyObject).perform(NSSelectorFromString("separatorItem"))?.takeUnretainedValue() {
                    menu.perform(addItem, with: separator)
                }
                continue
            }
            let item = itemClass.init()
            item.setValue(entry.title, forKey: "title")
            item.setValue(entries.count, forKey: "tag")
            item.setValue(self, forKey: "target")
            unsafeBitCast(item.method(for: setAction), to: SetAction.self)(item, setAction, #selector(chosen(_:)))
            menu.perform(addItem, with: item)
            entries.append(entry.run)
        }
        made = menu
        return menu
    }

    @objc private func chosen(_ sender: AnyObject) {
        guard let tag = (sender as? NSObject)?.value(forKey: "tag") as? Int, entries.indices.contains(tag) else { return }
        AppLog.note("mac", "dock menu item \(tag)")
        entries[tag]()
    }

    /// A Dock menu item leaves the app behind other apps; a chat opened from it comes to the front, the window with it.
    /// Mac polish #3: a closed main window comes back also while the Settings window is open (only no window at all
    /// asked for one, so New Chat did nothing with Settings alone on screen).
    private static func bringForward() {
        if !UIApplication.shared.connectedScenes.contains(where: { $0.delegate is SceneDelegate }) {
            let main = UIApplication.shared.openSessions.first { !MacSettingsWindow.isSettings($0) && !MacFileWindow.isFile($0) }
            UIApplication.shared.requestSceneSessionActivation(main, userActivity: nil, options: nil)
        }
        guard let app = application else { return }
        let activate = NSSelectorFromString("activate")
        if app.responds(to: activate) { app.perform(activate) }
    }
}
#endif

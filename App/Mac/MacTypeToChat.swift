// [Mac AAA 2026-11-17] Owner's call Q1 (as Messages): after a click on a bot or a chat (the sidebar, Sessions), nothing
// had the keyboard and the letters typed went nowhere until ⌘L or a click in the box. Now the first key that types
// something, pressed while a chat is open and no text field has the keyboard, goes into that chat's message box, and
// the box keeps the keyboard from then on. The keys the window already uses with nothing focused keep their meaning
// (↑/↓ walk the chats, Return, Space, Escape, Delete, Tab, the page keys, every ⌘ and ⌃ shortcut: `TypeToChat.takes`),
// and nothing moves while a sheet, a panel, a menu, a search field or another window has the keyboard.
//
// The key itself is not typed by the app: an AppKit local monitor sees the press before any window does and holds it,
// the box takes the keyboard, and the same press (with any typed in that moment, in order) is then handed to AppKit
// again, so it reaches the box through its input method. An accent (⌥E then E), an input method's first letter and
// ⌃⌘Space's Emoji & Symbols start in the box as they would had it been clicked first. Checked in the running app against
// putting the key's characters in by hand and against letting the press go on at once: both lost the accent's dead key
// (findings/calls-keys.md, Q1).

#if targetEnvironment(macCatalyst)
import UIKit

@MainActor enum TypeToChatKeys {
    private static var monitor: AnyObject?

    static func install() {
        guard monitor == nil, let events = NSClassFromString("NSEvent"),
              let method = class_getClassMethod(events, NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:")) else { return }
        typealias Handler = @convention(block) (NSObject) -> NSObject?
        typealias Add = @convention(c) (AnyClass, Selector, UInt64, @escaping Handler) -> AnyObject?
        let add = unsafeBitCast(method_getImplementation(method), to: Add.self)
        let keyDown: UInt64 = 1 << 10
        monitor = add(events, NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:"), keyDown) { event in
            let taken = MainActor.assumeIsolated { take(event) }
            return taken ? nil : event
        }
    }

    /// Presses held while the box takes the keyboard: the first, and any typed before it is ready, in order.
    private static var held: [NSObject] = []
    /// Until then the presses sent round again pass (AppKit hands them back as new events, so they can't be told by
    /// identity; the box has the keyboard by then, so they pass anyway, and this keeps one that didn't from looping).
    private static var passUntil: CFTimeInterval = 0

    /// [rest-hands 2026-11-17] Until then a search field is on its way to the keyboard (⌘F, a magnifier's click: the
    /// field takes it a turn of the run loop later). Letters typed in that moment went into the chat's message box, or
    /// nowhere with no chat open; now they wait for the field and land there in order.
    private static var fieldComing: CFTimeInterval = 0

    /// A search field (a list's, Find in Chat's) is about to take the keyboard.
    static func fieldWillFocus() { fieldComing = CACurrentMediaTime() + 0.5 }

    /// True when the press is taken here: it waits while the box takes the keyboard, then goes round again.
    private static func take(_ event: NSObject) -> Bool {
        if CACurrentMediaTime() < passUntil { return false }
        // A key typed while the first waits goes after it, whatever it is (Return included), so nothing changes order.
        if !held.isEmpty { held.append(event); return true }
        if CACurrentMediaTime() < fieldComing, ChatFirstResponder.current()?.hqTypingInput == nil {
            let flags = (event.value(forKey: "modifierFlags") as? NSNumber)?.uintValue ?? 0
            let mainWin = KeyCommands.root?.view.window
            let pressed = event.value(forKey: "window") as? NSObject
            let inMain = mainWin != nil && pressed?.responds(to: NSSelectorFromString("uiWindows")) == true
                && (pressed?.value(forKey: "uiWindows") as? [UIWindow])?.contains(mainWin!) == true
            if flags & (1 << 20) == 0, inMain {   // ⌘ shortcuts and other windows go on as they are
                AppLog.note("keys", "typed while a search field takes the keyboard: held for it")
                held = [event]
                awaitField()
                return true
            }
        }
        guard let code = (event.value(forKey: "keyCode") as? NSNumber)?.uint16Value else { return false }
        let flags = (event.value(forKey: "modifierFlags") as? NSNumber)?.uintValue ?? 0
        let characters = event.value(forKey: "charactersIgnoringModifiers") as? String
        guard TypeToChat.takes(keyCode: code, characters: characters, command: flags & (1 << 20) != 0, control: flags & (1 << 18) != 0) else { return false }
        guard let chat = chatTakingKeys(for: event) else { return false }
        var way = "later"
        #if DEBUG
        // The comparison the owner's call asked for (`-HQDebugTypeToChat deliver|insert|repost`, probe `set`), each
        // checked with ⌥E, ⌥U, ⌥I, ⌥N then O (calls-keys x3, x6, x7): only this way kept every accent.
        way = UserDefaults.standard.string(forKey: "HQDebugTypeToChat") ?? way
        #endif
        AppLog.note("keys", "typed with nothing focused: the message box takes the keyboard (\(way))")
        switch way {
        case "deliver":
            // The box takes the keyboard and the same press goes on at once: plain letters arrive, an accent's dead key
            // is lost (⌥E then E typed "e").
            chat.composer.textView.becomeFirstResponder()
            return false
        case "insert":
            // The key's characters put in by hand: a dead key has none, so the accent was lost too.
            chat.composer.textView.becomeFirstResponder()
            if let typed = event.value(forKey: "characters") as? String, !typed.isEmpty { chat.composer.textView.insertText(typed) }
            return true
        case "repost":
            // Focused here and sent again at once: the accents came through now and then, mostly not.
            chat.composer.textView.becomeFirstResponder()
            passUntil = CACurrentMediaTime() + 0.25
            post(event)
            return true
        default:
            // Focused once this press has been dealt with (a focus change made while AppKit hands out a key press leaves
            // the box's input method deaf to it), then the press, and any typed meanwhile, go round again in order.
            held = [event]
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MacSelection.focus(on: .detail)
                    chat.composer.textView.becomeFirstResponder()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { MainActor.assumeIsolated { release() } }
                }
            }
            return true
        }
    }

    /// The held presses go round again once a text field has the keyboard (or the moment has passed).
    private static func awaitField() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            MainActor.assumeIsolated {
                if ChatFirstResponder.current()?.hqTypingInput != nil || CACurrentMediaTime() >= fieldComing { fieldComing = 0; release() } else { awaitField() }
            }
        }
    }

    /// The held presses sent round again, in order, first in the queue.
    private static func release() {
        let presses = held
        held = []
        passUntil = CACurrentMediaTime() + 0.25
        for press in presses.reversed() { post(press) }
    }

    /// `NSApp.postEvent(event, atStart: true)`.
    private static func post(_ event: NSObject) {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
              let method = class_getInstanceMethod(object_getClass(app), NSSelectorFromString("postEvent:atStart:")) else { return }
        typealias Post = @convention(c) (NSObject, Selector, NSObject, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Post.self)(app, NSSelectorFromString("postEvent:atStart:"), event, true)
    }

    /// The chat whose box takes the key: a chat on show in the main window, which has the keyboard, with nothing over
    /// it and nothing in it holding the keyboard (a field, the question card), and its box there to type in.
    private static func chatTakingKeys(for event: NSObject) -> ChatViewController? {
        guard let root = KeyCommands.root, let window = root.view.window, window.hqIsAppKitKey,
              KeyCommands.presented(root) == nil, !MacSettingsWindow.isKey, !MacFileWindow.isKey,
              let chat = root.chatOnShow, chat.viewIfLoaded?.window === window else { return nil }
        // (Sending may be off, offline or while the chat loads: the box stays editable then, so a draft can be typed.)
        // The press is the main window's own (not a menu's being tracked, nor a panel's or a sheet's window).
        guard let pressed = event.value(forKey: "window") as? NSObject, pressed.responds(to: NSSelectorFromString("uiWindows")),
              (pressed.value(forKey: "uiWindows") as? [UIWindow])?.contains(window) == true else { return nil }
        if let first = window.hqFirstResponder, first.hqTypingInput != nil || first is QuestionDockView { return nil }
        if KeyCommands.questionCard(root) != nil { return nil }
        let box = chat.composer.textView
        guard box.window === window, !box.isHidden, box.isEditable, box.isUserInteractionEnabled,
              !chat.composer.memoActive, !chat.composer.dictating, CACurrentMediaTime() >= chat.composer.focusSuppressedUntil else { return nil }
        return chat
    }
}
#endif

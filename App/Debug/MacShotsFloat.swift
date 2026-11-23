// [Mac AAA 2026-11-17] DEBUG: `-HQDebugMacShotsFloat YES`, everything that floats over the Mac message box, in one
// run: the first bot's chat at its newest end and scrolled up a step at a time (so the rows pass under the box and
// whatever floats over it), the activity shelf opened, a reply banner, a picture in the tray, a reply running (its
// activity pill), a queued message, then the window at 1000 × 700. Each picture comes with `<name>-float.txt`: the
// chat's views in drawing order (back to front) with their frames, and the message box's frame, so what sits over
// or under what, and the gaps, can be read off.
// `-HQDebugFloatBot <id>` picks the chat. `-HQDebugFloatSteps <list>` (comma-separated: scroll, pillgo, pillhover, shelf, reply, edit, tray, work, queue, head, narrow) runs only those parts.

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

extension MacShots {
    @MainActor private static var floatTourStarted = false

    @MainActor static func floatTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        guard !floatTourStarted else { while true { try? await Task.sleep(for: .seconds(60)) } }
        floatTourStarted = true
        let only = UserDefaults.standard.string(forKey: "HQDebugFloatSteps").map { Set($0.split(separator: ",").map(String.init)) }
        func runs(_ part: String) -> Bool { only?.contains(part) ?? true }
        var step = 0
        var log = ""
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(1))
        // `-HQDebugFloatBot <id>` (default: the stand-in's main bot, `default`): the same chat in every run, whichever
        // bot spoke last.
        let wanted = UserDefaults.standard.string(forKey: "HQDebugFloatBot") ?? "default"
        guard let bot = tabs.services.bots.first(where: { $0.id == wanted }) ?? tabs.services.bots.first else { return }
        tabs.botsViewController.open(bot.id)
        try? await Task.sleep(for: .seconds(3.5))
        guard let chat = find(ChatViewController.self, in: window.rootViewController) else { return }
        func describe(_ view: UIView, in root: UIView) -> String {
            let f = view.convert(view.bounds, to: root)
            let id = view.accessibilityIdentifier.map { " \($0)" } ?? ""
            let state = view.isHidden ? " hidden" : view.alpha < 0.99 ? String(format: " alpha %.2f", view.alpha) : ""
            return String(format: "%@%@ (%.1f, %.1f, %.1f × %.1f)%@", String(describing: type(of: view)), id, f.minX, f.minY, f.width, f.height, state)
        }
        func snap(_ label: String, wait: Double = 1.2) async {
            try? await Task.sleep(for: .seconds(wait))
            step += 1
            let file = "\(name)-\(String(format: "%02d", step))-\(label)"
            shoot(window, to: folder.appending(path: "\(file).png"))
            let root = chat.view!
            log += "== \(file)\n"
            if let box = chat.composer.macBoxFrame {
                let b = chat.composer.convert(box, to: root)
                log += String(format: "message box (%.1f, %.1f, %.1f × %.1f)\n", b.minX, b.minY, b.width, b.height)
            }
            // The light or dark the message box and its wash are drawn in, against the chat's own (the owner's dark band
            // at the box: a system edge effect over dark rows turned the composer dark).
            func style(_ v: UIView) -> String { v.traitCollection.userInterfaceStyle == .dark ? "dark" : "light" }
            log += "style: chat \(style(root)), composer \(style(chat.composer))\n"
            log += "top bar: \(chat.debugTopBarReport)\n"
            log += "chat view, back to front:\n"
            for (index, sub) in root.subviews.enumerated() { log += "  \(index) \(describe(sub, in: root))\n" }
            log += "composer, back to front:\n"
            for (index, sub) in chat.composer.subviews.enumerated() { log += "  \(index) \(describe(sub, in: root))\n" }
        }
        func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
        }
        func shown(_ id: String) -> UIControl? {
            views(UIControl.self, in: window).first { $0.accessibilityIdentifier == id && $0.window != nil && !$0.isHidden && !($0.superview?.isHidden ?? true) }
        }
        // The helpers' pill (the rich stand-in with helpers seeded), when there is one.
        var summary: UIControl?
        for _ in 0..<16 where summary == nil {
            summary = shown("chat.shelf.summary")
            if summary == nil { try? await Task.sleep(for: .seconds(0.5)) }
        }
        await snap("newest")
        if runs("pillhover"), let summary {
            // Exercise the hover installed by the view itself; the tour must not manufacture a missing interaction.
            MacHover.debugHoverSurface(summary)
            let glass = chat.activity.shelf.debugGlassFrame(in: window)
            log += "pill hover: \(MacHover.debugHoverReport(summary, in: window))\n"
            log += String(format: "pill glass (%.1f, %.1f, %.1f × %.1f), window %.1f × %.1f\n", glass.minX, glass.minY, glass.width, glass.height, window.bounds.width, window.bounds.height)
            await snap("pill-hover", wait: 0.4)
            MacHover.debugHoverSurface(summary, false)
            log += "controls installed before layout that grew past a small button:\n\(MacHover.debugSweptReport(in: chat.view))\n"
        }
        if runs("scroll") {
            // `-HQDebugFloatScrollStep <pt>` (default 90) and `-HQDebugFloatScrollCount <n>` (default 7).
            let stepBy = UserDefaults.standard.double(forKey: "HQDebugFloatScrollStep")
            let count = max(1, UserDefaults.standard.integer(forKey: "HQDebugFloatScrollCount"))
            for index in 1...(UserDefaults.standard.object(forKey: "HQDebugFloatScrollCount") == nil ? 7 : count) {
                let before = chat.tableView.contentOffset.y
                chat.debugScroll(by: stepBy > 0 ? stepBy : 90)
                if abs(chat.tableView.contentOffset.y - before) < 2 { break }
                await snap("up-\(index)", wait: 0.8)
            }
        }
        if runs("pillgo") {
            // [Mac AAA 2026-11-17] The pill going and coming back through the shelf's own animation (owner's "Fade
            // before the pill": the conversation's fade follows it): frames every 0.12 s.
            chat.activity.shelf.debugHidden = true
            chat.activity.updateShelf(animated: true)
            for frame in 1...5 { await snap("pill-going-\(frame)", wait: 0.12) }
            try? await Task.sleep(for: .seconds(0.8))
            await snap("pill-gone", wait: 0.1)
            chat.activity.shelf.debugHidden = false
            chat.activity.updateShelf(animated: true)
            for frame in 1...5 { await snap("pill-coming-\(frame)", wait: 0.12) }
            try? await Task.sleep(for: .seconds(0.8))
            await snap("pill-back", wait: 0.1)
        }
        if runs("shelf"), let summary {
            summary.sendActions(for: .touchUpInside)
            await snap("shelf-open", wait: 1.5)
            // The collapse-all ⌃'s hover, as the pointer over it draws it (owner 2026-11-19: "messed up").
            chat.activity.shelf.debugHoverCollapse()
            await snap("shelf-collapse-hover", wait: 0.4)
            chat.activity.shelf.debugHoverCollapse(false)
            // [hover-shape] The opened card's head under the pointer: its top, in the card's corners.
            MacHover.debugHoverSurface(summary)
            log += "open head hover: \(MacHover.debugHoverReport(summary, in: chat.view))\n"
            await snap("shelf-head-hover", wait: 0.4)
            MacHover.debugHoverSurface(summary, false)
            log += "swept, card open:\n\(MacHover.debugSweptReport(in: chat.view))\n"
            summary.sendActions(for: .touchUpInside)
            try? await Task.sleep(for: .seconds(1))
        }
        if runs("reply"), let menus = chat.menus {
            // The newest reply with words (a helper's or a tool's row has none to quote).
            for message in chat.session.messages.reversed() where message.role == .assistant && chat.composer.editBanner == nil {
                menus.beginReply(message.id)
            }
            await snap("reply-banner")
            (chat.composer.editBanner as? ComposerEditBanner)?.onCancel?()
            chat.composer.textView.resignFirstResponder()
            try? await Task.sleep(for: .seconds(0.6))
        }
        if runs("edit"), let menus = chat.menus {
            menus.debugBeginEdit()
            await snap("edit-banner")
            (chat.composer.editBanner as? ComposerEditBanner)?.onCancel?()
            chat.composer.textView.resignFirstResponder()
            try? await Task.sleep(for: .seconds(0.6))
        }
        if runs("tray"), let attachments = chat.attachments {
            let files = FileManager.default.temporaryDirectory.appending(path: "float-tour", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            let picture = files.appending(path: "Picture.png")
            let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            try? shot.pngData()?.write(to: picture)
            attachments.debugDrop([picture].compactMap { NSItemProvider(contentsOf: $0) })
            await snap("tray", wait: 3)
        }
        if runs("work") {
            if !runs("tray") || chat.attachments?.hasAttachments != true {
                chat.composer.textView.becomeFirstResponder()
                chat.composer.textView.insertText("Check the build and tell me what failed")
            }
            chat.composer.submit()
            await snap("working-1", wait: 1.0)
            await snap("working-2", wait: 1.5)
            if runs("queue") {
                chat.composer.textView.becomeFirstResponder()
                chat.composer.textView.insertText("Then open a pull request")
                chat.composer.submit()
                await snap("queued", wait: 1.2)
                chat.debugScroll(by: 120)
                await snap("queued-up", wait: 0.8)
            }
        }
        if runs("head") {
            // [Mac AAA 2026-11-17] Under the title: the status capsule alone, a notice alone, both (owner: "sized weird
            // and too high"; two capsules once drew over each other). A running reply gives the title its "Working…".
            chat.debugStatus("Waiting for the current reply…")
            await snap("head-status", wait: 1.0)
            chat.debugStatus(nil)
            chat.showNotice("Model changed to Fixture Model", duration: 30, spinner: false)
            await snap("head-notice", wait: 1.0)
            chat.debugStatus("Waiting for the current reply…")
            await snap("head-both", wait: 1.0)
            chat.hideNotice()
            chat.debugStatus(nil)
        }
        if runs("narrow") {
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 0, y: 0, width: 1000, height: 700))) { _ in }
            await snap("narrow", wait: 2)
            chat.debugScroll(by: 120)
            await snap("narrow-up", wait: 0.8)
        }
        let file = folder.appending(path: "\(name)-float.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(2))
    }
}
#endif

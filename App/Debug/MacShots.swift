// [mac] DEBUG: `-HQDebugMacShots <name>` photographs the window on every tab, then with a chat open on the right,
// and quits. The pictures land in the app's own tmp folder (`<container>/Data/tmp/mac-shots/<name>-<n>-<tab>.png`):
// the Mac's screen can't be recorded from a script without permission, so the app draws its own window. Pair it with
// `-HQDemoLists` (no gateway needed) and `-HQDemoOpen <bot id>` is not needed: the tour opens the first bot itself.
// Signed in to a gateway (the stand-in, `HQN_SIGNIN_*`) it also narrows the window to one pane and widens it back, as
// only the real root has two panes. `-HQDebugMacShotsPins`: Artifacts' pins and Bot Info › Artifacts. `-HQDebugMacShotsPost http://127.0.0.1:<port>` sends each file to a local listener. `-HQDebugMacShotsWait <s>`: one picture after the wait ([page-tabs] and `<name>-sheet.png` of a sheet over it, a window of its own; [mac-audit] `-HQDebugMacShotsMenu` adds the chat ⋯'s rows, `dumpMoreMenu`; `-HQDebugMacShotsDrop`: the chat's "Drop to Attach" card and a drop, `dropTour`; `-HQDebugMacShotsFiles`: Files, Changes and Artifacts with each row's menu and drag, `filesTour`).

#if DEBUG && targetEnvironment(macCatalyst)
import UIKit
import UniformTypeIdentifiers

enum MacShots {
    /// [icon-study] The drawn ink of each icon: its box (points, in the icon view), its share of the view, its area.
    @MainActor static func iconInk(_ icons: [(String, UIView)]) -> String {
        var lines: [String] = []
        for (title, view) in icons {
            let scale: CGFloat = 8
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { lines.append("\(title): no size"); continue }
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in view.layer.render(in: context.cgContext) }
            guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { continue }
            let w = cg.width, h = cg.height, row = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
            var minX = w, minY = h, maxX = -1, maxY = -1, ink = 0
            for y in 0..<h { for x in 0..<w where bytes[y * row + x * bpp + 3] > 40 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); ink += 1
            } }
            guard maxX >= 0 else { lines.append("\(title): no ink"); continue }
            let box = CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
            let area = CGFloat(ink) / (scale * scale)
            lines.append(String(format: "%@: view %.1fx%.1f ink %.1fx%.1f at (%.1f, %.1f) centre (%.1f, %.1f) area %.0f pt²",
                                title, size.width, size.height, box.width, box.height, box.minX, box.minY, box.midX, box.midY, area))
        }
        return lines.joined(separator: "\n")
    }

    /// [sidebar-top] Where the window's close, minimise and zoom buttons sit, in the UIWindow's points (top-left
    /// origin), so a shot (which the app draws itself, without them) can be checked against them.
    static func writeWindowButtons(_ window: UIWindow, to file: URL) {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
              let windows = app.value(forKey: "windows") as? [NSObject] else { return }
        typealias ButtonFn = @convention(c) (NSObject, Selector, Int) -> NSObject?
        typealias ConvertFn = @convention(c) (NSObject, Selector, CGRect, NSObject?) -> CGRect
        var lines = ["uiwindow \(window.bounds)"]
        for ns in windows {
            let buttonSel = NSSelectorFromString("standardWindowButton:")
            guard ns.responds(to: buttonSel), let frame = (ns.value(forKey: "frame") as? NSValue)?.cgRectValue else { continue }
            let button = unsafeBitCast(ns.method(for: buttonSel), to: ButtonFn.self)
            let scale = window.bounds.width / max(frame.width, 1)
            lines.append("nswindow \(frame) scale \(scale)")
            for kind in 0...2 {
                guard let view = button(ns, buttonSel, kind), let local = (view.value(forKey: "bounds") as? NSValue)?.cgRectValue else { continue }
                let convertSel = NSSelectorFromString("convertRect:toView:")
                let r = unsafeBitCast(view.method(for: convertSel), to: ConvertFn.self)(view, convertSel, local, nil)
                let top = (frame.height - r.maxY) * scale
                lines.append("button \(kind) x \(r.minX * scale) y \(top) w \(r.width * scale) h \(r.height * scale)")
            }
        }
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        post(file)
    }

    /// The window holding the tabs now (a close and a Dock reopen makes a new one), else `fallback`.
    @MainActor static func mainWindow(fallback: UIWindow) -> UIWindow {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .first { !$0.isHidden && find(MainTabController.self, in: $0.rootViewController) != nil } ?? fallback
    }

    static func startIfAsked(_ window: UIWindow) {
        guard let name = UserDefaults.standard.string(forKey: "HQDebugMacShots"), !name.isEmpty else { return }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "mac-shots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The same window every time (the size docs/mac.md measured at): 1280 × 800 on the Mac's screen.
        let frame = CGRect(x: 80, y: 80, width: 1280, height: 800)
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            // What the text size reads as, from each place the app asks.
            let xl = UITraitCollection(preferredContentSizeCategory: .extraExtraLarge)
            let probe = [
                "app category: \(UIApplication.shared.preferredContentSizeCategory.rawValue)",
                "window category: \(window.traitCollection.preferredContentSizeCategory.rawValue)",
                "current category: \(UITraitCollection.current.preferredContentSizeCategory.rawValue)",
                // The system's own sizes, read from descriptors (the app's fonts come from HQFont: ThemeLintTests).
                "body: \(UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).pointSize)",
                "body (window traits): \(UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body, compatibleWith: window.traitCollection).pointSize)",
                "body (XXL traits): \(UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body, compatibleWith: xl).pointSize)",
                "metrics 17: \(UIFontMetrics(forTextStyle: .body).scaledValue(for: 17))",
                "HQFont body: \(HQFont.preferred(.body).pointSize)",
            ].joined(separator: "\n")
            try? probe.write(to: folder.appending(path: "\(name)-fonts.txt"), atomically: true, encoding: .utf8)
            // Signed in for real, the tabs come once the gateway answers.
            // [tinted-bubbles] `-HQDemoChat` has no tabs: it takes the waited picture alone. [nous-different-account]
            // Nor has `-HQDemoSignIn`.
            let demoChat = ChatDemo.argument("-HQDemoChat") != nil || ProcessInfo.processInfo.arguments.contains("-HQDemoSignIn")
            var tabs = find(MainTabController.self, in: window.rootViewController)
            for _ in 0..<40 where tabs == nil && !demoChat {
                try? await Task.sleep(for: .seconds(0.5))
                tabs = find(MainTabController.self, in: window.rootViewController)
            }
            guard tabs != nil || demoChat else { return }
            try? await Task.sleep(for: .seconds(2))
            // Mac audit #11: `-HQDemoChat 12 -HQDemoAutoOpen -HQDebugMacShotsSelect YES` selects in the demo's rich replies.
            if demoChat, UserDefaults.standard.bool(forKey: "HQDebugMacShotsSelect") {
                await selectTour(window, tabs: nil, name: name, folder: folder)
                exit(0)
            }
            // `-HQDebugMacShotsWait <seconds>`: one picture of the window as other debug arguments left it (a chat
            // opened by `-HQDebugOpenBot`, a memo or Talk shot), after the wait.
            let wait = UserDefaults.standard.double(forKey: "HQDebugMacShotsWait")
            guard let tabs, wait <= 0 else {
                try? await Task.sleep(for: .seconds(max(wait, 1)))
                // [glass-audit] `-HQDebugTourScroll <pt>`: the top sheet's (else the window's) biggest list scrolled
                // down first, so its rows sit under the page's bar.
                let scroll = UserDefaults.standard.double(forKey: "HQDebugTourScroll")
                if scroll > 0 {
                    var top = window.rootViewController
                    while let next = top?.presentedViewController { top = next }
                    func lists(_ view: UIView) -> [UIScrollView] {
                        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(lists)
                    }
                    let candidates = lists(top?.view ?? window).filter { $0.contentSize.height > $0.bounds.height }
                    if let list = candidates.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
                        list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top + scroll), animated: false)
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                // [rail-ring] `-HQDebugRailMark <bot id>`: that head marked as the open chat (`-HQDebugRailFocus`: with
                // the sidebar's focus, the accent ring).
                if let mark = UserDefaults.standard.string(forKey: "HQDebugRailMark"), let sidebar = findView(MacSidebar.self, in: window) {
                    if UserDefaults.standard.bool(forKey: "HQDebugRailFocus") { MacSelection.focus(on: .sidebar) }
                    sidebar.markOpen(bot: mark)
                    sidebar.focusChanged()
                    try? await Task.sleep(for: .seconds(0.5))
                }
                // [rail-top] `-HQDebugRailScroll <pt>`: the sidebar's rows scrolled down first.
                let railScroll = UserDefaults.standard.double(forKey: "HQDebugRailScroll")
                if railScroll > 0, let sidebar = findView(MacSidebar.self, in: window) {
                    let rows = sidebar.debugScroll
                    rows.setContentOffset(CGPoint(x: 0, y: -rows.contentInset.top + railScroll), animated: false)
                    try? await Task.sleep(for: .seconds(0.5))
                    try? "scroll frame \(rows.frame) in \(rows.superview.map { String(describing: type(of: $0)) } ?? "-") offset \(rows.contentOffset) inset \(rows.contentInset) content \(rows.contentSize) clips \(rows.clipsToBounds) sidebar \(sidebar.frame)".write(to: folder.appending(path: "\(name)-rail.txt"), atomically: true, encoding: .utf8)
                    post(folder.appending(path: "\(name)-rail.txt"))
                }
                // [icon-study] `-HQDebugIconInk YES`: each sidebar row's icon drawn alone, its ink box in points.
                if UserDefaults.standard.bool(forKey: "HQDebugIconInk"), let sidebar = findView(MacSidebar.self, in: window) {
                    var text = "rows:\n" + iconInk(sidebar.debugIcons)
                    // Every place's icon as a sidebar row draws it (the demo has only Bots and Sessions on show).
                    let places: [(String, UIImage?)] = [
                        ("Bots", TabIcons.bot), ("Sessions", TabIcons.barSymbol("bubble.left.and.bubble.right")),
                        ("Jobs", TabIcons.jobs), ("Jobs running", TabIcons.jobsRunning), ("Kanban", TabIcons.kanban),
                        ("Artifacts", TabIcons.barSymbol(PagesTabs.outlineSymbol("photo.on.rectangle"))),
                        ("Tiles", TabIcons.barSymbol(PagesTabs.outlineSymbol("rectangle.3.group.fill"))),
                        ("Settings", TabIcons.barSymbol(PagesTabs.outlineSymbol("gearshape.fill"))),
                        ("Connectors", TabIcons.barSymbol(PagesTabs.outlineSymbol("powerplug.fill"))),
                        ("More", TabIcons.barSymbol("ellipsis.circle", outline: "ellipsis")),
                    ]
                    for folded in [false, true] {
                        let size = MacSidebar.iconSize(folded: folded)
                        let views: [(String, UIView)] = places.map { title, image in
                            let view = TabIconView()
                            view.contentMode = .center
                            let drawn = UserDefaults.standard.bool(forKey: "HQDebugIconInkBefore")
                                ? (TabIcons.redrawn(image, pointSize: size) ?? image, size) : MacSidebar.rowIcon(image, folded: folded)
                            view.icon = drawn.0
                            view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: drawn.1, weight: .regular)
                            view.tintColor = .black
                            let fit = view.intrinsicContentSize
                            view.frame = CGRect(x: 0, y: 0, width: (size * 1.5).rounded(), height: max(fit.height, size * 1.5).rounded())
                            view.layoutIfNeeded()
                            return (title, view)
                        }
                        text += "\n\n\(folded ? "folded" : "open") (\(size) pt):\n" + iconInk(views)
                        // A strip of them, for the eye.
                        let cell: CGFloat = 44
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = 4
                        let strip = UIGraphicsImageRenderer(size: CGSize(width: cell * CGFloat(views.count), height: cell), format: format).image { context in
                            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: cell * CGFloat(views.count), height: cell))
                            for (index, (_, view)) in views.enumerated() {
                                context.cgContext.saveGState()
                                context.cgContext.translateBy(x: CGFloat(index) * cell + (cell - view.bounds.width) / 2, y: (cell - view.bounds.height) / 2)
                                view.layer.render(in: context.cgContext)
                                context.cgContext.restoreGState()
                            }
                        }
                        let url = folder.appending(path: "\(name)-icons-\(folded ? "folded" : "open").png")
                        try? strip.pngData()?.write(to: url)
                        post(url)
                    }
                    try? text.write(to: folder.appending(path: "\(name)-icons.txt"), atomically: true, encoding: .utf8)
                    post(folder.appending(path: "\(name)-icons.txt"))
                }
                // The main window now: closed and reopened from the Dock, the launch's `window` is gone and drew blank.
                shoot(mainWindow(fallback: window), to: folder.appending(path: "\(name).png"))
                // The stored theme keys (Debug shares the download's data folder: put them back after a skin shot).
                let theme = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("hqn.theme.") }
                    .sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
                    + "\n" + (findView(MacSidebar.self, in: window)?.debugGlass ?? "no sidebar")
                try? theme.write(to: folder.appending(path: "\(name)-theme.txt"), atomically: true, encoding: .utf8)
                post(folder.appending(path: "\(name)-theme.txt"))
                writeWindowButtons(window, to: folder.appending(path: "\(name)-buttons.txt"))
                if UserDefaults.standard.bool(forKey: "HQDebugMacShotsMenu") { dumpMoreMenu(window, name: name, folder: folder) }
                // [page-tabs] A Mac sheet is a window of its own (Bot Info, Settings from `-HQDebugTour`): it too.
                var top = window.rootViewController
                while let next = top?.presentedViewController { top = next }
                if let sheet = top?.viewIfLoaded?.window, sheet !== window {
                    shoot(sheet, to: folder.appending(path: "\(name)-sheet.png"))
                }
                // Mac polish #35: the tours' Settings (`-HQDebugTour settings`, `theme`, Talk's, Theme's) opens in the
                // Settings window now, not a sheet over this one: it too, as `<name>-settings.png` (the
                // `-HQDebugSettingsWindow` shot takes its own).
                if UserDefaults.standard.string(forKey: "HQDebugSettingsWindow")?.isEmpty != false,
                   let settings = MacSettingsWindow.scene?.windows.first {
                    shoot(settings, to: folder.appending(path: "\(name)-settings.png"))
                }
                try? await Task.sleep(for: .seconds(2))   // `-HQDebugMacShotsPost`'s upload
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsDeep") {
                await deepTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsSubagents") {
                await subagentsTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsSelect") {
                await selectTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsGlass") {
                await glassTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsPreviewTable") {
                await previewTableTour(window, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsDrop") {
                await dropTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsTable") {
                await tableTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsBotModels") {
                await botModelsTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            // [mac-polish new group, 2026-11-07, not committed] a group chat answering, and Switch Model's rows.
            if let words = UserDefaults.standard.string(forKey: "HQDebugMacShotsRoom"), !words.isEmpty {
                await roomTour(window, tabs: tabs, name: name, folder: folder, words: words)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsModelMenu") {
                await modelMenuTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsPopups") {
                await popupsTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsPages") {
                await pagesTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsRailMore") {
                await railMoreTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsRailNames") {
                await railNamesTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsRail") {
                await railTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsSidebar") {
                await sidebarTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsPins") {
                // [pins] Artifacts' pins and Bot Info › Artifacts (BotArtifactsSection.swift).
                await tabs.pages?.debugPinsTour(root: tabs) { label in
                    let presented = window.rootViewController.flatMap(topPresented)
                    shoot(window, to: folder.appending(path: "\(name)-\(label).png"))
                    if let sheet = presented?.view {
                        let image = UIGraphicsImageRenderer(bounds: sheet.bounds).image { _ in
                            _ = sheet.drawHierarchy(in: sheet.bounds, afterScreenUpdates: true)
                        }
                        let url = folder.appending(path: "\(name)-\(label)-sheet.png")
                        try? image.pngData()?.write(to: url)
                        post(url)
                    }
                }
                try? await Task.sleep(for: .seconds(2))
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsMenus") {   // [mac-audit K] MacShots+Menus.swift
                await menusTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsFiles") {
                await filesTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsTerminal") {
                await terminalTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsAlerts") {
                await alertsTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsLayout") {
                await layoutTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsDash") {
                await dashTour(window, tabs: tabs, name: name, folder: folder)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsGrids") {
                await gridsTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsFilesTable") {
                await filesTableTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsKanban") {
                await kanbanTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsResize") {
                await resizeTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsChats") {
                await chatsTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            if UserDefaults.standard.bool(forKey: "HQDebugMacShotsNav") {
                await navTour(window, tabs: tabs, name: name, folder: folder)
                exit(0)
            }
            let count = tabs.viewControllers?.count ?? 0
            var step = 0
            var tips = ""
            for index in 0..<count {
                tabs.selectedIndex = index
                try? await Task.sleep(for: .seconds(1.2))
                let title = tabs.viewControllers?[index].tabBarItem.title ?? "tab\(index)"
                shoot(window, to: folder.appending(path: "\(name)-\(step)-\(title.lowercased()).png"))
                tips += "[\(title.lowercased())]\n" + toolTips(window)
                // The tab's top with rows scrolled under it (owner 2026-11-01: one top for every tab).
                if let list = tabs.selectedViewController?.view.firstList(), list.contentSize.height > list.bounds.height {
                    let rest = list.contentOffset
                    list.setContentOffset(CGPoint(x: rest.x, y: rest.y + 120), animated: false)
                    try? await Task.sleep(for: .seconds(0.8))
                    shoot(window, to: folder.appending(path: "\(name)-\(step)-\(title.lowercased())-scrolled.png"))
                    list.setContentOffset(rest, animated: false)
                }
                step += 1
            }
            tabs.selectedIndex = 0
            try? await Task.sleep(for: .seconds(0.6))
            if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
            try? await Task.sleep(for: .seconds(1.5))
            shoot(window, to: folder.appending(path: "\(name)-\(step)-chat.png"))
            tips += "[chat]\n" + toolTips(window)
            // The sidebar folded to its icons by View › Hide Sidebar and opened again: pictures, widths, the menu's title.
            var folds = ""
            for stage in ["folded", "opened"] {
                let command = UIKeyCommand(title: "?", action: KeyCommands.toggleSidebar, input: "s", modifierFlags: [.control, .command])
                (UIApplication.shared.delegate as? AppDelegate)?.validate(command)
                UIApplication.shared.sendAction(KeyCommands.toggleSidebar, to: UIApplication.shared.delegate, from: nil, for: nil)
                try? await Task.sleep(for: .seconds(1))
                step += 1
                shoot(window, to: folder.appending(path: "\(name)-\(step)-sidebar-\(stage).png"))
                let bar = KeyCommands.root?.split?.macSidebar
                folds += "\(command.title) → \(stage): sidebar \(bar?.frame ?? .zero), min \(window.windowScene?.sizeRestrictions?.minimumSize ?? .zero)\n"
                    + paneFrames(window.rootViewController) + "\n"
                if stage == "folded" { tips += "[folded]\n" + toolTips(window) }
            }
            // The new shortcuts, sent as their keys would send them, and what each one changed.
            var keys = ""
            func validated(_ action: Selector, _ input: String, _ flags: UIKeyModifierFlags) -> String {
                let command = UIKeyCommand(title: "?", action: action, input: input, modifierFlags: flags)
                (UIApplication.shared.delegate as? AppDelegate)?.validate(command)
                return "\(command.title) \(command.attributes.contains(.disabled) ? "off" : "on")"
            }
            keys += "archive (bot's own chat): \(validated(KeyCommands.archiveChat, "a", [.command, .control]))\n"
            keys += "message field: \(validated(KeyCommands.messageField, "\r", []))"
            UIApplication.shared.sendAction(KeyCommands.messageField, to: UIApplication.shared.delegate, from: nil, for: nil)
            try? await Task.sleep(for: .seconds(0.5))
            keys += " → field focused \(KeyCommands.root?.chatOnShow?.composer.textView.isFirstResponder == true)"
            keys += ", then \(validated(KeyCommands.messageField, "\r", []))\n"
            KeyCommands.root?.chatOnShow?.composer.textView.resignFirstResponder()
            let before = KeyCommands.root.flatMap { KeyCommands.walkList($0)?.current } ?? "-"
            keys += "↓ walk: \(validated(KeyCommands.nextChat, UIKeyCommand.inputDownArrow, []))"
            UIApplication.shared.sendAction(KeyCommands.nextChat, to: UIApplication.shared.delegate, from: nil, for: nil)
            try? await Task.sleep(for: .seconds(1.5))
            keys += " · \(before) → \(KeyCommands.root.flatMap { KeyCommands.walkList($0)?.current } ?? "-")"
            UIApplication.shared.sendAction(KeyCommands.previousChat, to: UIApplication.shared.delegate, from: nil, for: nil)
            try? await Task.sleep(for: .seconds(1.5))
            keys += " → ↑ \(KeyCommands.root.flatMap { KeyCommands.walkList($0)?.current } ?? "-")\n"
            // Part of a reply selected as a drag would, then ⌘C through the responder chain: what the pasteboard got.
            var frames = folds
            if let table = find(ChatViewController.self, in: window.rootViewController).flatMap({ table(in: $0.view) }),
               let cell = table.visibleCells.compactMap({ $0 as? ChatBubbleCell }).first(where: { $0.debugIsReply }) {
                UIPasteboard.general.string = ""
                cell.debugSelect()
                try? await Task.sleep(for: .seconds(0.5))
                step += 1
                shoot(window, to: folder.appending(path: "\(name)-\(step)-selected.png"))
                UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.copy(_:)), to: nil, from: nil, for: nil)
                frames += "selected: \(cell.selectedText ?? "-") | first responder: \(cell.isFirstResponder) | pasteboard: \(UIPasteboard.general.string ?? "-")\n"
                cell.endSelection()
            }
            // The window dragged down to its smallest (one pane) and back out (two), first with the chat open, then
            // with a More page (Kanban) on the right: each picture and where the panes sit after it.
            for (stage, open) in [("chat", nil), ("page", "kanban")] as [(String, String?)] {
                if let open, let more = find(MoreViewController.self, in: tabs) {
                    tabs.selectedIndex = count - 1
                    try? await Task.sleep(for: .seconds(0.6))
                    more.open(rowId: open)
                    try? await Task.sleep(for: .seconds(1.5))
                }
                for (label, size) in [("narrow", CGSize(width: 400, height: 600)), ("wide", CGSize(width: 1280, height: 800))] {
                    step += 1
                    window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: frame.origin, size: size))) { _ in }
                    try? await Task.sleep(for: .seconds(2))
                    shoot(window, to: folder.appending(path: "\(name)-\(step)-\(stage)-\(label).png"))
                    frames += "\(stage) \(label): window \(window.bounds.size)\n" + paneFrames(window.rootViewController) + "\n"
                    if stage == "page", label == "wide" {
                        tips += "[kanban]\n" + toolTips(window)
                        if let kanban = find(KanbanViewController.self, in: window.rootViewController) {
                            let font = kanban.navigationItem.standardAppearance?.titleTextAttributes[.font] as? UIFont
                            frames += "kanban bar: title font \(font?.pointSize ?? 0), delegate \(kanban.navigationController?.delegate.map { String(describing: type(of: $0)) } ?? "none"), root \(kanban.navigationController?.viewControllers.first === kanban)\n"
                        }
                    }
                }
            }
            // More pages full of rows, and the list itself, at the tour's text size.
            for open in ["settings", "capabilities", "gateway"] {
                guard let more = find(MoreViewController.self, in: tabs) else { break }
                more.navigationController?.popToRootViewController(animated: false)
                more.open(rowId: open)
                try? await Task.sleep(for: .seconds(1.5))
                step += 1
                shoot(window, to: folder.appending(path: "\(name)-\(step)-\(open).png"))
            }
            keys += "open quickly: \(validated(KeyCommands.openQuickly, "k", .command))"
            UIApplication.shared.sendAction(KeyCommands.openQuickly, to: UIApplication.shared.delegate, from: nil, for: nil)
            try? await Task.sleep(for: .seconds(1.2))
            let first = window.firstResponderForDebug
            let search = KeyCommands.root?.pages?.more?.navigationItem.searchController
            keys += " → first responder \(first.map { String(describing: type(of: $0)) } ?? "none")"
                + ", search active \(search?.isActive == true), field focused \(search?.searchBar.searchTextField.isFirstResponder == true)\n"
            step += 1
            shoot(window, to: folder.appending(path: "\(name)-\(step)-quickly.png"))
            try? keys.write(to: folder.appending(path: "\(name)-keys.txt"), atomically: true, encoding: .utf8)
            post(folder.appending(path: "\(name)-keys.txt"))
            try? tips.write(to: folder.appending(path: "\(name)-tips.txt"), atomically: true, encoding: .utf8)
            post(folder.appending(path: "\(name)-tips.txt"))
            try? frames.write(to: folder.appending(path: "\(name)-frames.txt"), atomically: true, encoding: .utf8)
            post(folder.appending(path: "\(name)-frames.txt"))
            AppLog.note("debug", "mac shots written to \(folder.path)")
            try? await Task.sleep(for: .seconds(1))   // the last posts go out
            exit(0)
        }
    }

    /// [mac] Stress test round 6: every worded bar button on show (main window and any sheet) with the colours it draws.
    @MainActor private static func barProbe(_ window: UIWindow) -> String {
        var out = ""
        func hex(_ color: UIColor?, _ traits: UITraitCollection) -> String {
            guard let color else { return "nil" }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%.0f,%.0f,%.0f@%.2f", r * 255, g * 255, b * 255, a)
        }
        func walk(_ view: UIView) {
            if let button = view as? UIButton, let title = button.configuration?.title ?? button.currentTitle, !title.isEmpty,
               button.superview != nil, sequence(first: view, next: { $0.superview }).contains(where: { $0 is UINavigationBar }) {
                let t = button.traitCollection
                var alphas: [String] = []
                var node: UIView? = button
                while let current = node, alphas.count < 6 { alphas.append(String(format: "%.2f", current.alpha)); node = current.superview }
                out += "  bar button \"\(title)\": base \(hex(button.configuration?.baseForegroundColor, t)) label \(hex(button.titleLabel?.textColor, t)) tint \(hex(button.tintColor, t)) enabled \(button.isEnabled) state \(button.state.rawValue) adjust \(button.tintAdjustmentMode.rawValue) key \(button.window?.isKeyWindow ?? false) alphas \(alphas.joined(separator: "/")) labelAlpha \(String(format: "%.2f", button.titleLabel?.alpha ?? -1))\n"
            }
            view.subviews.forEach(walk)
        }
        for w in window.windowScene?.windows ?? [window] { walk(w) }
        return out
    }

    /// `-HQDebugMacShotsPages`: the places the first tour skipped. Each tab's first item opened; every row of More
    /// opened in turn; every item of a chat's ⋯ chosen in turn (all but Share and the destructive ones), with whatever
    /// it presents. `<name>-pages.txt` lists each picture with its title, the ⋯'s items, and every window on show.
    @MainActor private static func pagesTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        var step = 0
        func snap(_ label: String) {
            step += 1
            let slug = label.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            shoot(window, to: folder.appending(path: "\(name)-p\(step)-\(slug).png"))
            // A sheet or popover drawn in a window of its own gets its own picture.
            let others = (window.windowScene?.windows ?? []).filter { $0 !== window && !$0.isHidden && $0.bounds.width > 40 && !String(describing: type(of: $0)).contains("TextEffects") }
            for (index, other) in others.enumerated() {
                shoot(other, to: folder.appending(path: "\(name)-p\(step)-\(slug)-w\(index).png"))
            }
            let presented = window.rootViewController.flatMap(topPresented)
            // A sheet's own view, drawn on its own (the Mac hosts sheets where the window's picture doesn't reach).
            if let sheet = presented?.view, sheet.bounds.width > 40, sheet.bounds.width < window.bounds.width {
                let format = UIGraphicsImageRendererFormat()
                format.scale = window.screen.scale
                let image = UIGraphicsImageRenderer(bounds: sheet.bounds, format: format).image { _ in
                    _ = sheet.drawHierarchy(in: sheet.bounds, afterScreenUpdates: true)
                }
                let url = folder.appending(path: "\(name)-p\(step)-\(slug)-sheet.png")
                try? image.pngData()?.write(to: url)
                post(url)
            }
            log += barProbe(window)   // [mac] round 6: what the bars' worded buttons draw with (grey Back/Done)
            log += "p\(step) \(label): presented \(presented.map { String(describing: type(of: $0)) } ?? "-")"
                + (presented.map { " \($0.modalPresentationStyle.rawValue) \($0.view.frame.size)" } ?? "")
                + (others.isEmpty ? "" : " · windows \(others.map { "\(type(of: $0)) \($0.bounds.size)" })") + "\n"
        }
        func dismissAll() async {
            if let presented = window.rootViewController?.presentedViewController {
                presented.dismiss(animated: false)
                try? await Task.sleep(for: .seconds(0.8))
            }
        }
        // Each list tab's first item, opened as a click would.
        let names = (tabs.viewControllers ?? []).map { $0.tabBarItem.title ?? "?" }
        for (index, title) in names.enumerated() where !["Bots", "More"].contains(title) {
            tabs.selectedIndex = index
            tabs.split?.followSelectedTab()   // as a sidebar click: round 4's "job beside Kanban" was this tour skipping it
            try? await Task.sleep(for: .seconds(1.5))
            let nav = tabs.viewControllers?[index] as? UINavigationController
            nav?.popToRootViewController(animated: false)
            if let root = nav?.topViewController, clickFirstRow(in: root.view) {
                try? await Task.sleep(for: .seconds(2))
                snap("\(title) first item")
                await dismissAll()
            } else {
                log += "\(title): no row to open\n"
            }
        }
        // Every row of More.
        if let moreIndex = names.firstIndex(of: "More"), let nav = tabs.viewControllers?[moreIndex] as? UINavigationController,
           let more = nav.viewControllers.first {
            tabs.selectedIndex = moreIndex
            tabs.split?.followSelectedTab()
            try? await Task.sleep(for: .seconds(1))
            if let list = collection(in: more.view) {
                var paths: [IndexPath] = []
                for section in 0..<list.numberOfSections { for item in 0..<list.numberOfItems(inSection: section) { paths.append(IndexPath(item: item, section: section)) } }
                for path in paths {
                    nav.popToRootViewController(animated: false)
                    try? await Task.sleep(for: .seconds(0.5))
                    guard list.delegate?.collectionView?(list, shouldSelectItemAt: path) ?? true else { continue }
                    list.delegate?.collectionView?(list, didSelectItemAt: path)
                    try? await Task.sleep(for: .seconds(1.6))
                    let shown = KeyCommands.root?.split?.isDouble == true ? (KeyCommands.root?.split?.detailScreens.last ?? nav.topViewController) : nav.topViewController
                    snap("more \(shown?.navigationItem.title ?? shown?.title ?? "row \(path.item)")")
                    await dismissAll()
                }
            }
            nav.popToRootViewController(animated: false)
        }
        // A bot chat's ⋯, item by item.
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(0.8))
        if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
        try? await Task.sleep(for: .seconds(2))
        if let chat = find(ChatViewController.self, in: window.rootViewController), let menus = chat.menus {
            func flatten(_ elements: [UIMenuElement], _ path: String) -> [(String, UIAction)] {
                elements.flatMap { element -> [(String, UIAction)] in
                    if let action = element as? UIAction { return [(path + action.title, action)] }
                    if let menu = element as? UIMenu { return flatten(menu.children, menu.title.isEmpty ? path : path + menu.title + " ▸ ") }
                    return []
                }
            }
            let items = flatten(menus.moreMenuElements(), "")
            log += "chat ⋯: " + items.map { "\($0.0)\($0.1.attributes.contains(.disabled) ? " (off)" : "")" }.joined(separator: " | ") + "\n"
            typealias Handler = @convention(block) (UIAction) -> Void
            for (title, action) in items where !action.attributes.contains(.destructive) && !action.attributes.contains(.disabled)
                && ![MenuWords.share, "Pin", "Unpin", "Mark as Read", "Mark as Unread", "Archive", "Branch in New Chat"].contains(action.title) {
                // The action's own handler, as choosing it in the menu runs it (DEBUG only: a private key).
                guard let block = action.value(forKey: "handler") else { log += "can't fire \(title)\n"; continue }
                unsafeBitCast(block as AnyObject, to: Handler.self)(action)
                try? await Task.sleep(for: .seconds(2))
                snap("chat \(title)")
                await dismissAll()
                chat.navigationController?.popToViewController(chat, animated: false)
                try? await Task.sleep(for: .seconds(0.5))
            }
            menus.presentCommandsSheet()
            try? await Task.sleep(for: .seconds(2))
            snap("composer commands")
            if let sheet = window.rootViewController?.presentedViewController as? UINavigationController {
                let table = sheet.topViewController?.view.subviews.compactMap { $0 as? UITableView }.first
                log += "commands sheet: wants \(sheet.preferredContentSize), frame \(sheet.view.frame.size), table \(table?.bounds.size ?? .zero) content \(table?.contentSize ?? .zero)\n"
            }
            await dismissAll()
            // Round 2 fixes: the Chat menu's items as `validate` leaves them in this chat, ⌘R over Files, the Dock
            // menu, and ⌘Z with an undo pill up.
            var checks = "app state \(UIApplication.shared.applicationState.rawValue)\n"
            let delegate = UIApplication.shared.delegate as? AppDelegate
            for element in ChatMenuBar.menu().children.flatMap({ ($0 as? UIMenu)?.children ?? [] }) {
                guard let command = element as? UICommand else { continue }
                delegate?.validate(command)
                checks += "chat menu: \(command.title)\((command as? UIKeyCommand).map { " [\($0.modifierFlags.rawValue) \($0.input ?? "")]" } ?? "") \(command.attributes.contains(.disabled) ? "off" : "on")\n"
            }
            menus.performListAction(.files)
            try? await Task.sleep(for: .seconds(2))
            checks += "files sheet: ⌘R \(KeyCommands.root.flatMap { KeyCommands.sheetRefresh($0) } != nil ? "refreshes" : "does nothing")\n"
            snap("files for refresh")
            await dismissAll()
            if let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
               let appDelegate = app.value(forKey: "delegate") as? NSObject {
                checks += "dock menu: answers \(appDelegate.responds(to: NSSelectorFromString("applicationDockMenu:"))), items \(MacDockMenu.shared.titles().map { $0 ?? "—" })\n"
            }
            var undone = false
            UndoPill.show(label: "Archived", in: tabs) { undone = true }
            try? await Task.sleep(for: .seconds(0.3))
            let manager = window.undoManager
            checks += "undo: manager \(manager != nil), can undo \(manager?.canUndo == true), menu title \(manager?.undoMenuItemTitle ?? "-")"
            manager?.undo()
            try? await Task.sleep(for: .seconds(0.5))
            checks += " → undone \(undone), pill gone \(UndoPill.current?.isOnShow != true)\n"
            let checksFile = folder.appending(path: "\(name)-checks.txt")
            try? checks.write(to: checksFile, atomically: true, encoding: .utf8)
            post(checksFile)
        }
        let file = folder.appending(path: "\(name)-pages.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(1.5))
    }

    /// `-HQDebugMacShotsDeep`: the pages one level further in. Every Settings page (each root page and each config
    /// section and page, opened as their rows open them); the page behind the first row of each More page; a bot chat
    /// scrolled top to bottom; and the main tabs in a laptop-sized window. `<name>-deep.txt` lists them.
    @MainActor private static func deepTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        var step = 0
        func snap(_ label: String) {
            step += 1
            let slug = label.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            shoot(window, to: folder.appending(path: "\(name)-d\(step)-\(slug).png"))
            let presented = window.rootViewController.flatMap(topPresented)
            if let sheet = presented?.view, sheet.bounds.width > 40, sheet.bounds.width < window.bounds.width {
                let format = UIGraphicsImageRendererFormat()
                format.scale = window.screen.scale
                let image = UIGraphicsImageRenderer(bounds: sheet.bounds, format: format).image { _ in
                    _ = sheet.drawHierarchy(in: sheet.bounds, afterScreenUpdates: true)
                }
                let url = folder.appending(path: "\(name)-d\(step)-\(slug)-sheet.png")
                try? image.pngData()?.write(to: url)
                post(url)
            }
            log += "d\(step) \(label): presented \(presented.map { String(describing: type(of: $0)) } ?? "-")\n"
        }
        func dismissAll() async {
            if let presented = window.rootViewController?.presentedViewController {
                presented.dismiss(animated: false)
                try? await Task.sleep(for: .seconds(0.8))
            }
        }
        let names = (tabs.viewControllers ?? []).map { $0.tabBarItem.title ?? "?" }
        guard let moreIndex = names.firstIndex(of: "More"), let nav = tabs.viewControllers?[moreIndex] as? UINavigationController,
              let more = nav.viewControllers.first as? MoreViewController else { return }
        tabs.selectedIndex = moreIndex
        try? await Task.sleep(for: .seconds(1))
        // Settings, page by page.
        more.open(rowId: "settings")
        try? await Task.sleep(for: .seconds(2))
        if let root = find(SettingsRootController.self, in: window.rootViewController), let stack = root.router.navigation {
            // `-HQDebugMacShotsRoots a,b,c` photographs only those root pages and stops there.
            let only = UserDefaults.standard.string(forKey: "HQDebugMacShotsRoots")?.split(separator: ",").map(String.init)
            let roots = only ?? ["gateway", "notifications", "providers", "keys", "vault", "billing", "sessions", "capabilities", "skills",
                                 "tools", "plugins", "connectors", "auxiliary-models", "theme", "tab-order", "about", "diagnostics", "tool-calls",
                                 "sound-picker", "attachment-limit"]
            // [mac-audit] `page:<key>` in that list opens a config page (`page:model.main`: Main Model).
            var targets: [(String, () -> Void)] = roots.map { id in
                if id.hasPrefix("page:"), let page = ConfigCatalog.page(String(id.dropFirst(5))) {
                    return (id, { ConfigScreens.open(page: page, router: root.router) })
                }
                return (id, { SettingsNavigator.openRoot(id, router: root.router) })
            }
            for section in ConfigCatalog.sections where only == nil {
                targets.append(("config \(section.title)", { ConfigScreens.open(section: section, router: root.router) }))
                for page in section.pages {
                    targets.append(("config \(section.title) › \(page.title)", { ConfigScreens.open(page: page, router: root.router) }))
                }
            }
            for (label, open) in targets {
                stack.popToViewController(root, animated: false)
                try? await Task.sleep(for: .seconds(0.4))
                open()
                try? await Task.sleep(for: .seconds(1.8))
                if stack.topViewController === root, window.rootViewController?.presentedViewController == nil {
                    log += "settings \(label): nothing opened\n"
                    continue
                }
                snap("settings \(label)")
                await dismissAll()
            }
            stack.popToViewController(root, animated: false)
            if only != nil {
                let file = folder.appending(path: "\(name)-deep.txt")
                try? log.write(to: file, atomically: true, encoding: .utf8)
                post(file)
                try? await Task.sleep(for: .seconds(1.5))
                return
            }
        } else {
            log += "settings: no root\n"
        }
        // The page behind each More page's first row.
        if let list = collection(in: more.view) {
            var paths: [IndexPath] = []
            for section in 0..<list.numberOfSections { for item in 0..<list.numberOfItems(inSection: section) { paths.append(IndexPath(item: item, section: section)) } }
            for path in paths {
                nav.popToRootViewController(animated: false)
                try? await Task.sleep(for: .seconds(0.5))
                guard list.delegate?.collectionView?(list, shouldSelectItemAt: path) ?? true else { continue }
                list.delegate?.collectionView?(list, didSelectItemAt: path)
                try? await Task.sleep(for: .seconds(1.8))
                let shown = KeyCommands.root?.split?.isDouble == true ? (KeyCommands.root?.split?.detailScreens.last ?? nav.topViewController) : nav.topViewController
                let title = shown?.navigationItem.title ?? shown?.title ?? "row \(path.item)"
                guard let shown, !["Settings"].contains(title), window.rootViewController?.presentedViewController == nil else {
                    await dismissAll()
                    continue
                }
                let stack = shown.navigationController
                let depth = stack?.viewControllers.count ?? 0
                if clickFirstRow(in: shown.view) {
                    try? await Task.sleep(for: .seconds(1.8))
                    if (stack?.viewControllers.count ?? 0) > depth || window.rootViewController?.presentedViewController != nil {
                        snap("more \(title) › first row")
                    } else {
                        log += "more \(title): first row opened nothing\n"
                    }
                    await dismissAll()
                } else {
                    log += "more \(title): no row\n"
                }
            }
            nav.popToRootViewController(animated: false)
        }
        // A bot chat, top to bottom, a screen at a time.
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(0.8))
        for bot in tabs.services.bots.prefix(3) {
            tabs.botsViewController.open(bot.id)
            try? await Task.sleep(for: .seconds(2.5))
            guard let chat = find(ChatViewController.self, in: window.rootViewController), let table = table(in: chat.view) else { continue }
            table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
            try? await Task.sleep(for: .seconds(1))
            var page = 0
            while page < 6 {
                snap("chat \(bot.id) \(page)")
                let next = table.contentOffset.y + table.bounds.height * 0.85
                let bottom = table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom
                if table.contentOffset.y >= bottom - 2 { break }
                table.setContentOffset(CGPoint(x: 0, y: min(next, bottom)), animated: false)
                try? await Task.sleep(for: .seconds(0.8))
                page += 1
            }
        }
        // A laptop-sized window: each tab, then a chat.
        let laptop = CGRect(x: 80, y: 80, width: 1000, height: 680)
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: laptop)) { _ in }
        try? await Task.sleep(for: .seconds(2))
        // Switch tabs as a sidebar click does (the right pane follows, #62), then back to Bots: its chat comes back.
        for (index, title) in names.enumerated() {
            tabs.selectedIndex = index
            tabs.split?.followSelectedTab()
            try? await Task.sleep(for: .seconds(1.2))
            snap("laptop \(title)")
        }
        tabs.selectedIndex = 0
        tabs.split?.followSelectedTab()
        try? await Task.sleep(for: .seconds(1.2))
        snap("laptop back to bots")
        if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
        try? await Task.sleep(for: .seconds(2))
        snap("laptop chat")
        let file = folder.appending(path: "\(name)-deep.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(1.5))
    }

    /// [mac-popups] `-HQDebugMacShotsPopups`: the composer's pop-overs in a bot chat. ☰ Commands as it opens, after ↓↓↓,
    /// searched; Models as it opens; the slash drawer. Each as the whole window and as a close crop round the pop-over
    /// (`-crop`). `<name>-popups.txt` has the panel frames and what is marked.
    @MainActor private static func popupsTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        var step = 0
        func snap(_ label: String, crop: CGRect? = nil) {
            step += 1
            let slug = label.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            shoot(window, to: folder.appending(path: "\(name)-q\(step)-\(slug).png"))
            if let crop {
                let format = UIGraphicsImageRendererFormat()
                format.scale = window.screen.scale
                let rect = crop.insetBy(dx: -40, dy: -40).intersection(window.bounds)
                let image = UIGraphicsImageRenderer(bounds: rect, format: format).image { _ in
                    _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let url = folder.appending(path: "\(name)-q\(step)-\(slug)-crop.png")
                try? image.pngData()?.write(to: url)
                post(url)
            }
            let presented = window.rootViewController.flatMap(topPresented)
            log += "q\(step) \(label): presented \(presented.map { String(describing: type(of: $0)) } ?? "-")"
            if let panel = presented as? MacPickPanel {
                log += " panel \(panel.debugPanelFrame) marked \(panel.debugMarked.map { "\($0.section).\($0.row)" } ?? "-") field first \(panel.field.isFirstResponder)"
            }
            log += "\n"
        }
        func panel() -> MacPickPanel? { window.rootViewController.flatMap(topPresented) as? MacPickPanel }
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(0.8))
        if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
        try? await Task.sleep(for: .seconds(2.5))
        guard let chat = find(ChatViewController.self, in: window.rootViewController), let menus = chat.menus else {
            log += "no chat\n"
            return
        }
        // [favorite-commands] Two starred commands and one starred model, put back as they were at the end.
        let commandStore = menus.live.map { CommandFavorites(accountId: $0.account.id) }
        let starredBefore = commandStore?.commands ?? []
        for command in ["/status", "/compress"] where commandStore?.contains(command) == false { commandStore?.toggle(command) }
        let modelsBefore = menus.prefs?.favorites ?? []
        if menus.prefs?.favorites.contains("openrouter::moonshotai/kimi-k2-thinking") == false {
            menus.prefs?.toggleFavorite(provider: "openrouter", model: "moonshotai/kimi-k2-thinking")
        }
        log += "models: \(menus.context?.models().map(\.key) ?? [])\n"
        // [mac-audit] A typed line in the field, so a panel that covers it shows (Mac audit #3).
        chat.composer.text = "A draft line the panels must leave in view"
        menus.presentCommandsSheet()
        try? await Task.sleep(for: .seconds(2.5))
        snap("commands", crop: panel()?.debugPanelFrame)
        panel()?.move(by: 1); panel()?.move(by: 1); panel()?.move(by: 1); panel()?.move(by: 1)
        try? await Task.sleep(for: .seconds(0.5))
        snap("commands keys", crop: panel()?.debugPanelFrame)
        // ⌘D on the marked row (/new under Session) adds it to Favorites; the mark stays on it.
        if let p = panel() {
            let star = p.keyCommands?.first { $0.input == "d" }
            log += "⌘D offered: \(star?.title ?? "-")\n"
            p.perform(NSSelectorFromString("starMarked"))
        }
        try? await Task.sleep(for: .seconds(0.6))
        snap("commands starred by key", crop: panel()?.debugPanelFrame)
        if let p = panel() { p.perform(NSSelectorFromString("starMarked")) }   // and off again
        try? await Task.sleep(for: .seconds(0.4))
        if let p = panel() {
            p.field.text = "st"
            p.field.sendActions(for: .editingChanged)
        }
        try? await Task.sleep(for: .seconds(0.8))
        snap("commands search", crop: panel()?.debugPanelFrame)
        if let p = panel() {
            p.field.text = "zzzq"
            p.field.sendActions(for: .editingChanged)
        }
        try? await Task.sleep(for: .seconds(0.6))
        snap("commands no results", crop: panel()?.debugPanelFrame)
        panel()?.close()
        try? await Task.sleep(for: .seconds(1))
        log += "after close: composer focused \(chat.composer.textView.isFirstResponder)\n"
        menus.presentModelSheet(query: nil)
        try? await Task.sleep(for: .seconds(3))
        snap("models", crop: panel()?.debugPanelFrame)
        panel()?.move(by: 1); panel()?.move(by: 1)
        try? await Task.sleep(for: .seconds(0.4))
        snap("models keys", crop: panel()?.debugPanelFrame)
        // [model-fold] A provider folded by its heading's click, then Collapse All, then Expand All (as they were).
        let foldedBefore = menus.prefs?.foldedProviders ?? []
        if let p = panel(), let provider = menus.context?.models().first(where: { !$0.provider.isEmpty })?.provider {
            p.onFold?(provider)
            try? await Task.sleep(for: .seconds(0.5))
            snap("models folded", crop: p.debugPanelFrame)
            p.onFoldAll?(true)
            try? await Task.sleep(for: .seconds(0.5))
            snap("models all folded", crop: p.debugPanelFrame)
            p.onFoldAll?(false)
            menus.prefs?.setFoldedProviders(foldedBefore)
        }
        panel()?.close()
        try? await Task.sleep(for: .seconds(1))
        // The failed state, from a list that can't be read.
        let failing = MacCommandsPanel(anchor: chat.composer.commandsButton, clearOf: chat.composer, cached: nil, isBotChat: false, favorites: nil,
                                       loader: { _ in throw URLError(.timedOut) }, onPick: { _, _ in }, onCancel: {})
        _ = MacPickPanel.present(failing.panel, from: chat)
        try? await Task.sleep(for: .seconds(1.5))
        snap("commands failed", crop: panel()?.debugPanelFrame)
        panel()?.close()
        try? await Task.sleep(for: .seconds(1))
        chat.composer.text = ""
        chat.focusComposer()
        chat.composer.textView.insertText("/")
        try? await Task.sleep(for: .seconds(2))
        snap("slash drawer")
        chat.composer.textView.insertText("s")
        try? await Task.sleep(for: .seconds(1.5))
        snap("slash drawer s")
        chat.composer.textView.insertText("t")
        try? await Task.sleep(for: .seconds(1.5))
        snap("slash drawer st")
        chat.composer.text = ""
        for command in ["/status", "/compress"] where !starredBefore.contains(command) && commandStore?.contains(command) == true {
            commandStore?.toggle(command)
        }
        if !modelsBefore.contains("openrouter::moonshotai/kimi-k2-thinking") {
            menus.prefs?.toggleFavorite(provider: "openrouter", model: "moonshotai/kimi-k2-thinking")
        }
        let file = folder.appending(path: "\(name)-popups.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(1.5))
    }

    /// [mac-polish new group, 2026-11-07] `-HQDebugMacShotsRoom <words>`: the first group chat opened, those words
    /// typed and sent, the room photographed while its bots answer (Stop is the composer's square) and after, then
    /// Group Info (its own window: `-sheet`). Slow answers come from the stand-in (groups `turn-mode` slow:<s>).
    /// `<name>-room.txt`: what each picture had on show.
    @MainActor private static func roomTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL, words: String) async {
        var log = ""
        var step = 0
        func snap(_ label: String) {
            step += 1
            shoot(window, to: folder.appending(path: "\(name)-r\(step)-\(label).png"))
            var top: UIViewController? = window.rootViewController
            while let next = top?.presentedViewController { top = next }
            if let sheet = top?.viewIfLoaded?.window, sheet !== window {
                shoot(sheet, to: folder.appending(path: "\(name)-r\(step)-\(label)-sheet.png"))
            }
            let chat = tabs.chatOnShow
            log += "r\(step) \(label): chat \(chat?.title ?? "-") field \"\(chat?.composer.text ?? "-")\" presented \(top.map { String(describing: type(of: $0)) } ?? "-")\n"
        }
        defer {
            let file = folder.appending(path: "\(name)-room.txt")
            try? log.write(to: file, atomically: true, encoding: .utf8)
            post(file)
        }
        guard let groups = tabs.services as? GroupServices else { log += "no group services\n"; return }
        var key: String?
        for _ in 0..<40 where key == nil {
            key = groups.groupStore?.rows().first?.id
            if key == nil { try? await Task.sleep(for: .seconds(0.5)) }
        }
        guard let key else { log += "no room\n"; return }
        groups.openRoom(key, from: tabs.botsViewController)
        try? await Task.sleep(for: .seconds(3))
        snap("room")
        guard let chat = tabs.chatOnShow else { log += "no room on show\n"; return }
        chat.composer.text = words
        try? await Task.sleep(for: .seconds(0.8))
        snap("typed")
        chat.composer.submit()
        for index in 1...5 {
            try? await Task.sleep(for: .seconds(index == 1 ? 1.2 : 2.5))
            snap("answering-\(index)")
        }
        try? await Task.sleep(for: .seconds(6))
        snap("answered")
        GroupInfoSheet.present(roomKey: key, from: chat, services: groups)
        try? await Task.sleep(for: .seconds(2.5))
        snap("group-info")
        try? await Task.sleep(for: .seconds(2))
    }

    /// [mac-polish new group, 2026-11-07] `-HQDebugMacShotsModelMenu YES`: the first bot's chat with the model panel
    /// open, and Switch Model's rows as the menu would list them (Favorites with its star row, Recent, All Models), drawn
    /// as a plain light list (`-switchmenu.png`, `-switchmenu.txt`: a real menu can't be photographed). Pair it with
    /// `-HQDebugModelPanelSample YES` for a full Favorites list.
    @MainActor private static func modelMenuTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(0.8))
        if let first = tabs.services.bots.first(where: { $0.id == "default" })?.id ?? tabs.services.bots.first?.id {
            tabs.botsViewController.open(first)
        }
        try? await Task.sleep(for: .seconds(2.5))
        guard let chat = find(ChatViewController.self, in: window.rootViewController), let menus = chat.menus else { return }
        menus.presentModelPanel()
        try? await Task.sleep(for: .seconds(2.5))
        shoot(window, to: folder.appending(path: "\(name)-panel.png"))
        guard let panel = findView(ModelPanelView.self, in: window) else { return }
        let titles = await panel.debugMenuTitles()
        let text = titles.joined(separator: "\n")
        let txt = folder.appending(path: "\(name)-switchmenu.txt")
        try? text.write(to: txt, atomically: true, encoding: .utf8)
        post(txt)
        let rowH: CGFloat = 22, width: CGFloat = 380
        let height = CGFloat(titles.count) * rowH + 16
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            UIColor(white: 0.97, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerRadius: 10).fill()
            var y: CGFloat = 8
            for line in titles {
                let header = line.hasPrefix("[") && line.hasSuffix("]")
                (line as NSString).draw(at: CGPoint(x: header ? 14 : 30, y: y + 3), withAttributes: [
                    .font: HQFont.face(ofSize: header ? 11 : 13, weight: header ? .semibold : .regular),
                    .foregroundColor: header ? UIColor.gray : UIColor.black])
                y += rowH
            }
        }
        let png = folder.appending(path: "\(name)-switchmenu.png")
        try? image.pngData()?.write(to: png)
        post(png)
        try? await Task.sleep(for: .seconds(2))
    }

    /// [mac-audit G] `-HQDebugMacShotsNav YES` (Mac audit 2026-11-02 #14, #15, #18, #19): every tab as a sidebar click
    /// leaves it (its pane bar, and the empty states beside an empty list); a bot's chat opened on Bots and a chat on
    /// Sessions, then tabs switched away and back (each comes back); ⌘K over the Bots chat, then its first result
    /// picked (where it lands, which tab is marked).
    @MainActor private static func navTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        var step = 0
        func snap(_ label: String) {
            step += 1
            shoot(window, to: folder.appending(path: "\(name)-n\(step)-\(label).png"))
            let live = tabs.chatOnShow?.session as? LiveChatSession
            let chat = live.map { ($0.storedSessionId ?? $0.resolvedStoredId).map { "session \($0)" } ?? "bot \($0.profile)" } ?? "-"
            let pane = tabs.split?.detail.viewControllers.map { String(describing: type(of: $0)) } ?? []
            log += "n\(step) \(label): tab \(tabs.shownTab.map { "\($0)" } ?? "-"), right pane \(pane), chat \(chat)\n"
        }
        func click(_ tab: HQTab) async {
            guard let controller = tabs.controller(for: tab) else { log += "no \(tab) tab\n"; return }
            tabs.pick(controller)
            tabs.split?.followSelectedTab()
            try? await Task.sleep(for: .seconds(1.2))
        }
        for controller in tabs.placedTabs {
            tabs.pick(controller)
            tabs.split?.followSelectedTab()
            try? await Task.sleep(for: .seconds(1.5))
            let title = (controller.tabBarItem.title ?? "tab").lowercased().replacingOccurrences(of: " ", with: "-")
            snap("tab-\(title)")
        }
        // More's Pinned and Kanban pages, empty on the stand-in: their bars (Mac audit #18, mac2/3 and mac2/4).
        for row in ["pinned", "kanban"] {
            await click(.more)
            guard let more = find(MoreViewController.self, in: tabs) else { break }
            more.navigationController?.popToRootViewController(animated: false)
            more.open(rowId: row)
            try? await Task.sleep(for: .seconds(2))
            snap("more-\(row)")
        }
        await click(.bots)
        if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
        try? await Task.sleep(for: .seconds(2))
        snap("bots-chat")
        await click(.sessions)
        if let root = (tabs.controller(for: .sessions) as? UINavigationController)?.viewControllers.first, clickFirstRow(in: root.view) {
            try? await Task.sleep(for: .seconds(2))
        } else { log += "sessions: no row to open\n" }
        snap("sessions-chat")
        await click(.jobs)
        snap("jobs-between")
        await click(.bots)
        snap("bots-back")
        await click(.sessions)
        snap("sessions-back")
        // The window narrowed to one pane and widened again with the Sessions chat open: Bots' own chat stays its own.
        let frame = window.windowScene?.effectiveGeometry.systemFrame ?? CGRect(x: 80, y: 80, width: 1280, height: 800)
        for size in [CGSize(width: 400, height: 600), frame.size] {
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: frame.origin, size: size))) { _ in }
            try? await Task.sleep(for: .seconds(2))
        }
        snap("sessions-after-resize")
        await click(.bots)
        snap("bots-after-resize")
        await click(.bots)
        UIApplication.shared.sendAction(KeyCommands.openQuickly, to: UIApplication.shared.delegate, from: nil, for: nil)
        try? await Task.sleep(for: .seconds(1.2))
        snap("quickly")
        MacOpenQuickly.debugOpenMarked()
        try? await Task.sleep(for: .seconds(2))
        snap("quickly-picked")
        let file = folder.appending(path: "\(name)-nav.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(2))
    }

    private static func topPresented(_ controller: UIViewController) -> UIViewController? {
        guard let next = controller.presentedViewController else { return nil }
        return topPresented(next) ?? next
    }

    /// Opens the first selectable row of the first list in `view` through its delegate, as a click does.
    @MainActor private static func clickFirstRow(in view: UIView) -> Bool {
        if let list = collection(in: view) {
            for section in 0..<list.numberOfSections where list.numberOfItems(inSection: section) > 0 {
                for item in 0..<list.numberOfItems(inSection: section) {
                    let path = IndexPath(item: item, section: section)
                    if list.delegate?.collectionView?(list, shouldSelectItemAt: path) ?? true {
                        list.delegate?.collectionView?(list, didSelectItemAt: path)
                        return true
                    }
                }
            }
        }
        if let list = table(in: view) {
            for section in 0..<list.numberOfSections where list.numberOfRows(inSection: section) > 0 {
                let path = IndexPath(row: 0, section: section)
                list.delegate?.tableView?(list, didSelectRowAt: path)
                return true
            }
        }
        return false
    }

    private static func collection(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView, list.bounds.height > 100 { return list }
        for sub in view.subviews { if let found = collection(in: sub) { return found } }
        return nil
    }

    /// [mac-audit] `-HQDebugMacShotsMenu` (with `-HQDebugMacShotsWait`): the open chat's ⋯ as the Mac lays it out
    /// (a real menu is a window of the system's that the app can't draw), as text (`<name>-menu.txt`, "—" a separator,
    /// "▸" a submenu) and as a plain drawn list of the same rows (`<name>-menu.png`).
    private static func dumpMoreMenu(_ window: UIWindow, name: String, folder: URL) {
        guard let menus = find(ChatViewController.self, in: window.rootViewController)?.menus else { return }
        var lines: [(text: String, symbol: UIImage?, red: Bool, rule: Bool)] = []
        func walk(_ elements: [UIMenuElement], depth: Int) {
            for element in elements {
                if let menu = element as? UIMenu, menu.options.contains(.displayInline) {
                    if !lines.isEmpty, lines.last?.rule == false { lines.append(("—", nil, false, true)) }
                    walk(menu.children, depth: depth)
                    if lines.last?.rule == false { lines.append(("—", nil, false, true)) }
                } else if let menu = element as? UIMenu {
                    lines.append((String(repeating: "    ", count: depth) + menu.title + "  ▸", menu.image, false, false))
                    walk(menu.children, depth: depth + 1)
                } else if let action = element as? UIAction {
                    let mark = action.state == .on ? "✓ " : ""
                    let sub = action.subtitle.map { "  (\($0))" } ?? ""
                    lines.append((String(repeating: "    ", count: depth) + mark + action.title + sub, action.image,
                                  action.attributes.contains(.destructive), false))
                }
            }
        }
        walk(menus.moreMenuElements(), depth: 0)
        while lines.last?.rule == true { lines.removeLast() }
        let text = lines.map(\.text).joined(separator: "\n")
        let txt = folder.appending(path: "\(name)-menu.txt")
        try? text.write(to: txt, atomically: true, encoding: .utf8)
        post(txt)
        let rowH: CGFloat = 22, ruleH: CGFloat = 11, width: CGFloat = 380
        let height = lines.reduce(CGFloat(16)) { $0 + ($1.rule ? ruleH : rowH) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor(white: 0.97, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerRadius: 10).fill()
            var y: CGFloat = 8
            for line in lines {
                if line.rule {
                    UIColor(white: 0.82, alpha: 1).setFill()
                    context.fill(CGRect(x: 12, y: y + ruleH / 2, width: width - 24, height: 1))
                    y += ruleH
                    continue
                }
                let indent = CGFloat(line.text.prefix { $0 == " " }.count) / 4 * 20
                let color: UIColor = line.red ? .systemRed : .black
                line.symbol?.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 14 + indent, y: y + 3, width: 16, height: 16))
                (line.text.trimmingCharacters(in: .whitespaces) as NSString).draw(at: CGPoint(x: 40 + indent, y: y + 3),
                    withAttributes: [.font: HQFont.face(ofSize: 13, weight: .regular), .foregroundColor: color])
                y += rowH
            }
        }
        let png = folder.appending(path: "\(name)-menu.png")
        try? image.pngData()?.write(to: png)
        post(png)
    }

    static func shoot(_ window: UIWindow, to url: URL) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: url)
        post(url)
    }

    /// `-HQDebugMacShotsPost <url>`: each file is also sent there, as the sandbox keeps the container from scripts.
    static func post(_ file: URL) {
        guard let base = UserDefaults.standard.string(forKey: "HQDebugMacShotsPost").flatMap(URL.init(string:)),
              let data = try? Data(contentsOf: file) else { return }
        var request = URLRequest(url: base.appending(path: file.lastPathComponent))
        request.httpMethod = "POST"
        URLSession.shared.uploadTask(with: request, from: data).resume()
    }

    /// The root's panes: each child view's frame, whether it is hidden, and how many subviews it draws.
    private static func paneFrames(_ root: UIViewController?) -> String {
        guard let root else { return "" }
        return root.children.map { child in
            let view = child.viewIfLoaded
            let top = (child as? UINavigationController)?.topViewController ?? (child as? UITabBarController)?.selectedViewController
            return "  \(type(of: child)) frame \(view?.frame ?? .zero) hidden \(view?.isHidden ?? true) alpha \(view?.alpha ?? 0) window \(view?.window != nil) top \(top.map { String(describing: type(of: $0)) } ?? "-")"
        }.joined(separator: "\n")
    }

    /// Every button on screen that draws no words of its own, and the tip the pointer would get over its middle.
    private static func toolTips(_ window: UIWindow) -> String {
        var lines: [String] = []
        let interaction = window.interactions.compactMap { $0 as? UIToolTipInteraction }.first
        func walk(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if view is UIControl || view.accessibilityTraits.contains(.button), !MacToolTips.showsWords(view, depth: 0) {
                let frame = view.convert(view.bounds, to: window)
                if frame.width > 4, window.bounds.intersects(frame) {
                    let centre = CGPoint(x: frame.midX, y: frame.midY)
                    let tip = interaction.flatMap { MacToolTips.shared.toolTipInteraction($0, configurationAt: centre)?.toolTip }
                    lines.append("  \(tip == nil ? "NONE" : "ok  ") \(tip ?? "-") · \(type(of: view)) \(view.accessibilityIdentifier ?? "") \(Int(frame.minX)),\(Int(frame.minY))")
                }
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return lines.joined(separator: "\n") + "\n"
    }

    /// `-HQDebugMacShotsSelect YES` (Mac audit 2026-11-02 #11, ChatTextSelection.swift): the first bot's chat; part of
    /// its biggest reply selected through the drag's own `begin` / `move`, then ⌘C, ⌘A and ⌘C, a click away, the same
    /// with the composer holding the keyboard, your own bubble, and an opened folded reply when the chat has one. Each
    /// step's picture, and `<name>-select.txt`: what was selected, who had the keyboard, what the pasteboard got.
    @MainActor private static func selectTour(_ window: UIWindow, tabs: MainTabController?, name: String, folder: URL) async {
        if let tabs {
            tabs.selectedIndex = 0
            try? await Task.sleep(for: .seconds(0.6))
            if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
        }
        try? await Task.sleep(for: .seconds(3))
        var log = ""
        func note(_ line: String) { log += line + "\n" }
        func shown(_ s: String?) -> String {
            guard let s else { return "-" }
            return s.debugDescription
        }
        func save() {
            let url = folder.appending(path: "\(name)-select.txt")
            try? log.write(to: url, atomically: true, encoding: .utf8)
            post(url)
        }
        func responder() -> String { ChatFirstResponder.current().map { String(describing: type(of: $0)) } ?? "none" }
        guard let chat = find(ChatViewController.self, in: window.rootViewController), let list = table(in: chat.view) else {
            note("no chat"); save(); return
        }
        note("cells: " + list.visibleCells.map { String(describing: type(of: $0)) }.joined(separator: ", "))
        // The reply with the most blocks on screen (prose, code, a table), then the tallest.
        let replies = list.visibleCells.compactMap { $0 as? ChatBubbleCell }.filter(\.debugIsReply).filter {
            list.bounds.contains(list.convert($0.debugBubble.bounds, from: $0.debugBubble))
        }
        guard let cell = replies.max(by: { ($0.debugBlocks.count, $0.debugBubble.bounds.height) < ($1.debugBlocks.count, $1.debugBubble.bounds.height) })
                ?? list.visibleCells.compactMap({ $0 as? ChatBubbleCell }).first(where: \.debugIsReply),
              let selector = cell.debugSelector else { note("no reply"); save(); return }
        let bubble = cell.debugBubble
        let blocks = cell.debugBlocks
        note("reply blocks \(blocks.count), pieces \(blocks.map(\.pieceTexts.count))")
        // 1. A drag from the start of the first block to 60 % across the last block's middle.
        guard let firstBlock = blocks.first, let lastBlock = blocks.last else { note("no blocks"); save(); return }
        let from = firstBlock.convert(CGPoint(x: 3, y: 6), to: bubble)
        let to = lastBlock.convert(CGPoint(x: lastBlock.bounds.width * 0.6, y: lastBlock.bounds.height * 0.5), to: bubble)
        note("press on text claims the chat's scroll: \(selector.claimsPress(at: from)); press on the bubble's corner: \(selector.claimsPress(at: CGPoint(x: 1, y: 1)))")
        UIPasteboard.general.string = ""
        _ = selector.begin(at: from)
        for step in 1...8 {
            let t = CGFloat(step) / 8
            selector.move(to: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        }
        selector.end()
        try? await Task.sleep(for: .seconds(0.6))
        shoot(window, to: folder.appending(path: "\(name)-1-drag.png"))
        note("1 drag: selected \(shown(selector.selectedText))")
        note("  marks by block: \(blocks.map { $0.debugSelectionMarks.map { "\($0.key):\($0.value.location)+\($0.value.length)" }.sorted() })")
        note("  drawn by block: \(blocks.map { $0.debugDrawnSelections.count })")
        note("  first responder \(responder()), on the selection \(selector.isOnSelection(to.applying(.init(translationX: -6, y: 0))))")
        UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.copy(_:)), to: nil, from: nil, for: nil)
        note("  ⌘C pasteboard: \(shown(UIPasteboard.general.string))")
        // 2. ⌘A: the whole message, then ⌘C.
        UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.selectAll(_:)), to: nil, from: nil, for: nil)
        try? await Task.sleep(for: .seconds(0.6))
        shoot(window, to: folder.appending(path: "\(name)-2-select-all.png"))
        UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.copy(_:)), to: nil, from: nil, for: nil)
        note("2 ⌘A then ⌘C pasteboard (\(UIPasteboard.general.string?.count ?? 0) chars): \(shown(UIPasteboard.general.string))")
        // 3. A click on the chat's empty top edge (window coordinates) puts it away.
        let away = list.convert(CGPoint(x: list.bounds.midX, y: list.bounds.minY + 4), to: window)
        let awayHit = window.hitTest(away, with: nil)
        ChatClickAway.clicked(at: away, in: window)
        try? await Task.sleep(for: .seconds(0.6))
        shoot(window, to: folder.appending(path: "\(name)-3-clicked-away.png"))
        note("3 click away on \(awayHit.map { String(describing: type(of: $0)) } ?? "-"): has selection \(selector.hasSelection), first responder \(responder())")
        // 4. The composer holds the keyboard: a drag leaves it there and ⌘C comes up its chain to the chat.
        func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) } }
        if let field = views(ComposerTextView.self, in: chat.view).first {
            field.becomeFirstResponder()
            try? await Task.sleep(for: .seconds(0.6))
            UIPasteboard.general.string = ""
            _ = selector.begin(at: from)
            selector.move(to: to)
            selector.end()
            try? await Task.sleep(for: .seconds(0.4))
            shoot(window, to: folder.appending(path: "\(name)-4-composer-focused.png"))
            UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.copy(_:)), to: nil, from: nil, for: nil)
            note("4 composer focused: first responder \(responder()), selected \(selector.selectedText?.count ?? 0) chars, ⌘C pasteboard \(UIPasteboard.general.string?.count ?? 0) chars, same \(UIPasteboard.general.string == selector.selectedText)")
            selector.clear()
            field.resignFirstResponder()
        } else {
            note("4 no composer")
        }
        // 5. Your own bubble: white under the words.
        if let mine = list.visibleCells.compactMap({ $0 as? ChatBubbleCell }).first(where: { !$0.debugIsReply && !$0.debugBlocks.isEmpty }),
           let own = mine.debugSelector, let block = mine.debugBlocks.first {
            let b = mine.debugBubble
            _ = own.begin(at: block.convert(CGPoint(x: 2, y: 4), to: b))
            own.move(to: block.convert(CGPoint(x: block.bounds.width * 0.7, y: block.bounds.height - 4), to: b))
            try? await Task.sleep(for: .seconds(0.5))
            shoot(window, to: folder.appending(path: "\(name)-5-mine.png"))
            note("5 own bubble: \(shown(own.selectedText))")
            own.clear()
        } else {
            note("5 no own bubble on screen")
        }
        // 6. An opened folded reply (an exchange's member), when the chat shows one; a closed one is opened first.
        // The steps above may have moved the chat, so it is paged through until a member shows.
        let start = list.contentOffset
        var page = 0
        while !list.visibleCells.contains(where: { $0 is UpdateMemberCell }), page < 12 {
            page += 1
            let maxY = max(-list.adjustedContentInset.top, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
            let y = min(maxY, -list.adjustedContentInset.top + CGFloat(page) * list.bounds.height * 0.5)
            list.setContentOffset(CGPoint(x: start.x, y: y), animated: false)
            list.layoutIfNeeded()
            try? await Task.sleep(for: .seconds(0.3))
        }
        if !list.visibleCells.contains(where: { ($0 as? UpdateMemberCell)?.debugOpenedWords != nil }),
           let closed = list.visibleCells.compactMap({ $0 as? UpdateMemberCell }).first(where: \.debugOpensToWords) {
            closed.debugOpen()
            try? await Task.sleep(for: .seconds(1))
        }
        note("6 members: " + list.visibleCells.compactMap { $0 as? UpdateMemberCell }
            .map { $0.debugOpenedWords != nil ? "open" : $0.debugOpensToWords ? "closed" : "line" }.joined(separator: ", "))
        if let member = list.visibleCells.compactMap({ $0 as? UpdateMemberCell }).first(where: { $0.debugOpenedWords != nil }),
           let words = member.debugOpenedWords, let sel = member.debugSelector {
            let host = member.debugHost
            UIPasteboard.general.string = ""
            _ = sel.begin(at: words.convert(CGPoint(x: 2, y: 4), to: host))
            sel.move(to: words.convert(CGPoint(x: words.bounds.width * 0.5, y: words.bounds.height - 4), to: host))
            sel.end()
            try? await Task.sleep(for: .seconds(0.5))
            shoot(window, to: folder.appending(path: "\(name)-6-folded-reply.png"))
            UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.copy(_:)), to: nil, from: nil, for: nil)
            note("6 folded reply: selected \(shown(sel.selectedText)), ⌘C pasteboard \(shown(UIPasteboard.general.string))")
            sel.clear()
        } else {
            note("6 no opened folded reply on screen")
        }
        save()
        AppLog.note("debug", "mac select shots written to \(folder.path)")
        try? await Task.sleep(for: .seconds(2))   // the last upload (-HQDebugMacShotsPost) lands before the app quits
    }

    /// `-HQDebugMacShotsGlass YES` (2026-10-30 Mac glass): the first bot's chat with the sidebar, Open Quickly over it,
    /// then Model Prices; the Desktop Look switched live and the same three again, then switched back.
    @MainActor private static func glassTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(0.6))
        if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
        try? await Task.sleep(for: .seconds(2.5))
        let startLook = Theme.isDesktop
        for (step, desktop) in [startLook, !startLook, startLook].enumerated() {
            if Theme.isDesktop != desktop { Theme.shared.setDesktopLook(desktop); try? await Task.sleep(for: .seconds(1.5)) }
            let look = desktop ? "desktop" : "ios"
            shoot(window, to: folder.appending(path: "\(name)-\(step)-\(look)-chat.png"))
            UIApplication.shared.sendAction(KeyCommands.openQuickly, to: UIApplication.shared.delegate, from: nil, for: nil)
            try? await Task.sleep(for: .seconds(1.2))
            shoot(window, to: folder.appending(path: "\(name)-\(step)-\(look)-quickly.png"))
            window.rootViewController?.presentedViewController?.dismiss(animated: false)
            try? await Task.sleep(for: .seconds(0.6))
            find(ChatViewController.self, in: window.rootViewController)?.menus?.presentPrices()
            try? await Task.sleep(for: .seconds(2))
            var top = window.rootViewController
            while let next = top?.presentedViewController { top = next }
            if let sheet = top, sheet !== window.rootViewController {
                shoot(sheet.view.window ?? window, to: folder.appending(path: "\(name)-\(step)-\(look)-prices.png"))
                sheet.dismiss(animated: false)
                try? await Task.sleep(for: .seconds(0.8))
            }
        }
    }

    /// `-HQDebugMacShotsTable YES` (2026-10-29 table card and Table page): the first bot's chat at its top, its first
    /// table's page as it opens, the page fitted to the window and not, then quits.
    /// Tester 2026-10-30: a bot's own Fallback Models and Auxiliary Models. Bot Info for the first bot that isn't the
    /// default, scrolled to Brain, then each page pushed inside the sheet (a Mac sheet is a window of its own).
    @MainActor private static func botModelsTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        guard let bot = tabs.services.bots.first(where: { !BotModelPages.isDefault($0.id) }) else { return }
        BotInfoSheet.present(bot: bot, from: tabs, services: tabs.services)
        try? await Task.sleep(for: .seconds(2.5))
        guard let navigation = tabs.presentedViewController as? UINavigationController else { return }
        let sheet = navigation.view.window ?? window
        func scrolled(_ view: UIView) -> UIScrollView? {
            (view as? UIScrollView) ?? view.subviews.lazy.compactMap { scrolled($0) }.first
        }
        if let list = scrolled(navigation.topViewController?.view ?? navigation.view) {
            list.setContentOffset(CGPoint(x: 0, y: max(0, list.contentSize.height - list.bounds.height) * 0.5), animated: false)
        }
        try? await Task.sleep(for: .seconds(1))
        shoot(sheet, to: folder.appending(path: "\(name)-0-brain.png"))
        BotModelPages.openFallbacks(bot, services: tabs.services, on: navigation)
        try? await Task.sleep(for: .seconds(2.5))
        shoot(sheet, to: folder.appending(path: "\(name)-1-fallbacks.png"))
        navigation.popViewController(animated: false)
        BotModelPages.openAuxiliary(bot, services: tabs.services, on: navigation)
        try? await Task.sleep(for: .seconds(2.5))
        shoot(sheet, to: folder.appending(path: "\(name)-2-auxiliary.png"))
        AppLog.note("debug", "mac bot-model shots written to \(folder.path)")
        try? await Task.sleep(for: .seconds(2))   // the last upload (-HQDebugMacShotsPost) lands before the app quits
    }

    /// A tester 2026-11-07 ("drag and drop … screenshots and files"): `-HQDebugMacShotsDrop YES` opens the first
    /// bot's chat and photographs the "Drop to Attach" card a drag of files over it shows (one file, then three), then
    /// the tray after a picture and a text file are dropped through the drop's own path.
    @MainActor private static func dropTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(0.6))
        if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
        try? await Task.sleep(for: .seconds(2.5))
        guard let chat = find(ChatViewController.self, in: window.rootViewController), let attachments = chat.attachments else { return }
        shoot(window, to: folder.appending(path: "\(name)-0-chat.png"))
        attachments.debugDropOverlay(count: 1)
        try? await Task.sleep(for: .seconds(0.6))
        shoot(window, to: folder.appending(path: "\(name)-1-over-one.png"))
        attachments.debugDropOverlay(count: 3)
        try? await Task.sleep(for: .seconds(0.4))
        shoot(window, to: folder.appending(path: "\(name)-2-over-three.png"))
        attachments.debugDropOverlay(count: nil)
        let files = FileManager.default.temporaryDirectory.appending(path: "drop-tour", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let picture = files.appending(path: "Screenshot 2026-11-07 at 06.40.12.png")
        let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        try? shot.pngData()?.write(to: picture)
        let notes = files.appending(path: "notes.txt")
        try? "Drag and drop test".write(to: notes, atomically: true, encoding: .utf8)
        attachments.debugDrop([picture, notes].compactMap { NSItemProvider(contentsOf: $0) })
        try? await Task.sleep(for: .seconds(3))
        shoot(window, to: folder.appending(path: "\(name)-3-dropped.png"))
        try? await Task.sleep(for: .seconds(1))
    }

    @MainActor private static func tableTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(0.6))
        if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
        try? await Task.sleep(for: .seconds(2.5))
        guard let chat = find(ChatViewController.self, in: window.rootViewController), let list = table(in: chat.view) else { return }
        list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
        try? await Task.sleep(for: .seconds(1))
        shoot(window, to: folder.appending(path: "\(name)-0-card.png"))
        func blocks(in view: UIView) -> [BlockView] {
            (view as? BlockView).map { [$0] } ?? view.subviews.flatMap { blocks(in: $0) }
        }
        let cards = list.visibleCells.sorted { $0.frame.minY < $1.frame.minY }.flatMap { blocks(in: $0) }
        guard cards.contains(where: { $0.expandTableIfHit(CGPoint(x: 1, y: 1)) }) else { return }
        try? await Task.sleep(for: .seconds(1.5))
        var top = window.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let page = find(TableSheetController.self, in: top) else { return }
        // A Mac sheet is a window of its own.
        let sheet = page.view.window ?? window
        shoot(sheet, to: folder.appending(path: "\(name)-1-page.png"))
        let note = folder.appending(path: "\(name)-page.txt")
        try? ("fitted \(page.fitted) frozen \(page.frozen) canFit \(page.canFit) page \(page.view.bounds.size) window \(sheet.bounds.size)"
              + " asks \(page.preferredContentSize) navigation asks \(page.navigationController?.preferredContentSize ?? .zero)"
              + " insets \(page.view.safeAreaInsets) margins \(page.view.directionalLayoutMargins)")
            .write(to: note, atomically: true, encoding: .utf8)
        post(note)
        page.setFitted(!page.fitted)
        try? await Task.sleep(for: .seconds(1))
        shoot(sheet, to: folder.appending(path: "\(name)-2-page-\(page.fitted ? "fitted" : "natural").png"))
        try? await Task.sleep(for: .seconds(1))
    }

    /// [preview-tables] `-HQDebugMacShotsPreviewTable YES`: a Markdown file's Preview with a table wider than the page
    /// (the chat's table card over its place in the text), then scrolled sideways.
    @MainActor private static func previewTableTour(_ window: UIWindow, name: String, folder: URL) async {
        let markdown = "# Junk mail tracker\n\nStatus as of today.\n\n## Confirmed removed\n\n| Sender | Date confirmed | Note |\n|---|---|---|\n"
            + "| MailPrefs (most junk) | 2026-10-18 | active to 2036 |\n"
            + "| Catalog list (credit/insurance offers) | 2026-10-18 | 5 yrs |\n"
            + "| Shop A, Shop B, Shop C, Shop D | 2026-10-18–21 | web form confirmed |\n"
            + "| Shop E | 2026-10-21 | 6–8 wks |\n\nWatch the mail for 6–8 weeks.\n"
        let page = ArtifactTextViewController(title: "junk-mail-tracker.md", markdown: true, language: nil) { markdown }
        let nav = UINavigationController(rootViewController: page)
        nav.modalPresentationStyle = .fullScreen
        window.rootViewController?.present(nav, animated: false)
        try? await Task.sleep(for: .seconds(2.5))
        shoot(window, to: folder.appending(path: "\(name)-0-preview.png"))
        func blocks(in view: UIView) -> [BlockView] {
            (view as? BlockView).map { [$0] } ?? view.subviews.flatMap { blocks(in: $0) }
        }
        if let scroll = blocks(in: page.view).first?.subviews.compactMap({ $0 as? UIScrollView }).first {
            scroll.setContentOffset(CGPoint(x: max(0, scroll.contentSize.width - scroll.bounds.width), y: 0), animated: false)
        }
        try? await Task.sleep(for: .seconds(1))
        shoot(window, to: folder.appending(path: "\(name)-1-scrolled.png"))
        try? await Task.sleep(for: .seconds(2))   // `-HQDebugMacShotsPost`'s upload
    }

    /// `-HQDebugMacShotsSubagents YES`: the first bot's chat; once its Subagents chip shows (the stand-in's events),
    /// the card opened (the list and the first page side by side), then the second helper picked.
    @MainActor private static func subagentsTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(0.6))
        if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
        func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
        }
        var chip: UIControl?
        for _ in 0..<120 where chip == nil {
            try? await Task.sleep(for: .seconds(0.5))
            chip = views(UIControl.self, in: window).first { $0.accessibilityIdentifier == "chat.shelf.subagents" && $0.window != nil && !($0.superview?.superview?.isHidden ?? true) }
        }
        guard let chip else { shoot(window, to: folder.appending(path: "\(name)-0-no-chip.png")); return }
        try? await Task.sleep(for: .seconds(1))
        shoot(window, to: folder.appending(path: "\(name)-0-chip.png"))
        chip.sendActions(for: .touchUpInside)
        try? await Task.sleep(for: .seconds(2))
        shoot(window, to: folder.appending(path: "\(name)-1-card.png"))
        let rows = views(SubagentRowView.self, in: window).sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
        if rows.count > 1 {
            rows[1].sendActions(for: .touchUpInside)
            try? await Task.sleep(for: .seconds(1.5))
            shoot(window, to: folder.appending(path: "\(name)-2-second.png"))
        }
    }

    /// `-HQDebugMacShotsChats YES` (Mac stress test round 4): what a chat draws on the Mac, against whichever stand-in
    /// is signed in. With `-HQDebugMacShotsSend <text>` the first bot's chat is sent that text and photographed while
    /// the turn runs; then every bot's chat (up to 8) top to bottom a screen at a time, and the first Sessions rows
    /// opened. Sheets and popovers in windows of their own get their own pictures. `<name>-chats.txt` lists them.
    @MainActor private static func chatsTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        var step = 0
        func snap(_ label: String) {
            step += 1
            let slug = label.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            shoot(window, to: folder.appending(path: "\(name)-c\(step)-\(slug).png"))
            let others = (window.windowScene?.windows ?? []).filter { $0 !== window && !$0.isHidden && $0.bounds.width > 40 && !String(describing: type(of: $0)).contains("TextEffects") }
            for (index, other) in others.enumerated() { shoot(other, to: folder.appending(path: "\(name)-c\(step)-\(slug)-w\(index).png")) }
            let presented = window.rootViewController.flatMap(topPresented)
            log += "c\(step) \(label): presented \(presented.map { String(describing: type(of: $0)) } ?? "-")\n"
        }
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(0.8))
        let bots = tabs.services.bots.prefix(8).map(\.id)
        if let text = UserDefaults.standard.string(forKey: "HQDebugMacShotsSend"), !text.isEmpty, let first = bots.first {
            tabs.botsViewController.open(first)
            try? await Task.sleep(for: .seconds(2.5))
            if let chat = find(ChatViewController.self, in: window.rootViewController) {
                chat.composer.textView.becomeFirstResponder()
                chat.composer.textView.insertText(text)
                try? await Task.sleep(for: .seconds(0.4))
                snap("send typed")
                chat.composer.submit()
                for index in 0..<8 {
                    try? await Task.sleep(for: .seconds(index < 4 ? 1.2 : 2.5))
                    snap("send \(index)")
                }
            }
        }
        for bot in bots {
            tabs.botsViewController.open(bot)
            try? await Task.sleep(for: .seconds(2.5))
            guard let chat = find(ChatViewController.self, in: window.rootViewController) else { continue }
            try? await Task.sleep(for: .seconds(1))
            // Newest first, then a screen at a time toward older rows. The transcript is drawn upside down and follows
            // its newest row, so a plain offset change was undone (every page was the newest screen): `debugScroll`
            // stops the following too.
            for page in 0..<8 {
                snap("chat \(bot) \(page)")
                let before = chat.tableView.contentOffset.y
                chat.debugScroll(by: chat.tableView.bounds.height * 0.8)
                try? await Task.sleep(for: .seconds(0.9))
                if abs(chat.tableView.contentOffset.y - before) < 2 { break }
            }
        }
        let names = (tabs.viewControllers ?? []).map { $0.tabBarItem.title ?? "?" }
        if let index = names.firstIndex(of: "Sessions"), let nav = tabs.viewControllers?[index] as? UINavigationController {
            tabs.selectedIndex = index
            tabs.split?.followSelectedTab()
            try? await Task.sleep(for: .seconds(1.5))
            snap("sessions list")
            if let root = nav.viewControllers.first, let list = collection(in: root.view) {
                var paths: [IndexPath] = []
                for section in 0..<list.numberOfSections { for item in 0..<list.numberOfItems(inSection: section) { paths.append(IndexPath(item: item, section: section)) } }
                for path in paths.filter({ list.delegate?.collectionView?(list, shouldSelectItemAt: $0) ?? true }).prefix(5) {
                    list.delegate?.collectionView?(list, didSelectItemAt: path)
                    try? await Task.sleep(for: .seconds(2.5))
                    snap("session \(path.section)-\(path.item)")
                }
            }
        }
        let file = folder.appending(path: "\(name)-chats.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(1.5))
    }

    /// [mac-sidebar] `-HQDebugMacShotsSidebar YES` (owner 2026-10-31 "add more options to the sidebar"): with many rows
    /// (`-hqn.tabOrder`), each row clicked in turn and where its page landed (its own stack, never the system's More),
    /// the menus a Control-click gives (as titles: a menu can't be photographed), ⌘7 and ⌘9, adding, moving and
    /// removing a place, a short window (the list scrolls), the folded rail and Sidebar Settings….
    /// [rail-names] `-HQDebugMacShotsRailNames YES`: a bot's chat beside the folded rail at the faces' width, the edge
    /// held past halfway (the names come), let go (it settles at the names' width), then Sessions beside it. The rail's
    /// fold and width the person had go back at the end.
    @MainActor private static func railNamesTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        guard let split = tabs.split else { return }
        let bar = split.macSidebar
        let wasFolded = UserDefaults.standard.bool(forKey: MacSidebar.collapsedKey)
        let wasNamed = MacSidebar.railNamed
        var log = ""
        func step(_ label: String) async {
            try? await Task.sleep(for: .seconds(1.4))
            log += "\(label): width \(MacSidebar.width) named \(MacSidebar.railNamed) heads \(bar.debugHeads)\n" + paneFrames(split) + "\n"
            shoot(window, to: folder.appending(path: "\(name)-\(label).png"))
        }
        MacSidebar.railNamed = false
        if !MacSidebar.isCollapsed { bar.toggleCollapsed() } else { bar.rebuild() }
        if let bots = tabs.controller(for: .bots) { tabs.pick(bots); split.followSelectedTab() }
        let shown = tabs.services.bots.filter { !$0.hidden }
        if let bot = shown.first(where: { $0.name == "Ivy" }) ?? shown.first { tabs.botsViewController.open(bot.id) }
        await step("1-faces")
        bar.debugDragRail(to: ((MacSidebar.compactRailWidth + MacSidebar.namedRailWidth) / 2 + 6).rounded())
        await step("2-dragging")
        bar.debugDragRail(to: nil)
        await step("3-names")
        if let sessions = tabs.controller(for: .sessions) { tabs.pick(sessions); split.followSelectedTab() }
        await step("4-sessions")
        MacSidebar.railNamed = wasNamed
        UserDefaults.standard.set(wasFolded, forKey: MacSidebar.collapsedKey)
        try? log.write(to: folder.appending(path: "\(name)-names.txt"), atomically: true, encoding: .utf8)
        post(folder.appending(path: "\(name)-names.txt"))
        try? await Task.sleep(for: .seconds(2))
    }

    /// [rail-more] `-HQDebugMacShotsRailMore YES` (Mac audit #25): at each rail width (faces alone, then names) the rail
    /// with its group chats and, with a second gateway saved (`HQN_ADD_*`), the switcher at its top; a head held mid-drag
    /// over another (the drop line), dropped, and dragged back; a group chat's head clicked. The menus go in
    /// `<name>-more.txt` as titles. A gateway added for the shot is removed again, and the fold and width go back.
    @MainActor private static func railMoreTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        guard let split = tabs.split else { return }
        let bar = split.macSidebar
        let wasFolded = UserDefaults.standard.bool(forKey: MacSidebar.collapsedKey)
        let wasNamed = MacSidebar.railNamed
        var log = ""
        // The saved "Studio" gateway (`HQN_ADD_*`, the groups stand-in) is the one photographed; the one in use before
        // comes back at the end.
        let gateways = tabs.botsViewController.gatewaySwitcher?.gateways
        let before = gateways?.accounts.first(where: \.isCurrent).flatMap { $0.title == "Studio" ? nil : $0 }
            ?? gateways?.accounts.first { $0.title != "Studio" }   // an earlier tour left Studio in use
        if let gateways, let studio = gateways.accounts.first(where: { !$0.isCurrent && $0.title == "Studio" }) {
            try? await gateways.switchTo(studio.id)
            try? await Task.sleep(for: .seconds(6))
            log += "switched to Studio\n"
        }
        func step(_ label: String) async {
            try? await Task.sleep(for: .seconds(1.4))
            log += "\(label): width \(MacSidebar.width) heads \(bar.debugHeads)\n  \(bar.debugRailGateway)\n"
            shoot(window, to: folder.appending(path: "\(name)-\(label).png"))
        }
        if !MacSidebar.isCollapsed { bar.toggleCollapsed() }
        if let bots = tabs.controller(for: .bots) { tabs.pick(bots); split.followSelectedTab() }
        for named in [false, true] {
            let width = named ? "names" : "faces"
            MacSidebar.railNamed = named
            bar.rebuild()
            if let first = tabs.services.bots.first(where: { !$0.hidden }) { tabs.botsViewController.open(first.id) }
            await step("\(width)-1-rail")
            if !named, let menu = bar.debugHeadMenu(0) {   // [mac-menu] the groups, flat
                log += "  menu: " + menu.children.map { group in
                    ((group as? UIMenu)?.options.contains(.displayInline) == true ? (group as? UIMenu)?.children ?? [] : [group])
                        .map { $0.title + ($0 is UIMenu ? " ▸" : "") }.joined(separator: ", ")
                }.joined(separator: " | ") + "\n"
            }
            // The second head held over the first one's top half: the drop line above it. Then dropped, and back.
            log += "  drag: " + bar.debugRailDrag(from: 1, over: 0, below: false, drop: false) + "\n"
            await step("\(width)-2-dragging")
            log += "  drop: " + bar.debugRailDrag(from: 1, over: 0, below: false, drop: true) + "\n"
            await step("\(width)-3-dropped")
            log += "  back: " + bar.debugRailDrag(from: 0, over: 1, below: true, drop: true) + "\n"
            try? await Task.sleep(for: .seconds(1))
            // Across groups: the last bot's head over the first group's last head (filed there), not dropped.
            log += "  across: " + bar.debugRailDrag(from: 3, over: 1, below: true, drop: false) + "\n"
            await step("\(width)-4-across")
            bar.debugDropLine(nil)
            // A group chat's head: its room beside the rail, its head marked.
            if let room = bar.debugHeads.split(separator: " ").firstIndex(where: { $0.contains("room:") }) {
                let index = bar.debugHeads.split(separator: " ").prefix(room).filter { $0 != "|" && $0 != "+" }.count
                bar.debugClickHead(index)
                await step("\(width)-5-room")
            }
        }
        // A gateway saved for the shot only goes again.
        if let gateways, let before, before.title != "Studio", gateways.accounts.first(where: \.isCurrent)?.id != before.id {
            try? await gateways.switchTo(before.id)
            try? await Task.sleep(for: .seconds(4))
        }
        if let gateways, let added = gateways.accounts.first(where: { !$0.isCurrent && $0.title == "Studio" }) {
            try? await gateways.remove(added.id)
            log += "removed the shot's gateway\n"
        }
        MacSidebar.railNamed = wasNamed
        UserDefaults.standard.set(wasFolded, forKey: MacSidebar.collapsedKey)
        try? log.write(to: folder.appending(path: "\(name)-more.txt"), atomically: true, encoding: .utf8)
        post(folder.appending(path: "\(name)-more.txt"))
        try? await Task.sleep(for: .seconds(2))
    }

    /// [bots-rail] `-HQDebugMacShotsRail YES`: the sidebar open with a chat, folded into the heads, a second head
    /// clicked, Sessions (its list back beside the rail), a head again, a narrow window, then open again. The fold
    /// the person had goes back at the end. Each step's panes and marks go in `<name>-rail.txt`.
    @MainActor private static func railTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        guard let split = tabs.split else { return }
        let bar = split.macSidebar
        let wasFolded = UserDefaults.standard.bool(forKey: MacSidebar.collapsedKey)
        var log = ""
        func step(_ label: String) async {
            try? await Task.sleep(for: .seconds(1.4))
            log += "\(label): folded \(MacSidebar.isCollapsed) tab \(tabs.shownTab.map { "\($0)" } ?? "-") listFolded \(split.listFolded) "
                + "layout \(split.layout) detail \(split.detailScreens.map { String(describing: type(of: $0)) }) heads \(bar.debugHeads)\n"
                + paneFrames(split) + "\n"
            shoot(window, to: folder.appending(path: "\(name)-\(label).png"))
        }
        if MacSidebar.isCollapsed { bar.toggleCollapsed() }
        if let bots = tabs.controller(for: .bots) { tabs.pick(bots); split.followSelectedTab() }
        if let first = tabs.services.bots.first(where: { !$0.hidden }) { tabs.botsViewController.open(first.id) }
        await step("1-open")
        bar.toggleCollapsed()
        await step("2-folded")
        bar.debugClickHead(2)
        await step("3-head")
        if let sessions = tabs.controller(for: .sessions) { tabs.pick(sessions); split.followSelectedTab() }
        await step("4-sessions")
        bar.debugClickHead(0)
        await step("5-head-again")
        log += "menu on head 1:\n" + (bar.debugHeadMenu(0).map { $0.children.map { "  \($0.title)" }.joined(separator: "\n") } ?? "  none") + "\n"
        let frame = window.windowScene?.effectiveGeometry.systemFrame ?? CGRect(x: 80, y: 80, width: 1280, height: 800)
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: frame.origin, size: CGSize(width: 640, height: 760)))) { _ in }
        await step("6-narrow")
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
        try? await Task.sleep(for: .seconds(1))
        bar.toggleCollapsed()
        await step("7-unfolded")
        UserDefaults.standard.set(wasFolded, forKey: MacSidebar.collapsedKey)
        try? log.write(to: folder.appending(path: "\(name)-rail.txt"), atomically: true, encoding: .utf8)
        post(folder.appending(path: "\(name)-rail.txt"))
        try? await Task.sleep(for: .seconds(2))
    }

    @MainActor private static func sidebarTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        guard let bar = tabs.split?.macSidebar else { return }
        // The rows to start from, `-HQDebugSidebarTabs sessions,bots,page.files…` (not `-hqn.tabOrder`: an argument
        // would hide every change made here). What was stored goes back at the end: the Debug app shares its container.
        // `-HQDebugSidebarKeep YES` leaves the rows and a tenth row on show for the next launch, which
        // `-HQDebugSidebarLaunch YES` photographs (the place restored) before it puts the default rows back.
        let keep = UserDefaults.standard.bool(forKey: "HQDebugSidebarKeep")
        let launchCheck = UserDefaults.standard.bool(forKey: "HQDebugSidebarLaunch")
        let stored = launchCheck ? nil : UserDefaults.standard.object(forKey: TabOrder.key)
        defer {
            if keep {
            } else if let stored { UserDefaults.standard.set(stored, forKey: TabOrder.key) } else { UserDefaults.standard.removeObject(forKey: TabOrder.key) }
        }
        log += "stored before: \(UserDefaults.standard.object(forKey: TabOrder.key).map { "\($0)" } ?? "nothing (default)")\n"
        if let keys = UserDefaults.standard.string(forKey: "HQDebugSidebarTabs") {
            TabOrder.tabs = keys.split(separator: ",").compactMap { TabChoice(key: String($0)) }
            try? await Task.sleep(for: .seconds(1.2))
        }
        func state(_ label: String) -> String {
            let places = tabs.placedTabs
            let selected = tabs.selectedViewController
            let top = (selected as? UINavigationController)?.topViewController
            let held = (tabs.viewControllers ?? []).map { $0.tabBarItem.title ?? "?" }
            return "\(label): \(places.count) rows [\(places.map { $0.tabBarItem.title ?? "?" }.joined(separator: ", "))] · held [\(held.joined(separator: ", "))] · "
                + "on show \(selected?.tabBarItem.title ?? "-") top \(top.map { String(describing: type(of: $0)) } ?? "-") in window \(top?.viewIfLoaded?.window != nil) · "
                + "system More holds \(tabs.moreNavigationController.viewControllers.count) · back \(top?.navigationItem.backButtonTitle ?? "-")/\((selected as? UINavigationController)?.viewControllers.count ?? 0)\n"
        }
        func titles(_ menu: UIMenu, depth: Int = 0) -> String {
            menu.children.map { element in
                let pad = String(repeating: "  ", count: depth + 1)
                if let sub = element as? UIMenu {
                    let head = sub.options.contains(.displayInline) ? "\(pad)——\n" : "\(pad)\(sub.title) ▸\n"
                    return head + titles(sub, depth: sub.options.contains(.displayInline) ? depth : depth + 1)
                }
                if let action = element as? UIAction {
                    let flags = (action.attributes.contains(.disabled) ? " (off)" : "") + (action.image == nil ? "" : " [icon]")
                    return "\(pad)\(action.title)\(flags)\n"
                }
                return "\(pad)?\n"
            }.joined()
        }
        if launchCheck {
            log += state("launched")
            shoot(window, to: folder.appending(path: "\(name)-launch.png"))
            try? log.write(to: folder.appending(path: "\(name)-sidebar.txt"), atomically: true, encoding: .utf8)
            post(folder.appending(path: "\(name)-sidebar.txt"))
            try? await Task.sleep(for: .seconds(1))
            return
        }
        func tips() -> String {
            var lines: [String] = []
            func walk(_ view: UIView) {
                if let control = view as? UIControl, let tip = control.toolTip { lines.append("  \(tip)") }
                view.subviews.forEach(walk)
            }
            walk(bar)
            return lines.joined(separator: "\n") + "\n"
        }
        log += state("start")
        shoot(window, to: folder.appending(path: "\(name)-0-start.png"))
        let count = tabs.placedTabs.count
        for index in 0..<count {
            bar.debugClick(index)
            try? await Task.sleep(for: .seconds(0.9))
            log += state("click row \(index + 1)")
            if index == 6 || index == count - 2 { shoot(window, to: folder.appending(path: "\(name)-1-row\(index + 1).png")) }
        }
        log += "tooltips:\n" + tips()
        // The menus.
        for index in [0, 1, 2, count - 2, count - 1] {
            log += "menu on row \(index + 1) (\(tabs.placedTabs[index].tabBarItem.title ?? "?")):\n" + titles(bar.debugMenu(forRow: index))
        }
        log += "menu on the empty space:\n" + titles(bar.debugMenu(forRow: nil))
        if let more = tabs.pages?.more {
            for section in more.isViewLoaded ? tabs.pages?.moreSections() ?? [] : [] {
                for row in section.rows() where row.card == nil {
                    log += "More row \(row.id): " + (SidebarEditing.moreRowMenu(rowID: row.id).map { titles($0).replacingOccurrences(of: "\n", with: " ") } ?? "no menu") + "\n"
                }
            }
        }
        // ⌘1…⌘9 as the View menu validates them, then ⌘7 and ⌘9 pressed.
        let delegate = UIApplication.shared.delegate as? AppDelegate
        for number in 0..<KeyCommands.tabTitles.count {
            let command = UIKeyCommand(title: "?", action: KeyCommands.selectTab, input: String(number + 1), modifierFlags: .command, propertyList: number)
            delegate?.validate(command)
            log += "⌘\(number + 1): \(command.title)\(command.attributes.contains(.hidden) ? " (hidden)" : "")\(command.attributes.contains(.disabled) ? " (off)" : "")\n"
        }
        for number in [6, 8] {
            let command = UIKeyCommand(title: "?", action: KeyCommands.selectTab, input: String(number + 1), modifierFlags: .command, propertyList: number)
            delegate?.hqSelectTab(command)
            try? await Task.sleep(for: .seconds(0.9))
            log += state("⌘\(number + 1)")
        }
        shoot(window, to: folder.appending(path: "\(name)-2-cmd9.png"))
        // Add the first page not in the sidebar, move it up, then remove it.
        if let place = SidebarEditing.addable().first(where: { if case .page = $0.choice { true } else { false } }) {
            SidebarEditing.add(place.choice)
            try? await Task.sleep(for: .seconds(1))
            log += state("added \(place.title)")
            shoot(window, to: folder.appending(path: "\(name)-3-added.png"))
            SidebarEditing.move(place.choice, by: -1)
            try? await Task.sleep(for: .seconds(0.6))
            log += state("moved \(place.title) up")
            if let row = tabs.placedTabs.firstIndex(where: { TabChoice(tag: $0.tabBarItem.tag) == place.choice }) {
                bar.debugClick(row)
                try? await Task.sleep(for: .seconds(0.8))
                log += state("clicked \(place.title)")
            }
            SidebarEditing.remove(place.choice)
            try? await Task.sleep(for: .seconds(0.8))
            log += state("removed \(place.title) while on show")
        }
        // A drop as a drag ends it: Files above the first row, then below the last (More stays last); the line a drag
        // over the third gap draws.
        SidebarEditing.move(.page("files"), before: tabs.placedTabs.first.flatMap { TabChoice(tag: $0.tabBarItem.tag) })
        try? await Task.sleep(for: .seconds(0.6))
        log += state("dropped Files at the top")
        SidebarEditing.move(.page("files"), before: nil)
        try? await Task.sleep(for: .seconds(0.6))
        log += state("dropped Files at the end")
        bar.debugDropLine(2)
        try? await Task.sleep(for: .seconds(0.3))
        shoot(window, to: folder.appending(path: "\(name)-3-dropline.png"))
        bar.debugDropLine(nil)
        // A short window: the rows scroll.
        let frame = CGRect(x: 80, y: 80, width: 1280, height: 800)
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 80, y: 80, width: 1280, height: 470))) { _ in }
        try? await Task.sleep(for: .seconds(1.5))
        let scroll = bar.debugScroll
        log += "short window: rows \(scroll.frame) content \(scroll.contentSize)\n"
        shoot(window, to: folder.appending(path: "\(name)-4-short.png"))
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        try? await Task.sleep(for: .seconds(0.5))
        shoot(window, to: folder.appending(path: "\(name)-5-short-scrolled.png"))
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
        try? await Task.sleep(for: .seconds(1.5))
        // Folded to the rail and opened again.
        bar.toggleCollapsed()
        try? await Task.sleep(for: .seconds(1))
        shoot(window, to: folder.appending(path: "\(name)-6-folded.png"))
        log += "folded tooltips:\n" + tips()
        bar.toggleCollapsed()
        try? await Task.sleep(for: .seconds(1))
        // Sidebar Settings….
        SidebarEditing.openSettings()
        try? await Task.sleep(for: .seconds(3))
        log += state("sidebar settings") + "right pane: \(tabs.split?.detail.viewControllers.map { $0.title ?? String(describing: type(of: $0)) } ?? [])\n"
        shoot(window, to: folder.appending(path: "\(name)-7-settings.png"))
        if let page = tabs.split?.detail.topViewController?.view, let list = collection(in: page) {
            list.setContentOffset(CGPoint(x: 0, y: max(0, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)), animated: false)
            try? await Task.sleep(for: .seconds(0.6))
            shoot(window, to: folder.appending(path: "\(name)-8-settings-add.png"))
        }
        if keep, tabs.placedTabs.count > 9 {
            bar.debugClick(9)
            try? await Task.sleep(for: .seconds(1))
            log += state("left on show for the next launch")
        }
        try? log.write(to: folder.appending(path: "\(name)-sidebar.txt"), atomically: true, encoding: .utf8)
        post(folder.appending(path: "\(name)-sidebar.txt"))
        try? await Task.sleep(for: .seconds(1))
    }

    /// [mac-audit] `-HQDebugMacShotsFiles YES` (Mac audit J1–J3, against scripts/fixtures/morepages-gateway.py): More ›
    /// Files and Changes and Artifacts photographed; `<name>-files.txt` lists each row's menu (as the Mac lays it out,
    /// menus can't be photographed) and its drag: the types it offers, then the file a drop would get, loaded through
    /// the provider as the Finder loads it. Then Files' first file's Save As… is chosen and its panel left up
    /// `-HQDebugMacShotsHold` seconds (default 12) for a screen capture from outside.
    /// With `HQN_ADD_URL` (the stand-in saved as a second gateway at launch) the tour switches to it first, and back to
    /// the gateway in use, forgetting the stand-in, at the end: the Debug app's sign-in is shared by every run on this Mac.
    @MainActor private static func filesTour(_ window: UIWindow, tabs first: MainTabController, name: String, folder: URL) async {
        var log = ""
        var tabs = first
        let gateways = (first.services as? any SettingsServices)?.gateways
        let original = gateways?.accounts.first(where: \.isCurrent)?.id
        var added: String?
        if let gateways, let url = ProcessInfo.processInfo.environment["HQN_ADD_URL"].flatMap(URL.init(string:)),
           let row = gateways.accounts.first(where: { !$0.isCurrent && $0.account.baseURL.port == url.port && $0.account.baseURL.host == url.host }) {
            do {
                try await gateways.switchTo(row.id)
                added = row.id
                try? await Task.sleep(for: .seconds(6))
                tabs = find(MainTabController.self, in: window.rootViewController) ?? first
                log += "switched to \(row.hostAndPort)\n"
            } catch {
                log += "couldn't switch to \(row.hostAndPort): \(error)\n"
            }
        }
        func snap(_ label: String) {
            shoot(window, to: folder.appending(path: "\(name)-\(label).png"))
        }
        func titles(_ elements: [UIMenuElement]) -> String {
            elements.map { element -> String in
                if let menu = element as? UIMenu { return (menu.title.isEmpty ? "" : menu.title + ": ") + "[" + titles(menu.children) + "]" }
                return (element as? UIAction)?.title ?? "?"
            }.joined(separator: ", ")
        }
        func describe(_ provider: NSItemProvider?) async -> String {
            guard let provider else { return "no drag" }
            let types = provider.registeredTypeIdentifiers
            guard let type = types.first else { return "drag stays in the app (no types)" }
            if type == UTType.url.identifier || provider.canLoadObject(ofClass: NSURL.self) && !provider.hasRepresentationConforming(toTypeIdentifier: UTType.data.identifier, fileOptions: []) {
                return "drag \(types) (a link)"
            }
            let loaded: String = await withCheckedContinuation { done in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    let size = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? -1
                    done.resume(returning: url.map { "\($0.lastPathComponent), \(size) bytes" } ?? "failed \(error.map { "\($0)" } ?? "")")
                }
            }
            return "drag \(types) named \(provider.suggestedName ?? "-") → drop gets \(loaded)"
        }
        typealias Handler = @convention(block) (UIAction) -> Void
        func action(_ menu: UIMenu, _ title: String) -> UIAction? {
            for element in menu.children {
                if let action = element as? UIAction, action.title == title { return action }
                if let inner = element as? UIMenu, let found = action(inner, title) { return found }
            }
            return nil
        }
        /// Back to the gateway in use, the stand-in forgotten, before the app quits.
        func restore() async {
            guard let gateways, let added, let original else { return }
            try? await gateways.switchTo(original)
            try? await Task.sleep(for: .seconds(4))
            do { try await gateways.remove(added) } catch { AppLog.note("macshots", "couldn't forget the stand-in: \(error)") }
            try? await Task.sleep(for: .seconds(2))
            let after = folder.appending(path: "\(name)-files-restored.txt")
            try? "gateways now: \(gateways.accounts.map { "\($0.hostAndPort)\($0.isCurrent ? " (current)" : "")" })\n"
                .write(to: after, atomically: true, encoding: .utf8)
            post(after)
            try? await Task.sleep(for: .seconds(1.5))
        }
        tabs.select(.more)
        try? await Task.sleep(for: .seconds(1))
        guard let context = MorePages.context, let stack = tabs.pages?.more?.navigationController else {
            log += "no More stack or context\n"
            try? log.write(to: folder.appending(path: "\(name)-files.txt"), atomically: true, encoding: .utf8)
            await restore()
            return
        }
        var saveFrom: (MoreWorkspaceController, UIMenu)?
        for page in ["files", "review"] {
            stack.popToRootViewController(animated: false)
            guard let controller = MorePages.factories[page]?(context) as? MoreWorkspaceController else { log += "\(page): no page\n"; continue }
            stack.pushViewController(controller, animated: false)
            try? await Task.sleep(for: .seconds(4))
            snap(page)
            log += "== \(page)\n"
            for (label, menu, provider) in controller.debugRows() {
                log += "\(label): menu [\(titles(menu.children))]; \(await describe(provider))\n"
                if saveFrom == nil, action(menu, "Save As…") != nil { saveFrom = (controller, menu) }
            }
            // Mac polish #47: a drop that got nothing says why in the page's alert; noted and closed, so the tour goes on
            // (an alert left up kept the next pages from being pushed).
            try? await Task.sleep(for: .seconds(0.5))
            if let alert = window.rootViewController.flatMap(topPresented) as? UIAlertController {
                log += "alert: \(alert.title ?? "-"): \(alert.message ?? "-")\n"
                alert.dismiss(animated: false)
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
        stack.popToRootViewController(animated: false)
        let artifacts = tabs.pages?.makeArtifacts()
        if let artifacts = artifacts as? ArtifactsViewController {
            stack.pushViewController(artifacts, animated: false)
            try? await Task.sleep(for: .seconds(6))
            snap("artifacts")
            log += "== artifacts\n"
            for (label, menu, provider) in artifacts.debugMenus() {
                log += "\(label): menu [\(titles(menu.children))]; \(await describe(provider))\n"
            }
            stack.popToRootViewController(animated: false)
        }
        // Save As… chosen on Files' first file: the panel opens over the page.
        if let (controller, menu) = saveFrom, let save = action(menu, "Save As…"), let block = save.value(forKey: "handler") {
            stack.pushViewController(controller, animated: false)
            try? await Task.sleep(for: .seconds(1))
            unsafeBitCast(block as AnyObject, to: Handler.self)(save)
            try? await Task.sleep(for: .seconds(4))
            let presented = window.rootViewController.flatMap(topPresented)
            log += "save as: presented \(presented.map { String(describing: type(of: $0)) } ?? "-")\n"
            let hold = UserDefaults.standard.double(forKey: "HQDebugMacShotsHold")
            try? await Task.sleep(for: .seconds(hold > 0 ? hold : 12))
            presented?.dismiss(animated: false)
        }
        let file = folder.appending(path: "\(name)-files.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(2))
        await restore()
    }

    /// [terminal] `-HQDebugMacShotsTerminal YES` (with `-HQTerminalNoLock YES`, against scripts/fixtures/terminal-gateway.py):
    /// More › Terminal in each look, typed into; View › Make Text Bigger and Actual Size; Select All + ⌘C, then ⌘V of
    /// several lines; Escape. `<name>-terminal.txt` says what each step left (font size, pasteboard, first responder).
    @MainActor private static func terminalTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        guard let account = MorePages.context?.account else { return }
        TerminalSettings.setAllowed(true, account: account.id)
        let names = (tabs.viewControllers ?? []).map { $0.tabBarItem.title ?? "?" }
        guard let moreIndex = names.firstIndex(of: "More"), let nav = tabs.viewControllers?[moreIndex] as? UINavigationController,
              let more = nav.viewControllers.first as? MoreViewController else { return }
        let startLook = Theme.isDesktop
        func send(_ action: Selector) { UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil) }
        func responder() -> String { window.firstResponderForDebug.map { String(describing: type(of: $0)) } ?? "none" }
        for (step, desktop) in [startLook, !startLook].enumerated() {
            if Theme.isDesktop != desktop { Theme.shared.setDesktopLook(desktop); try? await Task.sleep(for: .seconds(1.5)) }
            let look = desktop ? "desktop" : "ios"
            if let tool = tabs.placedTab(tagged: 115) {
                tabs.show(tool)   // the Mac's sidebar has Terminal as a Tool (More has no Terminal row there now)
            } else {
                tabs.selectedIndex = moreIndex
                tabs.split?.followSelectedTab()
                try? await Task.sleep(for: .seconds(1))
                nav.popToRootViewController(animated: false)
                more.open(rowId: "terminal")
            }
            var page: TerminalViewController?
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(0.5))
                page = find(TerminalViewController.self, in: window.rootViewController)
                if page?.state == .connection(.live) { break }
            }
            guard let page, page.state == .connection(.live) else {
                log += "\(look): not live (\(String(describing: page?.state)))\n"
                shoot(window, to: folder.appending(path: "\(name)-\(step)-\(look)-not-live.png"))
                continue
            }
            try? await Task.sleep(for: .seconds(1))
            page.debugTerminal.insertText("clear; printf '\\e[1mHermes HQ\\e[0m  \\e[31mred \\e[32mgreen \\e[33myellow \\e[34mblue\\e[0m\\n'; ls -G; echo $SHELL\n")
            try? await Task.sleep(for: .seconds(2))
            log += "\(look): live, first responder \(responder()), font \(page.debugTerminal.font.pointSize), size \(page.debugTerminal.terminalDimensions)\n"
            shoot(window, to: folder.appending(path: "\(name)-\(step)-\(look).png"))
            // [mac] With the lock on (`-HQTerminalFakeUnlock YES`, no `-HQTerminalNoLock`): the app hidden locks the
            // shells again, and coming back asks (passed here without a prompt) and shows them again.
            if step == 0, UserDefaults.standard.bool(forKey: "HQTerminalFakeUnlock") {
                NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
                NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
                try? await Task.sleep(for: .seconds(1))
                log += "  hidden: \(responder())\n"
                shoot(window, to: folder.appending(path: "\(name)-\(step)-\(look)-locked.png"))
                NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
                try? await Task.sleep(for: .seconds(2))
                log += "  back: \(responder())\n"
                shoot(window, to: folder.appending(path: "\(name)-\(step)-\(look)-unlocked.png"))
            }
            // View › Make Text Bigger twice, as ⌘+ ⌘+ would send it through the responder chain.
            let scale = Theme.shared.state.uiScalePercent
            send(KeyCommands.textBigger)
            send(KeyCommands.textBigger)
            try? await Task.sleep(for: .seconds(1))
            log += "  bigger ×2: font \(page.debugTerminal.font.pointSize), size \(page.debugTerminal.terminalDimensions), UI Scale \(scale)% → \(Theme.shared.state.uiScalePercent)%\n"
            shoot(window, to: folder.appending(path: "\(name)-\(step)-\(look)-bigger.png"))
            send(KeyCommands.textNormal)
            try? await Task.sleep(for: .seconds(0.5))
            log += "  actual size: font \(page.debugTerminal.font.pointSize)\n"
            // Select All + ⌘C.
            UIPasteboard.general.string = ""
            send(#selector(UIResponderStandardEditActions.selectAll(_:)))
            try? await Task.sleep(for: .seconds(0.5))
            shoot(window, to: folder.appending(path: "\(name)-\(step)-\(look)-selected.png"))
            send(#selector(UIResponderStandardEditActions.copy(_:)))
            try? await Task.sleep(for: .seconds(0.5))
            let copied = UIPasteboard.general.string ?? ""
            log += "  select all + copy: \(copied.count) characters, has notes.txt \(copied.contains("notes.txt"))\n"
            // ⌘V of two lines: zsh takes them as one bracketed paste, so they wait for Return.
            UIPasteboard.general.string = "echo mac-paste-$((3*4))\necho mac-second\n"
            send(#selector(UIResponderStandardEditActions.paste(_:)))
            try? await Task.sleep(for: .seconds(1))
            let asked = window.rootViewController.flatMap(topPresented)
            log += "  paste: asked \(asked.map { String(describing: type(of: $0)) } ?? "no")\n"
            asked?.dismiss(animated: false)
            page.debugTerminal.insertText("\n")
            try? await Task.sleep(for: .seconds(1.5))
            log += "  pasted ran: \(page.allText.contains("mac-paste-12")) \(page.allText.contains("mac-second"))\n"
            shoot(window, to: folder.appending(path: "\(name)-\(step)-\(look)-pasted.png"))
            // Escape goes to the shell (the page stays).
            send(KeyCommands.escape)
            try? await Task.sleep(for: .seconds(0.8))
            log += "  escape: page still on show \(page.view.window != nil), first responder \(responder())\n"
            // zsh holds that Escape for the next key (Esc c would eat the next round's "c"): Control-C drops both.
            page.debugTerminal.send([0x03])
            try? await Task.sleep(for: .seconds(0.5))
        }
        if Theme.isDesktop != startLook { Theme.shared.setDesktopLook(startLook) }
        let file = folder.appending(path: "\(name)-terminal.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(2))
    }

    /// [mac] Audit 2026-11-02 #6/#17: `-HQDebugMacShotsAlerts YES` (with `-HQTerminalNoLock YES`). The Terminal's
    /// first-time question and the page behind it, then a one-field prompt and a destructive confirmation. Before each
    /// waits for a key, it posts `<name>-await-<step>.txt` (to `-HQDebugMacShotsPost`) and gives a script outside 20 s
    /// to press Return or Escape in the window; `<name>-alerts.txt` says what each key did.
    @MainActor private static func alertsTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        // Only the stand-in gateway: Turn On here answers for that computer.
        guard let account = MorePages.context?.account, account.baseURL.host == "127.0.0.1" else { return }
        let names = (tabs.viewControllers ?? []).map { $0.tabBarItem.title ?? "?" }
        guard let moreIndex = names.firstIndex(of: "More"), let nav = tabs.viewControllers?[moreIndex] as? UINavigationController,
              let more = nav.viewControllers.first as? MoreViewController else { return }
        func top() -> UIViewController? { window.rootViewController.flatMap(topPresented) }
        // An alert is drawn apart from the window's own hierarchy: its view is photographed on its own too.
        func shootAlert(_ label: String) {
            guard let view = (top() as? UIAlertController)?.view, view.bounds.width > 0 else { return }
            log += "  alert \(label): tint \(view.tintColor.map { String(describing: $0) } ?? "-"), mode \(view.tintAdjustmentMode.rawValue), window \(view.window.map { String(describing: type(of: $0)) } ?? "-") key \(view.window?.isKeyWindow ?? false), responder \(view.window?.firstResponderForDebug.map { String(describing: type(of: $0)) } ?? "none")\n"
            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale
            let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
                _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            let url = folder.appending(path: "\(name)-\(label)-alert.png")
            try? image.pngData()?.write(to: url)
            post(url)
        }
        func waitKey(_ step: String, until done: (() -> Bool)? = nil) async -> Bool {
            let done = done ?? { !(top() is UIAlertController) }
            let marker = folder.appending(path: "\(name)-await-\(step).txt")
            try? step.write(to: marker, atomically: true, encoding: .utf8)
            post(marker)
            for _ in 0..<80 {
                try? await Task.sleep(for: .seconds(0.25))
                if done() { return true }
            }
            // Not answered by the key: closed here, so the next step starts with nothing on top.
            if top() is UIAlertController { top()?.dismiss(animated: false) }
            try? await Task.sleep(for: .seconds(0.5))
            return false
        }
        func openTerminal() async -> TerminalViewController? {
            tabs.selectedIndex = moreIndex
            tabs.split?.followSelectedTab()
            try? await Task.sleep(for: .seconds(1))
            nav.popToRootViewController(animated: false)
            tabs.split?.detail.popToRootViewController(animated: false)
            try? await Task.sleep(for: .seconds(0.5))
            more.open(rowId: "terminal")
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(0.5))
                let page = find(TerminalViewController.self, in: window.rootViewController)
                if top() is UIAlertController || page?.state == .consent { break }
            }
            return find(TerminalViewController.self, in: window.rootViewController)
        }
        // 1. The first-time question: Return answers Turn On.
        TerminalSettings.setAllowed(false, account: account.id)
        var page = await openTerminal()
        try? await Task.sleep(for: .seconds(2.5))
        log += "consent up: alert \(top() is UIAlertController), card \(page?.state == .consent), first responder \(page?.isFirstResponder ?? false), title \((top() as? UIAlertController)?.title ?? "-")\n"
        log += "  message: \((top() as? UIAlertController)?.message ?? "-")\n"
        shoot(window, to: folder.appending(path: "\(name)-1-consent.png"))
        shootAlert("1")
        (top() as? UIAlertController)?.view.isHidden = true
        try? await Task.sleep(for: .seconds(0.5))
        shoot(window, to: folder.appending(path: "\(name)-2-behind.png"))
        (top() as? UIAlertController)?.view.isHidden = false
        try? await Task.sleep(for: .seconds(0.5))
        let closedByReturn = await waitKey("return") { page?.state != .consent && !(top() is UIAlertController) }
        try? await Task.sleep(for: .seconds(1))
        log += "return: closed \(closedByReturn), turned on \(TerminalSettings.allowed(account.id)), state \(String(describing: page?.state))\n"
        // 2. Again: Escape answers Not Now.
        TerminalSettings.setAllowed(false, account: account.id)
        page = await openTerminal()
        try? await Task.sleep(for: .seconds(1))
        let closedByEscape = await waitKey("escape") { page?.state != .consent && !(top() is UIAlertController) }
        try? await Task.sleep(for: .seconds(1))
        log += "escape: closed \(closedByEscape), turned on \(TerminalSettings.allowed(account.id)), state \(String(describing: page?.state))\n"
        shoot(window, to: folder.appending(path: "\(name)-3-off.png"))
        tabs.split?.detail.popToRootViewController(animated: false)
        nav.popToRootViewController(animated: false)
        try? await Task.sleep(for: .seconds(1))
        // 3. A one-field prompt: typed into, Return renames.
        var answer = "(none)"
        TextPrompt.present(title: "Rename Chat", text: "Old name", action: "Rename", requireChange: true, selectText: true,
                           from: tabs) { answer = $0 }
        try? await Task.sleep(for: .seconds(1))
        shoot(window, to: folder.appending(path: "\(name)-4-prompt.png"))
        shootAlert("4")
        let promptReturn = await waitKey("type-return")
        log += "prompt return: closed \(promptReturn), answer \(answer)\n"
        // 4. Escape cancels it.
        answer = "(none)"
        TextPrompt.present(title: "Rename Chat", text: "Old name", action: "Rename", from: tabs) { answer = $0 }
        try? await Task.sleep(for: .seconds(1))
        let promptEscape = await waitKey("escape2")
        log += "prompt escape: closed \(promptEscape), answer \(answer)\n"
        // 5. A destructive confirmation: Escape cancels, Return does nothing harmful.
        var deleted = false
        TextPrompt.confirm(title: "Delete Chat?", message: "This can’t be undone.", action: "Delete", from: tabs) { deleted = true }
        try? await Task.sleep(for: .seconds(1))
        shoot(window, to: folder.appending(path: "\(name)-5-confirm.png"))
        shootAlert("5")
        let confirmEscape = await waitKey("escape3")
        log += "confirm escape: closed \(confirmEscape), deleted \(deleted)\n"
        let file = folder.appending(path: "\(name)-alerts.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(2))
    }

    private static func table(in view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        for sub in view.subviews { if let found = table(in: sub) { return found } }
        return nil
    }

    /// [mac-layout] `-HQDebugMacShotsLayout YES` (with -HQDemoRealChat -HQDemoHelpers -HQDemoOpen <bot>
    /// -HQMacInspectorShown YES): the layout pass's sweep. The chat with each inspector tab, every place and tool with
    /// the inspector open, the window at 1000 and 760 wide, then the Settings window, a page pushed in it and the list
    /// scrolled. Nothing is saved but the inspector's last tab.
    @MainActor private static var layoutTourStarted = false
    @MainActor private static func layoutTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        // Once: the Settings window's scene connecting would start a second tour beside the first.
        guard !layoutTourStarted else { while true { try? await Task.sleep(for: .seconds(60)) } }
        layoutTourStarted = true
        var step = 0
        func snap(_ label: String, _ target: UIWindow? = nil) async {
            try? await Task.sleep(for: .seconds(1.2))
            step += 1
            shoot(target ?? window, to: folder.appending(path: "\(name)-\(String(format: "%02d", step))-\(label).png"))
        }
        try? await Task.sleep(for: .seconds(4))
        guard let split = tabs.split else { return }
        let chatPlace = tabs.selectedViewController
        for tab in MacInspector.Tab.allCases {
            split.inspector.show(tab)
            await snap("chat-\(tab.title.lowercased())")
        }
        for place in tabs.placedTabs where place !== chatPlace {
            let title = (place.tabBarItem.title ?? "place").lowercased().replacingOccurrences(of: " ", with: "-")
            tabs.pick(place, animated: false)
            split.followSelectedTab()
            await snap("place-\(title)")
        }
        if let chatPlace { tabs.pick(chatPlace, animated: false); split.followSelectedTab() }
        split.inspector.show(.helpers)
        let frame = window.windowScene?.effectiveGeometry.systemFrame ?? CGRect(x: 80, y: 80, width: 1280, height: 800)
        for width in [1000.0, 760.0] {
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: frame.minX, y: frame.minY, width: width, height: 760))) { _ in }
            try? await Task.sleep(for: .seconds(2.5))
            await snap("narrow-\(Int(width))")
        }
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
        try? await Task.sleep(for: .seconds(2))
        let opened = MacSettingsWindow.open()
        var settings: UIWindow?
        for _ in 0..<40 where settings == nil {
            try? await Task.sleep(for: .seconds(0.3))
            settings = MacSettingsWindow.scene?.windows.first
        }
        guard let settings, let nav = settings.rootViewController as? UINavigationController,
              let root = nav.viewControllers.first as? SettingsRootController else {
            print("layout tour: no settings window (open \(opened), scene \(MacSettingsWindow.scene != nil), windows \(MacSettingsWindow.scene?.windows.count ?? -1), root \(String(describing: settings?.rootViewController)))")
            return
        }
        try? await Task.sleep(for: .seconds(1.5))
        await snap("settings", settings)
        func lists(_ view: UIView) -> [UIScrollView] { ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(lists) }
        if let list = lists(root.view).max(by: { $0.contentSize.height < $1.contentSize.height }) {
            list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top + 700), animated: false)
            await snap("settings-scrolled", settings)
            list.setContentOffset(CGPoint(x: 0, y: max(-list.adjustedContentInset.top, list.contentSize.height - list.bounds.height)), animated: false)
            await snap("settings-end", settings)
        }
        SettingsNavigator.openRoot("tab-order", router: root.router)
        await snap("settings-pushed", settings)
        if let page = nav.topViewController, let list = lists(page.view).max(by: { $0.contentSize.height < $1.contentSize.height }) {
            list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top + 60), animated: false)
            await snap("settings-pushed-scrolled", settings)
        }
        MacSettingsWindow.close()
        try? await Task.sleep(for: .seconds(1))
    }

    /// [mac-tools] `-HQDebugMacShotsFilesTable YES`: the Mac's Files and Changes tables (morepages fixture). Files' root,
    /// a folder opened in place, a file beside the table, the window at 1000 wide; then Changes and a change's diff;
    /// then (with `-HQDebugKanbanHold <seconds>`) Files left open for a real pointer.
    @MainActor private static func filesTableTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var step = 0
        func snap(_ label: String) async {
            try? await Task.sleep(for: .seconds(1.5))
            step += 1
            shoot(window, to: folder.appending(path: "\(name)-\(String(format: "%02d", step))-\(label).png"))
        }
        func open(_ title: String) async -> MoreWorkspaceController? {
            guard let place = tabs.placedTabs.first(where: { $0.tabBarItem.title == title }) else { print("files tour: no \(title) place"); return nil }
            tabs.pick(place, animated: false)
            tabs.split?.followSelectedTab()
            try? await Task.sleep(for: .seconds(4))
            return find(MoreWorkspaceController.self, in: place)
        }
        try? await Task.sleep(for: .seconds(4))
        if let files = await open("Files") {
            await snap("files")
            files.debugClick("src")
            try? await Task.sleep(for: .seconds(2))
            files.debugClick("components")
            try? await Task.sleep(for: .seconds(2))
            await snap("folder")
            files.debugClick("nav.js")
            try? await Task.sleep(for: .seconds(2.5))
            await snap("file")
            files.debugCrumb(0)
            try? await Task.sleep(for: .seconds(2))
            files.debugClick("README.md")
            try? await Task.sleep(for: .seconds(2.5))
            await snap("markdown")
            let frame = window.windowScene?.effectiveGeometry.systemFrame ?? CGRect(x: 80, y: 80, width: 1280, height: 800)
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: frame.minX, y: frame.minY, width: 1000, height: 760))) { _ in }
            try? await Task.sleep(for: .seconds(2.5))
            await snap("narrow")
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
            try? await Task.sleep(for: .seconds(2))
            tabs.split?.closeDetail(animated: false)
        }
        if let changes = await open("Changes") {
            await snap("changes")
            changes.debugClick("src/app.js")
            try? await Task.sleep(for: .seconds(2.5))
            await snap("diff")
            tabs.split?.closeDetail(animated: false)
        }
        let hold = UserDefaults.standard.double(forKey: "HQDebugKanbanHold")
        if hold > 0 {
            _ = await open("Files")
            try? await Task.sleep(for: .seconds(hold))
        }
    }

    /// [mac-tools] `-HQDebugMacShotsGrids YES`: the Mac's grids (morepages fixture). Artifacts over the whole window, its
    /// Files segment, a file open beside it, the window at 1000 wide; Tiles (a few artifacts pinned first); Marketplace;
    /// then (with `-HQDebugKanbanHold <seconds>`) Artifacts left open for a real pointer.
    @MainActor private static func gridsTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var step = 0
        func snap(_ label: String) async {
            try? await Task.sleep(for: .seconds(1.5))
            step += 1
            shoot(window, to: folder.appending(path: "\(name)-\(String(format: "%02d", step))-\(label).png"))
        }
        func open(_ title: String) async -> UIViewController? {
            var found: UIViewController?
            for _ in 0..<20 where found == nil {   // a place added once its row is read (Marketplace) comes a little later
                found = tabs.placedTabs.first { $0.tabBarItem.title == title }
                if found == nil { try? await Task.sleep(for: .seconds(1)) }
            }
            guard let place = found else {
                AppLog.note("mac", "grids tour: no \(title) place among \(tabs.placedTabs.map { $0.tabBarItem.title ?? "?" })")
                return nil
            }
            tabs.pick(place, animated: false)
            tabs.split?.followSelectedTab()
            try? await Task.sleep(for: .seconds(4))
            return place
        }
        try? await Task.sleep(for: .seconds(4))
        if let place = await open("Artifacts"), let artifacts = find(ArtifactsViewController.self, in: place) {
            await snap("artifacts")
            artifacts.select(filter: .file)
            await snap("files")
            artifacts.select(filter: nil)
            artifacts.debugOpen("plan.md")
            try? await Task.sleep(for: .seconds(3))
            await snap("file-open")
            tabs.split?.closeDetail(animated: false)
            let frame = window.windowScene?.effectiveGeometry.systemFrame ?? CGRect(x: 80, y: 80, width: 1280, height: 800)
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: frame.minX, y: frame.minY, width: 1000, height: 760))) { _ in }
            try? await Task.sleep(for: .seconds(2.5))
            await snap("narrow")
            window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
            try? await Task.sleep(for: .seconds(2))
            if UserDefaults.standard.bool(forKey: "HQDebugGridsPin") {
                artifacts.debugPin(["index.html", "report.pdf", "plan.md", "export.csv", "Open Planning"])
                try? await Task.sleep(for: .seconds(3))
                await snap("artifacts-pinned")
            }
        }
        if await open("Tiles") != nil {
            try? await Task.sleep(for: .seconds(3))
            await snap("tiles")
        }
        if await open("Marketplace") != nil {
            try? await Task.sleep(for: .seconds(3))
            await snap("marketplace")
            if let market = find(MarketplaceController.self, in: await open("Marketplace") ?? UIViewController()) {
                market.debugKind(.plugins)
                try? await Task.sleep(for: .seconds(2))
                await snap("marketplace-plugins")
                market.debugKind(.skills)
                try? await Task.sleep(for: .seconds(2))
                await snap("marketplace-skills")
                market.debugKind(.plugins)
                try? await Task.sleep(for: .seconds(1))
                market.debugOpenFirst()
                try? await Task.sleep(for: .seconds(3))
                await snap("marketplace-open")
                tabs.split?.closeDetail(animated: false)
                market.debugKind(.all)
            }
        }
        try? await Task.sleep(for: .seconds(2))   // the last picture is still on its way to the receiver
        let hold = UserDefaults.standard.double(forKey: "HQDebugKanbanHold")
        if hold > 0 {
            _ = await open(UserDefaults.standard.string(forKey: "HQDebugGridsHoldOn") ?? "Artifacts")
            try? await Task.sleep(for: .seconds(hold))
        }
    }

    /// [mac-tools] `-HQDebugMacShotsDash YES`: the Mac's dashboards (morepages fixture): Status & Maintenance, Usage and
    /// Spawn Tree over the whole window, then (with `-HQDebugKanbanHold <seconds>`) `-HQDebugGridsHoldOn`'s left open
    /// for a real pointer.
    @MainActor private static func dashTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var step = 0
        func open(_ title: String) async -> Bool {
            var found: UIViewController?
            for _ in 0..<20 where found == nil {
                found = tabs.placedTabs.first { $0.tabBarItem.title == title }
                if found == nil { try? await Task.sleep(for: .seconds(1)) }
            }
            guard let place = found else { return false }
            tabs.pick(place, animated: false)
            tabs.split?.followSelectedTab()
            try? await Task.sleep(for: .seconds(5))
            return true
        }
        try? await Task.sleep(for: .seconds(4))
        // `-HQDebugDashPlaces "Tasks,Terminal"`: other places than the three dashboards.
        let places = UserDefaults.standard.string(forKey: "HQDebugDashPlaces")?.components(separatedBy: ",")
            ?? ["Status & Maintenance", "Usage", "Spawn Tree"]
        for title in places where await open(title) {
            try? await Task.sleep(for: .seconds(1.5))
            step += 1
            let label = title.lowercased().replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-")
            shoot(window, to: folder.appending(path: "\(name)-\(String(format: "%02d", step))-\(label).png"))
        }
        try? await Task.sleep(for: .seconds(2))   // the last picture is still on its way to the receiver
        let hold = UserDefaults.standard.double(forKey: "HQDebugKanbanHold")
        if hold > 0 {
            _ = await open(UserDefaults.standard.string(forKey: "HQDebugGridsHoldOn") ?? "Status & Maintenance")
            try? await Task.sleep(for: .seconds(hold))
        }
    }

    /// [mac-tools] `-HQDebugMacShotsKanban YES`: the Mac's Kanban board. The board, a task open beside it, the window
    /// at 1000 wide with and without the task, then (with `-HQDebugKanbanHold <seconds>`) the board left open for a
    /// real pointer.
    @MainActor private static func kanbanTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var step = 0
        func snap(_ label: String) async {
            try? await Task.sleep(for: .seconds(1.5))
            step += 1
            shoot(window, to: folder.appending(path: "\(name)-\(String(format: "%02d", step))-\(label).png"))
        }
        try? await Task.sleep(for: .seconds(4))
        guard let split = tabs.split,
              let place = tabs.placedTabs.first(where: { $0.tabBarItem.title == "Kanban" }) else { print("kanban tour: no Kanban place"); return }
        tabs.pick(place, animated: false)
        split.followSelectedTab()
        try? await Task.sleep(for: .seconds(2))
        await snap("board")
        guard let kanban = find(KanbanViewController.self, in: place) else { print("kanban tour: no board page"); return }
        let first = kanban.store.board?.columns.first { !$0.tasks.isEmpty }?.tasks.first?.id
        if let first { kanban.openTask(first) }
        await snap("task")
        let frame = window.windowScene?.effectiveGeometry.systemFrame ?? CGRect(x: 80, y: 80, width: 1280, height: 800)
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: frame.minX, y: frame.minY, width: 1000, height: 760))) { _ in }
        try? await Task.sleep(for: .seconds(2.5))
        await snap("narrow-task")
        split.closeDetail(animated: false)
        await snap("narrow-board")
        window.windowScene?.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
        try? await Task.sleep(for: .seconds(2))
        let hold = UserDefaults.standard.double(forKey: "HQDebugKanbanHold")
        if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
    }

    /// [mac-audit B] `-HQDebugMacShotsResize`: a chat open, the sidebar folded and opened again (its bar photographed
    /// each time, audit #5), then the window dragged narrower and wider in 20 steps 16 ms apart, as a live resize sends
    /// them (audit #4). `<name>-resize.txt` has the chat's bar appearance per stage and how many full relayouts each
    /// stage cost.
    @MainActor private static func resizeTour(_ window: UIWindow, tabs: MainTabController, name: String, folder: URL) async {
        var log = ""
        tabs.selectedIndex = 0
        try? await Task.sleep(for: .seconds(0.6))
        if let first = tabs.services.bots.first?.id { tabs.botsViewController.open(first) }
        try? await Task.sleep(for: .seconds(2))
        func chat() -> ChatViewController? { find(ChatViewController.self, in: window.rootViewController) }
        func bar() -> String {
            guard let item = chat()?.navigationItem, let a = item.standardAppearance else { return "chat bar: nil" }
            let colour = a.backgroundColor.map { c -> String in
                var w: CGFloat = 0, al: CGFloat = 0
                c.resolvedColor(with: window.traitCollection).getWhite(&w, alpha: &al)
                return String(format: "white %.3f alpha %.2f", w, al)
            } ?? "nil"
            return "chat bar: background \(colour), effect \(a.backgroundEffect == nil ? "none" : "blur")"
        }
        func snap(_ label: String) {
            shoot(window, to: folder.appending(path: "\(name)-\(label).png"))
            log += "[\(label)] \(bar()), relayouts so far \(ChatViewController.debugRelayouts)\n"
            if let c = chat(), let host = c.contentScrollView(for: .top) {
                log += "  host \(type(of: host)) top hidden \(host.topEdgeEffect.isHidden) style \(host.topEdgeEffect.style) size \(host.contentSize) bounds \(host.bounds) inset \(host.adjustedContentInset) offset \(host.contentOffset)\n"
            } else { log += "  no content scroll view\n" }
            if let nav = chat()?.navigationController?.view {
                let edges = topViews(nav, depth: 0).split(separator: "\n").filter { $0.contains("ScrollEdgeEffectView") }
                log += "  top edge views drawn: \(edges.count)\n"
                func every(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(every) }
                for v in every(nav) where "\(type(of: v))".contains("EdgeEffect") {
                    log += "   \(type(of: v)) \(v.frame.integral) hidden \(v.isHidden) alpha \(v.alpha) layer \(v.layer.opacity) subs \(v.subviews.map { "\(type(of: $0)) h\($0.isHidden) a\($0.alpha) \($0.frame.integral)" })\n"
                }
            }
        }
        snap("1-open")
        chat()?.debugRelayout()
        try? await Task.sleep(for: .seconds(1))
        snap("1b-relayout-only")
        for stage in ["2-folded", "3-opened"] {
            UIApplication.shared.sendAction(KeyCommands.toggleSidebar, to: UIApplication.shared.delegate, from: nil, for: nil)
            try? await Task.sleep(for: .seconds(1))
            snap(stage)
        }
        guard let scene = window.windowScene else { return }
        // A window narrow enough that the chat's column follows the pane (it stops at 1280 pt), as at 650–667 pt.
        var start = scene.effectiveGeometry.systemFrame
        start.size.width = 1000
        scene.requestGeometryUpdate(.Mac(systemFrame: start)) { _ in }
        try? await Task.sleep(for: .seconds(1.5))
        snap("4-narrow-start")
        let before = ChatViewController.debugRelayouts
        let began = CACurrentMediaTime()
        var applied = Set<Int>()
        for step in 1...24 {
            let dx = CGFloat(step <= 12 ? step : 24 - step) * -15
            var frame = start
            frame.size.width += dx
            scene.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
            try? await Task.sleep(for: .milliseconds(50))
            applied.insert(Int(window.bounds.width))
        }
        let dragged = CACurrentMediaTime() - began
        log += "[resize] 24 steps in \(String(format: "%.2f", dragged)) s, \(applied.count) window widths seen: \(ChatViewController.debugRelayouts - before) relayouts during the drag\n"
        try? await Task.sleep(for: .seconds(1))
        log += "[resize] \(ChatViewController.debugRelayouts - before) relayouts after it settled\n"
        snap("5-resized")
        let file = folder.appending(path: "\(name)-resize.txt")
        try? log.write(to: file, atomically: true, encoding: .utf8)
        post(file)
        try? await Task.sleep(for: .seconds(2))
    }

    private static func topViews(_ view: UIView, depth: Int) -> String {
        guard depth < 14 else { return "" }
        let frame = view.convert(view.bounds, to: nil)
        guard frame.minY < 120, !view.isHidden, view.alpha > 0.01 else { return "" }
        var out = String(repeating: " ", count: depth) + "\(type(of: view)) \(frame.integral)"
        if let bg = view.backgroundColor { out += " bg \(bg.resolvedColor(with: view.traitCollection))" }
        out += " a \(view.alpha)\n"
        for sub in view.subviews { out += topViews(sub, depth: depth + 1) }
        return out
    }

    static func findView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = findView(type, in: child) { return match } }
        return nil
    }

    static func find<T: UIViewController>(_ type: T.Type, in controller: UIViewController?) -> T? {
        guard let controller else { return nil }
        if let match = controller as? T { return match }
        for child in controller.children { if let found = find(type, in: child) { return found } }
        return nil
    }
}

private extension UIView {
    /// The first vertical list under this view (a tab's rows).
    func firstList() -> UIScrollView? {
        for child in subviews {
            if let list = child as? UICollectionView ?? child as? UITableView, !list.isHidden { return list }
            if let found = child.firstList() { return found }
        }
        return nil
    }

    var firstResponderForDebug: UIResponder? {
        if isFirstResponder { return self }
        for sub in subviews { if let found = sub.firstResponderForDebug { return found } }
        return nil
    }
}
#endif

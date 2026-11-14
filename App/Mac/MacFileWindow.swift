#if targetEnvironment(macCatalyst)
import QuickLook
import UIKit

/// [mac-files] Owner 2026-11-09 ("The way the Mac app opens up files like spreadsheets in a pop up is absolutely
/// awful"): a file Quick Look shows (a spreadsheet, a PDF, an office file, a movie) opens in a window of its own on the
/// Mac, as Preview and Finder's Quick Look do, not in a fixed-size sheet over the chat. The window is nearly as big as
/// the main window and can be resized, zoomed, moved to another screen or set beside the chat. Its bar names the file
/// and has Open in <the Mac's app for it> (Numbers for a spreadsheet) and Share… / Save As…. ⌘W and Escape close it.
/// The same file opened again brings its window forward. Like the Settings window it is a scene of its own
/// (`UIApplicationSupportsMultipleScenes` is on for the Mac only) and isn't reopened at the next launch.
@MainActor enum MacFileWindow {
    static let activityType = "com.hermeshq.file-window"
    private static let userInfoKey = "HQFileWindow"
    private static let pathKey = "path"

    /// The open file windows.
    static var scenes: [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0.delegate is FileSceneDelegate ? $0 as? UIWindowScene : nil }
    }

    /// The file window in front, if one is (⌘W and Escape close it, not the main window's chat).
    static var keyScene: UIWindowScene? { scenes.first { $0.keyWindow?.isKeyWindow == true } }
    static var isKey: Bool { keyScene != nil }

    /// Opens `url` in a window of its own, or brings forward the one already showing it. False when the window can't
    /// be asked for (the caller then shows the file as before).
    /// [Mac UI check 2026-11-13] It no longer fails without a word: a file gone from the cache, or a window the Mac
    /// refuses, says so over the main window.
    @discardableResult static func open(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            AppLog.note("mac", "file window: the file isn't there")
            couldNotOpen(url.lastPathComponent, gone: true)
            return true
        }
        let open = scenes.first { ($0.delegate as? FileSceneDelegate)?.url?.standardizedFileURL.path == path }
        let activity = NSUserActivity(activityType: activityType)
        activity.userInfo = [pathKey: path]
        AppLog.note("mac", open == nil ? "file window: open" : "file window: to the front")
        let name = url.lastPathComponent
        UIApplication.shared.requestSceneSessionActivation(open?.session, userActivity: activity, options: nil) { error in
            AppLog.note("mac", "file window: couldn't open (\(error.localizedDescription))")
            DispatchQueue.main.async { MainActor.assumeIsolated { couldNotOpen(name) } }
        }
        return true
    }

    /// "Couldn't Open File" over the main window, for a file window that didn't come. `gone`: the downloaded copy
    /// was cleared from the cache.
    static func couldNotOpen(_ name: String, gone: Bool = false) {
        guard let top = FailureAlert.topmost(MainTabController.current) else { return }
        FilePreviewPresenter.alert(gone ? "“\(name)” is no longer on this Mac. Click it again to download it."
                                        : "“\(name)” didn’t open in a window of its own. Click it again to try once more.", on: top)
    }

    static func close(_ scene: UIWindowScene) {
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
    }

    /// A file window's session, also after a relaunch (marked in `userInfo` when it connects).
    static func isFile(_ session: UISceneSession) -> Bool {
        session.configuration.name == activityType || session.userInfo?[userInfoKey] as? Bool == true
    }

    /// The scene configuration for a file window being connected (a request from `open`).
    static func configuration(for session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration? {
        let asked = options.userActivities.contains { $0.activityType == activityType }
        guard asked || isFile(session) else { return nil }
        let configuration = UISceneConfiguration(name: activityType, sessionRole: session.role)
        configuration.delegateClass = FileSceneDelegate.self
        return configuration
    }

    /// At launch: file windows left open last time are not reopened (their copies may be gone from the cache).
    static func forgetRestored(_ application: UIApplication) {
        for session in application.openSessions where isFile(session) {
            application.requestSceneSessionDestruction(session, options: nil)
        }
    }

    /// The file named in a connecting window's request.
    fileprivate static func url(in options: UIScene.ConnectionOptions) -> URL? {
        let path = options.userActivities.first { $0.activityType == activityType }?.userInfo?[pathKey] as? String
        return path.map { URL(fileURLWithPath: $0) }
    }
    fileprivate static func url(in activity: NSUserActivity?) -> URL? {
        guard activity?.activityType == activityType, let path = activity?.userInfo?[pathKey] as? String else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: The Mac's app for a file

    /// The app the Mac opens `url` with (Numbers for a spreadsheet), by name; nil when none takes it. AppKit's
    /// `NSWorkspace`, by name, as `MacTrail` reaches it.
    static func defaultApp(for url: URL) -> String? {
        guard let workspace = workspace,
              let app = workspace.perform(NSSelectorFromString("URLForApplicationToOpenURL:"), with: url)?
                .takeUnretainedValue() as? URL else { return nil }
        // "Numbers Creator Studio" reads "Numbers": the short name the Dock and the menu bar show.
        let info = Bundle(url: app)?.infoDictionary
        let name = (info?["CFBundleName"] as? String) ?? (info?["CFBundleDisplayName"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Hands `url` to the Mac's app for it. The app gets a copy, so its edits and the cached copy keep apart.
    static func openInDefaultApp(_ url: URL) -> Bool {
        guard let workspace else { return false }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Opened/\(UUID().uuidString)", directoryHint: .isDirectory)
        let copy = folder.appending(path: url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            AppLog.note("mac", "file window: couldn't copy for another app (\(error.localizedDescription))")
            return false
        }
        // `openURL:` answers a BOOL, which `perform` can't carry: its implementation is called as the C function it is.
        typealias OpenURL = @convention(c) (NSObject, Selector, NSURL) -> ObjCBool
        let selector = NSSelectorFromString("openURL:")
        guard let method = class_getInstanceMethod(type(of: workspace), selector) else { return false }
        let opened = unsafeBitCast(method_getImplementation(method), to: OpenURL.self)(workspace, selector, copy as NSURL).boolValue
        AppLog.note("mac", "file window: handed to the Mac's app (\(opened))")
        return opened
    }

    // MARK: What the window shows

    /// The page for `url`: a spreadsheet this app can read in its own table (a header that stays put, sorting, search;
    /// `SpreadsheetFile`), with the workbook's other sheets in a menu; any other file in Quick Look.
    static func viewer(for url: URL, sheets known: [SpreadsheetFile.Sheet]? = nil, showing index: Int = 0) -> UIViewController {
        guard let sheets = known ?? SpreadsheetFile.read(url), sheets.indices.contains(index) else {
            let viewer = FileWindowController(url: url)
            viewer.navigationItem.largeTitleDisplayMode = .never
            pageBar(viewer)
            return viewer
        }
        let sheet = sheets[index]
        let page = TableSheetController.filePage(SpreadsheetFile.table(sheet, named: url.lastPathComponent))
        page.title = url.lastPathComponent
        page.fileSheet = sheets.count > 1 ? sheet.name : nil
        page.fileRows = sheet.isCut ? sheet.totalRows : nil
        var items: [UIBarButtonItem] = []
        if let app = defaultApp(for: url) {
            let open = UIBarButtonItem(title: "Open in \(app)", primaryAction: UIAction { [weak page] _ in
                guard let page, !openInDefaultApp(url) else { return }
                FilePreviewPresenter.alert("\(app) didn’t open it. Share… or Save As… still can.", on: page)
            })
            open.accessibilityIdentifier = "file.window.open-in"
            items.append(open)
        }
        if sheets.count > 1 {
            let pick = UIBarButtonItem(title: sheet.name, image: nil, primaryAction: nil, menu: UIMenu(title: "Sheets", children: sheets.enumerated().map { at, other in
                UIAction(title: other.name, state: at == index ? .on : .off) { [weak page] _ in
                    guard at != index, let navigation = page?.navigationController else { return }
                    navigation.setViewControllers([viewer(for: url, sheets: sheets, showing: at)], animated: false)
                }
            }))
            pick.accessibilityLabel = "Sheet"
            pick.accessibilityIdentifier = "file.window.sheets"
            items.append(pick)
        }
        page.fileItems = items
        page.fileShare = [
            UIAction(title: "Share File…", image: UIImage(systemName: "doc")) { [weak page] _ in
                guard let page else { return }
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceItem = page.navigationItem.rightBarButtonItems?.first
                page.present(sheet, animated: true)
            },
            FileSaver.action { [weak page] in
                guard let page else { return }
                FileSaver.present(url, from: page)
            },
        ]
        pageBar(page)
        return page
    }

    private static func pageBar(_ page: UIViewController) { MacWindow.pageBar(page) }

    private static var workspace: NSObject? {
        (NSClassFromString("NSWorkspace") as? NSObject.Type)?.value(forKey: "sharedWorkspace") as? NSObject
    }

    #if DEBUG
    /// `-HQDebugFileWindowTap <file name>` (with `-HQDebugOpenBot <id>` and `-HQDebugMacShotsPost`): the chat's row for
    /// that file is clicked as a person would (`chatCellOpenFile`), then `-HQDebugFileWindow <name>` photographs the
    /// window that opens; then the main window as `<name>-main.png`; the same row clicked again (one window, brought
    /// forward), ⌘W, and `<name>-filewin.txt` says what each step left. `-HQDebugFileWindowOpenIn YES` also presses
    /// Open in <app>. The app quits at the end.
    private static var tapAsked = false
    static func tapIfAsked() {
        guard !tapAsked, let name = UserDefaults.standard.string(forKey: "HQDebugFileWindowTap"), !name.isEmpty else { return }
        tapAsked = true
        let shot = UserDefaults.standard.string(forKey: "HQDebugFileWindow") ?? "filewin"
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        Task { @MainActor in
            var log: [String] = []
            func row() -> (ChatViewController, FileRowView)? {
                guard let chat = MainTabController.current?.chatOnShow else { return nil }
                func find(_ view: UIView) -> FileRowView? {
                    if let row = view as? FileRowView, row.item?.attachment.name == name { return row }
                    for sub in view.subviews { if let found = find(sub) { return found } }
                    return nil
                }
                return find(chat.view).map { (chat, $0) }
            }
            for _ in 0..<80 where row() == nil { try? await Task.sleep(for: .seconds(0.5)) }
            guard let (chat, file) = row() else {
                log.append("no row named \(name) (chat \(MainTabController.current?.chatOnShow != nil))")
                finish(log, shot: shot, folder: folder)
                return
            }
            chat.chatCellOpenFile(messageId: "", row: file)
            for _ in 0..<40 where scenes.isEmpty { try? await Task.sleep(for: .seconds(0.25)) }
            try? await Task.sleep(for: .seconds(5))
            let frame = scenes.first?.effectiveGeometry.systemFrame ?? .zero
            let main = MainTabController.current?.view.window?.windowScene?.effectiveGeometry.systemFrame ?? .zero
            log.append("after click: \(scenes.count) file window(s), key \(isKey), frame \(Int(frame.width))×\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY)); main \(Int(main.width))×\(Int(main.height)) at \(Int(main.minX)),\(Int(main.minY))")
            let viewer = (scenes.first?.keyWindow?.rootViewController as? UINavigationController)?.topViewController
            log.append("title \(viewer?.title ?? "-"), bar \(viewer?.navigationItem.rightBarButtonItems?.map { $0.title ?? $0.accessibilityLabel ?? "?" } ?? [])")
            log.append("presented over the chat: \(chat.presentedViewController.map { "\(type(of: $0))" } ?? "nothing")")
            if let main = MainTabController.current?.view.window {
                MacShots.shoot(main, to: folder.appending(path: "\(shot)-main.png"))
            }
            chat.chatCellOpenFile(messageId: "", row: file)   // the same file again: brought forward, not a second window
            try? await Task.sleep(for: .seconds(2))
            log.append("clicked again: \(scenes.count) file window(s), key \(isKey)")
            if UserDefaults.standard.bool(forKey: "HQDebugFileWindowOpenIn"), let url = (scenes.first?.delegate as? FileSceneDelegate)?.url {
                log.append("open in \(defaultApp(for: url) ?? "no app"): \(openInDefaultApp(url))")
                try? await Task.sleep(for: .seconds(4))
                if let scene = scenes.first {   // the other app took the front: bring this window back for ⌘W
                    UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            let command = UIApplication.shared.delegate as? AppDelegate
            log.append("⌘W with the file window key \(isKey)")
            command?.hqCloseChat(nil)
            try? await Task.sleep(for: .seconds(2))
            log.append("after ⌘W: \(scenes.count) file window(s); main window \(MainTabController.current?.view.window != nil)")
            finish(log, shot: shot, folder: folder)
        }
    }

    private static func finish(_ log: [String], shot: String, folder: URL) {
        let url = folder.appending(path: "\(shot)-filewin.txt")
        try? log.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        MacShots.post(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }
    #endif
}

/// A file window: the file's name in the bar, Quick Look under it.
final class FileSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var url: URL?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        session.userInfo = (session.userInfo ?? [:]).merging(["HQFileWindow": true]) { $1 }
        guard let windowScene = scene as? UIWindowScene, let url = MacFileWindow.url(in: connectionOptions),
              FileManager.default.fileExists(atPath: url.path) else {
            // [Mac UI check 2026-11-13] The file went from the cache between the click and the window: say so.
            let name = MacFileWindow.url(in: connectionOptions)?.lastPathComponent
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
            if let name { DispatchQueue.main.async { MainActor.assumeIsolated { MacFileWindow.couldNotOpen(name, gone: true) } } }
            return
        }
        self.url = url
        windowScene.title = url.lastPathComponent   // the Window menu and Mission Control name it
        windowScene.titlebar?.titleVisibility = .hidden
        windowScene.titlebar?.toolbar = nil
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 520, height: 420)
        // Big enough to read a sheet's columns: the main window's size less a little (at least 900 × 680, at most
        // 1,400 × 1,000 screen points), just down and right of it, inside the screen's visible part.
        if let main = MainTabController.current?.view.window?.windowScene?.effectiveGeometry.systemFrame {
            let visible = MacSettingsWindow.visibleScreen(around: main)
            let width = min(max(main.width - 80, 900), 1400), height = min(max(main.height - 60, 680), 1000)
            let frame = WindowFit.inside(CGRect(x: main.minX + 40, y: main.minY + 30, width: width, height: height), visible: visible)
            windowScene.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
        }
        let window = UIWindow(windowScene: windowScene)
        MacToolTips.install(on: window)
        AppearanceSetting.apply(to: window)
        Theme.shared.adopt(window)
        let viewer = MacFileWindow.viewer(for: url)
        let navigation = UINavigationController(rootViewController: viewer)
        navigation.navigationBar.prefersLargeTitles = false
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
        AppLog.note("mac", "file window: shown")
        #if DEBUG
        // `-HQDebugFileWindow <name>`: the window as <name>.png (POSTed with -HQDebugMacShotsPost) once it has drawn.
        if let name = UserDefaults.standard.string(forKey: "HQDebugFileWindow"), !name.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak window] in
                guard let window else { return }
                MacShots.shoot(window, to: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(name).png"))
            }
        }
        #endif
    }

    /// The same file asked for again: this window comes forward (nothing to change). Another file: it shows that.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let url = MacFileWindow.url(in: userActivity), url != self.url,
              let navigation = window?.rootViewController as? UINavigationController else { return }
        if let old = self.url { MediaLoader.shared.purgeBigPreview(old) }
        self.url = url
        (scene as? UIWindowScene)?.title = url.lastPathComponent
        let viewer = MacFileWindow.viewer(for: url)
        navigation.setViewControllers([viewer], animated: false)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        AppLog.note("mac", "file window: closed")
        if let url { MediaLoader.shared.purgeBigPreview(url) }   // a file over 64 MB isn't kept once it closes (spec §8.1)
    }
}

/// Quick Look filling the window, under a bar with the file's name, Open in <app> and Share.
final class FileWindowController: UIViewController, QLPreviewControllerDataSource {
    let url: URL
    private let preview = QLPreviewController()

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        title = url.lastPathComponent
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "file.window"
        preview.dataSource = self
        addChild(preview)
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview.view)
        NSLayoutConstraint.activate([
            preview.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            preview.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            preview.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        preview.didMove(toParent: self)
        preview.reloadData()   // an embedded preview reads its data source once it is in the hierarchy

        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), menu: UIMenu(children: [
            UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share() },
            FileSaver.action { [weak self] in
                guard let self else { return }
                FileSaver.present(self.url, from: self)   // the cached copy stays: only a copy goes where you save it
            },
        ]))
        share.accessibilityLabel = "Share"
        var items = [share]
        if let app = MacFileWindow.defaultApp(for: url) {
            let open = UIBarButtonItem(title: "Open in \(app)", primaryAction: UIAction { [weak self] _ in self?.openInApp(app) })
            open.accessibilityIdentifier = "file.window.open-in"
            items.append(open)
        }
        navigationItem.rightBarButtonItems = items
    }

    private func share() {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceItem = navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }

    private func openInApp(_ app: String) {
        guard !MacFileWindow.openInDefaultApp(url) else { return }
        FilePreviewPresenter.alert("\(app) didn’t open it. Share… or Save As… still can.", on: self)
    }

    // MARK: QLPreviewControllerDataSource

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
}
#endif

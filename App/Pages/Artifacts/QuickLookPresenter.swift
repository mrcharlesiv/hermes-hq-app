// Quick Look for files the native viewers don't draw (docs/spec/1x-pages.md §5.6): PDFs, office files, audio, video,
// archives, HTML (D-P8: rendered out of process, no WKWebView in the app). Share comes with it.
//
// QuickLook is not linked (§6, P-NAV-6: linking a framework the first frame doesn't need moved `didFinishLaunching`
// before, `docs/ARCHITECTURE.md` "Launch"): it is `dlopen`ed on the first preview and driven through the Objective-C
// runtime, as `WebAuthRuntime` does for AuthenticationServices. Public API only.

import UIKit

@MainActor
enum QuickLookRuntime {
    private static let loaded: Bool = {
        dlopen("/System/Library/Frameworks/QuickLook.framework/QuickLook", RTLD_NOW) != nil
    }()
    private static var adopted = false

    /// A `QLPreviewController` showing `source`'s file; nil when Quick Look can't be loaded.
    static func makeController(_ source: QuickLookItemSource) -> UIViewController? {
        guard loaded, let cls = NSClassFromString("QLPreviewController") as? UIViewController.Type else { return nil }
        if !adopted, let proto = objc_getProtocol("QLPreviewControllerDataSource") {
            adopted = true
            class_addProtocol(QuickLookItemSource.self, proto)
        }
        let controller = cls.init(nibName: nil, bundle: nil)
        controller.setValue(source, forKey: "dataSource")
        return controller
    }

    /// `reloadData()` on a `QLPreviewController` (it reads its data source again; an embedded child needs it once it
    /// is in the hierarchy).
    static func reload(_ controller: UIViewController) {
        let selector = NSSelectorFromString("reloadData")
        if controller.responds(to: selector) { controller.perform(selector) }
    }
}

/// One file for Quick Look: answers `QLPreviewControllerDataSource` (adopted at runtime). Keep it alive as long as its
/// controller (the controller's data source is weak).
final class QuickLookItemSource: NSObject {
    let url: URL
    init(url: URL) { self.url = url }

    @objc(numberOfPreviewItemsInPreviewController:)
    func numberOfPreviewItems(in controller: UIViewController) -> Int { 1 }

    /// NSURL is a `QLPreviewItem` (QuickLook's own category on it).
    @objc(previewController:previewItemAtIndex:)
    func previewItem(_ controller: UIViewController, at index: Int) -> NSURL { url as NSURL }
}

enum QuickLookPresenter {
    private static var current: QuickLookItemSource?

    /// Presents a full-screen preview of a downloaded file (Share comes with it).
    @MainActor
    static func present(url: URL, from controller: UIViewController) {
        #if targetEnvironment(macCatalyst)
        if MacFileWindow.open(url) { return }   // [mac-files] a window of its own on the Mac, not a sheet
        #endif
        let source = QuickLookItemSource(url: url)
        guard let preview = QuickLookRuntime.makeController(source) else {
            // No Quick Look: hand the file to Share instead.
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = controller.view
            controller.present(share, animated: true)
            return
        }
        current = source
        preview.view.accessibilityIdentifier = "artifact.quicklook"
        controller.present(preview, animated: true)
    }

    /// Open in Quick Look for a file that has to be fetched or saved first: a `busy` HUD while it loads (none when nil,
    /// for data already in memory that is only saved to disk), the preview only once the file is on disk, and a
    /// "Couldn’t Open in Quick Look" alert (with Try Again) when it isn't.
    @MainActor
    static func open(from controller: UIViewController, busy: String? = "Downloading…",
                     load: @escaping @MainActor () async throws -> URL) {
        let hud = busy.flatMap { MenusHUD.show($0, symbol: nil, in: controller.view, seconds: nil) }
        Task { @MainActor [weak controller] in
            do {
                let url = try await load()
                MenusHUD.hide(hud)
                if let controller { present(url: url, from: controller) }
            } catch {
                MenusHUD.hide(hud)
                guard let controller else { return }
                FailureAlert.present(title: "Couldn’t Open in Quick Look",
                                     reason: (error as? LocalizedError)?.errorDescription ?? "The file didn’t download.",
                                     detail: "\(error)", from: controller) { [weak controller] in
                    if let controller { open(from: controller, busy: busy, load: load) }
                }
            }
        }
    }
}

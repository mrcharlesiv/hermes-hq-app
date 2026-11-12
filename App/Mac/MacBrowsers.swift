#if targetEnvironment(macCatalyst)
import UIKit

/// [links-browser] The Mac's browsers, for Settings › Open Links In: every app that takes web links, and a page handed
/// to one of them by name. AppKit's `NSWorkspace`, by name, as `MacFileWindow` reaches it.
@MainActor enum MacBrowsers {
    private static var workspace: NSObject? {
        (NSClassFromString("NSWorkspace") as? NSObject.Type)?.value(forKey: "sharedWorkspace") as? NSObject
    }

    /// The apps that open both http and https links (a browser takes both; an app that claims one site's links
    /// doesn't), without this app, in the Mac's own order (the default browser first).
    static func installed() -> [LinkBrowser] {
        let secure = apps(taking: "https://example.com")
        let plain = Set(apps(taking: "http://example.com").map(\.path))
        var seen: Set<String> = [Bundle.main.bundleIdentifier ?? ""]
        return secure.compactMap { app in
            guard plain.contains(app.path), let bundle = Bundle(url: app), let id = bundle.bundleIdentifier,
                  seen.insert(id).inserted else { return nil }
            let info = bundle.infoDictionary
            let name = (info?["CFBundleName"] as? String) ?? (info?["CFBundleDisplayName"] as? String)
                ?? app.deletingPathExtension().lastPathComponent
            return name.isEmpty ? nil : LinkBrowser(id: id, name: name)
        }
    }

    private static func apps(taking address: String) -> [URL] {
        guard let workspace, let probe = URL(string: address) else { return [] }
        let selector = NSSelectorFromString("URLsForApplicationsToOpenURL:")
        guard workspace.responds(to: selector) else { return [] }
        return workspace.perform(selector, with: probe)?.takeUnretainedValue() as? [URL] ?? []
    }

    /// Opens `page` in the app `bundleId`. False when that app is gone or the Mac can't be asked; `failed` runs if
    /// the Mac then reports that the app didn't open it. Either way the caller hands the page to the default browser.
    static func open(_ page: URL, in bundleId: String, failed: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard let workspace else { return false }
        let find = NSSelectorFromString("URLForApplicationWithBundleIdentifier:")
        let open = NSSelectorFromString("openURLs:withApplicationAtURL:configuration:completionHandler:")
        guard workspace.responds(to: find),
              let app = workspace.perform(find, with: bundleId)?.takeUnretainedValue() as? URL,
              let configuration = (NSClassFromString("NSWorkspaceOpenConfiguration") as? NSObject.Type)?.init(),
              let method = class_getInstanceMethod(type(of: workspace), open) else { return false }
        // Four arguments, the last a block: more than `perform` carries, so its implementation is called as the C
        // function it is. The Mac calls the block on a queue of its own.
        typealias Open = @convention(c) (NSObject, Selector, NSArray, NSURL, NSObject, AnyObject?) -> Void
        let done: @convention(block) @Sendable (NSObject?, NSError?) -> Void = { _, error in
            guard let error else { return }
            let reason = error.localizedDescription
            Task { @MainActor in
                AppLog.note("mac", "browser: couldn't open the page (\(reason))")
                failed()
            }
        }
        unsafeBitCast(method_getImplementation(method), to: Open.self)(workspace, open, [page as NSURL] as NSArray, app as NSURL,
                                                                      configuration, unsafeBitCast(done, to: AnyObject.self))
        return true
    }
}
#endif

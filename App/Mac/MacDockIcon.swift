// [app-icons] Settings › App Icon on the Mac (owner 2026-11-02: "Do the mac too"). Mac Catalyst has no alternate icons,
// so the chosen icon is AppKit's `applicationIconImage`: the Dock wears it while the app runs, in the Mac's light or
// dark look, and it is set again at every launch from the choice saved here and whenever the Mac changes look.
// Finder, Launchpad and a Dock icon of the app while it's closed keep the bundle's own icon (a sandboxed app can't
// change that). AppKit's classes are reached by name, as in `MacDockMenu`.

#if targetEnvironment(macCatalyst)
import ObjectiveC
import UIKit

@MainActor enum MacDockIcon {
    private static let key = "HQMacAppIcon"

    /// The chosen icon's set name ("AppIcon-Feather-Dark" when pinned); nil for the app's own icon, automatic.
    static var chosen: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Puts the chosen icon on the Dock in the Mac's own look (System Settings › Appearance, not the app's theme), the
    /// app's own icon too: owner 2026-11-02, "Every icon that we have for people to use needs dark mode and light mode
    /// options". With no picture the Dock gets the bundle's icon back.
    static func apply() {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject else { return }
        followMacLook()
        let (choice, look) = AppIconChoice.worn(named: chosen)
        let dark = look.isDark(onDark: macIsDark(app))   // [icon-look] a pinned look keeps it
        var image: AnyObject?
        if let picture = AppIcons.picture(choice, dark: dark, pixels: Int(body)), let png = dockArt(picture).pngData() {
            image = nsImage(png)
        }
        app.setValue(image, forKey: "applicationIconImage")   // nil: the bundle's icon again
        AppLog.note("mac", "dock icon \(choice.id) \(dark ? "dark" : "light")\(image == nil ? " (no picture)" : "")")
    }

    /// NSApp's `effectiveAppearance`: the windows wear the app's theme, the application itself the Mac's look.
    private static func macIsDark(_ app: NSObject) -> Bool {
        let name = (app.value(forKey: "effectiveAppearance") as? NSObject)?.value(forKey: "name") as? String
        return name?.contains("Dark") ?? (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
    }

    private static var following = false

    /// Puts the icon on again when the Mac turns light or dark (NSDistributedNotificationCenter is a NotificationCenter).
    /// The application takes its new look a moment after the notice, hence the short wait.
    private static func followMacLook() {
        guard !following,
              let center = (NSClassFromString("NSDistributedNotificationCenter") as? NSObject.Type)?
                .value(forKey: "defaultCenter") as? NotificationCenter
        else { return }
        following = true
        center.addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                apply()
            }
        }
    }

    /// The icon grid of a Mac app icon: an 824 pt rounded square in a 1024 canvas, with the Dock's soft shadow under it.
    private static let canvas: CGFloat = 1024, body: CGFloat = 824

    private static func dockArt(_ picture: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas), format: format).image { context in
            let rect = CGRect(x: (canvas - body) / 2, y: (canvas - body) / 2 - 10, width: body, height: body)
            let shape = UIBezierPath(roundedRect: rect, cornerRadius: body * 0.2237)
            let cg = context.cgContext
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: UIColor.black.withAlphaComponent(0.3).cgColor)
            UIColor.black.setFill()
            shape.fill()
            cg.restoreGState()
            shape.addClip()
            picture.draw(in: rect)
        }
    }

    /// `[[NSImage alloc] initWithData:]`: init takes the alloc's reference and hands back its own.
    private static func nsImage(_ data: Data) -> AnyObject? {
        guard let imageClass = NSClassFromString("NSImage"),
              let allocated = (imageClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        let initWithData = NSSelectorFromString("initWithData:")
        typealias InitWithData = @convention(c) (AnyObject, Selector, NSData) -> Unmanaged<AnyObject>?
        guard let method = class_getMethodImplementation(imageClass, initWithData) else { return nil }
        return unsafeBitCast(method, to: InitWithData.self)(allocated, initWithData, data as NSData)?.takeRetainedValue()
    }
}
#endif

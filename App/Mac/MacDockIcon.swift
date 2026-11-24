// [app-icons] Settings › App Icon on the Mac (owner 2026-11-02: "Do the mac too"). Mac Catalyst has no alternate icons,
// so the chosen icon is AppKit's `applicationIconImage`: the Dock wears it while the app runs, in the Mac's light or
// dark look, and it is set again at every launch from the choice saved here and whenever the Mac changes look.
// Finder, Launchpad and a Dock icon of the app while it's closed keep the bundle's own icon (a sandboxed app can't
// change that). AppKit's classes are reached by name, as in `MacDockMenu`.

#if targetEnvironment(macCatalyst)
import CoreGraphics
import Darwin
import ObjectiveC
import UIKit

@MainActor enum MacDockIcon {
    private static let key = "HQMacAppIcon"

    /// The chosen icon's set name ("AppIcon-Feather-Dark" when pinned); nil for the app's own icon, automatic.
    static var chosen: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Puts the chosen icon on the Dock in the Mac's own appearance (Default, Dark, Clear, or Tinted).
    /// For the app's own icon in System look (`alternateName == nil`), clearing `applicationIconImage` lets macOS
    /// draw the bundle's `AppIcon.icon` natively everywhere on the Mac (Dock, Cmd-Tab, Finder, Spotlight,
    /// Applications, Notifications). An alternate icon or a pinned look renders its compiled Icon Composer stack from
    /// `Assets.car` through `IconServices` so Light, Dark, Clear, and Tinted all work on the Dock while the app runs,
    /// falling back to the preview raster if unavailable.
    static func apply() {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject else { return }
        followMacLook()
        let (choice, look) = AppIconChoice.worn(named: chosen)
        guard choice.alternateName(look) != nil else {
            app.setValue(nil, forKey: "applicationIconImage")
            AppLog.note("mac", "dock icon \(choice.id) system (bundle)")
            return
        }
        let dark = look.isDark(onDark: macIsDark(app))   // [icon-look] a pinned look keeps it
        var image: AnyObject?
        if let stackImage = iconStackImage(named: choice.id, look: look, darkFallback: dark) {
            image = stackImage
        } else if let picture = AppIcons.picture(choice, dark: dark, pixels: Int(body)), let png = dockArt(picture).pngData() {
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

    /// Puts the icon on again when the Mac turns light/dark or switches Icon & widget style (Default, Dark, Clear,
    /// Tinted). The application takes its new look a moment after the notice, hence the short wait.
    private static func followMacLook() {
        guard !following else { return }
        following = true
        if let center = (NSClassFromString("NSDistributedNotificationCenter") as? NSObject.Type)?
            .value(forKey: "defaultCenter") as? NotificationCenter {
            center.addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    apply()
                }
            }
        }
        if let workspace = (NSClassFromString("NSWorkspace") as? NSObject.Type)?.value(forKey: "sharedWorkspace") as? NSObject,
           let center = workspace.value(forKey: "notificationCenter") as? NotificationCenter {
            center.addObserver(forName: Notification.Name("NSWorkspaceIconAppearanceConfigurationDidChangeNotification"), object: nil, queue: .main) { _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    apply()
                }
            }
        }
    }

    // MARK: Native Icon Composer stack rendering (Light / Dark / Clear / Tinted)

    private static var loadedIconServices = false

    /// Renders `name`'s compiled `IconImageStack` from `Assets.car` with macOS's current icon appearance
    /// (Default, Dark, Clear Light/Dark, or Tinted Light/Dark with the user's tint color). When macOS is in Default
    /// or Dark mode (`appearanceVariant == 0`), respects `look` (System follows Mac appearance; Light/Dark pin it).
    /// Note: ObjC `init...` methods consume the `+1` reference from `alloc`, so `alloc` uses `takeUnretainedValue()`
    /// and the `init...` return value uses `takeRetainedValue()`.
    private static func iconStackImage(named name: String, look: AppIconLook, darkFallback: Bool) -> AnyObject? {
        if !loadedIconServices {
            loadedIconServices = true
            _ = dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW)
            _ = dlopen("/System/Library/PrivateFrameworks/IconFoundation.framework/IconFoundation", RTLD_NOW)
            _ = dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW)
        }
        guard let carURL = Bundle.main.url(forResource: "Assets", withExtension: "car"),
              let cuiCls = NSClassFromString("CUICatalog") as? NSObject.Type,
              let stackCls = NSClassFromString("ISIconStackAssetCatalogResource") as? NSObject.Type,
              let descCls = NSClassFromString("ISImageDescriptor") as? NSObject.Type,
              let cdCls = NSClassFromString("ISCompositingDescriptor") as? NSObject.Type
        else { return nil }

        let allocSel = NSSelectorFromString("alloc")

        // 1. Open Assets.car with CUICatalog.
        let cuiSel = NSSelectorFromString("initWithURL:error:")
        typealias CuiInit = @convention(c) (AnyObject, Selector, NSURL, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
        guard let cuiMethod = class_getInstanceMethod(cuiCls, cuiSel),
              let cuiAlloc = (cuiCls as AnyObject).perform(allocSel)?.takeUnretainedValue()
        else { return nil }
        let cuiFn = unsafeBitCast(method_getImplementation(cuiMethod), to: CuiInit.self)
        var err: NSError?
        guard let catalog = cuiFn(cuiAlloc, cuiSel, carURL as NSURL, &err)?.takeRetainedValue() as? NSObject else { return nil }

        // 2. Load the compiled IconImageStack (platform 2 = Mac Catalyst / UIKit appearances in Assets.car).
        let catalystPlatform: UInt = 2
        let stackInitSel = NSSelectorFromString("initWithCatalog:imageName:platform:")
        typealias StackInit = @convention(c) (AnyObject, Selector, AnyObject, NSString, UInt) -> Unmanaged<AnyObject>?
        guard let stackMethod = class_getInstanceMethod(stackCls, stackInitSel),
              let stackAlloc = (stackCls as AnyObject).perform(allocSel)?.takeUnretainedValue()
        else { return nil }
        let stackInitFn = unsafeBitCast(method_getImplementation(stackMethod), to: StackInit.self)
        guard let resource = stackInitFn(stackAlloc, stackInitSel, catalog, name as NSString, catalystPlatform)?.takeRetainedValue() as? NSObject else {
            return nil
        }

        // 3. Build an ISImageDescriptor matching macOS's active icon appearance (Default / Dark / Clear / Tinted).
        let initDescSel = NSSelectorFromString("initWithSize:scale:")
        typealias InitDescFn = @convention(c) (AnyObject, Selector, CGSize, CGFloat) -> Unmanaged<AnyObject>?
        guard let initDescMethod = class_getInstanceMethod(descCls, initDescSel),
              let descAlloc = (descCls as AnyObject).perform(allocSel)?.takeUnretainedValue()
        else { return nil }
        let initDescFn = unsafeBitCast(method_getImplementation(initDescMethod), to: InitDescFn.self)
        let size = CGSize(width: 512, height: 512)
        let scale: CGFloat = 2
        guard let desc = initDescFn(descAlloc, initDescSel, size, scale)?.takeRetainedValue() as? NSObject else { return nil }

        let applyCfgSel = NSSelectorFromString("applyIconAppearanceConfiguration:")
        if let workspace = (NSClassFromString("NSWorkspace") as? NSObject.Type)?.value(forKey: "sharedWorkspace") as? NSObject,
           workspace.responds(to: NSSelectorFromString("currentIconAppearanceConfiguration")),
           let cfg = workspace.value(forKey: "currentIconAppearanceConfiguration") as? NSObject,
           desc.responds(to: applyCfgSel) {
            desc.perform(applyCfgSel, with: cfg)
        }

        // appearanceVariant == 0 is standard Default/Dark; non-zero is Clear or Tinted (which owns its own look).
        let variant = (desc.value(forKey: "appearanceVariant") as? Int) ?? 0
        if variant == 0 {
            let wantDark: Bool
            switch look {
            case .light: wantDark = false
            case .dark: wantDark = true
            case .automatic:
                let currentApp = (desc.value(forKey: "appearance") as? Int) ?? 0
                wantDark = (currentApp == 1) || darkFallback
            }
            desc.setValue(wantDark ? 1 : 0, forKey: "appearance")
        }

        // 4. Composite the IconImageStack into a macOS Dock icon image (already masked and shadowed).
        // Set appearance and appearanceVariant on the resource itself too so it picks UIAppearanceDark /
        // ISAppearanceTintable layers from Assets.car rather than staying on UIAppearanceLight.
        let resolvedAppearance = (desc.value(forKey: "appearance") as? Int) ?? 0
        let resolvedVariant = (desc.value(forKey: "appearanceVariant") as? Int) ?? 0
        if resource.responds(to: NSSelectorFromString("setAppearance:")) {
            resource.setValue(resolvedAppearance, forKey: "appearance")
        }
        if resource.responds(to: NSSelectorFromString("setAppearanceVariant:")) {
            resource.setValue(resolvedVariant, forKey: "appearanceVariant")
        }
        let initCDSel = NSSelectorFromString("initWithImageDescriptor:")
        typealias CDInitFn = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        guard let cdMethod = class_getInstanceMethod(cdCls, initCDSel),
              let cdAlloc = (cdCls as AnyObject).perform(allocSel)?.takeUnretainedValue(),
              let cd = unsafeBitCast(method_getImplementation(cdMethod), to: CDInitFn.self)(cdAlloc, initCDSel, desc)?.takeRetainedValue() as? NSObject,
              resource.responds(to: NSSelectorFromString("setCompositingDescriptor:"))
        else { return nil }
        if cd.responds(to: NSSelectorFromString("setAssetPlatformHint:")) {
            cd.setValue(catalystPlatform, forKey: "assetPlatformHint")
        }
        resource.setValue(cd, forKey: "compositingDescriptor")

        let imgSel = NSSelectorFromString("imageForSize:scale:")
        typealias ImgFn = @convention(c) (AnyObject, Selector, CGSize, CGFloat) -> Unmanaged<AnyObject>?
        guard let imgMethod = class_getInstanceMethod(type(of: resource), imgSel) else { return nil }
        let imgFn = unsafeBitCast(method_getImplementation(imgMethod), to: ImgFn.self)
        guard let ifImage = imgFn(resource, imgSel, size, scale)?.takeUnretainedValue() as? NSObject,
              ifImage.responds(to: NSSelectorFromString("CGImage")),
              let cgObj = ifImage.perform(NSSelectorFromString("CGImage"))?.takeUnretainedValue(),
              CFGetTypeID(cgObj) == CGImage.typeID
        else { return nil }
        let cgImage = cgObj as! CGImage
        guard let png = UIImage(cgImage: cgImage).pngData() else { return nil }
        return nsImage(png)
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

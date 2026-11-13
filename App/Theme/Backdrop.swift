// [backdrop] Theme › App Background and Chat Background. Owner 2026-10-30: "Custom background support" (chats);
// 2026-11-01: "change my background in the rest of the app, as well as chats … the option for them to be separate … Or
// I can have them be the same", and ten pictures that come with the app. One background behind the app's pages
// (Sessions, Bots, Jobs, More, Settings and what they open) and one behind chats, under the glass bars and the message
// bar. In the iOS look only: the Desktop Look's lists and replies stand on its plain page (as it keeps its own corners
// over Chat Bubbles).
//
// - Off until one is chosen. Spec 06 §12 keeps the owner's 2026-10-06 rejection of the Telegram wallpaper (one forced on
//   every chat): nothing is drawn behind a page unless the person picks it.
// - A background is one of the app's own pictures (`BackdropPreset`, drawn in code in a Light and a Dark version) or a
//   photo of the person's own.
// - Dim lays the page colour over it (0–80 %: 45 standard on pages, whose rows stand straight on it; 30 in chats, whose
//   messages have bubbles), so it goes lighter in Light and darker in Dark and the words on it stay readable. Blur
//   softens it.
// - Chats: Use App Background (on while chats have no picture of their own) draws the app's picture under the chats'
//   own Dim and Blur. Picking a picture for chats, or None, turns it off.
// - Kept on this device only: a photo is one JPEG (2560 px at most on its long side, no metadata) in Application Support
//   (chat-background/, app-background/), plus the `hqn.chatBackground.*` and `hqn.appBackground.*` keys. Never sent.
// - [backdrop-still] Two pages with the same picture keep it still between them as one slides over the other
//   (`BackdropStill`): one wall behind the app, not a copy per page.
// - DEBUG: `-HQDebugChatBackground` / `-HQDebugAppBackground <abs path | picture id>` set them at launch, with `…Dim
//   <percent>` and `…Blur YES`; `-HQDebugChatBackgroundSame YES|NO` (App/Debug/ThemeDebugHooks.swift).

import CoreImage
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable
final class Backdrop {
    nonisolated enum Place: String, Sendable { case app, chats }

    /// What a place draws.
    nonisolated enum Source: Hashable, Sendable {
        case preset(BackdropPreset)
        /// A photo of the person's own: its file name in the place's folder.
        case photo(String)
    }

    static let app = Backdrop(place: .app)
    static let chats = Backdrop(place: .chats, app: app)
    /// Posted on main when a choice changed (a picture, None, Dim, Blur, Use App Background), for either place.
    static let didChange = Notification.Name("hqn.backdrop.didChange")
    /// Posted on main when a picture finished being read or drawn (the views put it up).
    static let pictureReady = Notification.Name("hqn.backdrop.pictureReady")
    /// The long side a chosen photo is kept at: a Pro Max screen is 2868 px tall.
    #if targetEnvironment(macCatalyst)
    /// [mac] Mac polish #86: a 5K display is 5120 px wide; at 2560 a full-screen window stretched the photo about twice.
    nonisolated static let maxPixel = 5120
    #else
    nonisolated static let maxPixel = 2560
    #endif
    /// A blurred picture needs no detail: it is drawn from this small a copy.
    nonisolated static let blurPixel = 720
    nonisolated static let dimRange = 0...80

    nonisolated struct Keys: Sendable {
        let photo: String, preset: String, dim: String, blur: String, sameAsApp: String, cards: String
        init(_ prefix: String) {
            photo = prefix + ".photo"
            preset = prefix + ".preset"
            dim = prefix + ".dim"
            blur = prefix + ".blur"
            sameAsApp = prefix + ".sameAsApp"
            cards = prefix + ".cards"
        }
        var all: [String] { [photo, preset, dim, blur, sameAsApp, cards] }
    }

    nonisolated static func keys(_ place: Place) -> Keys { Keys(place == .app ? "hqn.appBackground" : "hqn.chatBackground") }
    /// Pages' rows stand straight on the picture; chats' messages have bubbles.
    nonisolated static func defaultDim(_ place: Place) -> Int { place == .app ? 45 : 30 }

    nonisolated static func defaultFolder(_ place: Place) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: place == .app ? "app-background" : "chat-background", directoryHint: .isDirectory)
    }

    let place: Place
    /// This place's own choice; nil is None.
    private(set) var source: Source?
    private(set) var dim: Int
    private(set) var blur: Bool
    /// Chats only: they draw the app's picture instead of their own.
    private(set) var sameAsApp: Bool
    /// [backdrop-cards] App only, off until turned on (owner 2026-11-12: "a toggle so people can cut it in only if they
    /// want it"): the lists' sections and the grouped pages' titles and notes stand on soft cards over the picture.
    private(set) var cards: Bool
    /// Bumped on every change (the Theme page's previews read it).
    private(set) var revision = 0

    @ObservationIgnored let keys: Keys
    @ObservationIgnored let folder: URL
    @ObservationIgnored private let defaults: UserDefaults
    /// Chats: the app's background, which they may draw instead of their own.
    @ObservationIgnored private let app: Backdrop?

    init(place: Place, app: Backdrop? = nil, defaults: UserDefaults = .standard, folder: URL? = nil) {
        self.place = place
        self.app = place == .chats ? app : nil
        self.defaults = defaults
        self.folder = folder ?? Self.defaultFolder(place)
        keys = Self.keys(place)
        let photo = defaults.string(forKey: keys.photo).flatMap { Self.isFileName($0) ? $0 : nil }
        let preset = defaults.string(forKey: keys.preset).flatMap(BackdropPreset.init(stored:))
        let source = photo.map(Source.photo) ?? preset.map(Source.preset)
        self.source = source
        dim = Self.clampedDim(defaults.object(forKey: keys.dim), place: place)
        blur = (defaults.object(forKey: keys.blur) as? NSNumber)?.boolValue ?? false
        cards = place == .app && ((defaults.object(forKey: keys.cards) as? NSNumber)?.boolValue ?? false)
        let stored = (defaults.object(forKey: keys.sameAsApp) as? NSNumber)?.boolValue
        sameAsApp = place == .chats && (stored ?? (source == nil))
    }

    /// Outside `dimRange` or not a number is the place's standard.
    nonisolated static func clampedDim(_ value: Any?, place: Place = .chats) -> Int {
        guard let number = value as? NSNumber, !(value is String) else { return defaultDim(place) }
        let percent = number.doubleValue.rounded()
        guard percent.isFinite, percent >= Double(dimRange.lowerBound), percent <= Double(dimRange.upperBound) else { return defaultDim(place) }
        return Int(percent)
    }

    /// A stored name is one of ours (`<uuid>.jpg`), never a path that climbs out of the folder.
    nonisolated static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name.hasSuffix(".jpg")
    }

    // MARK: What is drawn

    /// Chats that use the app's background, and the app has one.
    var followsApp: Bool { sameAsApp && app?.source != nil }

    /// The picture the page shows as chosen (its tick, its row's value): nothing while chats use the app's background
    /// and the app has none, as nothing is drawn then (the chats' own picture is kept for when they choose it again).
    var chosen: Source? { sameAsApp ? nil : source }

    /// The picture this place draws and the folder a photo of it is in: the app's, for chats that use it.
    var drawn: (source: Source, folder: URL)? {
        if sameAsApp, let app { return app.source.map { ($0, app.folder) } }
        return source.map { ($0, folder) }
    }

    /// Whether this place draws a picture: one is chosen and the look is the iOS one.
    var shows: Bool { drawn != nil && !Theme.isDesktop }

    /// The picture as drawn for `traits` (Light or Dark, the theme's tint), or nil while it is made the first time:
    /// that happens off the main thread, and `pictureReady` is posted when it's done.
    func image(for traits: UITraitCollection) -> UIImage? {
        guard let picture = picture(for: traits) else { return nil }
        return BackdropImages.shared.image(picture)
    }

    func picture(for traits: UITraitCollection) -> BackdropPicture? {
        guard let drawn else { return nil }
        return BackdropPicture.make(drawn.source, folder: drawn.folder, blur: blur, traits: traits)
    }

    /// Starts making the picture now (launch): the first page or chat shown then has it on its first frame.
    func prepare(_ traits: UITraitCollection) { _ = image(for: traits) }

    // MARK: Changes

    /// One of the app's own pictures becomes the background. A photo kept before is deleted.
    func setPreset(_ preset: BackdropPreset) {
        source = .preset(preset)
        defaults.set(preset.rawValue, forKey: keys.preset)
        defaults.removeObject(forKey: keys.photo)
        removeFiles(keeping: nil)
        chooseOwn()
        AppLog.trace("backdrop", "\(place.rawValue) background: \(preset.rawValue)")
        changed()
    }

    /// A picked photo (read at `maxPixel` by `PhotoLoad`) becomes the background, written off the main thread.
    /// Throws when it couldn't be kept.
    func setPhoto(_ photo: PickedPhoto) async throws {
        let folder = folder
        let name = try await Task.detached(priority: .userInitiated) { try Self.write(photo.image, into: folder) }.value
        adopt(name, decoded: photo.image)
    }

    /// The JPEG the background is kept as, in `folder`, every older one removed. Returns its file name.
    nonisolated static func write(_ image: CGImage, into folder: URL) throws -> String {
        guard let data = jpeg(image, quality: PhotoNormalizer.quality) else { throw CocoaError(.fileWriteUnknown) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".jpg"
        // Readable after the first unlock: a chat opened by a notification on a locked phone still has it.
        try data.write(to: folder.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        removeFiles(in: folder, keeping: name)
        return name
    }

    nonisolated private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    nonisolated private static func removeFiles(in folder: URL, keeping: String?) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent != keeping {
            try? fm.removeItem(at: url)
        }
    }

    private func removeFiles(keeping: String?) {
        let folder = folder
        DispatchQueue.global(qos: .utility).async { Self.removeFiles(in: folder, keeping: keeping) }
    }

    /// The stored photo is `name` from now on. `decoded`: the picture as just picked, so the views needn't read it back.
    func adopt(_ name: String, decoded: CGImage? = nil) {
        source = .photo(name)
        defaults.set(name, forKey: keys.photo)
        defaults.removeObject(forKey: keys.preset)
        if let decoded, !blur {
            BackdropImages.shared.store(BackdropPicture(kind: .photo(folder.appending(path: name)), blur: false), UIImage(cgImage: decoded))
        }
        chooseOwn()
        AppLog.trace("backdrop", "\(place.rawValue) background: a photo (\(decoded.map { "\($0.width)×\($0.height)" } ?? "from disk"))")
        changed()
    }

    /// None: nothing is drawn here (chats also stop using the app's). Dim and Blur stay for the next picture.
    func clear() {
        source = nil
        defaults.removeObject(forKey: keys.photo)
        defaults.removeObject(forKey: keys.preset)
        removeFiles(keeping: nil)
        chooseOwn()
        AppLog.trace("backdrop", "\(place.rawValue) background: none")
        changed()
    }

    /// Everything back to the start: no picture, the standard Dim, no Blur, chats on Use App Background.
    func reset() {
        source = nil
        keys.all.forEach(defaults.removeObject(forKey:))
        dim = Self.defaultDim(place)
        blur = false
        cards = false
        sameAsApp = place == .chats
        removeFiles(keeping: nil)
        changed()
    }

    /// Chats: draw the app's picture (on) or their own (off). Stored either way: the person chose it.
    func setSameAsApp(_ on: Bool) {
        guard place == .chats, on != sameAsApp else { return }
        sameAsApp = on
        defaults.set(on, forKey: keys.sameAsApp)
        AppLog.trace("backdrop", "chats use the app background: \(on)")
        changed()
    }

    /// A choice made for chats themselves ends Use App Background.
    private func chooseOwn() {
        guard place == .chats else { return }
        sameAsApp = false
        defaults.set(false, forKey: keys.sameAsApp)
    }

    /// Stored only when it isn't the place's standard.
    func setDim(_ percent: Int) {
        let percent = min(max(percent, Self.dimRange.lowerBound), Self.dimRange.upperBound)
        guard percent != dim else { return }
        dim = percent
        if percent == Self.defaultDim(place) { defaults.removeObject(forKey: keys.dim) } else { defaults.set(percent, forKey: keys.dim) }
        changed()
    }

    /// [backdrop-cards] Soft Cards (the app's background only).
    func setCards(_ on: Bool) {
        guard place == .app, on != cards else { return }
        cards = on
        if on { defaults.set(true, forKey: keys.cards) } else { defaults.removeObject(forKey: keys.cards) }
        changed()
    }

    func setBlur(_ on: Bool) {
        guard on != blur else { return }
        blur = on
        if on { defaults.set(true, forKey: keys.blur) } else { defaults.removeObject(forKey: keys.blur) }
        changed()
    }

    private func changed() {
        revision &+= 1
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

// MARK: - Pictures

/// One picture as drawn: a photo's file, or one of the app's own pictures in Light or Dark (the theme's tint for Theme
/// Glow) at the screen's size; blurred or not. The key of `BackdropImages`.
nonisolated struct BackdropPicture: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case photo(URL)
        case preset(BackdropPreset, dark: Bool, accent: BackdropPreset.Ink, width: Int, height: Int)
    }

    var kind: Kind
    var blur: Bool

    /// The accent every picture but Theme Glow is keyed with: they don't use it.
    private static let noAccent = BackdropPreset.Ink(r: 0, g: 0, b: 0)

    @MainActor static func make(_ source: Backdrop.Source, folder: URL, blur: Bool, traits: UITraitCollection) -> BackdropPicture {
        switch source {
        case .photo(let name):
            return BackdropPicture(kind: .photo(folder.appending(path: name)), blur: blur)
        case .preset(let preset):
            let canvas = canvasSize
            return BackdropPicture(kind: .preset(preset, dark: traits.userInterfaceStyle == .dark, accent: accent(preset, traits),
                                                 width: canvas.width, height: canvas.height), blur: blur)
        }
    }

    /// The theme's tint for Theme Glow; nothing for the others, so a theme change never draws them again.
    @MainActor static func accent(_ preset: BackdropPreset, _ traits: UITraitCollection) -> BackdropPreset.Ink {
        preset == .glow ? ink(HQPalette.tint.resolvedColor(with: traits)) : noAccent
    }

    static func ink(_ color: UIColor) -> BackdropPreset.Ink {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        // Rounded to 1/255: a tint read back through a colour space never keys a second copy of the same picture.
        func step(_ value: CGFloat) -> Double { (Double(min(max(value, 0), 1)) * 255).rounded() / 255 }
        return BackdropPreset.Ink(r: step(r), g: step(g), b: step(b))
    }

    /// The app's own pictures are drawn at the screen's size in pixels (its long side at most 2868 px): portrait on a
    /// phone, the display's shape on a Mac. Every page and chat shows the same copy, filling itself from its centre.
    @MainActor static var canvasSize: (width: Int, height: Int) {
        if let canvas { return canvas }
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        var size = screen?.nativeBounds.size ?? .zero
        if size.width <= 0 || size.height <= 0 { size = CGSize(width: 1179, height: 2556) }
        let scale = min(1, 2868 / max(size.width, size.height))
        let made = (width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()))
        canvas = made
        return made
    }
    @MainActor private static var canvas: (width: Int, height: Int)?

    /// Reads or draws the picture (off the main thread).
    func make() -> UIImage? {
        switch kind {
        case .photo(let url):
            guard let pixels = PhotoNormalizer.thumbnail(url, maxPixel: blur ? Backdrop.blurPixel : Backdrop.maxPixel) else { return nil }
            return finish(pixels)
        case .preset(let preset, let dark, let accent, let width, let height):
            // Blurred, the picture needs no detail: drawn at the blur's size.
            let scale = blur ? min(1, Double(Backdrop.blurPixel) / Double(max(width, height))) : 1
            let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
            if preset.keptOnDisk, let kept = BackdropPictureCache.read(preset, dark: dark, width: w, height: h) { return finish(kept) }
            guard let pixels = preset.render(width: w, height: h, dark: dark, accent: accent) else { return nil }
            if preset.keptOnDisk { BackdropPictureCache.write(pixels, preset, dark: dark, width: w, height: h) }
            return finish(pixels)
        }
    }

    private func finish(_ pixels: CGImage) -> UIImage? {
        guard blur else { return UIImage(cgImage: pixels).preparingForDisplay() ?? UIImage(cgImage: pixels) }
        return Self.blurred(pixels).map { UIImage(cgImage: $0) }
    }

    /// A soft blur, the edges clamped first so the border doesn't fade to clear.
    static func blurred(_ pixels: CGImage) -> CGImage? {
        let input = CIImage(cgImage: pixels)
        let radius = Double(max(pixels.width, pixels.height)) / 40
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: input.extent)
    }
}

/// The slow pictures once drawn, in Caches: a Photographic one costs seconds on a phone, the first time only. PNG, because
/// a lossy format would band their dark skies. Bump `version` when a painter changes, or old pictures stay.
nonisolated enum BackdropPictureCache {
    static let version = 1
    private static let limit = 200 * 1024 * 1024

    static func folder(in caches: URL = URL.cachesDirectory) -> URL {
        caches.appending(path: "Wallpapers/v\(version)", directoryHint: .isDirectory)
    }

    private static func file(_ preset: BackdropPreset, dark: Bool, width: Int, height: Int, in folder: URL) -> URL {
        folder.appending(path: "\(preset.rawValue)-\(dark ? "dark" : "light")-\(width)x\(height).png")
    }

    static func read(_ preset: BackdropPreset, dark: Bool, width: Int, height: Int, in folder: URL = folder()) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file(preset, dark: dark, width: width, height: height, in: folder) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Best effort: a picture that can't be kept is drawn again next time.
    static func write(_ image: CGImage, _ preset: BackdropPreset, dark: Bool, width: Int, height: Int, in folder: URL = folder()) {
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return }
        // A half-written file must never be read as the picture: written beside it, then moved.
        let url = file(preset, dark: dark, width: width, height: height, in: folder)
        let draft = folder.appending(path: UUID().uuidString)
        guard let out = CGImageDestinationCreateWithURL(draft as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(out, image, nil)
        guard CGImageDestinationFinalize(out) else {
            try? manager.removeItem(at: draft)
            return
        }
        try? manager.removeItem(at: url)
        do { try manager.moveItem(at: draft, to: url) } catch { try? manager.removeItem(at: draft) }
        tidy(folder)
    }

    /// Old versions' pictures go, and the oldest of this version's past `limit`.
    private static func tidy(_ folder: URL) {
        let manager = FileManager.default
        let parent = folder.deletingLastPathComponent()
        for other in (try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] where other.lastPathComponent != folder.lastPathComponent {
            try? manager.removeItem(at: other)
        }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        let sized = files.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.date < $1.date }
        var total = sized.reduce(0) { $0 + $1.size }
        for entry in sized where total > limit {
            try? manager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

/// The pictures made so far: the last three used (a decoded picture is up to 30 MB). Shared by both places, so chats on
/// the app's background draw the same copy. Let go when iOS asks for memory, and made again when next shown.
@MainActor final class BackdropImages {
    static let shared = BackdropImages()
    private static let limit = 3
    /// Most recently used last.
    private var made: [(picture: BackdropPicture, image: UIImage)] = []
    private var making: [BackdropPicture: Task<Void, Never>] = [:]
    private var memoryWatch: NSObjectProtocol?

    private init() {
        memoryWatch = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.made.removeAll() }
        }
    }

    /// The picture if it is made; otherwise nil, and it is made off the main thread (`Backdrop.pictureReady` follows).
    func image(_ picture: BackdropPicture) -> UIImage? {
        if let index = made.firstIndex(where: { $0.picture == picture }) {
            let hit = made.remove(at: index)
            made.append(hit)
            return hit.image
        }
        guard making[picture] == nil else { return nil }
        let start = ContinuousClock.now
        making[picture] = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { picture.make() }.value
            guard let self else { return }
            self.making[picture] = nil
            guard let image else {
                AppLog.trace("backdrop", "background unreadable: \(picture.kind)")
                return
            }
            AppLog.trace("backdrop", "background made in \(AppLog.ms(since: start)) ms")
            self.store(picture, image)
            NotificationCenter.default.post(name: Backdrop.pictureReady, object: nil)
        }
        return nil
    }

    func store(_ picture: BackdropPicture, _ image: UIImage) {
        made.removeAll { $0.picture == picture }
        made.append((picture, image))
        if made.count > Self.limit { made.removeFirst(made.count - Self.limit) }
    }
}

// MARK: - The view

/// What a page or a chat draws behind itself: the picture filling the view from its centre, the page colour over it at
/// Dim. Hidden with no picture, in the Desktop Look, and until the first picture is made; a picture on show stays up
/// while the next is made (the other mode's copy can take seconds the first time) and fades into it. Never touched or read out.
final class BackdropView: UIView {
    let place: Backdrop.Place
    /// Called when the picture comes or goes (a page turns its list clear while it shows).
    var onShowChange: ((Bool) -> Void)?
    /// A page's background is the app's, not a sheet's: hidden in a presented page.
    var hidesInSheets = false
    /// A copy over part of a page (behind its bar): the picture is laid out over this view's bounds, so it lines up with
    /// the page's own and the seam can't be seen.
    weak var alignedTo: UIView? { didSet { setNeedsLayout() } }
    private var inSheet = false
    /// The picture on show is an old one, up until the one wanted is made.
    private var holding = false
    private let backdrop: Backdrop
    private let imageView = UIImageView()
    private let veil = UIView()
    private var watches: [NSObjectProtocol] = []

    init(place: Backdrop.Place, frame: CGRect = .zero, backdrop: Backdrop? = nil) {
        self.place = place
        self.backdrop = backdrop ?? (place == .app ? .app : .chats)
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        clipsToBounds = true
        isHidden = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        veil.backgroundColor = HQPalette.page
        for child in [imageView, veil] {
            child.frame = bounds
            addSubview(child)
        }
        for name in [Backdrop.didChange, Backdrop.pictureReady, Theme.didChange] {
            watches.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        // Light and Dark have their own copy of the app's pictures, and Theme Glow follows the tint.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: BackdropView, _) in view.refresh() }
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit { watches.forEach(NotificationCenter.default.removeObserver) }

    /// Whether a picture is drawn (the page then leaves its own colour off under it).
    var showsPicture: Bool { !isHidden }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = alignedTo.map { $0.convert($0.bounds, to: self) } ?? bounds
        // Bounds and centre, not the frame: the picture may be held still by a transform (`BackdropStill`).
        imageView.bounds = CGRect(origin: .zero, size: frame.size)
        imageView.center = CGPoint(x: frame.midX, y: frame.midY)
        veil.frame = frame.union(bounds)
    }

    /// The picture this view has up for its traits (nil with none on show): two pages with the same one keep it still
    /// between them.
    var shownPicture: BackdropPicture? { isHidden ? nil : backdrop.picture(for: traitCollection) }

    /// How far the picture is drawn from its place on the page (`BackdropStill`).
    var pictureShift: CGPoint = .zero {
        didSet { imageView.transform = CGAffineTransform(translationX: pictureShift.x, y: pictureShift.y) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        if hidesInSheets {
            var controller = sequence(first: self as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController
            while let parent = controller?.parent { controller = parent }
            inSheet = controller?.presentingViewController != nil
        }
        refresh()
        BackdropStill.follow(self)
    }

    func refresh() {
        let was = !isHidden
        let wanted = backdrop.shows && !inSheet ? backdrop.image(for: traitCollection) : nil
        if backdrop.shows, !inSheet, let image = wanted ?? imageView.image {
            isHidden = false
            if imageView.image !== image {
                if holding, window != nil {
                    UIView.transition(with: imageView, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {   // motion-ok: a cross-fade, nothing moves
                        self.imageView.image = image
                    }
                } else {
                    imageView.image = image
                }
            }
            holding = wanted == nil
            veil.alpha = CGFloat(backdrop.dim) / 100
        } else {
            isHidden = true
            imageView.image = nil
            holding = false
        }
        if was != !isHidden { onShowChange?(!isHidden) }
    }
}

/// [backdrop-still] One wall behind the app (owner 2026-11-11: the same picture on the app and on chats, "as you're
/// swiping through … it doesn't look like we designed that feature to work for the same background for both"). Every
/// page draws its own copy of the picture, so a push or a swipe back slid one copy over the other. When the page
/// leaving and the page arriving show the same picture (the same one, blurred or not, at the same size), each copy is
/// moved against its page's slide, so the picture stays where it is on screen and only the pages' contents move over
/// it. Different pictures still slide with their pages, as cards do.
///
/// The system moves the pages with a spring of its own that an animation beside the transition doesn't share (that one
/// is linear: the picture drifted up to 58 pt mid-slide), and a swipe back follows the finger. So each frame the
/// picture is put back by as far as its page is from its place just then.
@MainActor final class BackdropStill: NSObject {
    private static var running: BackdropStill?
    private let pages: [(page: UIView, pictures: [BackdropView])]
    private weak var container: UIView?
    /// Where a page stands when no slide runs, in the container.
    private let rest: CGPoint
    private var link: CADisplayLink?
    private weak var coordinator: AnyObject?

    /// Called by a page's picture as it comes on screen: a slide between two pages starts with the arriving one.
    static func follow(_ view: BackdropView) {
        #if DEBUG
        // `-HQDebugBackdropSlides YES`: as before, each page's picture slides with it (the before picture).
        if UserDefaults.standard.bool(forKey: "HQDebugBackdropSlides") { return }
        #endif
        let owner = sequence(first: view as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController
        guard let coordinator = owner?.transitionCoordinator, coordinator.isAnimated, running?.coordinator !== coordinator,
              let from = coordinator.viewController(forKey: .from)?.viewIfLoaded,
              let to = coordinator.viewController(forKey: .to)?.viewIfLoaded, from !== to,
              from.bounds.size == to.bounds.size, from.bounds.width > 0 else { return }
        let leaving = pictures(in: from), arriving = pictures(in: to)
        guard let picture = arriving.first?.shownPicture, !leaving.isEmpty,
              (leaving + arriving).allSatisfy({ $0.shownPicture == picture }) else { return }
        running?.end()
        let container = coordinator.containerView
        let still = BackdropStill(pages: [(from, leaving), (to, arriving)], container: container,
                                  rest: from.convert(CGPoint.zero, to: container), coordinator: coordinator)
        running = still
        coordinator.animate(alongsideTransition: { _ in still.begin() }, completion: { _ in still.end() })
    }

    private init(pages: [(page: UIView, pictures: [BackdropView])], container: UIView, rest: CGPoint, coordinator: AnyObject) {
        self.pages = pages
        self.container = container
        self.rest = rest
        self.coordinator = coordinator
    }

    /// The pages stand where the slide starts.
    private func begin() {
        guard link == nil, Self.running === self else { return }
        hold(presented: false)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() { hold(presented: true) }

    private func hold(presented: Bool) {
        guard let container else { return end() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (page, pictures) in pages where page.window != nil {
            let at: CGPoint = if presented, let shown = page.layer.presentation(), let within = container.layer.presentation() {
                shown.convert(CGPoint.zero, to: within)
            } else {
                page.convert(CGPoint.zero, to: container)
            }
            let shift = CGPoint(x: rest.x - at.x, y: rest.y - at.y)
            for picture in pictures where picture.pictureShift != shift { picture.pictureShift = shift }
        }
        CATransaction.commit()
        #if DEBUG
        BackdropStillProbe.note(pages.flatMap(\.pictures))
        #endif
    }

    private func end() {
        link?.invalidate()
        link = nil
        pages.flatMap(\.pictures).forEach { $0.pictureShift = .zero }
        if Self.running === self { Self.running = nil }
        #if DEBUG
        BackdropStillProbe.done()
        #endif
    }

    private static func pictures(in view: UIView) -> [BackdropView] {
        var found: [BackdropView] = []
        func look(_ view: UIView) {
            if let picture = view as? BackdropView { if picture.showsPicture { found.append(picture) }; return }
            view.subviews.forEach(look)
        }
        look(view)
        return found
    }
}

#if DEBUG
/// `-HQDebugBackdropStill YES`: logs how far the pictures were from still on screen through a slide (0 is still), as
/// the layers stood when each frame was set.
@MainActor enum BackdropStillProbe {
    private static var worst: CGFloat = 0, frames = 0

    static func note(_ views: [BackdropView]) {
        guard UserDefaults.standard.bool(forKey: "HQDebugBackdropStill") else { return }
        frames += 1
        for view in views {
            guard let image = view.subviews.first, view.window != nil else { continue }
            var x = image.layer.frame.minX
            var layer = image.layer.superlayer
            while let up = layer { x += (up.presentation() ?? up).frame.minX - up.bounds.minX; layer = up.superlayer }
            worst = max(worst, abs(x))
        }
    }

    static func done() {
        guard UserDefaults.standard.bool(forKey: "HQDebugBackdropStill") else { return }
        NSLog("[backdrop-still] slide done: %d frames, furthest from still %.1f pt", frames, worst)
        worst = 0
        frames = 0
    }
}
#endif

nonisolated(unsafe) private var pageBackdropKey: UInt8 = 0

/// [backdrop] Theme › App Background behind a list page: the picture under its views, which turn clear while it shows
/// (their own colour comes back with no picture, in the Desktop Look and in a sheet). A tab's list keeps its title over
/// a solid band of the page colour (`ListBarAppearance.pinTitle`): with a picture the bar is clear and the band is a copy
/// of the picture lined up with the page's, so rows go under it with no seam to see.
@MainActor final class PageBackdrop {
    let view: BackdropView
    private var band: BackdropView?
    private weak var controller: UIViewController?
    private var cleared: [(view: WeakView, colour: UIColor?)] = []

    /// The page keeps it: the picture is drawn after the page loads, and only this turns the page's views clear then.
    @discardableResult
    static func install(in controller: UIViewController, clearing views: [UIView]) -> PageBackdrop {
        let backdrop = PageBackdrop(controller, clearing: views)
        objc_setAssociatedObject(controller, &pageBackdropKey, backdrop, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return backdrop
    }

    private init(_ controller: UIViewController, clearing views: [UIView]) {
        self.controller = controller
        view = BackdropView(place: .app, frame: controller.view.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.hidesInSheets = true
        controller.view.insertSubview(view, at: 0)
        if ListBarAppearance.hasBand(controller.navigationItem), let top = views.last {
            let band = BackdropView(place: .app)
            band.hidesInSheets = true
            band.alignedTo = controller.view
            band.translatesAutoresizingMaskIntoConstraints = false
            controller.view.insertSubview(band, aboveSubview: top)
            NSLayoutConstraint.activate([
                band.topAnchor.constraint(equalTo: controller.view.topAnchor),
                band.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
                band.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
                band.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
            ])
            self.band = band
        }
        for view in [controller.view!] + views { clear(view) }
        view.onShowChange = { [weak self] _ in self?.apply() }
        // [backdrop-cards] Soft Cards turned on or off while the page is up.
        switchWatch = NotificationCenter.default.addObserver(forName: Backdrop.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    /// Also clear while the picture shows (a band added after the list: Sessions' bot strip).
    func clear(_ view: UIView) {
        cleared.append((WeakView(value: view), view.backgroundColor))
        apply()
    }

    /// [backdrop-cards] Whether the page's picture shows just now (its lists then stand their sections on cards).
    static func showsPicture(on controller: UIViewController?) -> Bool {
        guard let controller, let backdrop = objc_getAssociatedObject(controller, &pageBackdropKey) as? PageBackdrop else { return false }
        return backdrop.view.showsPicture
    }

    private var carded: Bool?
    private var switchWatch: NSObjectProtocol?
    /// [soft-cards] Called after the page's lists went on cards or came off them (a page whose rows draw differently
    /// on a card redraws them).
    /// Set after the page's lists were already on cards (the picture was up at once): called then too.
    var onCardsChange: (() -> Void)? { didSet { if carded == true { onCardsChange?() } } }

    private func apply() {
        let shows = view.showsPicture
        for page in cleared { page.view.value?.backgroundColor = shows ? .clear : page.colour }
        // [backdrop-cards] The lists lay their sections out again, on cards or off them.
        let cards = shows && Backdrop.app.cards
        // Flipped, or on from the start: a page that lays itself out for cards hears of both.
        let flipped = carded != cards && (carded != nil || cards)
        carded = cards
        for page in cleared {
            guard let list = page.view.value as? UIScrollView else { continue }
            BackdropCards.mark(list, carded: cards && !Theme.isDesktop)
            BackdropPlates.refresh(list)
            if flipped { (list as? UICollectionView)?.collectionViewLayout.invalidateLayout() }
        }
        if flipped { onCardsChange?() }
        // The page's own view says (the band's may hear of the picture a moment later: it draws the same).
        if let controller, band != nil {
            ListBarAppearance.setPictureBand(shows, on: controller.navigationItem)
        }
    }

    private struct WeakView { weak var value: UIView? }

    /// A table page (a `UITableViewController`, whose view is the table): the picture is the table's still background.
    @discardableResult
    static func install(behind table: UITableView) -> BackdropView {
        let backdrop = BackdropView(place: .app, frame: table.bounds)
        backdrop.hidesInSheets = true
        table.backgroundView = backdrop
        let colour = table.backgroundColor
        backdrop.onShowChange = { [weak table] shows in
            table?.backgroundColor = shows ? .clear : colour
            BackdropPlates.refresh(table)   // [backdrop-cards]
        }
        backdrop.onShowChange?(backdrop.showsPicture)
        BackdropPlates.attach(to: table) { [weak backdrop] in backdrop?.showsPicture == true }   // [backdrop-cards]
        return backdrop
    }
}

/// [backdrop] The same behind a SwiftUI grouped page (`hqGroupedPage`): the app's picture, or the grouped page colour
/// where none is drawn (a sheet, or while the picture is made).
struct PageBackdropLayer: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let holder = Holder()
        holder.backgroundColor = HQPalette.groupedPage
        let backdrop = BackdropView(place: .app, frame: holder.bounds)
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.hidesInSheets = true
        backdrop.onShowChange = { [weak holder] shows in
            holder?.backgroundColor = shows ? .clear : HQPalette.groupedPage
            BackdropPlates.refresh(holder?.list)   // [backdrop-cards]
        }
        holder.addSubview(backdrop)
        holder.backdrop = backdrop
        backdrop.onShowChange?(backdrop.showsPicture)
        return holder
    }

    func updateUIView(_ uiView: UIView, context: Context) { (uiView as? Holder)?.find() }

    /// [backdrop-cards] Finds the list it stands behind (as `GlassListProbe` does) and puts its sections on plates.
    final class Holder: UIView {
        weak var backdrop: BackdropView?
        weak var list: UICollectionView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            find()
        }

        func find() {
            guard window != nil, list == nil else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil, self.list == nil else { return }
                    var ancestor = self.superview
                    for _ in 0..<6 {
                        guard let current = ancestor else { return }
                        if let list = Self.firstList(in: current, depth: 6) {
                            self.list = list
                            BackdropPlates.attach(to: list) { [weak self] in self?.backdrop?.showsPicture == true }
                            return
                        }
                        ancestor = current.superview
                    }
                }
            }
        }

        private static func firstList(in view: UIView, depth: Int) -> UICollectionView? {
            if let list = view as? UICollectionView { return list }
            guard depth > 0 else { return nil }
            for child in view.subviews { if let found = firstList(in: child, depth: depth - 1) { return found } }
            return nil
        }
    }
}

// MARK: - Choosing a photo

/// Your Own Photo on the Theme page: the system photo picker or the Files browser, read at `Backdrop.maxPixel`
/// (upright, no metadata), then stored for the place. No Move and Scale: the picture fills the page from its centre.
@MainActor final class BackdropPicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    enum Source { case library, file }

    /// The one pick under way (held so the system picker's delegate lives as long as the picker does).
    private static var current: BackdropPicker?
    private let place: Backdrop.Place
    /// Called on main: true while a picked file is read and stored (the Theme page shows a spinner).
    private let busy: (Bool) -> Void
    private var load: PhotoLoad?

    private init(place: Backdrop.Place, busy: @escaping (Bool) -> Void) {
        self.place = place
        self.busy = busy
    }

    static func pick(_ source: Source, for place: Backdrop.Place, busy: @escaping (Bool) -> Void) {
        guard let host = activeHost else { return }
        current?.load?.cancel()
        PickedFile.removeLeftovers()
        let picker = BackdropPicker(place: place, busy: busy)
        current = picker
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "HQDebugChatBackgroundPick"), !path.isEmpty {
            picker.read(PhotoLoad(file: URL(fileURLWithPath: path), owned: false, maxPixel: Backdrop.maxPixel))
            return
        }
        #endif
        switch source {
        case .library:
            var configuration = PHPickerConfiguration()
            configuration.selectionLimit = 1
            configuration.filter = .images
            configuration.preferredAssetRepresentationMode = .current
            let controller = PHPickerViewController(configuration: configuration)
            controller.delegate = picker
            host.present(controller, animated: true)
        case .file:
            let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
            controller.allowsMultipleSelection = false
            controller.delegate = picker
            host.present(controller, animated: true)
        }
    }

    /// The key window's top page (a SwiftUI page has no controller of its own to present from).
    private static var activeHost: UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return FailureAlert.topmost((windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController)
    }

    private func read(_ load: PhotoLoad) {
        self.load = load
        busy(true)
        let place = place
        load.onFinish = { [self] result in
            switch result {
            case .success(let photo):
                Task { @MainActor in
                    do {
                        try await (place == .app ? Backdrop.app : Backdrop.chats).setPhoto(photo)
                        Haptics.play(.success)   // your own photo is the background (a preset tile ticks as it's picked)
                        HQAnnounce.say(place == .app ? "App background set." : "Chat background set.")
                    } catch {
                        AppLog.trace("backdrop", "\(place.rawValue) background not stored: \(error)")
                        BotPhotoPicker.explain(.unreadable, from: Self.activeHost)
                    }
                    self.end()
                }
            case .failure(let error):
                BotPhotoPicker.explain(error, from: Self.activeHost)
                end()
            }
        }
    }

    private func end() {
        load = nil
        busy(false)
        if Self.current === self { Self.current = nil }
    }

    // MARK: Photo Library

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let load = results.first.map { PhotoLoad(provider: $0.itemProvider, maxPixel: Backdrop.maxPixel) }
        picker.dismiss(animated: true)
        if let load { read(load) } else { end() }
    }

    // MARK: Choose File

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return end() }
        read(PhotoLoad(file: PickedFile.move(url) ?? url, owned: true, maxPixel: Backdrop.maxPixel))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { end() }
}

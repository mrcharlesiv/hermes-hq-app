// [photoheads] The one place every face asks "does this bot wear a photo?" (docs/spec/3x-photoheads.md §4.5, §4.6).
// `BotPhotoStore` knows the verdicts and keeps the small picture files; this keeps the decoded pictures in memory and
// tells the faces on screen when one arrives, changes or goes. A face that gets nil draws the bot's head.
//
// Faces reach it through the two entry points that take a profile: `HeadView.configure(raw:profile:working:)` and
// `HeadImage(raw:profile:size:working:)`. Anything new that draws a bot's picture must use one of those, or
// `faceImage` for a picture handed to the system (a notification, the reply peek, the Share sheet's roster).

import Observation
import UIKit

@MainActor @Observable
final class BotFaces {
    static let shared = BotFaces()
    /// The app-icon corner: a share of the picture's width, never a circle (owner, 2026-10-02).
    static let cornerShare: CGFloat = 0.2237
    /// Photos decoded before the first frame after a store is set (the top of the Bots list), within `firstPaintBudget`.
    static let firstPaintCount = 12
    static let firstPaintBudget: Duration = .milliseconds(30)

    /// Bumped when any face may have changed. A SwiftUI face reads it so it is drawn again.
    private(set) var version = 0

    private final class Decoded {
        let image: UIImage
        let fingerprint: String
        init(image: UIImage, fingerprint: String) { self.image = image; self.fingerprint = fingerprint }
    }

    @ObservationIgnored private var store: BotPhotoStore?
    @ObservationIgnored private let cache: NSCache<NSString, Decoded> = {
        let cache = NSCache<NSString, Decoded>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    /// Profile → the fingerprint being decoded.
    @ObservationIgnored private var decoding: [String: String] = [:]
    @ObservationIgnored private let views = NSHashTable<HeadView>.weakObjects()
    /// Bumped by `use`: a decode that started under another account's store is dropped.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var memoryToken: NSObjectProtocol?

    /// The app uses `shared`; a test makes its own so it never sees another test's store.
    init() {
        memoryToken = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropDecoded() }
        }
    }

    isolated deinit {
        if let memoryToken { NotificationCenter.default.removeObserver(memoryToken) }
    }

    // MARK: - The store

    /// The signed-in account's pictures (sign-in, gateway switch), or nil (sign-out). Nothing of the account before is
    /// ever drawn after this, even for a bot of the same name.
    func use(_ next: BotPhotoStore?) {
        if let store, store !== next { store.onChange = nil; store.onSupportChange = nil }
        store = next
        epoch &+= 1
        cache.removeAllObjects()
        decoding = [:]
        if let next {
            next.onChange = { [weak self, weak next] profile in
                guard let self, let next, self.store === next else { return }
                self.changed(profile)
            }
            // The gateway turned out to store pictures (or not to): a page that asked before the first roster answer
            // (Edit Bot's Picture section) is drawn again.
            next.onSupportChange = { [weak self, weak next] in
                guard let self, let next, self.store === next else { return }
                self.version &+= 1
            }
            decodeFirstPaint(next)
        }
        version &+= 1
        for view in views.allObjects { view.syncPhoto() }
    }

    /// Bot Info opened for this bot: look at the gateway's picture again unless it was checked in the last minute.
    func refresh(_ profile: String) { store?.refresh(profile) }

    /// The Bots list was pulled: the same for every bot that has a picture.
    func refreshAll() { store?.refreshAll() }

    /// Whether the signed-in gateway can store bot pictures at all (an older one has no asset store: DECISION D6).
    /// Reads `version`, so whoever observes this is told when the first roster answer settles it.
    var supportsPictures: Bool {
        _ = version
        return store?.supportsAssets ?? false
    }

    /// Whether `store` is the one faces draw from (tests).
    func isUsing(_ candidate: BotPhotoStore) -> Bool { store === candidate }

    /// The top of the list, decoded on the spot so the first frame shows photos rather than heads that then change.
    private func decodeFirstPaint(_ store: BotPhotoStore) {
        let began = ContinuousClock.now
        for profile in store.order.prefix(Self.firstPaintCount) {
            guard let fingerprint = store.fingerprint(for: profile), let url = store.photoURL(for: profile) else { continue }
            guard let data = try? Data(contentsOf: url), let image = Self.decode(data) else { continue }
            remember(image, profile: profile, fingerprint: fingerprint)
            if ContinuousClock.now - began >= Self.firstPaintBudget { break }
        }
    }

    // MARK: - Faces

    /// The bot's photo, ready to draw; nil when the head wins or the picture is not decoded yet (the face is told when
    /// it is).
    func photo(for profile: String) -> UIImage? {
        guard let store, let fingerprint = store.fingerprint(for: profile) else { return nil }
        let held = cache.object(forKey: profile as NSString)
        if let held, held.fingerprint == fingerprint { return held.image }
        decode(profile, fingerprint: fingerprint, from: store)
        // A photo replaced by another keeps the old picture for the moment the new one takes to decode.
        return held?.image
    }

    /// Whether a face for this bot draws a photo (decoded or about to be).
    func showsPhoto(_ profile: String) -> Bool { store?.hasPhoto(profile) ?? false }

    /// [ship, m9: share + photoheads] The photo a bot wears, for the Share sheet's roster: its kept file and the
    /// picture's fingerprint (the same one `faceKey` names). nil for a bot that wears its head.
    func sharePhoto(_ profile: String) -> SharePhoto? {
        guard let store, let fingerprint = store.fingerprint(for: profile), let url = store.photoURL(for: profile) else { return nil }
        return SharePhoto(fingerprint: fingerprint, url: url)
    }

    /// A `HeadView` that shows a profile's face: told when that face changes. Held weakly.
    func register(_ view: HeadView) { views.add(view) }

    private func changed(_ profile: String) {
        if store?.hasPhoto(profile) != true {
            cache.removeObject(forKey: profile as NSString)
            decoding[profile] = nil
        } else if let store, let fingerprint = store.fingerprint(for: profile), cache.object(forKey: profile as NSString)?.fingerprint != fingerprint {
            // Decode first; the faces are told when the picture is ready (no head in between two photos, and nobody
            // is told about a photo that cannot be drawn yet). A file that turns out damaged comes back here through
            // `discardUnreadable` with no photo, and is told then.
            decode(profile, fingerprint: fingerprint, from: store)
            return
        }
        notify(profile)
    }

    private func notify(_ profile: String) {
        version &+= 1
        for view in views.allObjects where view.faceProfile == profile { view.syncPhoto() }
        noteFacesChanged()
    }

    /// Told a moment after any bot's face changed (several changes at once tell it once): whoever hands faces to the
    /// system (the pictures kept for pushed alerts) draws them again.
    @ObservationIgnored var onFacesChanged: (() -> Void)?
    @ObservationIgnored private var changeNotice: Task<Void, Never>?

    private func noteFacesChanged() {
        guard onFacesChanged != nil, changeNotice == nil else { return }
        changeNotice = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.changeNotice = nil
            self.onFacesChanged?()
        }
    }

    private func decode(_ profile: String, fingerprint: String, from store: BotPhotoStore) {
        guard decoding[profile] != fingerprint else { return }
        decoding[profile] = fingerprint
        let epoch = self.epoch
        Task { [weak self, weak store] in
            let data = await store?.photoData(for: profile)
            let image = await Self.decodeOffMain(data)
            guard let self, let store, self.epoch == epoch, self.store === store else { return }
            guard self.decoding[profile] == fingerprint else { return }       // a newer picture is being decoded
            self.decoding[profile] = nil
            guard store.fingerprint(for: profile) == fingerprint else { return }
            guard let image else {
                // The kept file is damaged: forget it (the head shows) and let the store fetch the picture again.
                store.discardUnreadable(profile)
                return
            }
            self.remember(image, profile: profile, fingerprint: fingerprint)
            self.notify(profile)
        }
    }

    private func remember(_ image: UIImage, profile: String, fingerprint: String) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        cache.setObject(Decoded(image: image, fingerprint: fingerprint), forKey: profile as NSString, cost: max(1, cost))
    }

    /// A memory warning: the decoded pictures go. Faces on screen keep what they hold; the next ask decodes again.
    func dropDecoded() {
        cache.removeAllObjects()
        decoding = [:]
    }

    private nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data), image.size.width >= 1, image.size.height >= 1 else { return nil }
        return image.preparingForDisplay() ?? image
    }

    private nonisolated static func decodeOffMain(_ data: Data?) async -> UIImage? {
        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) { decode(data) }.value
    }

    // MARK: - Faces handed out as pictures (§4.6)

    enum FaceShape { case appIcon, square }

    /// What names a bot's face: changes when its photo or its head does, and is the same on every launch (whoever
    /// keeps faces between launches, like the Share sheet's roster, compares it with the one it stored).
    func faceKey(profile: String, raw: JSONValue?) -> String {
        if let fingerprint = store?.fingerprint(for: profile) { return "photo:" + fingerprint }
        return Self.headKey(raw)
    }

    /// "head:" and a digest of the head record written with its keys in order; "head:none:shape" for a bot with no
    /// record (it wears its Shapes default; the ":shape" retires the dot-matrix faces saved under "head:none").
    nonisolated static func headKey(_ raw: JSONValue?) -> String {
        guard let raw, raw != .null else { return "head:none:shape" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(raw) else { return "head:none:shape" }
        return "head:" + BotPicture.fingerprint(data)
    }

    /// A bot's face as a picture, and whether that picture is its photo.
    struct Face {
        let image: UIImage
        let isPhoto: Bool
    }

    /// The bot's face as a picture `side` points wide: its photo (aspect-filled; `appIcon` rounds the corners, `square`
    /// leaves them for whoever draws it), or its head as the head draws itself. A bot whose photo cannot be drawn yet
    /// gets its head; `readyFace` says so instead.
    func faceImage(profile: String, raw: JSONValue?, side: CGFloat, scale: CGFloat, dark: Bool, shape: FaceShape) -> UIImage {
        readyFace(profile: profile, raw: raw, side: side, scale: scale, dark: dark, shape: shape)?.image
            ?? headImage(profile: profile, raw: raw, side: side, scale: scale, dark: dark)
    }

    /// The same, saying which it is. nil when the bot wears a photo that is not in memory and not on this phone's disk
    /// yet (it was just fetched and its file is still being written): the caller draws the head as a head, or waits
    /// for `onFacesChanged`, rather than keeping a head under the photo's name.
    func readyFace(profile: String, raw: JSONValue?, side: CGFloat, scale: CGFloat, dark: Bool, shape: FaceShape) -> Face? {
        guard showsPhoto(profile) else {
            return Face(image: headImage(profile: profile, raw: raw, side: side, scale: scale, dark: dark), isPhoto: false)
        }
        guard let photo = readyPhoto(profile) else { return nil }
        return Face(image: Self.tile(photo, side: side, scale: scale, shape: shape), isPhoto: true)
    }

    func headImage(profile: String, raw: JSONValue?, side: CGFloat, scale: CGFloat, dark: Bool) -> UIImage {
        HeadImageCache.shared.image(for: Head.resolve(raw, profile: profile), side: side, scale: scale, dark: dark)
    }

    /// The bot's photo if it is decoded and in memory. Nothing is read or decoded.
    func cachedPhoto(_ profile: String) -> UIImage? {
        guard let fingerprint = store?.fingerprint(for: profile),
              let held = cache.object(forKey: profile as NSString), held.fingerprint == fingerprint else { return nil }
        return held.image
    }

    /// The photo now, decoding it on the spot when it is not in memory. Only for one face that cannot wait (the reply
    /// peek); anything that walks the whole roster uses `cachedPhoto` and `photoCopy`.
    private func readyPhoto(_ profile: String) -> UIImage? {
        guard let store, let fingerprint = store.fingerprint(for: profile) else { return nil }
        if let held = cache.object(forKey: profile as NSString), held.fingerprint == fingerprint { return held.image }
        guard let url = store.photoURL(for: profile), let data = try? Data(contentsOf: url), let image = Self.decode(data) else { return nil }
        remember(image, profile: profile, fingerprint: fingerprint)
        return image
    }

    /// The bot's photo for a copy kept outside the app's own faces (the picture saved for pushed alerts): read after
    /// any write of its file still on its way and decoded off the main actor, and not kept in memory here (a roster of
    /// 200 photos would push the faces on screen out). nil for a head, a file that cannot be read, or a store that
    /// changed meanwhile. `fingerprint` is the picture's, as in `faceKey`.
    func photoCopy(for profile: String) async -> (image: UIImage, fingerprint: String)? {
        guard let store, let fingerprint = store.fingerprint(for: profile) else { return nil }
        if let held = cache.object(forKey: profile as NSString), held.fingerprint == fingerprint { return (held.image, fingerprint) }
        let epoch = self.epoch
        let data = await store.photoData(for: profile)
        let image = await Self.decodeOffMain(data)
        guard self.epoch == epoch, self.store === store, store.fingerprint(for: profile) == fingerprint else { return nil }
        guard let image else {
            // The kept file is missing or damaged: forget it (the head shows) and let the store fetch the picture again.
            store.discardUnreadable(profile)
            return nil
        }
        return (image, fingerprint)
    }

    static func tile(_ photo: UIImage, side: CGFloat, scale: CGFloat, shape: FaceShape) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1, scale)
        format.opaque = false
        format.preferredRange = .standard
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: box.size, format: format).image { _ in
            if shape == .appIcon {
                UIBezierPath(roundedRect: box, cornerRadius: side * cornerShare).addClip()
            }
            photo.draw(in: fillRect(photo.size, in: box))
        }
    }

    /// Aspect fill, centred (`object-fit: cover`).
    static func fillRect(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let k = max(box.width / size.width, box.height / size.height)
        let width = size.width * k, height = size.height * k
        return CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }
}

// [backdrop] Theme › App Background and Chat Background: the stored choice (a picture of the app's, a photo's file,
// None, Dim, Blur, Use App Background), what reads as garbage, and the app's own pictures.

import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite struct BackdropTests {
    private func fresh() -> (UserDefaults, URL) {
        let name = "hqn.backdrop.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return (suite, FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory))
    }

    /// The two places on one store, as the app has them.
    private func pair() -> (app: Backdrop, chats: Backdrop, suite: UserDefaults, folder: URL) {
        let (suite, folder) = fresh()
        let app = Backdrop(place: .app, defaults: suite, folder: folder.appending(path: "app"))
        return (app, Backdrop(place: .chats, app: app, defaults: suite, folder: folder.appending(path: "chats")), suite, folder)
    }

    private func picture(width: Int = 40, height: Int = 30) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func files(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test func offUntilAPictureIsChosen() {
        let (app, chats, _, _) = pair()
        for backdrop in [app, chats] {
            #expect(backdrop.source == nil && backdrop.drawn == nil && !backdrop.shows)
            #expect(!backdrop.blur)
            #expect(backdrop.image(for: UITraitCollection(userInterfaceStyle: .light)) == nil)
        }
        #expect(app.dim == 45 && chats.dim == 30, "pages' rows stand on the picture; chats' messages have bubbles")
        #expect(chats.sameAsApp && !chats.followsApp, "chats use the app's background once there is one")
        #expect(!app.sameAsApp)
    }

    @Test func chatsUseTheAppsPictureUntilTheyChooseTheirOwn() {
        let (app, chats, suite, _) = pair()
        app.setPreset(.ocean)
        #expect(chats.followsApp && chats.drawn?.source == .preset(.ocean))
        chats.setPreset(.sunset)
        #expect(!chats.sameAsApp && chats.drawn?.source == .preset(.sunset), "a picture of their own ends Use App Background")
        chats.setSameAsApp(true)
        #expect(chats.drawn?.source == .preset(.ocean) && chats.source == .preset(.sunset), "their own is kept for later")
        chats.clear()
        #expect(chats.drawn == nil && !chats.sameAsApp, "None is plain chats, not the app's picture")
        let reloaded = Backdrop(place: .chats, app: app, defaults: suite)
        #expect(!reloaded.sameAsApp && reloaded.drawn == nil)
    }

    @Test func chatsOnTheAppsBackgroundWhenTheAppHasNoneShowNone() {
        let (app, chats, _, _) = pair()
        chats.setPreset(.sunset)
        app.setPreset(.ocean)
        chats.setSameAsApp(true)
        #expect(BackdropWords.value(of: chats) == "Same as App")
        app.clear()
        #expect(chats.drawn == nil && chats.source == .preset(.sunset), "nothing drawn; their own kept")
        #expect(chats.chosen == nil && BackdropWords.value(of: chats) == "None", "the row and the tick say what is drawn")
        chats.setPreset(.sunset)
        #expect(chats.chosen == .preset(.sunset) && BackdropWords.value(of: chats) == BackdropPreset.sunset.label)
    }

    @Test func aChatPictureFromBeforeStaysTheChatsOwn() {
        // Builds 526+ stored only `hqn.chatBackground.photo`: those chats keep their picture when an app one is set.
        let (suite, folder) = fresh()
        suite.set("A.jpg", forKey: "hqn.chatBackground.photo")
        let app = Backdrop(place: .app, defaults: suite, folder: folder.appending(path: "app"))
        let chats = Backdrop(place: .chats, app: app, defaults: suite, folder: folder)
        app.setPreset(.aurora)
        #expect(!chats.sameAsApp && chats.drawn?.source == .photo("A.jpg"))
    }

    @Test func aPresetIsStoredAndSurvivesAReload() {
        let (app, _, suite, folder) = pair()
        app.setPreset(.contours)
        #expect(suite.string(forKey: "hqn.appBackground.preset") == "contours")
        #expect(Backdrop(place: .app, defaults: suite, folder: folder).source == .preset(.contours))
        suite.set("nonsense", forKey: "hqn.appBackground.preset")
        #expect(Backdrop(place: .app, defaults: suite, folder: folder).source == nil, "an unknown picture reads as None")
    }

    @Test func aPhotoIsKeptAsOneJPEGAndSurvivesAReload() async throws {
        let (suite, folder) = fresh()
        let backdrop = Backdrop(place: .chats, defaults: suite, folder: folder)
        try await backdrop.setPhoto(PickedPhoto(image: picture()))
        guard case .photo(let first) = backdrop.source else { Issue.record("no photo"); return }
        #expect(files(folder) == [first] && first.hasSuffix(".jpg"))
        #expect(backdrop.image(for: UITraitCollection(userInterfaceStyle: .light)) != nil, "the picked photo is drawn at once, not read back")
        try await backdrop.setPhoto(PickedPhoto(image: picture(width: 30, height: 40)))
        guard case .photo(let second) = backdrop.source else { Issue.record("no photo"); return }
        #expect(second != first && files(folder) == [second], "the older photo goes")
        #expect(Backdrop(place: .chats, defaults: suite, folder: folder).source == .photo(second))
        backdrop.setPreset(.paper)
        try await Task.sleep(for: .milliseconds(300))
        #expect(files(folder).isEmpty && suite.string(forKey: "hqn.chatBackground.photo") == nil, "a picture of the app's deletes the photo")
    }

    /// [backdrop-cards] Soft Cards: off until turned on, kept on the app's background only, gone with Reset.
    @Test func softCardsAreOffUntilTurnedOn() {
        let (suite, folder) = fresh()
        let app = Backdrop(place: .app, defaults: suite, folder: folder)
        #expect(!app.cards, "off for everyone who never turned it on")
        app.setCards(true)
        #expect(Backdrop(place: .app, defaults: suite, folder: folder).cards)
        let chats = Backdrop(place: .chats, defaults: suite, folder: folder)
        chats.setCards(true)
        #expect(!chats.cards && suite.object(forKey: "hqn.chatBackground.cards") == nil, "chats have no Soft Cards")
        app.setCards(false)
        #expect(suite.object(forKey: "hqn.appBackground.cards") == nil, "off is not stored")
        app.setCards(true)
        app.reset()
        #expect(!app.cards && suite.object(forKey: "hqn.appBackground.cards") == nil, "Reset turns it off")
    }

    @Test func dimAndBlurAreStoredOnlyWhenNotStandard() {
        let (suite, folder) = fresh()
        let backdrop = Backdrop(place: .app, defaults: suite, folder: folder)
        backdrop.setDim(55)
        backdrop.setBlur(true)
        #expect(Backdrop(place: .app, defaults: suite, folder: folder).dim == 55)
        #expect(Backdrop(place: .app, defaults: suite, folder: folder).blur)
        backdrop.setDim(45)
        backdrop.setBlur(false)
        #expect(suite.object(forKey: "hqn.appBackground.dim") == nil && suite.object(forKey: "hqn.appBackground.blur") == nil)
        backdrop.setDim(200)
        #expect(backdrop.dim == 80, "set clamps to the slider's range")
        backdrop.setDim(-5)
        #expect(backdrop.dim == 0, "no dim is a choice")
    }

    @Test func garbageReadsAsStandard() {
        for bad: Any in ["40", Double.nan, 81, -1] {
            #expect(Backdrop.clampedDim(bad) == 30, "\(bad)")
            #expect(Backdrop.clampedDim(bad, place: .app) == 45, "\(bad)")
        }
        #expect(Backdrop.clampedDim(nil) == 30)
        #expect(Backdrop.clampedDim(44.6) == 45)
        for bad in ["", "../secret.jpg", ".hidden.jpg", "photo.png", "a/b.jpg"] {
            #expect(!Backdrop.isFileName(bad), "\(bad)")
        }
        let (suite, folder) = fresh()
        suite.set("../../Library/Preferences/x.jpg", forKey: "hqn.chatBackground.photo")
        #expect(Backdrop(place: .chats, defaults: suite, folder: folder).source == nil, "a stored path never leaves the folder")
    }

    @Test func noneKeepsDimAndBlurAndResetForgetsEverything() async throws {
        let (app, chats, suite, _) = pair()
        try await chats.setPhoto(PickedPhoto(image: picture()))
        chats.setDim(10)
        chats.setBlur(true)
        chats.clear()
        #expect(chats.source == nil && chats.dim == 10 && chats.blur, "None keeps the sliders for the next picture")
        app.setPreset(.dunes)
        chats.reset()
        app.reset()
        #expect(chats.source == nil && chats.dim == 30 && !chats.blur && chats.sameAsApp)
        #expect(app.source == nil && app.dim == 45)
        #expect((Backdrop.keys(.chats).all + Backdrop.keys(.app).all).allSatisfy { suite.object(forKey: $0) == nil })
    }

    @Test func blurKeepsThePicturesSize() throws {
        let blurred = try #require(BackdropPicture.blurred(picture(width: 64, height: 48)))
        #expect(blurred.width == 64 && blurred.height == 48)
    }

    @Test func everyPictureOfTheAppsDrawsInBothLooks() {
        #expect(BackdropPreset.allCases.count == 42, "the first ten, then 8 each of Photographic, Illustrated, Painted and Doodles")
        #expect(Set(BackdropPreset.allCases.map(\.label)).count == 42)
        #expect(BackdropPreset.Group.allCases.map(\.presets.count) == [10, 8, 8, 8, 8])
        let accent = BackdropPreset.Ink(r: 0.04, g: 0.52, b: 1)
        for preset in BackdropPreset.allCases {
            for dark in [false, true] {
                let image = preset.render(width: 90, height: 160, dark: dark, accent: accent)
                #expect(image?.width == 90 && image?.height == 160, "\(preset) dark: \(dark)")
            }
        }
    }

    @Test func replacedPicturesMoveToTheNearestNewOne() {
        #expect(BackdropPreset(stored: "doodleMint") == .doodleForest)
        #expect(BackdropPreset(stored: "doodlePeach") == .doodleRose)
        #expect(BackdropPreset(stored: "cityLights") == .cityDusk)
        #expect(BackdropPreset(stored: "terrazzo") == .rollingHills)
        #expect(BackdropPreset(stored: "alpine") == .photoAlpenglow, "build 723's Mountains")
        #expect(BackdropPreset(stored: "desert") == .photoDunes, "build 723's Scenes")
        #expect(BackdropPreset(stored: "cityDusk") == .cityDusk, "kept under its own name")
        #expect(BackdropPreset(stored: "nonsense") == nil)
        for gone in ["alpine", "alpenglow", "mistyRidges", "pinePeaks", "mountainLake", "canyon", "lonePeak", "starlitPeaks", "oceanSunset", "desert", "seaOfClouds", "mistyForest"] {
            #expect(BackdropPreset(stored: gone) != nil, "\(gone) must not read as None")
        }
    }

    @Test func aSlowPictureIsKeptAndComesBackTheSame() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hqn.wallpapers.\(UUID().uuidString)/v1", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        #expect(BackdropPictureCache.read(.photoLake, dark: true, width: 40, height: 30, in: folder) == nil)
        let image = picture()
        BackdropPictureCache.write(image, .photoLake, dark: true, width: 40, height: 30, in: folder)
        let kept = try #require(BackdropPictureCache.read(.photoLake, dark: true, width: 40, height: 30, in: folder))
        #expect(kept.width == 40 && kept.height == 30)
        #expect(BackdropPictureCache.read(.photoLake, dark: false, width: 40, height: 30, in: folder) == nil, "Light is its own picture")
        #expect(files(folder).count == 1, "no draft left behind")
    }

    @Test func onlyTheSlowStylesAreKept() {
        #expect(BackdropPreset.photoLake.keptOnDisk && BackdropPreset.posterMesa.keptOnDisk && BackdropPreset.paintHarbor.keptOnDisk)
        #expect(!BackdropPreset.doodleRose.keptOnDisk && !BackdropPreset.aurora.keptOnDisk)
    }

    @Test func blurredPicturesAreDrawnSmall() throws {
        let picture = BackdropPicture(kind: .preset(.aurora, dark: false, accent: .init(r: 0, g: 0, b: 0), width: 1179, height: 2556), blur: true)
        let image = try #require(picture.make())
        #expect(max(image.size.width, image.size.height) * image.scale <= CGFloat(Backdrop.blurPixel) + 1)
    }

    @Test func onlyThemeGlowFollowsTheTint() {
        let traits = UITraitCollection(userInterfaceStyle: .light)
        #expect(BackdropPicture.accent(.aurora, traits) == BackdropPreset.Ink(r: 0, g: 0, b: 0))
        #expect(BackdropPicture.accent(.glow, traits) != BackdropPreset.Ink(r: 0, g: 0, b: 0))
    }

    @Test func theViewIsHiddenWithNoPicture() {
        let view = BackdropView(place: .chats, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        if Backdrop.chats.drawn == nil { #expect(!view.showsPicture) }
        #expect(!view.isUserInteractionEnabled && view.accessibilityElementsHidden)
    }

    /// The first switch to the other mode has to draw that copy: the picture on show stays up until it's made, so the
    /// page never drops to its plain colour. Taking the picture away still takes it away at once.
    @Test func aPictureStaysUpWhileItsOtherModeIsMade() async throws {
        let (app, _, _, _) = pair()
        try #require(!Theme.isDesktop)
        app.setPreset(.aurora)
        let view = BackdropView(place: .app, frame: CGRect(x: 0, y: 0, width: 100, height: 100), backdrop: app)
        view.overrideUserInterfaceStyle = .light
        view.refresh()
        for _ in 0..<400 where !view.showsPicture { try await Task.sleep(for: .milliseconds(25)) }
        try #require(view.showsPicture)

        // Nothing is made in memory now, so the other mode's copy can't already be there.
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        view.overrideUserInterfaceStyle = .dark
        view.refresh()
        #expect(view.showsPicture, "the old picture stays up while the new one is made")

        app.reset()
        view.refresh()
        #expect(!view.showsPicture)
    }
}

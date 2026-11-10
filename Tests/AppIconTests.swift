import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HermesHQNative

/// [app-icons] The app icons (AppIconChoice, AppIconArt): the list and the asset catalog agree, the build turns every
/// alternate set into an icon iOS can switch to, and the drawn faces sit in the icon grid in all three looks.
/// `TEST_RUNNER_HQ_WRITE_APP_ICONS=1` writes the drawn icons into their sets (run after changing the drawing).
struct AppIconTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let catalog = repo.appending(path: "App/Resources/Assets.xcassets")

    static func set(_ choice: AppIconChoice) -> URL { catalog.appending(path: "\(choice.id).appiconset") }

    // MARK: The list and the catalog

    @Test func everyIconHasItsSetAndEverySetIsListed() throws {
        let sets = try FileManager.default.contentsOfDirectory(atPath: Self.catalog.path)
            .filter { $0.hasSuffix(".appiconset") }.map { String($0.dropLast(".appiconset".count)) }
        #expect(Set(sets) == Set(AppIconChoice.allSetNames))   // [icon-look] each icon pinned light and dark too
        #expect(AppIconChoice.all.first?.id == AppIconChoice.primary)
        #expect(Set(AppIconChoice.all.map(\.id)).count == AppIconChoice.all.count)
        // Artwork the picker can't draw has a picture of its own in both looks (iOS keeps icons' pictures to itself).
        for choice in AppIconChoice.all where choice.art == .picture {
            let preview = Self.catalog.appending(path: "\(choice.id)-Preview.imageset/Contents.json")
            let data = try Data(contentsOf: preview)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let images = try #require(json["images"] as? [[String: Any]])
            let looks = images.map { (($0["appearances"] as? [[String: String]])?.first?["value"]) ?? "any" }
            #expect(Set(looks) == ["any", "dark"], "\(choice.id)")
        }
    }

    /// Owner 2026-11-02: "Every icon that we have for people to use needs dark mode and light mode options." The light
    /// look (any) is on a light ground, the dark one on a dark ground: not the same picture twice.
    @Test(arguments: AppIconChoice.all) func lightAndDarkLooks(_ choice: AppIconChoice) throws {
        let data = try Data(contentsOf: Self.set(choice).appending(path: "Contents.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let images = try #require(json["images"] as? [[String: Any]])
        func ground(_ look: String) throws -> Double {
            let image = try #require(images.first { (($0["appearances"] as? [[String: String]])?.first?["value"] ?? "any") == look })
            let url = Self.set(choice).appending(path: try #require(image["filename"] as? String))
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let p = Self.pixels(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), side: 64)
            // The four corners, 2 px in.
            let corners = [(2, 2), (61, 2), (2, 61), (61, 61)].map { (x, y) in
                let i = (y * 64 + x) * 4
                return (Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2])) / 3
            }
            return corners.reduce(0, +) / 4
        }
        #expect(try ground("any") > 200, "\(choice.id) light ground")
        #expect(try ground("dark") < 60, "\(choice.id) dark ground")
    }

    /// The images of a set: its look ("any", "dark", "tinted") → the file's bytes.
    static func looks(_ set: String) throws -> [String: Data] {
        let folder = catalog.appending(path: "\(set).appiconset")
        let data = try Data(contentsOf: folder.appending(path: "Contents.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let images = try #require(json["images"] as? [[String: Any]])
        var out: [String: Data] = [:]
        for image in images {
            let look = (image["appearances"] as? [[String: String]])?.first?["value"] ?? "any"
            out[look] = try Data(contentsOf: folder.appending(path: try #require(image["filename"] as? String)))
        }
        return out
    }

    /// [icon-look] A pinned icon wears its look on every Home Screen: the light (or dark) picture of the icon in both
    /// its any and dark slots, the icon's own tinted one (scripts/make-pinned-icons.py, run after an icon changes).
    @Test(arguments: AppIconChoice.all) func pinnedSetsKeepOneLook(_ choice: AppIconChoice) throws {
        let automatic = try Self.looks(choice.id)
        for (look, slot) in [(AppIconLook.light, "any"), (.dark, "dark")] {
            let pinned = try Self.looks(choice.id + look.suffix)
            #expect(pinned["any"] == automatic[slot], "\(choice.id) \(look)")
            #expect(pinned["dark"] == automatic[slot], "\(choice.id) \(look)")
            #expect(pinned["tinted"] == automatic["tinted"], "\(choice.id) \(look)")
        }
    }

    @Test func pinnedNames() {
        let feather = AppIconChoice.choice(named: "AppIcon-Feather")
        #expect(feather.alternateName(.automatic) == "AppIcon-Feather")
        #expect(feather.alternateName(.dark) == "AppIcon-Feather-Dark")
        #expect(AppIconChoice.all[0].alternateName(.automatic) == nil)
        #expect(AppIconChoice.all[0].alternateName(.light) == "AppIcon-Light")
        for name in AppIconChoice.allSetNames {
            let (choice, look) = AppIconChoice.worn(named: name)
            #expect(choice.alternateName(look) ?? AppIconChoice.primary == name)
        }
        #expect(AppIconChoice.worn(named: nil).look == .automatic)
        #expect(AppIconChoice.worn(named: "AppIcon-Gone-Dark").choice.id == "AppIcon")
    }

    /// Each set: one 1024 picture for each look (any, dark, tinted), every file there.
    @Test(arguments: AppIconChoice.allSetNames) func setHasThreeLooks(_ set: String) throws {
        let folder = Self.catalog.appending(path: "\(set).appiconset")
        let data = try Data(contentsOf: folder.appending(path: "Contents.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let images = try #require(json["images"] as? [[String: Any]])
        let looks = images.map { (($0["appearances"] as? [[String: String]])?.first?["value"]) ?? "any" }
        #expect(Set(looks) == ["any", "dark", "tinted"])
        for image in images {
            #expect(image["size"] as? String == "1024x1024")
            let file = try #require(image["filename"] as? String)
            let url = folder.appending(path: file)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let picture = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(picture.width == 1024 && picture.height == 1024, "\(file)")
        }
    }

    /// The build made every alternate set an icon iOS can switch to (`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`).
    @Test func buildCarriesEveryAlternate() throws {
        let icons = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let alternates = icons["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
        #expect(Set(alternates.keys) == Set(AppIconChoice.allSetNames).subtracting([AppIconChoice.primary]))
        let primary = icons["CFBundlePrimaryIcon"] as? [String: Any]
        #expect(primary?["CFBundleIconName"] as? String == AppIconChoice.primary)
    }

    @Test func choiceByName() {
        #expect(AppIconChoice.choice(named: nil).id == "AppIcon")
        #expect(AppIconChoice.choice(named: "AppIcon-Matrix").title == "Matrix")
        #expect(AppIconChoice.choice(named: "AppIcon-Gone").id == "AppIcon")   // a name an older build had
    }

    // MARK: The drawn faces

    nonisolated static let drawn = AppIconChoice.all.filter { $0.art != .picture }

    /// The icon's ground alone, as drawn under its face.
    static func groundImage(_ choice: AppIconChoice, _ variant: AppIconArt.Variant) -> CGImage {
        let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.translateBy(x: 0, y: 1024)
        ctx.scaleBy(x: 1, y: -1)
        AppIconArt.ground(choice.art == .robot && variant == .tinted ? .light : variant, in: ctx)
        return ctx.makeImage()!
    }

    static func pixels(_ image: CGImage, side: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: side * side * 4)
        let ctx = CGContext(data: &out, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return out
    }

    /// What isn't the ground: the box round every pixel that differs from the ground alone by more than `limit`.
    static func inkBox(_ image: CGImage, ground: CGImage, limit: Int = 40) -> CGRect {
        let side = 256
        let p = pixels(image, side: side), g = pixels(ground, side: side)
        var minX = side, maxX = -1, minY = side, maxY = -1
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                if abs(Int(p[i]) - Int(g[i])) + abs(Int(p[i + 1]) - Int(g[i + 1])) + abs(Int(p[i + 2]) - Int(g[i + 2])) > limit {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        // Row 0 of the buffer is the picture's top.
        return CGRect(x: Double(minX) / Double(side), y: Double(minY) / Double(side),
                      width: Double(maxX + 1 - minX) / Double(side), height: Double(maxY + 1 - minY) / Double(side))
    }

    /// Centred across, inside the grid's margins, and big enough to read at Spotlight size. Even margins all round
    /// (the robot's bust too).
    @Test(arguments: drawn) func faceSitsInTheGrid(_ choice: AppIconChoice) throws {
        for variant in AppIconArt.Variant.allCases where variant != .tinted || choice.art != .robot {
            let image = try #require(AppIconArt.image(choice.art, variant: variant))
            let box = Self.inkBox(image, ground: Self.groundImage(choice, variant))
            #expect(abs(box.midX - 0.5) < 0.03, "\(choice.id) \(variant) across \(box.midX)")
            #expect(box.width > 0.5 && box.width < 0.8, "\(choice.id) \(variant) width \(box.width)")
            #expect(abs(box.midY - 0.5) < 0.04 && box.minY > 0.1, "\(choice.id) \(variant) \(box)")
        }
    }

    /// Tinted: grey only (iOS colours it), on black.
    @Test(arguments: drawn) func tintedIsGreyOnBlack(_ choice: AppIconChoice) throws {
        let image = try #require(AppIconArt.image(choice.art, variant: .tinted, pixels: 128))
        let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: 128 * 128 * 4)
        var bright = 0
        for i in stride(from: 0, to: 128 * 128 * 4, by: 4) {
            let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
            #expect(abs(r - g) <= 3 && abs(g - b) <= 3)
            if r > 128 { bright += 1 }
        }
        #expect(p[0] < 4 && p[1] < 4 && p[2] < 4, "corner is black")
        #expect(bright > 128 * 128 / 20, "the face shows")
    }

    // MARK: Writing them

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func contents(_ id: String) -> String {
        func entry(_ suffix: String, _ look: String?) -> String {
            let appearance = look.map { "\n      \"appearances\" : [ { \"appearance\" : \"luminosity\", \"value\" : \"\($0)\" } ]," } ?? ""
            return "    {\(appearance)\n      \"filename\" : \"\(id)\(suffix).png\",\n      \"idiom\" : \"universal\",\n      \"platform\" : \"ios\",\n      \"size\" : \"1024x1024\"\n    }"
        }
        return "{\n  \"images\" : [\n\(entry("", nil)),\n\(entry("-Dark", "dark")),\n\(entry("-Tinted", "tinted"))\n  ],\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n"
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HQ_WRITE_APP_ICONS"] == "1"))
    func writeDrawnIcons() throws {
        for choice in Self.drawn {
            let folder = Self.set(choice)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for variant in AppIconArt.Variant.allCases {
                let image = try #require(AppIconArt.image(choice.art, variant: variant))
                try Self.png(image).write(to: folder.appending(path: "\(choice.id)\(variant.suffix).png"))
            }
            try Self.contents(choice.id).write(to: folder.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
        }
    }
}

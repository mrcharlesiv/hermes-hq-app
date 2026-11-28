import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import HermesHQNative

/// The Robot, Dots, Orb, Pixel and Emoji heads: ThemeHeadSVG must write exactly the recorded markup (ids normalised),
/// SVGMini must draw it, and Describe it must read words as `describe.ts` does. The record began as the web's
/// (ref240 `headSvg`); since the owner's 2026-11-16/17 face changes (faces rest looking right, the face colours
/// retuned) the app's faces are its own, and the record is the app's markup. After a deliberate face change, run this
/// test once with `TEST_RUNNER_HQ_THEME_HEADS_REWRITE=1` to record the new markup, and review the faces themselves.
struct ThemeHeadTests {
    private struct Sample: Decodable {
        let head: JSONValue
        let state: String?
        let compact: Bool
        let sha: String
    }

    private static func samples() throws -> [Sample] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/theme-heads-web.json")
        return try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
    }

    private static func normalised(_ svg: String) -> String {
        svg.replacingOccurrences(of: #"(dh|rb)[0-9a-z]+"#, with: "ID", options: .regularExpression)
    }

    @Test func markupMatchesTheWebRenderer() throws {
        let samples = try Self.samples()
        #expect(samples.count > 300)
        var mismatches: [String] = []
        var renewed: [String: String] = [:], clash = false
        for (index, sample) in samples.enumerated() {
            guard let record = HeadRecord.parse(sample.head) else { mismatches.append("#\(index) unparsed"); continue }
            let svg = ThemeHeadSVG.svg(record, state: sample.state.flatMap(HeadState.init(rawValue:)), compact: sample.compact)
            let sha = SHA256.hash(data: Data(Self.normalised(svg).utf8)).map { String(format: "%02x", $0) }.joined()
            if sha != sample.sha {
                mismatches.append("#\(index) \(record.pictureKey)")
                if let other = renewed[sample.sha], other != sha { clash = true }
                renewed[sample.sha] = sha
            }
        }
        if ProcessInfo.processInfo.environment["HQ_THEME_HEADS_REWRITE"] != nil, !mismatches.isEmpty {
            // Records the app's markup as it is now (see the note above). Two samples that shared a hash and no longer
            // do cannot be rewritten by hash: that needs the file rebuilt by hand.
            try #require(!clash, "samples that shared a hash now differ")
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/theme-heads-web.json")
            var text = try String(contentsOf: url, encoding: .utf8)
            for (old, new) in renewed { text = text.replacingOccurrences(of: "\"\(old)\"", with: "\"\(new)\"") }
            try text.write(to: url, atomically: true, encoding: .utf8)
            print("[theme-heads] recorded \(renewed.count) changed hashes for \(mismatches.count) samples")
            return
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(10))")
    }

    @Test(arguments: ["robot", "dots", "orb", "pixel", "glyph"])
    func drawsEveryTheme(theme: String) throws {
        var record = HeadRecord()
        record.theme = theme
        record.tile = "dark"
        let head = try #require(Head(record: record))
        #expect(head.themed != nil)
        let image = try #require(HeadRenderer.picture(head, side: 64, scale: 2, dark: false))
        #expect(image.width == 128)
        // Something opaque in the middle of the tile.
        let data = try #require(image.dataProvider?.data as Data?)
        let middle = (64 * image.bytesPerRow) + 64 * 4
        #expect(data[middle + 3] > 0)
    }

    @Test func characterFallsBackToTheDefault() {
        let raw: JSONValue = .object(["v": 6, "theme": "persona", "color": "pink"])
        let head = Head.resolve(raw, profile: "ivy")
        #expect(head == Head.defaultHead(profile: "ivy"))
    }

    @Test func robotResolvesAndKeepsItsKey() {
        let raw: JSONValue = .object(["v": 6, "theme": "robot", "shape": "cat", "face": "happy", "color": "lilac"])
        let head = Head.resolve(raw, profile: "ivy")
        #expect(head.themed?.shape == "cat")
        #expect(head.cacheKey.hasPrefix("robot|cat|happy|"))
    }

    @Test func describeReadsWords() {
        let described = HeadDescribe.describe("sleepy purple cat with goggles")
        #expect(described.understood == ["purple", "cat", "sleepy", "goggles"])
        #expect(described.parts["color"] == "lilac")
        #expect(described.parts["shape"] == "cat")
        #expect(described.parts["face"] == "sleepy")
        #expect(described.parts["visor"] == "goggles")
        #expect(described.parts["theme"] == nil, "no theme word")
        let rocket = HeadDescribe.describe("🚀 deploys")
        #expect(rocket.parts["theme"] == "glyph")
        #expect(rocket.parts["glyph"] == "🚀")
        #expect(rocket.understood.first == "🚀")
        #expect(HeadDescribe.describe("cool shades").parts["theme"] == "shape", "dark glasses are a Shapes head's")
        #expect(HeadDescribe.describe("xyzzy").understood.isEmpty)
    }

    @Test func savingKeepsTheThemeButNeverCharacter() {
        var robot = HeadRecord()
        robot.theme = "robot"
        robot.hat = "crown"
        #expect(robot.forSaving.theme == "robot")
        #expect(robot.forSaving.hat == "none")
        var persona = HeadRecord()
        persona.theme = "persona"
        #expect(persona.forSaving.theme == "shape")
    }

    /// Edit Head's Ideas read as heads to VoiceOver, not "Idea 2".
    @Test func summaryNamesThemeColourAndPart() {
        var robot = HeadRecord()
        robot.color = "teal"
        robot.shape = "cat"
        #expect(HeadLabels.summary(robot) == "Robot, Teal, Cat")
        var shape = HeadRecord()
        shape.theme = "shape"
        shape.color = "pink"
        shape.form = "star"
        #expect(HeadLabels.summary(shape) == "Shapes, Bubblegum, Star")
        var orb = HeadRecord()
        orb.theme = "orb"
        #expect(HeadLabels.summary(orb) == "Orb, Ink")
    }
}

/// The editor's small choices must show the same Dots design as the large stage, not the compact list-row design.
@MainActor @Suite struct EditHeadPreviewTests {
    @Test(arguments: HeadRecord.patterns, [true, false])
    func dotsChoicesMatchTheStage(pattern: String, eyes: Bool) async throws {
        var record = HeadRecord()
        record.theme = "dots"
        record.pattern = pattern
        record.eyes = eyes
        record.color = "teal"
        record.seed = 17
        let head = try #require(Head(record: record))
        for side: CGFloat in [56, 60] {
            let preview = try #require(await StripHeadImages.render(head, size: side, scale: 2, dark: false)?.cgImage)
            let stage = try #require(HeadRenderer.picture(head, side: 64, scale: side * 2 / 64, dark: false))
            #expect(preview.width == Int(side * 2))
            #expect(preview.height == Int(side * 2))
            let previewPixels = try #require(preview.dataProvider?.data as Data?)
            let stagePixels = try #require(stage.dataProvider?.data as Data?)
            #expect(previewPixels == stagePixels, "\(pattern), eyes: \(eyes), side: \(side)")
        }
    }

    @Test func ordinarySmallDotsStayCompact() throws {
        var record = HeadRecord()
        record.theme = "dots"
        record.pattern = "bloom"
        let head = try #require(Head(record: record))
        let compact = try #require(HeadRenderer.picture(head, side: 56, scale: 2, dark: false))
        let full = try #require(HeadRenderer.picture(head, side: 64, scale: 56 * 2 / 64, dark: false))
        let compactPixels = try #require(compact.dataProvider?.data as Data?)
        let fullPixels = try #require(full.dataProvider?.data as Data?)
        #expect(compactPixels != fullPixels)
    }

    @Test func otherThemeChoicesKeepTheirSmallRendering() async throws {
        var record = HeadRecord()
        record.theme = "robot"
        let head = try #require(Head(record: record))
        let preview = try #require(await StripHeadImages.render(head, size: 56, scale: 2, dark: false)?.cgImage)
        let ordinary = try #require(HeadRenderer.picture(head, side: 56, scale: 2, dark: false))
        let previewPixels = try #require(preview.dataProvider?.data as Data?)
        let ordinaryPixels = try #require(ordinary.dataProvider?.data as Data?)
        #expect(previewPixels == ordinaryPixels)
    }
}

/// [perf] A themed head under 32 pt is drawn off the main thread (`HeadImage` → `SmallHeadPicture`): the async draw
/// must land in the shared cache, where the next row with that head finds it in place.
@MainActor @Suite struct HeadImageCacheTests {
    private func themed(_ theme: String) throws -> Head {
        var record = HeadRecord()
        record.theme = theme
        record.tile = "dark"
        return try #require(Head(record: record))
    }

    @Test func theOffMainDrawIsStoredForTheNextRow() async throws {
        let head = try themed("robot")
        let side: CGFloat = 27.5   // a size no other test draws, so the cache starts cold for it
        #expect(HeadImageCache.shared.cachedImage(for: head, side: side, scale: 2, dark: false) == nil)
        let images = await HeadImageCache.shared.images(for: head, side: side, scale: 2, dark: false, state: .idle, parts: [.all])
        let drawn = try #require(images.first)
        let cached = try #require(HeadImageCache.shared.cachedImage(for: head, side: side, scale: 2, dark: false))
        #expect(cached === drawn)
        #expect(cached.cgImage?.width == 55, "side × scale pixels")
    }

    @Test func aThemedHeadIgnoresTheDarkPage() async throws {
        let head = try themed("orb")
        let side: CGFloat = 23.5
        _ = await HeadImageCache.shared.images(for: head, side: side, scale: 2, dark: true, state: .idle, parts: [.all])
        let light = HeadImageCache.shared.cachedImage(for: head, side: side, scale: 2, dark: false)
        let dark = HeadImageCache.shared.cachedImage(for: head, side: side, scale: 2, dark: true)
        #expect(light != nil)
        #expect(light === dark)
    }
}

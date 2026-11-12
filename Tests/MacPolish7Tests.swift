// Mac polish audit 2026-11-06, batch 7 (Tasks, Kanban, Jobs, Tiles and Artifacts): the words and naming rules its fixes
// changed. The iPhone's words stay as they were; the Mac's are asked for with `mac: true`.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct MacPolish7Tests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    /// #138: Tasks names the device it runs on and the Mac's own ways to act.
    @Test func tasksSpeaksMac() {
        #expect(TodoWords.alertNote(hasTime: true, mac: true) == "This Mac reminds you at that time.")
        #expect(TodoWords.alertNote(hasTime: true, mac: false) == "This phone reminds you at that time.")
        let day = TodoWords.alertNote(hasTime: false, calendar: Self.calendar, locale: Locale(identifier: "en_US"), mac: true)
        #expect(day.hasPrefix("This Mac reminds you at 9:00") && day.hasSuffix("that day."), "\(day)")
        #expect(TodoWords.newTaskHelpNote("Ivy", tap: "click").hasPrefix("When you click Add, Ivy’s chat opens"))
        #expect(TodoWords.newTaskHelpNote("Ivy", tap: "tap").hasPrefix("When you tap Add, Ivy’s chat opens"))
    }

    /// #45: two tiles named by files that read the same keep their extensions; a name of their own wins.
    @Test func clashingTileNamesKeepTheirExtensions() {
        #expect(TileNames.pretty("index.md", keepsExtension: true) == "Index.md")
        #expect(TileNames.pretty("/home/hermes/site/index.HTML", keepsExtension: true) == "Index.html")
        #expect(TileNames.pretty("index.md", keepsExtension: false) == "Index")
        let clash = TileNames.clashing([("a", "Index", true), ("b", "Index", true), ("c", "Plan", true), ("d", "index", false)])
        #expect(clash == ["a", "b"])

        let pins = ArtifactPins(fileURL: nil)
        func record(_ value: String) -> ArtifactRecord {
            ArtifactRecord(id: "s1:\(value)", kind: .file, value: value, href: ArtifactCollector.href(value),
                           label: ArtifactCollector.label(value, kind: .file), sessionId: "s1", profile: "deploys",
                           sessionTitle: "The 2.4 report", timestamp: 1000)
        }
        pins.toggle(record("/home/hermes/site/index.md"))
        pins.toggle(record("/home/hermes/site/index.html"))
        #expect(pins.pins.map { pins.name($0) }.sorted() == ["Index.html", "Index.md"])
        #expect(pins.shown(pins.pins[0]).name == pins.name(pins.pins[0]))
        // The page's own title arrives: the names no longer clash.
        let page = pins.pins.first { $0.value.hasSuffix(".html") }!
        pins.notePage(id: page.id, head: TileNames.Head(title: "Release 2.4"))
        #expect(pins.pins.map { pins.name($0) }.sorted() == ["Index", "Release 2.4"])
    }
}

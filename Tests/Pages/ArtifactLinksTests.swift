// 3x-morepages §3 (U2): the path of a note linked from a note (`S/fe-pages-r5.test.ts:23-33`), what a link is, and
// the heading a `#fragment` names.

import Foundation
import Testing
@testable import HermesHQNative

struct ArtifactLinksTests {
    @Test func aLinkedNoteResolvesInTheLinkingNotesFolder() {
        #expect(ArtifactLinks.linkedNotePath(from: "report.md", target: "notes.md") == "notes.md")
        #expect(ArtifactLinks.linkedNotePath(from: "docs/report.md", target: "./notes.md") == "docs/notes.md")
        #expect(ArtifactLinks.linkedNotePath(from: "docs/report.md", target: "../README.md") == "README.md")
        #expect(ArtifactLinks.linkedNotePath(from: "report.md", target: "../up.md") == "../up.md")
        #expect(ArtifactLinks.linkedNotePath(from: "/Users/ivy/work/report.md", target: "briefs/a.md") == "/Users/ivy/work/briefs/a.md")
        #expect(ArtifactLinks.linkedNotePath(from: "/Users/ivy/work/report.md", target: "../../x.md") == "/Users/x.md")
        #expect(ArtifactLinks.linkedNotePath(from: "/Users/ivy/work/report.md", target: "/etc/hosts") == "/etc/hosts")
        #expect(ArtifactLinks.linkedNotePath(from: "report.md", target: "~/notes/a.md") == "~/notes/a.md")
        #expect(ArtifactLinks.linkedNotePath(from: "report.md", target: "file:///Users/ivy/a.md") == "/Users/ivy/a.md")
    }

    @Test func climbingAboveAnAbsoluteRootStopsAtTheRoot() {
        #expect(ArtifactLinks.linkedNotePath(from: "/a.md", target: "../../../x.md") == "/x.md")
        #expect(ArtifactLinks.linkedNotePath(from: "a/b/c.md", target: "../../../../x.md") == "../../x.md")
    }

    @Test func whatALinkIs() {
        #expect(ArtifactLinks.classify(href: "https://example.com/a") == .external(URL(string: "https://example.com/a")!))
        #expect(ArtifactLinks.classify(href: "//example.com/a") == .external(URL(string: "https://example.com/a")!))
        #expect(ArtifactLinks.classify(href: "www.example.com") == .external(URL(string: "https://www.example.com")!))
        #expect(ArtifactLinks.classify(href: "plan.md") == .file("plan.md", fragment: nil))
        #expect(ArtifactLinks.classify(href: "../My%20Notes/plan.md#next-steps") == .file("../My Notes/plan.md", fragment: "next-steps"))
        #expect(ArtifactLinks.classify(href: "file:///Users/ivy/a.md") == .file("file:///Users/ivy/a.md", fragment: nil))
        #expect(ArtifactLinks.classify(href: "C:\\notes\\a.md") == .file("C:\\notes\\a.md", fragment: nil))
        #expect(ArtifactLinks.classify(href: "#usage") == .hash("usage"))
        #expect(ArtifactLinks.classify(href: "#") == .inert)
        #expect(ArtifactLinks.classify(href: "") == .inert)
        #expect(ArtifactLinks.classify(href: "   ") == .inert)
        #expect(ArtifactLinks.classify(href: "javascript:alert(1)") == .inert)
        #expect(ArtifactLinks.classify(href: "data:text/html,hi") == .inert)
        #expect(ArtifactLinks.classify(href: "mailto:ivy@example.com") == .inert)
        #expect(ArtifactLinks.classify(href: "hq-note://link?d=x") == .inert)
    }

    @Test func aHeadingsSlug() {
        #expect(ArtifactLinks.headingSlug("  Getting Started!  ") == "getting-started")
        #expect(ArtifactLinks.headingSlug("What's new in 2.4?") == "whats-new-in-24")
        #expect(ArtifactLinks.headingSlug("snake_case and kebab-case") == "snake_case-and-kebab-case")
        #expect(ArtifactLinks.headingSlug("a  --  b") == "a-b")
        // Composed and decomposed accents slug alike.
        #expect(ArtifactLinks.headingSlug("Caf\u{00E9}") == ArtifactLinks.headingSlug("Cafe\u{0301}"))
        #expect(ArtifactLinks.headingSlug("日本語 の 見出し") == "日本語-の-見出し")
        #expect(ArtifactLinks.headingSlug("!!!") == "")
    }

    @Test func headingsAreNumberedAndCodeIsSkipped() {
        let note = "# Usage\n\ntext\n\n```\n# not a heading\n```\n\n## Usage\n### `Code` and **bold** [link](x.md) ##\n#nospace\n"
        let found = ArtifactLinks.headings(in: note)
        #expect(found.map(\.id) == ["usage", "usage-1", "code-and-bold-link"])
        #expect(found.map(\.text) == ["Usage", "Usage", "Code and bold link"])
    }

    @Test func backUsesTheNameUpToTwelveCharacters() {
        #expect(ArtifactLinks.backUsesName("index.md"))
        #expect(ArtifactLinks.backUsesName("123456789.md"))
        #expect(!ArtifactLinks.backUsesName("a-long-name.md"))
        #expect(ArtifactLinks.name("notes/plan.md") == "plan.md")
        #expect(ArtifactLinks.name("/a/b/") == "b")
    }

    @Test func theViewersOwnLinkRoundTrips() throws {
        let url = try #require(ArtifactLinks.viewerURL(destination: "../My Notes/plan.md#a b&c=d"))
        #expect(url.scheme == "hq-note")
        #expect(ArtifactLinks.destination(of: url) == "../My Notes/plan.md#a b&c=d")
        #expect(ArtifactLinks.destination(of: URL(string: "https://example.com/?d=x")!) == nil)
    }
}

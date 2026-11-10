import Foundation
import UIKit
import Testing
@testable import HermesHQNative

// Tester reports of 2026-10-26 (docs/briefs/agent-images-markdown.md): a bot's picture showed as its path (ivy), and
// your own messages drew markdown as raw characters (a tester).

@Suite("Agent images: every way a reply names a picture")
struct AgentImageFormsTests {
    private let style = ChatStyleCache.shared.style(for: .large)

    private func media(_ markdown: String) -> [[MediaRef]] {
        MarkdownRenderer.render(markdown, style: style).blocks.compactMap { if case .media(let r) = $0 { return r } else { return nil } }
    }

    private func text(_ markdown: String) -> String {
        MarkdownRenderer.render(markdown, style: style).blocks.compactMap { if case .text(let s) = $0 { return s.string } else { return nil } }
            .joined(separator: "\n")
    }

    @Test func mediaTagsMatchTheWeb() {
        let cases: [(String, String)] = [
            ("MEDIA:/tmp/a.png", "/tmp/a.png"),
            ("MEDIA: /tmp/a.png", "/tmp/a.png"),
            ("MEDIA:\"/Users/me/My Pictures/shot 1.png\"", "/Users/me/My Pictures/shot 1.png"),
            ("MEDIA:'/tmp/stop!.png'", "/tmp/stop!.png"),
            ("MEDIA:`/tmp/code.png`", "/tmp/code.png"),
            ("MEDIA:/Users/me/AI Brain/report chart.png", "/Users/me/AI Brain/report chart.png"),
            ("MEDIA:C:\\Users\\ivy\\Pictures\\out.png", "C:\\Users\\ivy\\Pictures\\out.png"),
            ("MEDIA:~/Desktop/a.png", "~/Desktop/a.png"),
            ("MEDIA:chart.png", "chart.png"),
        ]
        for (line, path) in cases {
            let refs = media(line)
            #expect(refs.count == 1 && refs.first?.first?.attachment.source == .gateway(path: path), "\(line)")
            #expect(refs.first?.first?.kind == .image, "\(line)")
        }
        #expect(media("MEDIA:https://images.example.com/x.png").first?.first?.attachment.source
            == .remote(URL(string: "https://images.example.com/x.png")!))
    }

    @Test func mediaTagTrailingPunctuationStaysProse() {
        #expect(MediaTags.value("/tmp/a.pdf.")! == ("/tmp/a.pdf", "."))
        #expect(MediaTags.value("'/tmp/stop!.md'")! == ("/tmp/stop!.md", ""))
        #expect(MediaTags.value("...") == nil, "a bare ellipsis is prose")
        #expect(MediaTags.value("word") == nil)
        let r = MediaTags.renderTags("open MEDIA:/tmp/a.pdf.")
        #expect(r.text.hasSuffix(").") && !r.mediaOnly)
        #expect(MediaTags.renderTags("  MEDIA:/a.png MEDIA:/b.png ").mediaOnly)
    }

    @Test func aBarePathAloneIsAPicture() {
        for line in ["/Users/ivy/.hermes/cache/screenshots/browser_ab12.png", "`/tmp/My Shot.png`", "~/Desktop/a.jpeg",
                     "C:\\Users\\ivy\\out.webp", "/tmp/a.png."] {
            let refs = media(line)
            #expect(refs.count == 1 && refs.first?.first?.kind == .image, "\(line)")
            #expect(!text(line).contains("/"), "no raw path left: \(line)")
        }
    }

    @Test func aBarePathInASentenceIsANameAndThePictureFollows() throws {
        let r = MarkdownRenderer.render("I saved the screenshot to /Users/ivy/.hermes/cache/shot.png for you.", style: style)
        #expect(r.blocks.count == 2)
        guard case .text(let words) = r.blocks[0], case .media(let refs) = r.blocks[1] else { Issue.record("blocks"); return }
        #expect(words.string.contains("shot.png") && !words.string.contains("/Users/ivy"), "\(words.string)")
        #expect(refs.first?.attachment.source == .gateway(path: "/Users/ivy/.hermes/cache/shot.png"))
    }

    @Test func pathsThatAreNotPicturesStayText() {
        for line in ["See https://example.com/img/a.png now", "Run `cp /tmp/a.png /tmp/b.png` first", "a/b.png is relative",
                     "Edit /etc/hosts please", "[chart](https://x.com/c.png)", "//cdn.example.com/a.png"] {
            #expect(media(line).isEmpty, "\(line)")
        }
        // In a fence nothing changes.
        #expect(media("```\n/tmp/a.png\n```").isEmpty)
    }

    // Owner, Mac, 2026-10-30: "when the agent sent me images i didn't get a preview of the images, i only got links".
    // The bot listed its screenshots as list items (app profile rows 7466 and 7680).
    @Test func aListOfPicturePathsShowsThePictures() {
        let plain = "Screenshots use demo data.\n\n- /Users/me/.hermes/attachments/b468/01-update-needed.png\n- /Users/me/.hermes/attachments/b468/02-addon-ready.png"
        let refs = media(plain).flatMap { $0 }
        #expect(refs.map(\.attachment.source) == [.gateway(path: "/Users/me/.hermes/attachments/b468/01-update-needed.png"),
                                                    .gateway(path: "/Users/me/.hermes/attachments/b468/02-addon-ready.png")])
        #expect(!text(plain).contains("/Users/me"))
        let nested = "- **Created three showcase images:**  \n  - `/Users/me/shots/01-collapsed.png`  \n  - `/Users/me/shots/02-expanded.png`  \n- **Provenance:** `/Users/me/shots/PROVENANCE.md`"
        #expect(media(nested).flatMap { $0 }.count == 2)
        #expect(text(nested).contains("Created three showcase images") && text(nested).contains("Provenance"))
        let numbered = "1. /tmp/a.png\n2) `/tmp/b.jpg`"
        #expect(media(numbered).flatMap { $0 }.count == 2)
    }

    @Test func aPictureNamedInAListItemFollowsTheList() throws {
        // The list keeps its shape: the path becomes a tappable name and the picture comes after the whole list.
        let r = MarkdownRenderer.render("- one /tmp/a.png\n- two\n\nAfter.", style: style)
        #expect(r.blocks.count == 3, "\(r.blocks)")
        guard r.blocks.count == 3, case .text(let list) = r.blocks[0], case .media(let refs) = r.blocks[1],
              case .text(let after) = r.blocks[2] else { Issue.record("blocks"); return }
        #expect(list.string.contains("one") && list.string.contains("two") && !list.string.contains("/tmp/"))
        #expect(refs.first?.attachment.source == .gateway(path: "/tmp/a.png"))
        #expect(after.string == "After.")
        // A loose list's blank line doesn't end it early.
        let loose = MarkdownRenderer.render("- one /tmp/a.png\n\n- two", style: style)
        guard case .media = loose.blocks.last else { Issue.record("picture after the list"); return }
        #expect(loose.blocks.count == 2, "\(loose.blocks)")
    }

    @Test func aRefusedPictureIsANamedFileRow() {
        let ref = MarkdownMedia.ref(destination: "#media:%2Ftmp%2Fgone.png", title: "Image: gone.png", image: false)!
        let ok = AttachmentBubbleLayout.mediaBlock([ref], context: nil, maxText: 300, mine: false, style: style)
        #expect(ok.media.groups.count == 1 && ok.media.rows.isEmpty)
        let refused = AttachmentBubbleLayout.mediaBlock([ref], context: nil, maxText: 300, mine: false, style: style,
                                                       unavailable: ["/tmp/gone.png": MediaUnavailable.words(.notFound)])
        #expect(refused.media.groups.isEmpty && refused.media.rows.count == 1)
        #expect(refused.media.rows.first?.item.attachment.name == "gone.png")
        #expect(refused.media.rows.first?.item.detail == "Image · not on your gateway")
        #expect(MediaUnavailable.words(.forbidden) == "Image · your gateway keeps this file private")
    }

    @Test func voiceOverReadsTheNameNotThePath() {
        let spoken = SpokenMarkdown.plain(MediaTags.forSpeech("The old one was at /fixture/media/gone-shot.png\nMEDIA:\"/a/two words.png\""))
        #expect(!spoken.contains("/fixture") && !spoken.contains("/a/"), "\(spoken)")
        #expect(spoken.contains("gone-shot.png") && spoken.contains("two words.png"), "\(spoken)")
    }

    @Test func windowsPathsShowTheirName() {
        #expect(MediaKinds.name(ofPath: "C:\\Users\\ivy\\Pictures\\out.png", image: true) == "out.png")
        #expect(MediaTags.displayName("C:\\Users\\ivy\\out.png") == "out.png")
    }
}

@Suite("Your messages: inline markdown")
struct UserMarkdownTests {
    private let style = ChatStyleCache.shared.style(for: .large)

    private func attributes(_ s: NSAttributedString, of word: String) -> [NSAttributedString.Key: Any] {
        let r = (s.string as NSString).range(of: word)
        return r.location == NSNotFound ? [:] : s.attributes(at: r.location, effectiveRange: nil)
    }

    @Test func inlineStylesRender() throws {
        let r = MarkdownRenderer.renderUser("make it **bold**, *slanted*, ~~gone~~ and `code` see [docs](https://example.com)", style: style)
        guard case .text(let s) = try #require(r.blocks.first) else { Issue.record("not text"); return }
        #expect(!s.string.contains("**") && !s.string.contains("~~") && !s.string.contains("`") && !s.string.contains("]("))
        #expect((attributes(s, of: "bold")[.font] as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect((attributes(s, of: "slanted")[.font] as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        #expect(attributes(s, of: "gone")[.strikethroughStyle] != nil)
        #expect(attributes(s, of: "code")[.chatCopy] as? String == "code")
        #expect(attributes(s, of: "docs")[.chatLink] as? URL == URL(string: "https://example.com"))
        #expect(r.plainText.contains("**bold**"), "Copy keeps what you typed")
    }

    @Test func fencedCodeIsACodeCard() {
        let r = MarkdownRenderer.renderUser("try this:\n```swift\nlet x = 1\n```", style: style)
        #expect(r.blocks.count == 2)
        if case .code(_, let code, _, _) = r.blocks.last { #expect(code == "let x = 1") } else { Issue.record("no code block") }
    }

    @Test func linesKeepTheShapeYouTyped() throws {
        let typed = "# not a heading\n- not a list *but italic*\n1. still one\n> not a quote\n| a | b |\n|---|---|\n---\n    indented"
        let r = MarkdownRenderer.renderUser(typed, style: style)
        #expect(r.blocks.count == 1)
        guard case .text(let s) = try #require(r.blocks.first) else { Issue.record("not text"); return }
        for line in ["# not a heading", "- not a list but italic", "1. still one", "> not a quote", "| a | b |", "|---|---|", "---"] {
            #expect(s.string.contains(line), "\(line) in \(s.string)")
        }
        #expect(s.string.contains("\u{00A0}\u{00A0}\u{00A0}\u{00A0}indented"))
    }

    @Test func aReplyOpensWithItsQuote() throws {
        let r = MarkdownRenderer.renderUser("> Option A is faster.\n> # still words\n\nA please\n> not a quote", style: style)
        guard case .quote(let quote, _) = try #require(r.blocks.first) else { Issue.record("no quote: \(r.blocks)"); return }
        #expect(quote.string.contains("Option A is faster.") && quote.string.contains("# still words"))
        guard case .text(let rest) = try #require(r.blocks.last) else { Issue.record("no text"); return }
        #expect(rest.string.contains("A please") && rest.string.contains("> not a quote"))
    }

    @Test func voiceOverReadsYourMessageAsDrawn() {
        let spoken = UserMarkdown.spoken("Take a **screenshot**\n- keep this dash\n# and this hash\n1. one")
        #expect(spoken == "Take a screenshot\n- keep this dash\n# and this hash\n1. one", "\(spoken)")
    }

    @Test func plainMessagesDrawExactlyAsBefore() {
        let text = "Hello\n\nTwo lines\nhere"
        let r = MarkdownRenderer.renderUser(text, style: style)
        guard case .text(let s) = r.blocks.first else { Issue.record("not text"); return }
        #expect(s.isEqual(to: MarkdownRenderer.plain(text, style: style, theme: .me)))
    }

    @Test func yourBubbleIsMarkdown() {
        let m = ChatMessage(id: "u1", role: .user, parts: [.text("**hi**")], timestamp: Date(), rowId: 1)
        let rows = ChatRowBuilder.build(.init(messages: [m], isRunning: false, botName: "Hermes", expanded: []))
        let bubble = rows.compactMap { if case .bubble(let b) = $0.kind { return b } else { return nil } }.first
        #expect(bubble?.mine == true && bubble?.markdown == true)
    }
}

// Owner, 2026-10-31: Otto's chart came as `::preview{file="….html"}` (the desktop app's inline page) and drew as raw text.
@Suite("Desktop ::preview lines")
struct PreviewDirectiveTests {
    private let style = ChatStyleCache.shared.style(for: .large)

    @Test func aPreviewLineIsTheFilesCard() {
        let reply = "I built a chart.\n\n::preview{file=\"/Users/me/Projects/charts/follow-up-chart.html\"}\n\n**At a glance:**"
        let blocks = MarkdownRenderer.render(reply, style: style).blocks
        let refs = blocks.compactMap { if case .media(let r) = $0 { return r } else { return nil } }.flatMap { $0 }
        #expect(refs.count == 1)
        #expect(refs.first?.attachment.source == .gateway(path: "/Users/me/Projects/charts/follow-up-chart.html"))
        #expect(refs.first?.kind == .file)
        let words = blocks.compactMap { if case .text(let s) = $0 { return s.string } else { return nil } }.joined()
        #expect(!words.contains("::preview"))
    }

    @Test func previewPathForms() {
        #expect(MediaTags.previewPath("::preview{file=\"/a/b c.html\"}") == "/a/b c.html")
        #expect(MediaTags.previewPath("  ::preview{height=\"480\" file='/a/b.html'}  ") == "/a/b.html")
        #expect(MediaTags.previewPath("::preview{file=/a/b.html}") == "/a/b.html")
        #expect(MediaTags.previewPath("see ::preview{file=\"/a/b.html\"} here") == nil, "only a line of its own")
        #expect(MediaTags.previewPath("::preview{height=\"480\"}") == nil)
    }

    @Test func talkSkipsThePreviewLine() {
        let said = SpeechText.sanitizeForSpeech("Here is the chart.\n::preview{file=\"/a/b.html\"}\nDrag the line.")
        #expect(!said.contains("preview") && said.contains("Drag the line"))
    }
}

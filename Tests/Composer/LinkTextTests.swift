// [m9/composer] Link… text rules (docs/spec/3x-composer.md §4.2, §4.5).

import Foundation
import Testing
@testable import HermesHQNative

struct LinkTextTests {
    @Test func bareHostsGetHttps() {
        #expect(LinkText.normalised("example.com/post") == "https://example.com/post")
        #expect(LinkText.normalised("  Sub.Example.co.uk?x=1 ") == "https://Sub.Example.co.uk?x=1")
        #expect(LinkText.normalised("example.com:8080/a") == "https://example.com:8080/a")
        #expect(LinkText.normalised("10.0.0.1:8080/x") == "https://10.0.0.1:8080/x")
    }

    @Test func anythingElseStays() {
        #expect(LinkText.normalised("") == "")
        #expect(LinkText.normalised("http://10.0.0.1:8080/x") == "http://10.0.0.1:8080/x")
        #expect(LinkText.normalised("HTTPS://A.COM") == "HTTPS://A.COM")
        #expect(LinkText.normalised("hello world") == "hello world")
        #expect(LinkText.normalised("notalink") == "notalink")
        #expect(LinkText.normalised("mailto:a@b.co") == "mailto:a@b.co")
        #expect(LinkText.normalised("tel:+15551234") == "tel:+15551234")
        #expect(LinkText.normalised("file:/etc/hosts") == "file:/etc/hosts")
        #expect(LinkText.normalised("ftp://x.com") == "ftp://x.com")
    }

    @Test func isLinkNeedsHttpAndSomethingAfter() {
        #expect(LinkText.isLink("https://a"))
        #expect(LinkText.isLink("HTTP://a.b"))
        #expect(!LinkText.isLink("https://"))
        #expect(!LinkText.isLink("ftp://a.com"))
        #expect(!LinkText.isLink("example.com"))
        #expect(LinkText.isLink(LinkText.normalised("example.com/a")))
        #expect(!LinkText.isLink(LinkText.normalised("hello world")))
    }

    @Test func displayDropsTheScheme() {
        #expect(LinkText.display("https://example.com/post") == "example.com/post")
        #expect(LinkText.display("http://10.0.0.1:8080/x") == "10.0.0.1:8080/x")
    }

    @Test func refValueQuoting() {
        #expect(RefValue.format("https://example.com/post") == "https://example.com/post")
        #expect(RefValue.format("https://e.com/a(b)") == "`https://e.com/a(b)`")
        #expect(RefValue.format("a b") == "`a b`")
        #expect(RefValue.format("a `b` c") == "\"a `b` c\"")
        #expect(RefValue.format("a `b` \"c\"") == "'a `b` \"c\"'")
        #expect(RefValue.format("a `b` \"c\" 'd'") == "a `b` \"c\" 'd'")
        #expect(RefValue.urlRef("https://example.com") == "@url:https://example.com")
    }

    @Test func promptPutsLinksFirst() {
        let ref = RefValue.urlRef("https://example.com/post")
        #expect(AttachmentSender.promptText(typed: "hi", fileRefs: [ref], hasImages: false) == "@url:https://example.com/post\n\nhi")
        #expect(AttachmentSender.promptText(typed: "", fileRefs: [ref], hasImages: false) == "@url:https://example.com/post")
    }

    @Test func hydrationLiftsLeadingUrlLines() {
        let lifted = AttachmentHydration.liftText("@url:https://example.com/post\n\nhi")
        #expect(lifted.text == "hi")
        #expect(lifted.attachments.count == 1)
        #expect(lifted.attachments[0].kind == .link)
        #expect(lifted.attachments[0].gatewayPath == "https://example.com/post")
        let quoted = AttachmentHydration.liftText("@url:`https://e.com/a(b)`\n\nx")
        #expect(quoted.attachments.first?.gatewayPath == "https://e.com/a(b)")
    }

    @Test func oldStashesDecode() throws {
        let old = #"{"id":"x","kind":"file","name":"a.txt","localFile":"x/a.txt","byteSize":1,"typeIdentifier":"public.text","upload":{"waiting":{}}}"#
        let a = try JSONDecoder().decode(DraftAttachment.self, from: Data(old.utf8))
        #expect(a.refText == nil)
        var link = a; link.kind = .link; link.refText = "@url:https://a.co"
        let back = try JSONDecoder().decode(DraftAttachment.self, from: JSONEncoder().encode(link))
        #expect(back == link)
    }
}

struct SteerRuleTests {
    private func msg(_ text: String, hidden: Bool = false) -> QueuedMessage { QueuedMessage(id: "q", text: text, hidden: hidden) }

    @Test func steerableTextOnly() {
        #expect(SteerRule.steerable(msg("also update the README")))
        #expect(!SteerRule.steerable(msg("   ")))
        #expect(!SteerRule.steerable(msg("/help")))
        #expect(!SteerRule.steerable(msg("/model sonnet")))
        #expect(SteerRule.steerable(msg("see /etc/hosts")))
        #expect(!SteerRule.steerable(msg("x", hidden: true)))
        var withFile = msg("look")
        withFile.attachments = [DraftAttachment(id: "a", kind: .file, name: "a.txt", localFile: "a/a.txt", byteSize: 1, pixelWidth: nil,
                                                pixelHeight: nil, typeIdentifier: "public.text", upload: .waiting)]
        #expect(!SteerRule.steerable(withFile))
    }

    @Test func slashRule() {
        #expect(SteerRule.isSlashCommand("/new"))
        #expect(SteerRule.isSlashCommand("/model x"))
        #expect(!SteerRule.isSlashCommand("/usr/bin"))
        #expect(!SteerRule.isSlashCommand("hello /new"))
    }
}

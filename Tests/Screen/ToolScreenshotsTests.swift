// Ports of the web's `tool-screenshots.test.ts` and the screenshot cases of `image-zoom.test.ts`
// (docs/spec/3x-screen.md §5.3).

import Foundation
import Testing
@testable import HermesHQNative

private let folder = "/h/.hermes/cache/images"

private actor ListCounter {
    var hits = 0
    var answer: Set<String>?
    init(_ answer: Set<String>?) { self.answer = answer }
    func list() -> Set<String>? { hits += 1; return answer }
    func set(_ next: Set<String>?) { answer = next }
}

@MainActor struct ToolScreenshotsTests {
    @Test func readsTheSavedPathOfScreenToolsOnly() {
        let text = "capture mode=som 1920x1080\n  (shareable screenshot saved to \(folder)/computer_use_1.png)"
        #expect(ToolScreenshots.restored(tool: "computer_use", result: .string(text)) == "\(folder)/computer_use_1.png")
        #expect(ToolScreenshots.restored(tool: "browser_vision", result: .string("ok. Screenshot path: \(folder)/b.png")) == "\(folder)/b.png")
        #expect(ToolScreenshots.restored(tool: "terminal", result: .string(text)) == "")
        #expect(ToolScreenshots.isScreenshotTool("computer_use"))
        #expect(ToolScreenshots.isScreenshotTool("computer_use_preview"))
        #expect(ToolScreenshots.isScreenshotTool("browser_click"))
        #expect(!ToolScreenshots.isScreenshotTool("read_file"))
        #expect(!ToolScreenshots.isScreenshotTool(nil))
    }

    @Test func aMultimodalResultGivesItsInlineImageThenItsPath() {
        let inline: JSONValue = ["_multimodal": true, "content": [["type": "text", "text": "clicked"],
                                                                 ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]]]
        #expect(ToolScreenshots.multimodalToolImage(inline) == "data:image/png;base64,AAAA")
        #expect(ToolScreenshots.multimodalToolImage(["content": [["image_url": "DATA:image/jpeg;base64,BB"]]]) == "DATA:image/jpeg;base64,BB")
        #expect(ToolScreenshots.multimodalToolImage(["meta": ["screenshot_path": "/Users/x/.hermes/cache/images/computer_use_1.png"]])
                == "/Users/x/.hermes/cache/images/computer_use_1.png")
        #expect(ToolScreenshots.multimodalToolImage(["text_summary": "Clicked OK; shareable screenshot saved to /h/.hermes/cache/images/computer_use_2.jpg"])
                == "/h/.hermes/cache/images/computer_use_2.jpg")
        #expect(ToolScreenshots.multimodalToolImage(["output": "Screenshot path: /h/.hermes/cache/screenshots/browser_screenshot_3.png"])
                == "/h/.hermes/cache/screenshots/browser_screenshot_3.png")
        #expect(ToolScreenshots.multimodalToolImage(["content": [["type": "text", "text": "no image"]]]) == "")
        #expect(ToolScreenshots.multimodalToolImage(nil) == "")
        #expect(ToolScreenshots.multimodalToolImage(.null) == "")
        #expect(ToolScreenshots.multimodalToolImage(42) == "")
    }

    @Test func aStoredResultIsReadAsJSONOrAsItsSummary() {
        let summary = "Clicked Save.\n(shareable screenshot saved to /Users/x/.hermes/profiles/ivy/cache/images/computer_use_ab12.png)"
        #expect(ToolScreenshots.storedScreenshot(.string(summary)) == "/Users/x/.hermes/profiles/ivy/cache/images/computer_use_ab12.png")
        let json = #"{"mode":"ax","summary":"no image","screenshot_path":"/h/.hermes/cache/images/computer_use_c.png"}"#
        #expect(ToolScreenshots.storedScreenshot(.string(json)) == "/h/.hermes/cache/images/computer_use_c.png")
        #expect(ToolScreenshots.storedScreenshot(.string("Looked at the page. Screenshot path: /h/.hermes/cache/screenshots/browser_screenshot_9.png"))
                == "/h/.hermes/cache/screenshots/browser_screenshot_9.png")
        #expect(ToolScreenshots.storedScreenshot(["text_summary": "shareable screenshot saved to /h/c.jpg"]) == "/h/c.jpg")
        #expect(ToolScreenshots.storedScreenshot(.string("clicked element #4")) == "")
        #expect(ToolScreenshots.storedScreenshot(nil) == "")
        #expect(ToolScreenshots.storedScreenshot(.string("{not json screenshot saved to /h/x.webp")) == "/h/x.webp")
        #expect(ToolScreenshots.savedScreenshot("SCREENSHOT SAVED TO   /h/UP.JPEG now") == "/h/UP.JPEG")
        #expect(ToolScreenshots.savedScreenshot("screenshot saved to /h/x.gif") == "")
    }

    @Test func aLiveResultPrefersItsOwnImageThenItsTextThenItsSummary() {
        let result: JSONValue = ["content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]],
                                 "meta": ["screenshot_path": "/h/a.png"]]
        #expect(ToolScreenshots.liveSource(result: result, resultText: "screenshot saved to /h/b.png", summary: nil) == "data:image/png;base64,AAAA")
        #expect(ToolScreenshots.liveSource(result: nil, resultText: "screenshot saved to /h/b.png", summary: "screenshot saved to /h/c.png") == "/h/b.png")
        #expect(ToolScreenshots.liveSource(result: .string("nothing"), resultText: nil, summary: "screenshot saved to /h/c.png") == "/h/c.png")
        #expect(ToolScreenshots.liveSource(result: nil, resultText: nil, summary: nil) == "")
    }

    @Test func namesAndKindsOfSources() {
        #expect(ToolScreenshot(source: "/h/.hermes/cache/shot-0007.png").fileName == "shot-0007.png")
        #expect(ToolScreenshot(source: #"C:\Users\x\shots\a.png"#).fileName == "a.png")
        #expect(ToolScreenshot(source: "data:image/png;base64,AAAA").isInline)
        #expect(!ToolScreenshot(source: "/h/a.png").isInline)
        #expect(ToolScreenshots.isRemote("https://example.com/a.png"))
        #expect(ToolScreenshots.isRemote("BLOB:abc"))
        #expect(!ToolScreenshots.isRemote("/h/a.png"))
        #expect(ToolScreenshots.expiredOutput("Clicked Save") == "This screenshot has expired: the gateway keeps only its 20 most recent screenshots.\n\nClicked Save")
        #expect(ToolScreenshots.expiredOutput(nil) == ToolScreenshots.expiredNote)
    }

    @Test func aListingAnswerIsReadAsNamesOrAsNothing() {
        #expect(ToolScreenshots.names(inListing: Data(#"{"entries":[{"name":"a.png"},{"name":"b.png"}]}"#.utf8)) == ["a.png", "b.png"])
        #expect(ToolScreenshots.names(inListing: Data(#"{"entries":[]}"#.utf8)) == [])
        #expect(ToolScreenshots.names(inListing: Data(#"{"error":"No such folder","entries":[]}"#.utf8)) == nil)
        #expect(ToolScreenshots.names(inListing: Data(#"{"ok":true}"#.utf8)) == nil)
        #expect(ToolScreenshots.names(inListing: Data("<html>".utf8)) == nil)
    }

    // MARK: The step's screenshot and the transcript cache

    @Test func aStepKeepsThePathWhenTheResultCarriesBothAndTheInlinePictureOnlyWithoutOne() {
        let both: JSONValue = ["content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]],
                               "meta": ["screenshot_path": "/Users/x/.hermes/screenshots/shot-0008.png"]]
        #expect(ToolScreenshots.stepScreenshot(result: both, resultText: nil, summary: nil) == ToolScreenshot(source: "/Users/x/.hermes/screenshots/shot-0008.png"))
        let inlineOnly: JSONValue = ["content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]]]
        #expect(ToolScreenshots.stepScreenshot(result: inlineOnly, resultText: nil, summary: nil)?.isInline == true)
        #expect(ToolScreenshots.stepScreenshot(result: inlineOnly, resultText: nil, summary: "Clicked. Screenshot saved to /h/s.png")?.source == "/h/s.png")
        let huge: JSONValue = ["content": [["image_url": .string("data:image/png;base64," + String(repeating: "A", count: ToolScreenshots.maxInlineStep))]]]
        #expect(ToolScreenshots.stepScreenshot(result: huge, resultText: nil, summary: nil) == nil)
        // A stored row: the summary text, or the JSON text of the envelope.
        #expect(ToolScreenshots.stepScreenshot(result: "Clicked Save. Shareable screenshot saved to /Users/x/.hermes/screenshots/shot-0007.png",
                                               resultText: nil, summary: nil)?.source == "/Users/x/.hermes/screenshots/shot-0007.png")
        #expect(ToolScreenshots.stepScreenshot(result: .string(#"{"summary":"ok","meta":{"screenshot_path":"/h/m.png"}}"#), resultText: nil, summary: nil)?.source == "/h/m.png")
        #expect(ToolScreenshots.stepScreenshot(result: "clicked element #4", resultText: nil, summary: nil) == nil)
    }

    @Test func theTranscriptCacheKeepsThePathAndTheExpiredMarkButNeverAnInlinePicture() throws {
        var path = ToolDetail(), expired = ToolDetail(), inline = ToolDetail(), plain = ToolDetail()
        path.screenshot = ToolScreenshot(source: "/Users/x/.hermes/screenshots/shot-0007.png")
        expired.screenshot = ToolScreenshot(source: "/Users/x/.hermes/screenshots/shot-0001.png", expired: true, capturedAt: 1_760_000_123.5)
        inline.screenshot = ToolScreenshot(source: "data:image/png;base64,AAAA")
        plain.failed = true
        var meta = MessageMeta()
        meta.tools = ["a": path, "b": expired, "c": inline, "d": plain]
        let message = ChatMessage(id: "m1", role: .assistant, parts: [.text("done")], timestamp: Date(), rowId: 7)
        let data = TranscriptEntry(messages: [message], meta: ["m1": meta], savedAt: Date()).encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains("data:image"))
        let back = try #require(try TranscriptEntry.decode(data).meta["m1"])
        #expect(back.tools["a"]?.screenshot == ToolScreenshot(source: "/Users/x/.hermes/screenshots/shot-0007.png"))
        #expect(back.tools["b"]?.screenshot == ToolScreenshot(source: "/Users/x/.hermes/screenshots/shot-0001.png", expired: true,
                                                               capturedAt: 1_760_000_123.5))
        #expect(back.tools["c"]?.screenshot == nil)
        #expect(back.tools["d"]?.screenshot == nil)
        #expect(back.tools["d"]?.failed == true)
        #expect(inline.slimmedForCache(keepDiff: false).screenshot == nil)
        #expect(path.slimmedForCache(keepDiff: false).screenshot == path.screenshot)
    }

    // MARK: Expiry

    @Test func aPrunedCaptureIsExpiredOnceWithOneListingPerFolder() async {
        let counter = ListCounter(["computer_use_2.png"])
        let expiry = ScreenshotExpiry { _ in await counter.list() }
        let now = 2_000_000.0
        #expect(await expiry.check(toolCallId: "call-1", path: "\(folder)/computer_use_1.png", completedAt: 1_000, now: now))
        #expect(await !expiry.check(toolCallId: "call-2", path: "\(folder)/computer_use_2.png", completedAt: 1_000, now: now))
        // Native keeps the answer (the web keeps it in the card's own state): asking again costs no listing.
        #expect(await expiry.check(toolCallId: "call-1", path: "\(folder)/computer_use_1.png", completedAt: 1_000, now: now))
        #expect(await expiry.settled("call-1") == true)
        #expect(await expiry.settled("call-2") == false)
        #expect(await expiry.settled("call-3") == nil)
        #expect(await counter.hits == 1)
    }

    @Test func aNewCaptureIsNeverExpiredFromAnOlderListingNorFromAnUnreadableFolder() async {
        let first = ListCounter(["computer_use_old.png"])
        let expiry = ScreenshotExpiry { directory in
            if directory == "/elsewhere" { return nil }
            if directory == "/empty" { return [] }
            return await first.list()
        }
        let now = 3_000_000.0
        #expect(await !expiry.check(toolCallId: "a", path: "\(folder)/computer_use_old.png", completedAt: now - 100, now: now))
        #expect(await first.hits == 1)
        // The capture happened after that listing: the folder is listed again, and the file is there now.
        await first.set(["computer_use_old.png", "computer_use_new.png"])
        #expect(await !expiry.check(toolCallId: "b", path: "\(folder)/computer_use_new.png", completedAt: (now + 5) * 1000, now: now + 6))
        #expect(await first.hits == 2)
        #expect(await !expiry.check(toolCallId: "c", path: "/elsewhere/computer_use_x.png", completedAt: 1, now: now))
        #expect(await !expiry.check(toolCallId: "d", path: "/empty/computer_use_x.png", completedAt: 1, now: now))
        #expect(await !expiry.check(toolCallId: "e", path: "data:image/png;base64,AAAA", completedAt: 1, now: now))
        #expect(await !expiry.check(toolCallId: nil, path: "\(folder)/x.png", completedAt: 1, now: now))
        #expect(await !expiry.check(toolCallId: "f", path: "no-folder.png", completedAt: 1, now: now))
        #expect(await expiry.settled("c") == nil)
        #expect(await expiry.settled("d") == nil)
        #expect(await first.hits == 2)
    }

    @Test func anUnreadableListingAsksAgainLaterAndThenSettles() async {
        let counter = ListCounter(nil)
        let expiry = ScreenshotExpiry { _ in await counter.list() }
        #expect(await !expiry.check(toolCallId: "t1", path: "\(folder)/gone.png", completedAt: 1, now: 1_000))
        #expect(await !expiry.check(toolCallId: "t1", path: "\(folder)/gone.png", completedAt: 1, now: 1_010))
        #expect(await counter.hits == 1)                      // at most one listing per 30 s for one step
        await counter.set(["other.png"])
        #expect(await expiry.check(toolCallId: "t1", path: "\(folder)/gone.png", completedAt: 1, now: 1_040))
        #expect(await expiry.check(toolCallId: "t1", path: "\(folder)/gone.png", completedAt: 1, now: 1_100))
        #expect(await counter.hits == 2)
    }

    @Test func aListingIsReusedForAMinuteThenReadAgain() async {
        let counter = ListCounter(["a.png", "b.png", "c.png"])
        let expiry = ScreenshotExpiry { _ in await counter.list() }
        for (index, name) in ["a.png", "b.png", "c.png"].enumerated() {
            #expect(await !expiry.check(toolCallId: "s\(index)", path: "\(folder)/\(name)", completedAt: 10, now: 5_000 + Double(index)))
        }
        #expect(await counter.hits == 1)
        #expect(await !expiry.check(toolCallId: "late", path: "\(folder)/a.png", completedAt: 10, now: 5_061))
        #expect(await counter.hits == 2)
    }

    /// The step carries its own capture time (the stored row's, or the live result's arrival), so a listing read
    /// before the capture is never reused for it, and one read after it costs no second request.
    @Test func aStepCarriesItsCaptureTimeSoAnOlderListingIsNotReusedForIt() async {
        let stored = ToolScreenshots.stepScreenshot(result: .string("screenshot saved to \(folder)/new.png"), resultText: nil,
                                                    summary: nil, at: 5_030)
        #expect(stored == ToolScreenshot(source: "\(folder)/new.png", capturedAt: 5_030))
        let counter = ListCounter(["old.png"])
        let expiry = ScreenshotExpiry { _ in await counter.list() }
        #expect(await !expiry.check(toolCallId: "old", path: "\(folder)/old.png", completedAt: 4_000, now: 5_000))
        await counter.set(["old.png", "new.png"])
        // Captured at 5,030: the listing of 5,000 predates it, so the folder is read again and the file is there.
        #expect(await !expiry.check(toolCallId: "new", path: "\(folder)/new.png", completedAt: stored?.capturedAt, now: 5_040))
        #expect(await counter.hits == 2)
        // A step from before that listing reuses it: one request per folder per minute, however many steps are opened.
        for index in 0..<30 {
            _ = await expiry.check(toolCallId: "gone-\(index)", path: "\(folder)/gone-\(index).png", completedAt: 4_000, now: 5_041)
        }
        #expect(await counter.hits == 2)
        #expect(await expiry.settled("gone-7") == true)
    }

    @Test func whatItRemembersIsBounded() async {
        let expiry = ScreenshotExpiry { _ in ["kept.png"] }
        for index in 0..<2_300 {
            _ = await expiry.check(toolCallId: "call-\(index)", path: "/dir-\(index % 90)/kept.png", completedAt: 1, now: 10_000 + Double(index) * 0.001)
        }
        let held = await expiry.held
        #expect(held.listings <= 64)
        #expect(held.noted <= 2_000)
        #expect(held.asked == 0)
    }
}

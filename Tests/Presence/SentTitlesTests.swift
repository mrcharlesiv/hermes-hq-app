// [presence] A titled request keeps its title when its stored row comes back (docs/spec/3x-presence.md §10, G1).

import Foundation
import Testing
@testable import HermesHQNative

struct SentTitlesTests {
    private func user(_ id: String, _ text: String) -> ChatMessage {
        ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: Date(timeIntervalSince1970: 1), rowId: 7)
    }

    @Test func aStoredPromptShowsItsTitle() {
        var titles = SentTitles()
        #expect(titles.isEmpty)
        let prompt = "Please install the plugin.\n\n1. First step.\n2. Second   step."
        titles.note(text: prompt, title: "Install the plugin.")
        let stored = [
            user("a", "Hello"),
            user("b", "Please install the plugin. 1. First step. 2. Second step."),       // whitespace as the gateway kept it
            ChatMessage(id: "c", role: .assistant, parts: [.text(prompt)], timestamp: Date(), rowId: 9),
        ]
        let shown = titles.applied(to: stored)
        #expect(shown[0].plainText == "Hello")
        #expect(shown[1].plainText == "Install the plugin." && shown[1].id == "b" && shown[1].rowId == 7)
        #expect(shown[2].plainText == prompt, "only the person's own row is titled")
        #expect(titles.title(forStored: "Please install the plugin") == nil, "the whole prompt, not a part of it")
    }

    @Test func nothingNotedChangesNothingAndTheListIsBounded() {
        var titles = SentTitles()
        let rows = [user("a", "Hello")]
        #expect(titles.applied(to: rows) == rows)
        titles.note(text: "", title: "Empty")
        titles.note(text: "Same", title: "Same")
        titles.note(text: "No title", title: "")
        #expect(titles.isEmpty)
        for i in 0..<(SentTitles.limit + 4) { titles.note(text: "prompt \(i)", title: "title \(i)") }
        #expect(titles.title(forStored: "prompt 0") == nil && titles.title(forStored: "prompt 3") == nil)
        #expect(titles.title(forStored: "prompt 4") == "title 4")
        #expect(titles.title(forStored: "prompt \(SentTitles.limit + 3)") == "title \(SentTitles.limit + 3)")
        titles.note(text: "prompt 5", title: "renamed")
        #expect(titles.title(forStored: "prompt 5") == "renamed" && titles.title(forStored: "prompt 4") == "title 4")
    }

    /// A title that came back to the field (a refused send, a queue row taken out) stands for its request again.
    @Test func aTitleStandsForItsRequest() {
        var titles = SentTitles()
        let prompt = "Please install the plugin.\n\n1. First step.\n2. Second   step."
        titles.note(text: prompt, title: "Install the plugin.")
        #expect(titles.prompt(forTitle: "Install the plugin.") == prompt, "the request as it was sent, line breaks and all")
        #expect(titles.prompt(forTitle: "  Install the\nplugin.  ") == prompt, "whitespace aside")
        #expect(titles.prompt(forTitle: "Install the plugin") == nil, "the whole title only")
        #expect(titles.prompt(forTitle: "install the plugin.") == nil, "and exactly")
        #expect(titles.prompt(forTitle: "") == nil)
        // Dropped with its title when the list is full.
        for i in 0..<SentTitles.limit { titles.note(text: "prompt \(i)", title: "title \(i)") }
        #expect(titles.prompt(forTitle: "Install the plugin.") == nil)
        #expect(titles.prompt(forTitle: "title 0") == "prompt 0")
    }

    /// The browser plugin's request is the app's one fixed pair: its title is short, and the stored prompt (which names
    /// the plugin's old wire name) never reaches the bubble.
    @MainActor @Test func theBrowserRequestShowsItsTitleWhereverItIsRead() {
        var titles = SentTitles()
        titles.note(text: BrowserSetupPrompt.text, title: MainBotRequest.browserTitle)
        titles.note(text: BrowserSetupPrompt.text, title: MainBotRequest.browserTitle)          // noted at every sign-in
        let stored = [user("a", BrowserSetupPrompt.text), user("b", ChatText.flat(BrowserSetupPrompt.text))]
        let shown = titles.applied(to: stored)
        #expect(shown.map(\.plainText) == [MainBotRequest.browserTitle, MainBotRequest.browserTitle])
        #expect(!shown.contains { $0.plainText.localizedCaseInsensitiveContains("dispatch") })
        #expect(titles.prompt(forTitle: MainBotRequest.browserTitle) == BrowserSetupPrompt.text)
    }
}

/// The title in the chat itself (docs/spec/3x-presence.md §10, DECISION D29): from the cache at the first paint, and out
/// again as the whole request when its title comes back to the field.
@MainActor @Suite(.serialized) struct TitledRequestChatTests {
    private func noted() -> SentTitles {
        let saved = LiveChatSession.sentTitles
        LiveChatSession.sentTitles.note(text: BrowserSetupPrompt.text, title: MainBotRequest.browserTitle)
        return saved
    }

    /// The gateway refuses the request: the field gets the title back (never the long prompt), and sending that from
    /// the main bot's field sends the whole request again, under the same title.
    @Test func aRefusedRequestComesBackAsItsTitleAndGoesOutWholeAgain() async throws {
        let saved = noted()
        defer { LiveChatSession.sentTitles = saved }
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw RPCError(code: 5000, message: "Refused for the test", data: nil) }
            return [:]
        }
        s.send(BrowserSetupPrompt.text, display: MainBotRequest.browserTitle)
        #expect(await waitUntil { !h.drafts.isEmpty })
        #expect(h.drafts.first?.0 == MainBotRequest.browserTitle, "the title comes back, not the long prompt")
        #expect(h.client.calls("prompt.submit").first?.params["text"]?.string == BrowserSetupPrompt.text)

        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming", "user_row_id": 3000] : [:] }
        s.send(MainBotRequest.browserTitle)                         // the person taps Send on what came back
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["text"]?.string == BrowserSetupPrompt.text,
                "the title goes out as the request it stands for")
        #expect(h.lastUser?.plainText == MainBotRequest.browserTitle, "and its bubble still shows the title")
        // Anything else typed is sent as typed.
        #expect(LiveChatSession.sentTitles.prompt(forTitle: "Install the browser plugin") == nil)
    }

    /// The request is put in the main bot's chat while that chat is still opening (the gateway away, or slow): the send
    /// joins the open's `session.resume`. It was resumed before the open had bound the runtime the resume named, found
    /// none and was refused with "Couldn’t reach this chat." (seen in S13: the request never went out when the gateway
    /// came back). It goes out once, on the one resume.
    @Test func aRequestPutInAChatThatIsStillOpeningGoesOut() async throws {
        let saved = noted()
        defer { LiveChatSession.sentTitles = saved }
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let resumed = try ChatFixtures.json("perf-resume.json")["result"] ?? .null
        h.client.onCall { method, _ in
            switch method {
            case "session.resume":
                try? await Task.sleep(for: .milliseconds(300))      // the gateway takes its time
                return resumed
            case "prompt.submit": return ["status": "streaming", "user_row_id": 3000]
            case "session.events.since": return ["events": [], "latest_seq": 0, "truncated": false, "epoch": "fixture-epoch"]
            default: return [:]
            }
        }
        let s = h.make()
        s.start()
        #expect(await waitUntil { h.client.calls("session.resume").count == 1 })
        #expect(s.runtimeSessionId == nil, "the open's resume is still on its way")
        s.send(BrowserSetupPrompt.text, display: MainBotRequest.browserTitle)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 1 }, "the request goes out when the resume answers")
        #expect(h.drafts.isEmpty, "nothing is handed back to the field: \(h.drafts)")
        #expect(!s.messages.contains { $0.error != nil }, "and no error card")
        #expect(h.lastUser?.plainText == MainBotRequest.browserTitle)
        #expect(h.client.calls("session.resume").count == 1, "one resume, shared")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(h.client.calls("prompt.submit").count == 1, "once")
    }

    /// The chat opens from its cache before the gateway answers: a cached row that holds the stored prompt paints as
    /// its title (after a relaunch, or when another device sent it).
    @Test func theCachedPaintShowsTheTitle() throws {
        let saved = noted()
        defer { LiveChatSession.sentTitles = saved }
        let h = try ChatHarness()
        let s = h.make()
        let rows = [
            ChatMessage(id: "row-1", role: .user, parts: [.text(BrowserSetupPrompt.text)], timestamp: Date(timeIntervalSince1970: 10), rowId: 1),
            ChatMessage(id: "row-2", role: .assistant, parts: [.text("Installed.")], timestamp: Date(timeIntervalSince1970: 11), rowId: 2),
        ]
        s.applyCachedPaint(TranscriptEntry(messages: rows, meta: [:], savedAt: Date(), partial: false, stale: false))
        #expect(s.messages.first { $0.role == .user }?.plainText == MainBotRequest.browserTitle)
        #expect(!s.messages.contains { $0.plainText.localizedCaseInsensitiveContains("dispatch") })
    }
}

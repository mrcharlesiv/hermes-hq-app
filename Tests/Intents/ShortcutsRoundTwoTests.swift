// [shortcuts] Add Task, Run Job, Talk to Bot and New Chat's first message (owner 2026-11-20).

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ShortcutsRoundTwoTests {
    private let account = "http://127.0.0.1:9920\nfixture"

    @Test func newChatLinkCarriesItsFirstMessage() throws {
        let scheme = AppIdentity.current.urlScheme
        let url = try #require(URL(string: "\(scheme)://new-chat?bot=app&message=Fix%20the%20build%20please"))
        #expect(NewChatLink.parse(DeepLink.parse(url, scheme: scheme)) == NewChatLink(bot: "app", project: nil, message: "Fix the build please", send: true))
        let draft = try #require(URL(string: "\(scheme)://new-chat?bot=app&message=hello&send=0"))
        #expect(NewChatLink.parse(DeepLink.parse(draft, scheme: scheme))?.send == false)
        let blank = try #require(URL(string: "\(scheme)://new-chat?bot=app&message=%20%20"))
        #expect(NewChatLink.parse(DeepLink.parse(blank, scheme: scheme))?.message == nil, "blanks are no message")
        // What it writes, it reads back: a message with "&", "=", "+", "#" and a draft-only send.
        for link in [NewChatLink(bot: "app", project: "/srv/app", message: "One & two = 1+1 #three?", send: false),
                     NewChatLink(bot: "app", project: nil, message: "Go", send: true)] {
            let written = try #require(link.url(scheme: scheme))
            #expect(NewChatLink.parse(DeepLink.parse(written, scheme: scheme)) == link)
        }
        // A link's words are one line (links refuse control characters); the Shortcuts action passes lines as typed.
        let lines = try #require(NewChatLink(bot: "app", project: nil, message: "a\nb").url(scheme: scheme))
        #expect(NewChatLink.parse(DeepLink.parse(lines, scheme: scheme)) == nil)
    }

    @Test func aShortcutsTaskIsTheNewTaskSheetsBody() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let due = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 9, minute: 30))!
        // Your own: no bot, whatever "who" said.
        let mine = try JSONValue.parse(ShortcutTaskBody.make(title: "Renew the domain", bot: nil, who: .bot, due: due, hasTime: false,
                                                             notes: "  ", calendar: calendar))
        #expect(mine["title"]?.string == "Renew the domain")
        #expect(mine["who"]?.string == "me")
        #expect(mine["bot"] == .null)
        #expect(mine["due"]?.string == "2026-11-21")
        #expect(mine["notes"]?.string == "")
        #expect(mine["source"]?["kind"]?.string == "app")
        // A bot's: who and bot as picked, a due time with its offset.
        let theirs = try JSONValue.parse(ShortcutTaskBody.make(title: "Draft the post", bot: "app", who: .bot, due: due, hasTime: true,
                                                               notes: "For Monday", calendar: calendar))
        #expect(theirs["who"]?.string == "bot")
        #expect(theirs["bot"]?.string == "app")
        #expect(theirs["due"]?.string == "2026-11-21T09:30:00-06:00")
        #expect(theirs["notes"]?.string == "For Monday")
        let together = try JSONValue.parse(ShortcutTaskBody.make(title: "Plan", bot: "app", who: .together, due: nil, hasTime: false, notes: ""))
        #expect(together["who"]?.string == "together" && together["due"] == .null)
    }

    @Test func storesTheJobsListForTheRunJobPicker() {
        var nightly = CronJob(id: "j1")
        nightly.profile = "app"
        var weekly = CronJob(id: "j2")
        weekly.profileName = "default"
        let records = JobShortcutCatalog.records([(nightly, "Nightly  build"), (weekly, "Weekly review"), (nightly, "Twice"),
                                                  (CronJob(id: ""), "No id")], account: account)
        #expect(records == [JobShortcutRecord(key: "app|j1", id: "j1", owner: "app", name: "Nightly build", account: account),
                            JobShortcutRecord(key: "default|j2", id: "j2", owner: "default", name: "Weekly review", account: account)])
        let box = IntentsDefaults()
        #expect(JobShortcutCatalog.store(records, box.defaults))
        #expect(!JobShortcutCatalog.store(records, box.defaults), "the same jobs are not written twice")
        #expect(JobShortcutCatalog.jobs(box.defaults) == records)
        JobShortcutCatalog.clear(box.defaults)
        #expect(JobShortcutCatalog.jobs(box.defaults).isEmpty)
    }

    @Test func aRunsResultIsItsNewestRunsWords() {
        var old = CronRun(id: "r1"); old.startedAt = 100; old.preview = "Yesterday's digest"
        var new = CronRun(id: "r2"); new.startedAt = 1_000; new.preview = "  Today: 3 PRs merged  "
        #expect(JobShortcutCatalog.resultText(runs: [old, new], startedAfter: 990, job: "Digest") == "Today: 3 PRs merged")
        var titled = CronRun(id: "r3"); titled.startedAt = 1_000; titled.title = "Digest for Friday"
        #expect(JobShortcutCatalog.resultText(runs: [titled], startedAfter: 990, job: "Digest") == "Digest for Friday")
        // Only an older run: nothing new to hand on.
        #expect(JobShortcutCatalog.resultText(runs: [old], startedAfter: 990, job: "Digest")
                == "“Digest” ran. Its result is in the job’s Run History in Hermes HQ.")
    }

    @Test func aRefusalIsTheGatewaysOwnReason() {
        let detail = ShareRESTAnswer(status: 422, data: Data(#"{"detail":"title is required"}"#.utf8))
        #expect(ShortcutGateway.refusal(detail, what: "the task") == "title is required")
        let nested = ShareRESTAnswer(status: 409, data: Data(#"{"detail":{"message":"Job is already running"}}"#.utf8))
        #expect(ShortcutGateway.refusal(nested, what: "the job") == "Job is already running")
        #expect(ShortcutGateway.refusal(ShareRESTAnswer(status: 409, data: Data()), what: "the job") == "That’s already running.")
        #expect(ShortcutGateway.refusal(ShareRESTAnswer(status: 404, data: Data()), what: "Tasks").contains("Update the Hermes HQ add-on"))
        #expect(ShortcutGateway.refusal(ShareRESTAnswer(status: 500, data: Data("<html>".utf8)), what: "the task")
                == "Your gateway didn’t accept the task (500).")
    }

    @Test func shortcutDefaultBotDefaultsToAskAndResolvesConfiguredBot() {
        let box = IntentsDefaults()
        let key1 = VoiceBotCatalog.key(profile: "default")
        let key2 = VoiceBotCatalog.key(profile: "chief")
        let records = [
            VoiceBotRecord(id: VoiceBotCatalog.id(account: account, key: key1), name: "Hermes", key: key1, account: account),
            VoiceBotRecord(id: VoiceBotCatalog.id(account: account, key: key2), name: "Chief", key: key2, account: account),
        ]
        VoiceBotCatalog.store(records, box.defaults)
        // Default: nil (Ask Every Time).
        #expect(ShortcutDefaultBot.profile(box.defaults) == nil)
        #expect(ShortcutDefaultBot.resolved(box.defaults) == nil)
        // Set to a bot in the catalog: resolves cleanly.
        ShortcutDefaultBot.setProfile("chief", box.defaults)
        #expect(ShortcutDefaultBot.profile(box.defaults) == "chief")
        #expect(ShortcutDefaultBot.resolved(box.defaults)?.name == "Chief")
        // Bot no longer in catalog: falls back to nil (Ask Every Time).
        ShortcutDefaultBot.setProfile("removed", box.defaults)
        #expect(ShortcutDefaultBot.resolved(box.defaults) == nil)
        // Clear back to Ask Every Time.
        ShortcutDefaultBot.setProfile(nil, box.defaults)
        #expect(ShortcutDefaultBot.profile(box.defaults) == nil)
    }
}

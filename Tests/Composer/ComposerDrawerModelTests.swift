// [composer-drawers] Unit checks for the slash drawer and the @ drawer (docs/spec/3x-composer.md §9, §10). No network.

import Foundation
import Testing
@testable import HermesHQNative

private typealias M = ComposerDrawerModel

private func utf16(_ s: String) -> Int { (s as NSString).length }

@Suite("Composer drawers · triggers (§9.1, §10.1)")
struct ComposerDrawerTriggerTests {
    /// (text, caret or nil for the end, expected kind: "closed" | "slash" | "skill:<word>" | "at:<word>")
    @Test(arguments: [
        ("", nil, "closed"),
        ("/", nil, "slash"),
        ("/m", nil, "slash"),
        ("/model", nil, "slash"),
        ("/reasoning h", nil, "slash"),
        ("/reasoning ", nil, "slash"),
        ("/my-skill_2", nil, "slash"),
        ("//", nil, "closed"),
        ("/1abc", nil, "closed"),
        ("/ab/cd", nil, "closed"),
        ("/usr/local/bin", nil, "closed"),
        (" /model", nil, "skill:/model"),
        ("hi /rel", nil, "skill:/rel"),
        ("hi /", nil, "skill:/"),
        ("hi/rel", nil, "closed"),
        ("and/or", nil, "closed"),
        ("hi /9", nil, "closed"),
        ("http://x.com/a", nil, "closed"),
        ("/model", 2, "closed"),
        ("/model x", 3, "closed"),
        ("hi /rel more", 7, "skill:/rel"),
        ("@", nil, "at:"),
        ("@fi", nil, "at:fi"),
        ("@file:src/", nil, "at:file:src/"),
        ("look at @ivy", nil, "at:ivy"),
        ("me@example.com", nil, "closed"),
        ("mail me@ex", nil, "closed"),
        ("@@", nil, "closed"),
        ("hi @ivy and", nil, "closed"),
        ("hi @ivy and", 7, "at:ivy"),
        ("hi @ivy and", 5, "at:i"),
        ("/reasoning @fi", nil, "at:fi"),
        ("日本語 @fi", nil, "at:fi"),
        ("日本語/fi", nil, "closed"),
        ("日本語 /fi", nil, "skill:/fi"),
        ("👋🏽 @sa", nil, "at:sa"),
        ("👋🏽 /ch", nil, "skill:/ch"),
        ("\u{3000}@x", nil, "at:x"),
        ("a\n/ch", nil, "skill:/ch"),
        ("a\n@x", nil, "at:x"),
        ("@file:my docs", nil, "closed"),
        ("/m\n", nil, "slash"),
    ] as [(String, Int?, String)])
    func trigger(text: String, caret: Int?, expected: String) {
        let mode = M.mode(text: text, caret: caret ?? utf16(text))
        let kind: String
        switch mode {
        case .closed: kind = "closed"
        case .slash(let t): kind = "slash"; #expect(t == text)
        case .skill(let w, let r): kind = "skill:\(w)"; #expect((text as NSString).substring(with: r) == w)
        case .at(let w, let r): kind = "at:\(w)"; #expect((text as NSString).substring(with: r) == "@" + w)
        }
        #expect(kind == expected)
    }

    @Test func rangesAreUTF16() {
        let text = "👋🏽 @sa"
        guard case .at(_, let range) = M.mode(text: text, caret: utf16(text)) else { Issue.record("no @"); return }
        #expect(range.location == utf16("👋🏽 "))
        #expect(range.length == 3)
    }
}

@Suite("Composer drawers · the slash drawer (§9.2–9.4)")
struct ComposerDrawerSlashTests {
    let catalog = MenusCommandsTests.fixtureCatalog()

    private func titles(_ sections: [M.Section]?) -> [String] { (sections ?? []).flatMap(\.rows).map(\.title) }

    @Test func bareSlashShowsTheCatalogWithoutPhoneHiddenOrUnsupported() {
        let s = M.slashSections(text: "/", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: [])
        let t = titles(s)
        #expect(t.contains("/reasoning"))
        #expect(t.contains("/model"))          // the desktop's picker command: the drawer lists it (§9.6 check 2)
        #expect(t.contains("/help"))           // listed in the drawer (the ☰ sheet leaves it out)
        #expect(!t.contains("/debug"))         // phoneHidden
        #expect(t.contains("/new"))            // answered here now (3x-composer §8.2)
        #expect(t.contains("/compress"))       // §8.3
        #expect(!t.contains("/reset") && !t.contains("/compact"))   // aliases are not rows of their own
        #expect(!t.contains("/branch"))        // still no native answer
        #expect(t.contains("/release-notes"))
    }

    /// The drawer's row text (owner 2026-10-27: commands in monospaced Body read "oddly large"): a command is set as
    /// the Commands sheet's rows are, a ref stays monospaced, a chat, a bot, an option or a note is plain.
    @Test func rowTitleFaces() {
        let s = M.slashSections(text: "/", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: [])
        let commandRows = (s ?? []).flatMap(\.rows)
        #expect(!commandRows.isEmpty && commandRows.allSatisfy { M.titleFace($0) == .command })
        #expect(M.titleFace(M.Row(id: "o", title: "high", detail: "", action: .option(prefix: "/reasoning ", text: "high"))) == .plain)
        #expect(M.titleFace(M.Row(id: "m", title: "@file:", detail: "", action: .mention("@file:", range: NSRange(location: 0, length: 1)))) == .ref)
        #expect(M.titleFace(M.Row(id: "p", title: "a.txt", detail: "", action: .mention("@file:src/a.txt", range: NSRange(location: 0, length: 1)),
                                  parent: "src/")) == .ref)
        #expect(M.titleFace(M.Row(id: "b", title: "Ivy", detail: "", action: .mention("@Ivy ", range: NSRange(location: 0, length: 1)),
                                  bot: "ivy")) == .plain)
        #expect(M.titleFace(M.Row(id: "c", title: "Trip planning", detail: "", action: .openChat("c1"))) == .plain)
        #expect(M.titleFace(M.Row(id: "note", title: M.noMatches, detail: "", action: .none)) == .plain)
    }

    /// Favorite / Unfavorite from the drawer (§9.7): only whole-command rows star, under the sheet's "/name" key.
    @Test func favoriteFromTheDrawer() {
        let s = M.slashSections(text: "/sta", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: [])
        let status = try? #require((s ?? []).flatMap(\.rows).first { $0.title == "/status" })
        #expect(status.flatMap(M.favoriteCommand) == "/status")
        #expect(M.favoriteCommand(M.Row(id: "o", title: "high", detail: "", action: .option(prefix: "/reasoning ", text: "high"))) == nil)
        #expect(M.favoriteCommand(M.Row(id: "c", title: "Trip", detail: "", action: .openChat("c1"))) == nil)
        #expect(M.favoriteCommand(M.Row(id: "note", title: M.noMatches, detail: "", action: .none)) == nil)
        #expect(M.favoriteAction(favorited: false).title == "Add to Favorites" && M.favoriteAction(favorited: false).image == "star")
        #expect(M.favoriteAction(favorited: true).title == "Remove from Favorites" && M.favoriteAction(favorited: true).image == "star.slash")
        #expect(M.favoriteAction(favorited: false).short == "Favorite" && M.favoriteAction(favorited: true).short == "Unfavorite")
        // Starred from the drawer (the store the sheet's star writes), Favorites leads the drawer at once.
        let defaults = UserDefaults(suiteName: "hqn.tests.drawer-favorites.\(UUID().uuidString)")!
        let store = CommandFavorites(accountId: "acct-drawer", defaults: defaults)
        store.toggle("/status")
        let starred = M.slashSections(text: "/", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: [],
                                      favorites: store.commands)
        #expect(starred?.first?.title == SlashCatalog.favoritesTitle)
        #expect(starred?.first?.rows.map(\.title) == ["/status"])
        store.toggle("/status")
        let unstarred = M.slashSections(text: "/", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: [],
                                        favorites: store.commands)
        #expect(unstarred?.first?.title != SlashCatalog.favoritesTitle)
    }

    @Test func localFilteringPrefixBeforeContains() {
        let t = titles(M.slashSections(text: "/re", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: []))
        #expect(t.first == "/retry" || t.first == "/reasoning" || t.first == "/resume")
        #expect(t.firstIndex(of: "/release-notes")! < t.count)
        #expect(!t.contains("/new"))
        let contains = titles(M.slashSections(text: "/ason", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: []))
        #expect(contains == ["/reasoning"])
    }

    @Test func noMatchesAndLoading() {
        #expect(titles(M.slashSections(text: "/zzz", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: [])) == [M.noMatches])
        let loading = M.slashSections(text: "/m", catalog: nil, catalogLoading: true, isBotChat: false, remote: nil, recent: [])
        #expect(titles(loading) == [M.loadingCommands])
        #expect(loading?.first?.rows.first?.spinner == true)
        #expect(loading?.first?.rows.first?.tappable == false)
        #expect(M.slashSections(text: "/m", catalog: nil, catalogLoading: false, isBotChat: false, remote: nil, recent: []) == nil)
        // A failed load says so in one line instead of showing nothing.
        let failed = M.slashSections(text: "/m", catalog: nil, catalogLoading: false, catalogFailed: true, isBotChat: false, remote: nil, recent: [])
        #expect(titles(failed) == [M.commandsFailed])
        #expect(failed?.first?.rows.first?.tappable == false)
    }

    /// [mac-audit] #24: an empty catalog says there are no commands, with Check Again, bare or typed.
    @Test func emptyCatalogSaysNoCommands() {
        let empty = CommandsCatalog(json: .object([:]))
        for text in ["/", "/m"] {
            let shown = M.slashSections(text: text, catalog: empty, catalogLoading: false, isBotChat: false, remote: nil, recent: [])
            #expect(titles(shown) == [M.noCommands, M.checkAgain])
            #expect(shown?.first?.rows.first?.tappable == false)
            #expect(shown?.first?.rows.last?.action == .checkAgain)
        }
    }

    @Test func remoteAnswerIsFilteredForThePhone() {
        let answer = M.answer(["items": [["text": "reasoning", "display": "/reasoning", "meta": "Set reasoning", "kind": "command"],
                                         ["text": "debug", "display": "/debug", "meta": "x", "kind": "command"],
                                         ["text": "worktree", "display": "/worktree", "meta": "x", "kind": "command"],
                                         ["text": "new", "display": "/new", "meta": "x", "kind": "command"],
                                         ["text": "pet", "display": "/pet", "meta": "Pet the bot", "kind": "command"],
                                         ["text": "release-notes", "display": "/release-notes", "meta": "x", "kind": "skill"]],
                               "replace_from": 1], asked: "/r")
        let t = titles(M.slashSections(text: "/r", catalog: catalog, catalogLoading: false, isBotChat: false, remote: answer, recent: []))
        #expect(t == ["/reasoning", "/new", "/release-notes"])   // /new is answered here (3x-composer §8.2)
    }

    @Test func optionsUseReplaceFrom() {
        let answer = M.answer(["items": [["text": "high", "display": "high", "meta": ""], ["text": "hide", "meta": ""]], "replace_from": 11],
                              asked: "/reasoning h")
        let s = M.slashSections(text: "/reasoning h", catalog: catalog, catalogLoading: false, isBotChat: false, remote: answer, recent: [])
        #expect(s?.first?.title == "Options")
        guard case .option(let prefix, let text)? = s?.first?.rows.first?.action else { Issue.record("no option"); return }
        #expect(prefix == "/reasoning ")
        let (edit, keep) = M.applyOption(prefix: prefix, text: text)
        #expect(edit.text == "/reasoning high")
        #expect(edit.caret == utf16("/reasoning high"))
        #expect(!keep)
        #expect(M.applyOption(prefix: "/x ", text: "set ").keepOpen)
    }

    @Test func optionPrefixCountsCodePoints() {
        #expect(M.optionPrefix(text: "/title 👋🏽 h", replaceFrom: 10) == "/title 👋🏽 ")
        #expect(M.optionPrefix(text: "/reasoning h", replaceFrom: nil) == "/reasoning ")
        #expect(M.optionPrefix(text: "/reasoning h", replaceFrom: 0) == "/reasoning ")
    }

    @Test func badReplaceFromIsIgnored() {
        #expect(M.answer(["items": [], "replace_from": 99], asked: "/a b").replaceFrom == nil)
        #expect(M.answer(["items": [], "replace_from": 1.5], asked: "/a b").replaceFrom == nil)
        #expect(M.answer(["items": [], "replace_from": -1], asked: "/a b").replaceFrom == nil)
        #expect(M.answer(["items": [], "replace_from": "3"], asked: "/a b").replaceFrom == nil)
        #expect(M.answer(["items": [], "replace_from": 3], asked: "/a b").replaceFrom == 3)
    }

    @Test func malformedItemsAreDropped() {
        let a = M.answer(["items": [["text": 3], ["display": "x"], ["text": ""], ["text": "ok\nnow", "meta": 4]]], asked: "/x")
        #expect(a.items.map(\.text) == ["ok now"])
        #expect(a.items.first?.meta == "")
        #expect(M.answer(nil, asked: "/x").items.isEmpty)
    }

    @Test func argumentStageWithNoOptionsIsClosed() {
        #expect(M.slashSections(text: "/title hello", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: []) == nil)
        let empty = M.answer(["items": []], asked: "/title hello")
        #expect(M.slashSections(text: "/title hello", catalog: catalog, catalogLoading: false, isBotChat: false, remote: empty, recent: []) == nil)
    }

    @Test func resumeOffersRecentChats() {
        let recent = (1...10).map { M.RecentChat(id: "s\($0)", title: "Plan \($0)") }
        let s = M.slashSections(text: "/resume pla", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: recent)
        #expect(s?.first?.title == "Chats")
        #expect(s?.first?.rows.count == 8)
        #expect(s?.first?.rows.first?.action == .openChat("s1"))
        #expect(M.slashSections(text: "/resume zz", catalog: catalog, catalogLoading: false, isBotChat: false, remote: nil, recent: recent) == nil)
    }

    @Test func inlineSkillsOnly() {
        let range = NSRange(location: 3, length: 4)
        let s = M.skillSections(word: "/rel", range: range, catalog: catalog, isBotChat: false)
        #expect(titles(s) == ["/release-notes"])
        #expect(M.skillSections(word: "/mod", range: range, catalog: catalog, isBotChat: false) == nil)   // commands never mid-text
        let edit = M.applySkill("/release-notes", range: range, in: "hi /rel")
        #expect(edit.text == "hi /release-notes ")
        #expect(edit.caret == utf16(edit.text))
    }

    @Test func spokenLabel() {
        let row = M.Row(id: "x", title: "/model", detail: "Switch model", action: .command("/model", skill: false))
        #expect(row.spokenLabel == "/model, Switch model")
    }

    @Test func escapeClosesTheDrawerBeforeStoppingAReply() {
        #expect(EscapeAction.decide(.init(running: true, fieldFocused: true, drawer: true)) == .closeDrawer)
        #expect(EscapeAction.decide(.init(find: true, drawer: true)) == .closeFind)
        #expect(EscapeAction.decide(.init(presented: true, drawer: true)) == .dismissPresented)
    }
}

@Suite("Composer drawers · one call in flight (§9.3)")
struct ComposerDrawerGateTests {
    @Test func oneInFlightAndStaleAnswersDropped() {
        var gate = CompletionGate()
        gate.want("slash|/r")
        let r1 = gate.next()
        #expect(r1 == "slash|/r")
        gate.want("slash|/re")
        let r2 = gate.next()
        #expect(r2 == nil)                       // one out at a time
        gate.want("slash|/rea")
        let r3 = gate.finished("slash|/r")
        #expect(r3 == false)       // stale: dropped
        let r4 = gate.next()
        #expect(r4 == "slash|/rea")              // only the newest goes out (/re never does)
        let r5 = gate.finished("slash|/rea")
        #expect(r5)
        let r6 = gate.next()
        #expect(r6 == nil)
    }

    @Test func clearKeepsTheCallCounted() {
        var gate = CompletionGate()
        gate.want("path|@a")
        _ = gate.next()
        gate.clear()
        gate.want("path|@b")
        let r7 = gate.next()
        #expect(r7 == nil)
        let r8 = gate.finished("path|@a")
        #expect(!r8)
        let r9 = gate.next()
        #expect(r9 == "path|@b")
    }

    @Test func skipCachedAnswers() {
        var gate = CompletionGate()
        gate.want("slash|/m")
        let r10 = gate.next(skip: { $0 == "slash|/m" })
        #expect(r10 == nil)
        #expect(gate.inFlight == nil)
    }
}

@Suite("Composer drawers · what the drawer remembers")
struct ComposerDrawerMemoryTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let answer = ComposerDrawerModel.Answer(items: [], replaceFrom: nil)

    @Test func aFailedLookupIsAskedAgainAfterAFewSeconds() {
        var memory = CompletionMemory()
        memory.fail("slash|/mo", now: t0)
        #expect(memory.failed("slash|/mo", now: t0.addingTimeInterval(1)))
        #expect(!memory.wantsAsk("slash|/mo", now: t0.addingTimeInterval(1)))
        // A timeout once no longer leaves that text dead for the rest of the chat.
        #expect(!memory.failed("slash|/mo", now: t0.addingTimeInterval(CompletionMemory.failureFor)))
        #expect(memory.wantsAsk("slash|/mo", now: t0.addingTimeInterval(CompletionMemory.failureFor)))
    }

    @Test func fileAnswersAreAskedAgainButCommandAnswersAreKept() {
        var memory = CompletionMemory()
        memory.remember("path|@src/", answer, now: t0)
        memory.remember("slash|/mo", answer, now: t0)
        #expect(!memory.wantsAsk("path|@src/", now: t0.addingTimeInterval(5)))
        // A file the bot made meanwhile shows under the same "@src/" once the old answer is stale.
        let later = t0.addingTimeInterval(CompletionMemory.pathAnswerFor)
        #expect(memory.wantsAsk("path|@src/", now: later))
        #expect(memory.answer("path|@src/") != nil)       // the old rows show until the new ones come
        #expect(!memory.wantsAsk("slash|/mo", now: later))
    }

    @Test func anAnswerClearsAnEarlierFailure() {
        var memory = CompletionMemory()
        memory.fail("path|@a", now: t0)
        memory.remember("path|@a", answer, now: t0.addingTimeInterval(6))
        #expect(!memory.failed("path|@a", now: t0.addingTimeInterval(6)))
    }
}

@Suite("Composer drawers · the @ drawer (§10.2)")
struct ComposerDrawerAtTests {
    let bots = [M.BotEntry(profile: "default", name: "Hermes"), M.BotEntry(profile: "ivy", name: "Ivy"),
                M.BotEntry(profile: "claude", name: "Claude")]
    let range = NSRange(location: 0, length: 1)

    private func titles(_ s: [M.Section]) -> [String] { s.flatMap(\.rows).map(\.title) }

    @Test func bareAtShowsStartersThenBots() {
        let s = M.atSections(word: "", range: range, bots: bots, own: "ivy", remote: nil, waiting: false, failed: false,
                             folderMissing: false, previous: nil)
        #expect(titles(s) == ["@file:", "@folder:", "@url:", "@diff", "@staged", "@hermes", "@claude"])
        #expect(s.last?.title == "Bots")
        #expect(s.flatMap(\.rows).first { $0.title == "@hermes" }?.detail == "Your main bot")
        #expect(s.flatMap(\.rows).first { $0.title == "@claude" }?.detail == "Claude")
        #expect(s[0].rows[0].detail == "Attach a file from the chat’s folder")
    }

    @Test func ownBotIsNeverOffered() {
        let s = M.atSections(word: "", range: range, bots: bots, own: "", remote: nil, waiting: false, failed: false,
                             folderMissing: false, previous: nil)
        #expect(!titles(s).contains("@hermes"))
        let answer = M.answer(["items": [["text": "@hermes", "meta": "agent profile (primary)"], ["text": "@ivy", "meta": "agent profile"]]],
                              asked: "@")
        let r = M.atSections(word: "s", range: range, bots: bots, own: "default", remote: answer, waiting: false, failed: false,
                             folderMissing: false, previous: nil)
        #expect(titles(r) == ["@ivy"])
        #expect(r.first?.rows.first?.bot == "ivy")
    }

    @Test func profileMetaIsMapped() {
        let answer = M.answer(["items": [["text": "@hermes", "meta": "agent profile (primary)"], ["text": "@zed", "meta": "agent profile"],
                                         ["text": "@diff", "meta": "git diff"]]], asked: "@")
        let r = M.atSections(word: "x", range: range, bots: bots, own: "ivy", remote: answer, waiting: false, failed: false,
                             folderMissing: false, previous: nil)
        let rows = r.flatMap(\.rows)
        #expect(rows.first { $0.title == "@hermes" }?.detail == "Your main bot")
        #expect(rows.first { $0.title == "@zed" }?.detail == "Another bot")
        #expect(rows.first { $0.title == "@diff" }?.detail == "Changes not yet committed")
    }

    @Test func dotfilesHiddenUnlessTyped() {
        let answer = M.answer(["items": [["text": "@file:.env", "meta": ""], ["text": "@folder:.config/", "meta": "dir"],
                                         ["text": "@file:src/main.py", "meta": ""], ["text": "@folder:src/util/", "meta": "dir"]]],
                              asked: "@file:")
        let r = M.atSections(word: "file:", range: range, bots: bots, own: "ivy", remote: answer, waiting: false, failed: false,
                             folderMissing: false, previous: nil)
        #expect(titles(r) == ["main.py", "util/"])
        #expect(r.flatMap(\.rows).first?.parent == "src/")
        #expect(r.flatMap(\.rows).last?.detail == "Folder")
        let dots = M.atSections(word: "file:.e", range: range, bots: bots, own: "ivy", remote: answer, waiting: false, failed: false,
                                folderMissing: false, previous: nil)
        #expect(titles(dots).contains(".env"))
    }

    @Test func folderMissingNote() {
        let r = M.atSections(word: "file:", range: range, bots: bots, own: "ivy", remote: nil, waiting: false, failed: false,
                             folderMissing: true, previous: nil)
        #expect(titles(r) == [M.folderMissing])
        #expect(r.first?.rows.first?.tappable == false)
    }

    @Test func waitingKeepsPreviousRowsOrSaysLooking() {
        let looking = M.atSections(word: "file:s", range: range, bots: bots, own: "ivy", remote: nil, waiting: true, failed: false,
                                   folderMissing: false, previous: nil)
        #expect(titles(looking) == [M.looking])
        let previous = [M.Section(title: nil, rows: [M.Row(id: "a", title: "a", detail: "", action: .mention("@file:a", range: range))])]
        let kept = M.atSections(word: "file:s", range: range, bots: bots, own: "ivy", remote: nil, waiting: true, failed: false,
                                folderMissing: false, previous: previous)
        #expect(titles(kept) == ["a"])
        let failed = M.atSections(word: "file:s", range: range, bots: bots, own: "ivy", remote: nil, waiting: true, failed: true,
                                  folderMissing: false, previous: previous)
        #expect(titles(failed) == [M.noMatches])
    }

    @Test func offlineStillOffersBotsLocally() {
        let r = M.atSections(word: "cl", range: range, bots: bots, own: "ivy", remote: nil, waiting: false, failed: true,
                             folderMissing: false, previous: nil)
        #expect(titles(r) == ["@claude"])
        let byName = M.atSections(word: "herm", range: range, bots: bots, own: "ivy", remote: nil, waiting: false, failed: true,
                                  folderMissing: false, previous: nil)
        #expect(titles(byName) == ["@hermes"])
    }

    @Test func aBotCalledHermesKeepsItsHandle() {
        let withHermes = bots + [M.BotEntry(profile: "hermes", name: "Hermes Two")]
        #expect(M.handle(withHermes[0], among: withHermes) == "default")
        #expect(M.handle(bots[0], among: bots) == "hermes")
        #expect(M.profile(forHandle: "hermes", among: bots) == "default")
    }

    @Test func mentionPicks() {
        let text = "see @fi"
        let r = NSRange(location: 4, length: 3)
        #expect(M.applyMention("@file:", range: r, in: text) == M.Edit(text: "see @file:", caret: 10))
        #expect(M.applyMention("@folder:src/", range: r, in: text).text == "see @folder:src/")
        #expect(M.applyMention("@ivy", range: r, in: text) == M.Edit(text: "see @ivy ", caret: 9))
        let mid = M.applyMention("@ivy", range: NSRange(location: 3, length: 2), in: "hi @s there")
        #expect(mid == M.Edit(text: "hi @ivy  there", caret: 8))
        // A range past the end (the text changed) never crashes.
        #expect(M.applyMention("@x", range: NSRange(location: 40, length: 3), in: "ab").text == "ab@x ")
    }

    @Test func refLeafAndSegments() {
        #expect(M.refLeaf("@file:src/.env") == ".env")
        #expect(M.refLeaf("@folder:src/util/") == "util")
        #expect(M.refLeaf("@diff") == nil)
        #expect(M.typedSegment("file:src/ma") == "ma")
        #expect(M.typedSegment("file:.e") == ".e")
        #expect(M.isFolderQuery("folder:"))
        #expect(!M.isFolderQuery("ivy"))
    }
}

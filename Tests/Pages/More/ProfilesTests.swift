// More › Bot Profiles (docs/spec/3x-morepages.md §10 acceptance 1): the name rule, the wire with bad data and exact
// bodies, the draft file's life, conflict detection, and the Cancel / Save bar restoring exactly what a page had.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

nonisolated private func json(_ text: String) -> JSONValue { try! JSONValue.parse(Data(text.utf8)) }

struct ProfileNameTests {
    @Test func acceptsTheGatewaysNames() {
        for name in ["a", "0", "inbox", "inbox-2", "a_b", "9lives", "a-", "a__-9", String(repeating: "a", count: 64)] {
            #expect(ProfileName.isValid(name), "\(name)")
        }
    }

    @Test func refusesEverythingElse() {
        for name in ["", " ", "Inbox", "-a", "_a", "a b", "a.b", "a/b", "é", "aé", "١", "a\n", " a", "a ", "😀", "a😀",
                     "../x", "a%20b", String(repeating: "a", count: 65)] {
            #expect(!ProfileName.isValid(name), "\(name)")
        }
    }

    @Test func checkTellsUnchangedInvalidTakenAndOk() {
        let existing = ["default", "inbox", "deploys"]
        #expect(ProfileName.check("inbox", current: "inbox", existing: existing) == .unchanged)
        #expect(ProfileName.check("Inbox", current: "inbox", existing: existing) == .invalid)
        #expect(ProfileName.check("", current: "inbox", existing: existing) == .invalid)
        #expect(ProfileName.check("default", current: "inbox", existing: existing) == .invalid)
        #expect(ProfileName.check("deploys", current: "inbox", existing: existing) == .taken)
        #expect(ProfileName.check("mail", current: "inbox", existing: existing) == .ok)
        #expect(ProfileName.check("mail ", current: "inbox", existing: existing) == .invalid)
    }

    @Test func renameReasonPrefersTheGatewaysWords() {
        #expect(ProfileName.renameReason(HTTPError(status: 409, body: #"{"detail":"Profile 'mail' already exists."}"#)) == "Profile 'mail' already exists.")
        #expect(ProfileName.renameReason(HTTPError(status: 409, body: nil)) == "A profile with that name already exists.")
        #expect(ProfileName.renameReason(HTTPError(status: 400, body: "")) == "A profile with that name already exists.")
        #expect(ProfileName.renameReason(HTTPError(status: 500, body: nil)) == "The gateway couldn’t do that.")
    }

    @Test func counts() {
        #expect(ProfileName.count(0) == "0 profiles")
        #expect(ProfileName.count(1) == "1 profile")
        #expect(ProfileName.count(60) == "60 profiles")
    }
}

struct ProfileWireTests {
    @Test func decodesTheGatewaysRows() {
        let rows = ProfileRow.rows(from: json("""
        {"profiles":[
          {"name":"inbox","path":"/home/hermes/profiles/inbox","is_default":false,"model":"hermes-4","provider":"nous","has_env":true,"skill_count":4,"display_name":"Inbox","bot_title":"Mail"},
          {"name":"default","path":"/home/hermes","is_default":true,"model":"hermes-4","provider":"nous","skill_count":12,"display_name":"","bot_title":"Hermes"}
        ]}
        """))
        #expect(rows.map(\.name) == ["default", "inbox"])          // the default profile first
        #expect(rows[0].isDefault && !rows[1].isDefault)
        #expect(rows[0].displayName == "Hermes")                    // an empty display_name falls back to bot_title
        #expect(rows[1].displayName == "Inbox")
        #expect(rows[1].skillCount == 4 && rows[1].model == "hermes-4" && rows[1].provider == "nous")
        #expect(rows[1].path == "/home/hermes/profiles/inbox")
    }

    @Test func badRowsAreSkippedAndBadFieldsReadAsAbsent() {
        let rows = ProfileRow.rows(from: json("""
        {"profiles":[null, 7, "text", {}, {"name":null}, {"name":""}, {"name":"   "}, {"name":42},
          {"name":"numbers","skill_count":"7","is_default":"no","model":5,"provider":null,"path":["x"]},
          {"name":"neg","skill_count":-3},
          {"name":"huge","skill_count":1e400},
          {"name":"numbers","skill_count":99},
          {"name":"default"}
        ]}
        """.replacingOccurrences(of: "1e400", with: "\"1e400\"")))
        #expect(rows.map(\.name) == ["default", "numbers", "neg", "huge"])   // a repeated name is kept once
        let numbers = rows[1]
        #expect(numbers.skillCount == 7 && numbers.model == nil && numbers.provider == nil && numbers.path == nil && !numbers.isDefault)
        #expect(rows[2].skillCount == 0 && rows[3].skillCount == 0)
        #expect(rows[0].isDefault)                                   // `default` is the default whatever the row says
    }

    @Test func oddShapesGiveNoRows() {
        #expect(ProfileRow.rows(from: json("{}")).isEmpty)
        #expect(ProfileRow.rows(from: json(#"{"profiles":{"a":1}}"#)).isEmpty)
        #expect(ProfileRow.rows(from: json(#"{"profiles":null}"#)).isEmpty)
        #expect(ProfileRow.rows(from: json("null")).isEmpty)
        #expect(ProfileRow.rows(from: json(#"[{"name":"a"}]"#)).map(\.name) == ["a"])
    }

    @Test func manyRowsAndLongNames() {
        let long = String(repeating: "x", count: 1000)
        let list = (0..<5000).map { "{\"name\":\"bot-\($0)\",\"display_name\":\"\(long)\"}" }.joined(separator: ",")
        let rows = ProfileRow.rows(from: json("{\"profiles\":[" + list + "]}"))
        #expect(rows.count == 5000 && rows[4999].displayName == long)
    }

    @Test func soulDocumentReadsLeniently() {
        #expect(SoulDocument(json(##"{"content":"# Hi","exists":true}"##)) == SoulDocument(content: "# Hi", exists: true))
        #expect(SoulDocument(json(#"{"content":"","exists":false}"#)) == SoulDocument(content: "", exists: false))
        #expect(SoulDocument(json(#"{"content":null}"#)) == SoulDocument(content: "", exists: false))
        #expect(SoulDocument(json(#"{"content":"x"}"#)) == SoulDocument(content: "x", exists: true))
        #expect(SoulDocument(json(#"{"content":7,"exists":"yes"}"#)) == SoulDocument(content: "", exists: false))
        #expect(SoulDocument(json("{}")) == SoulDocument(content: "", exists: false))
    }

    @Test func listReadsOnePathAndThrowsOnAnUnreadableAnswer() async throws {
        let client = MoreFakeClient { _ in json(#"{"profiles":[{"name":"default"},{"name":"inbox"}]}"#) }
        let rows = try await ProfilesAPI(client: client).list()
        #expect(rows.map(\.name) == ["default", "inbox"])
        #expect(client.logLines == ["GET /api/profiles"])
        client.respond { _ in json(#"{"detail":"nope"}"#) }
        await #expect(throws: ProfilesFailure.self) { _ = try await ProfilesAPI(client: client).list() }
        client.respond { _ in json("[1,2]") }
        #expect(try await ProfilesAPI(client: client).list().isEmpty)
    }

    @Test func soulRoutesEncodeTheNameAsOneSegmentAndSendOnlyContent() async throws {
        let client = MoreFakeClient { request in
            return request.method == "GET" ? json(#"{"content":"old","exists":true}"#) : json(#"{"ok":true}"#)
        }
        let api = ProfilesAPI(client: client)
        #expect(try await api.soul("a/b c") == SoulDocument(content: "old", exists: true))
        try await api.saveSoul("a/b c", content: "new\ntext “quoted”")
        #expect(client.logLines == ["GET /api/profiles/a%2Fb%20c/soul", "PUT /api/profiles/a%2Fb%20c/soul"])
        #expect(client.log[1].body == .object(["content": .string("new\ntext “quoted”")]))
        client.respond { _ in json("[]") }
        await #expect(throws: ProfilesFailure.self) { _ = try await api.soul("inbox") }
    }

    @Test func renameSendsOnlyNewNameAndReadsTheAnswer() async throws {
        let client = MoreFakeClient { _ in json(#"{"ok":true,"name":"mail","path":"/home/hermes/profiles/mail"}"#) }
        let renamed = try await ProfilesAPI(client: client).rename("inbox", to: "mail")
        #expect(renamed == ProfileRenamed(name: "mail", path: "/home/hermes/profiles/mail"))
        #expect(client.logLines == ["PATCH /api/profiles/inbox"])
        #expect(client.log[0].body == .object(["new_name": .string("mail")]))
        client.respond { _ in json("{}") }
        #expect(try await ProfilesAPI(client: client).rename("inbox", to: "mail") == ProfileRenamed(name: "mail", path: nil))
    }

    @Test func saveSoulSendsALargeFileWhole() async throws {
        let big = String(repeating: "Remember: plain words. 😀\n", count: 16_000)       // about 430 KB
        let client = MoreFakeClient { _ in json(#"{"ok":true}"#) }
        try await ProfilesAPI(client: client).saveSoul("inbox", content: big)
        #expect(client.log[0].body?["content"]?.string == big)
    }
}

struct SoulDraftTests {
    private func store() -> SoulDraftStore {
        SoulDraftStore(directory: FileManager.default.temporaryDirectory.appending(path: "soul-drafts-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    @Test func fileNamesAreSafeAndPerAccountAndProfile() {
        let a = SoulDraftStore.fileName(account: "http://127.0.0.1:10050|more", profile: "inbox")
        let b = SoulDraftStore.fileName(account: "http://127.0.0.1:10050|other", profile: "inbox")
        let c = SoulDraftStore.fileName(account: "http://127.0.0.1:10050|more", profile: "../../etc/passwd")
        #expect(a.hasPrefix("soul-draft-") && a.hasSuffix("-inbox.txt"))
        #expect(a != b && a != c)
        for name in [a, b, c, SoulDraftStore.fileName(account: "", profile: ""), SoulDraftStore.fileName(account: "x", profile: "a b/😀")] {
            #expect(!name.contains("/") && !name.contains("..") && !name.contains(":") && !name.contains(" ") && !name.contains("|"))
        }
    }

    @Test func lifecycleWriteReadRemove() {
        let drafts = store()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        #expect(drafts.read(account: "acct", profile: "inbox") == nil)
        let draft = SoulDraft(text: "# Inbox\n\nline two\n", baseHash: SoulDraft.hash("# Inbox\n"))
        drafts.write(draft, account: "acct", profile: "inbox")
        #expect(drafts.read(account: "acct", profile: "inbox") == draft)
        #expect(drafts.read(account: "acct", profile: "deploys") == nil)
        #expect(drafts.read(account: "other", profile: "inbox") == nil)
        // A later pause replaces it.
        let later = SoulDraft(text: "", baseHash: draft.baseHash)
        drafts.write(later, account: "acct", profile: "inbox")
        #expect(drafts.read(account: "acct", profile: "inbox") == later)
        drafts.remove(account: "acct", profile: "inbox")
        #expect(drafts.read(account: "acct", profile: "inbox") == nil)
        drafts.remove(account: "acct", profile: "inbox")           // removing nothing is fine
    }

    @Test func textSurvivesExactly() {
        let drafts = store()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        for text in ["", "\n", "\n\nleading", "trailing\n\n", "hq-soul-draft base=fake\nx", "emoji 😀 עברית\u{200B}\r\n",
                     String(repeating: "0123456789abcdef\n", count: 24_000)] {
            let draft = SoulDraft(text: text, baseHash: SoulDraft.hash("base"))
            drafts.write(draft, account: "acct", profile: "p")
            #expect(drafts.read(account: "acct", profile: "p") == draft)
        }
    }

    @Test func aDamagedFileIsNoDraft() throws {
        let drafts = store()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        let url = drafts.url(account: "acct", profile: "p")
        for bytes in [Data(), Data("just text".utf8), Data("hq-soul-draft base=short\ntext".utf8), Data([0xFF, 0xFE, 0x00]),
                      Data(("hq-soul-draft base=" + String(repeating: "z", count: 64) + "\ntext").utf8),
                      Data(("hq-soul-draft base=" + SoulDraft.hash("x")).utf8)] {
            try bytes.write(to: url)
            #expect(drafts.read(account: "acct", profile: "p") == nil)
        }
    }

    @Test func removeAllTakesOnlyThatAccountsDrafts() {
        let drafts = store()
        defer { try? FileManager.default.removeItem(at: drafts.directory) }
        let draft = SoulDraft(text: "x", baseHash: SoulDraft.hash(""))
        drafts.write(draft, account: "one", profile: "a")
        drafts.write(draft, account: "one", profile: "b")
        drafts.write(draft, account: "two", profile: "a")
        drafts.removeAll(account: "one")
        #expect(drafts.read(account: "one", profile: "a") == nil && drafts.read(account: "one", profile: "b") == nil)
        #expect(drafts.read(account: "two", profile: "a") == draft)
    }

    @Test func aDraftIsOfferedOnlyWhenItSaysSomethingNew() {
        let base = SoulDraft.hash("server")
        #expect(SoulRules.draftOffer(nil, server: "server") == .none)
        #expect(SoulRules.draftOffer(SoulDraft(text: "server", baseHash: base), server: "server") == .none)
        #expect(SoulRules.draftOffer(SoulDraft(text: "server plus", baseHash: base), server: "server") == .offer)
        #expect(SoulRules.draftOffer(SoulDraft(text: "", baseHash: base), server: "server") == .offer)
        // The gateway's file moved on while the draft waited: still offered (Save then asks before replacing).
        #expect(SoulRules.draftOffer(SoulDraft(text: "mine", baseHash: base), server: "theirs") == .offer)
    }
}

struct SoulRulesTests {
    @Test func conflictDetection() {
        let base = SoulDraft.hash("one")
        #expect(!SoulRules.changedOnGateway(baseHash: base, baseExists: true, now: SoulDocument(content: "one", exists: true)))
        #expect(SoulRules.changedOnGateway(baseHash: base, baseExists: true, now: SoulDocument(content: "two", exists: true)))
        #expect(SoulRules.changedOnGateway(baseHash: base, baseExists: true, now: SoulDocument(content: "one\n", exists: true)))
        // Removed on the gateway, or made there while this edit began from nothing.
        #expect(SoulRules.changedOnGateway(baseHash: base, baseExists: true, now: SoulDocument(content: "", exists: false)))
        let none = SoulDraft.hash("")
        #expect(!SoulRules.changedOnGateway(baseHash: none, baseExists: false, now: SoulDocument(content: "", exists: false)))
        #expect(SoulRules.changedOnGateway(baseHash: none, baseExists: false, now: SoulDocument(content: "", exists: true)))
        #expect(SoulRules.changedOnGateway(baseHash: none, baseExists: false, now: SoulDocument(content: "new", exists: true)))
        // An existing empty file that is still empty is unchanged.
        #expect(!SoulRules.changedOnGateway(baseHash: none, baseExists: true, now: SoulDocument(content: "", exists: true)))
    }

    @Test func barRule() {
        #expect(SoulRules.bar(dirty: false, saving: false) == .init(cancelEnabled: true, saveEnabled: false, saveTitle: "Save"))
        #expect(SoulRules.bar(dirty: true, saving: false) == .init(cancelEnabled: true, saveEnabled: true, saveTitle: "Save"))
        #expect(SoulRules.bar(dirty: true, saving: true) == .init(cancelEnabled: false, saveEnabled: false, saveTitle: "Saving…"))
        #expect(SoulRules.bar(dirty: false, saving: true, savingLabel: "Sending…").saveTitle == "Sending…")
    }

    @Test func wording() {
        #expect(SoulRules.discardTitle == "Discard Changes?")
        #expect(SoulRules.discardConfirm == "Discard Changes" && SoulRules.discardCancel == "Keep Editing")
        #expect(ProfileName.hint == "Lowercase letters, digits, hyphens, and underscores. Must start with a letter or digit.")
        let all = [SoulRules.discardTitle, SoulRules.discardMessage, SoulRules.placeholder, ProfileName.hint, ProfileName.taken]
        #expect(!all.contains { $0.localizedCaseInsensitiveContains("dispatch") })
    }
}

@MainActor
struct NavEditBarTests {
    private func hosted() -> (UIViewController, UINavigationController, [UIBarButtonItem], [UIBarButtonItem]) {
        let root = UIViewController()
        let page = UIViewController()
        let left = [UIBarButtonItem(title: "Own Left", style: .plain, target: nil, action: nil)]
        let right = [UIBarButtonItem(title: "Edit", style: .plain, target: nil, action: nil),
                     UIBarButtonItem(systemItem: .search)]
        page.navigationItem.leftBarButtonItems = left
        page.navigationItem.rightBarButtonItems = right
        page.navigationItem.leftItemsSupplementBackButton = true
        let navigation = UINavigationController(rootViewController: root)
        navigation.pushViewController(page, animated: false)
        navigation.loadViewIfNeeded()
        return (page, navigation, left, right)
    }

    @Test func beginPutsCancelAndADisabledSaveAndHidesBack() {
        let (page, navigation, _, _) = hosted()
        var cancelled = 0, saved = 0
        let bar = NavEditBar(host: page, onCancel: { cancelled += 1 }, onSave: { saved += 1 })
        #expect(!bar.isEditing)
        bar.begin()
        let item = page.navigationItem
        #expect(bar.isEditing && item.hidesBackButton && !item.leftItemsSupplementBackButton)
        #expect(item.leftBarButtonItems?.count == 1 && item.rightBarButtonItems?.count == 1)
        #expect(item.leftBarButtonItem?.accessibilityIdentifier == "nav-edit.cancel")
        #expect(item.rightBarButtonItem?.accessibilityIdentifier == "nav-edit.save")
        // UX study #96: a Save that can't act is a plain dimmed item, as on every other edit bar.
        #expect(item.rightBarButtonItem?.style == .plain && item.rightBarButtonItem?.title == "Save")
        #expect(item.leftBarButtonItem?.isEnabled == true && item.rightBarButtonItem?.isEnabled == false)
        #expect(navigation.interactivePopGestureRecognizer?.isEnabled == false)
        #expect(navigation.interactiveContentPopGestureRecognizer?.isEnabled == false)
        _ = (cancelled, saved)
    }

    @Test func updateFollowsDirtyAndSaving() {
        let (page, _, _, _) = hosted()
        let bar = NavEditBar(host: page, onCancel: {}, onSave: {})
        bar.begin()
        let save = page.navigationItem.rightBarButtonItem!, cancel = page.navigationItem.leftBarButtonItem!
        for (dirty, saving) in [(false, false), (true, false), (true, true), (false, true), (true, false), (false, false)] {
            bar.update(dirty: dirty, saving: saving)
            let rule = SoulRules.bar(dirty: dirty, saving: saving)
            #expect(save.isEnabled == rule.saveEnabled && cancel.isEnabled == rule.cancelEnabled && save.title == rule.saveTitle)
            #expect(save.style == (rule.saveEnabled ? .prominent : .plain))
            #expect(page.navigationItem.rightBarButtonItem === save && page.navigationItem.leftBarButtonItem === cancel)
        }
        bar.update(dirty: true, saving: true, savingLabel: "Sending…")
        #expect(save.title == "Sending…" && !save.isEnabled)
    }

    @Test func endRestoresExactlyWhatWasThere() {
        let (page, navigation, left, right) = hosted()
        let bar = NavEditBar(host: page, onCancel: {}, onSave: {})
        for _ in 0..<3 {                       // rapid Edit / Cancel
            bar.begin()
            bar.begin()                        // a second begin changes nothing (the page's items are not lost)
            bar.update(dirty: true, saving: true)
            bar.end()
            bar.end()
            let item = page.navigationItem
            #expect(!bar.isEditing && !item.hidesBackButton && item.leftItemsSupplementBackButton)
            #expect(item.leftBarButtonItems?.count == left.count && item.rightBarButtonItems?.count == right.count)
            #expect(zip(item.leftBarButtonItems ?? [], left).allSatisfy { $0 === $1 })
            #expect(zip(item.rightBarButtonItems ?? [], right).allSatisfy { $0 === $1 })
            #expect(navigation.interactivePopGestureRecognizer?.isEnabled == true)
            #expect(navigation.interactiveContentPopGestureRecognizer?.isEnabled == true)
            #expect(bar.cancelItem == nil && bar.saveItem == nil && !bar.dirty && !bar.saving)
        }
    }

    @Test func aPageWithNoItemsAndAHiddenBackGetsThemBack() {
        let page = UIViewController()
        page.navigationItem.hidesBackButton = true
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(page, animated: false)
        let bar = NavEditBar(host: page, onCancel: {}, onSave: {})
        bar.begin()
        bar.end()
        #expect(page.navigationItem.hidesBackButton)
        #expect((page.navigationItem.leftBarButtonItems ?? []).isEmpty && (page.navigationItem.rightBarButtonItems ?? []).isEmpty)
        bar.update(dirty: true, saving: false)          // an update outside an edit touches nothing
        #expect((page.navigationItem.rightBarButtonItems ?? []).isEmpty)
    }

    @Test func buttonsRunTheirActionsAndSwipeBackFollowsThePage() {
        let (page, navigation, _, _) = hosted()
        var cancelled = 0, saved = 0
        let bar = NavEditBar(host: page, onCancel: { cancelled += 1 }, onSave: { saved += 1 })
        bar.begin()
        bar.update(dirty: true, saving: false)
        if let action = bar.cancelItem?.primaryAction { action.performWithSender(nil, target: nil) }
        if let action = bar.saveItem?.primaryAction { action.performWithSender(nil, target: nil) }
        #expect(cancelled == 1 && saved == 1)
        // Another page shows over the editor: the stack gets its gestures back; they are held again on return.
        bar.hostWillDisappear()
        #expect(navigation.interactivePopGestureRecognizer?.isEnabled == true)
        bar.hostDidAppear()
        #expect(navigation.interactivePopGestureRecognizer?.isEnabled == false)
        // A page that is not on top never holds the stack's gestures.
        let over = UIViewController()
        navigation.pushViewController(over, animated: false)
        navigation.interactivePopGestureRecognizer?.isEnabled = true
        bar.hostDidAppear()
        #expect(navigation.interactivePopGestureRecognizer?.isEnabled == true)
        bar.end()
    }

    @Test func aHostThatWentAwayIsHarmless() {
        var page: UIViewController? = UIViewController()
        let bar = NavEditBar(host: page!, onCancel: {}, onSave: {})
        bar.begin()
        page = nil
        bar.update(dirty: true, saving: false)
        bar.end()
        #expect(!bar.isEditing)
    }
}

// Settings stream unit tests (docs/spec/1x-settings.md §13): U1 pinned-section rules, U4 identity, U5 gateway names,
// U6 news count, U7 heads, U8 install-blocked parsing. Vectors ported from the web app's own tests.

import Foundation
import Testing
@testable import HermesHQNative

private let P = RosterRules.pinnedSectionId
private let names: [String: String] = ["work": "Work", "home": "Home"]
private func nameOf(_ id: String) -> String? { names[id] }
private func apply(_ meta: [String: JSONValue], _ patch: [String: JSONValue]?) -> [String: JSONValue] { PinnedSection.apply(patch, to: meta) }
private func home(_ id: String, _ name: String) -> JSONValue { .object(["id": .string(id), "name": .string(name)]) }

// MARK: - U1 `S/ui-bots/pinned-section-model.test.ts`

@Suite struct PinnedSectionTests {
    @Test func filesAPinnedBotIntoPinnedAndRemembersItsSection() {
        #expect(PinnedSection.pinnedSectionPatch(["pinned": true, "sectionId": "work", "sectionName": "Work"], sectionName: nameOf)
                == ["sectionId": .string(P), "sectionName": "Pinned", "pinnedFrom": home("work", "Work")])
        #expect(PinnedSection.pinnedSectionPatch(["pinned": true], sectionName: nameOf)
                == ["sectionId": .string(P), "sectionName": "Pinned", "pinnedFrom": .null])
    }

    @Test func leavesAgreeingBotsAlone() {
        #expect(PinnedSection.pinnedSectionPatch(["pinned": true, "sectionId": .string(P), "sectionName": "Pinned", "pinnedFrom": .null], sectionName: nameOf) == nil)
        #expect(PinnedSection.pinnedSectionPatch(["sectionId": "work"], sectionName: nameOf) == nil)
        #expect(PinnedSection.pinnedSectionPatch(["pinnedFrom": false], sectionName: nameOf) == nil)
        #expect(PinnedSection.pinnedSectionPatch(nil, sectionName: nameOf) == nil)
    }

    @Test func putsAnUnpinnedBotBackWhereItWas() {
        #expect(PinnedSection.pinnedSectionPatch(["pinned": false, "sectionId": .string(P), "sectionName": "Pinned", "pinnedFrom": home("work", "Work")], sectionName: nameOf)
                == ["sectionId": "work", "sectionName": "Work", "pinnedFrom": false])
        #expect(PinnedSection.pinnedSectionPatch(["sectionId": .string(P), "pinnedFrom": .null], sectionName: nameOf)
                == ["sectionId": .null, "sectionName": .null, "pinnedFrom": false])
    }

    @Test func sendsAnUnpinnedBotToNoSectionWhenItsSectionWasDeleted() {
        #expect(PinnedSection.pinnedSectionPatch(["sectionId": .string(P), "pinnedFrom": home("gone", "Gone")], sectionName: nameOf)
                == ["sectionId": .null, "sectionName": .null, "pinnedFrom": false])
    }

    @Test func pinsABotFiledIntoPinnedByHand() {
        #expect(PinnedSection.pinnedSectionPatch(["sectionId": .string(P), "sectionName": "Pinned"], sectionName: nameOf)
                == ["pinned": true, "sectionName": "Pinned", "pinnedFrom": .null])
        #expect(PinnedSection.pinnedSectionPatch(["sectionId": .string(P), "pinnedFrom": false], sectionName: nameOf)
                == ["pinned": true, "sectionName": "Pinned", "pinnedFrom": .null])
    }

    @Test func keepsAPinnedBotInPinnedWhenADesktopMovesIt() {
        #expect(PinnedSection.pinnedSectionPatch(["pinned": true, "sectionId": "home", "sectionName": "Home", "pinnedFrom": home("work", "Work")], sectionName: nameOf)
                == ["sectionId": .string(P), "sectionName": "Pinned", "pinnedFrom": home("home", "Home")])
    }

    @Test func renamesPinnedBackAndRecordsAHomeForAHandFiledPin() {
        #expect(PinnedSection.pinnedSectionPatch(["pinned": true, "sectionId": .string(P), "sectionName": "Favs", "pinnedFrom": .null], sectionName: nameOf)
                == ["sectionName": "Pinned"])
        #expect(PinnedSection.pinnedSectionPatch(["pinned": true, "sectionId": .string(P), "sectionName": "Pinned"], sectionName: nameOf)
                == ["pinnedFrom": .null])
    }

    @Test func forgetsAStaleHomeOutsidePinned() {
        #expect(PinnedSection.pinnedSectionPatch(["sectionId": "work", "pinnedFrom": home("home", "Home")], sectionName: nameOf) == ["pinnedFrom": false])
    }

    @Test func settlesAfterOneWriteInEveryCase() {
        let cases: [[String: JSONValue]] = [["pinned": true, "sectionId": "work"], ["pinned": true], ["sectionId": .string(P)],
                                            ["sectionId": .string(P), "pinnedFrom": home("work", "Work")],
                                            ["pinned": true, "sectionId": .string(P), "sectionName": "X"], ["sectionId": "work", "pinnedFrom": .null]]
        for meta in cases {
            let once = apply(meta, PinnedSection.pinnedSectionPatch(meta, sectionName: nameOf))
            #expect(PinnedSection.pinnedSectionPatch(once, sectionName: nameOf) == nil, "\(meta)")
        }
    }

    @Test func pinsAndUnpinsInOneWriteThatRoundTripsTheSection() {
        let start: [String: JSONValue] = ["sectionId": "work", "sectionName": "Work"]
        let pinned = apply(start, PinnedSection.pinPatch(start, pinned: true, sectionName: nameOf))
        #expect(pinned["pinned"] == true && pinned["sectionId"] == .string(P) && pinned["pinnedFrom"] == home("work", "Work"))
        let unpinned = apply(pinned, PinnedSection.pinPatch(pinned, pinned: false, sectionName: nameOf))
        #expect(unpinned["pinned"] == false && unpinned["sectionId"] == "work" && unpinned["sectionName"] == "Work" && unpinned["pinnedFrom"] == false)
    }

    @Test func movesAPinnedBotByChangingWhereAnUnpinPutsIt() {
        let meta: [String: JSONValue] = ["pinned": true, "sectionId": .string(P), "pinnedFrom": home("work", "Work")]
        #expect(PinnedSection.sectionMovePatch(meta, target: "home", sectionName: nameOf) == ["pinnedFrom": home("home", "Home")])
        #expect(PinnedSection.sectionMovePatch(meta, target: nil, sectionName: nameOf) == ["pinnedFrom": .null])
        #expect(PinnedSection.sectionMovePatch(meta, target: P, sectionName: nameOf) == [:])
        #expect(PinnedSection.sectionMovePatch(["sectionId": "work"], target: "home", sectionName: nameOf) == nil)
        let pin = PinnedSection.sectionMovePatch(["sectionId": "work"], target: P, sectionName: nameOf)
        #expect(pin?["pinned"] == true && pin?["sectionId"] == .string(P))
    }

    @Test func showsAPinnedBotUnderItsHomeAndNeverOffersPinned() {
        #expect(PinnedSection.shownSectionId(["pinnedFrom": home("work", "Work")], sectionId: P) == "work")
        #expect(PinnedSection.shownSectionId(["pinnedFrom": .null], sectionId: P) == nil)
        #expect(PinnedSection.shownSectionId([:], sectionId: "home") == "home")
        #expect(PinnedSection.withoutPinned([RosterSectionRecord(id: P, name: "Pinned"), RosterSectionRecord(id: "work", name: "Work")])
                == [RosterSectionRecord(id: "work", name: "Work")])
    }

    @Test func undoesToThePreviousValues() {
        #expect(PinnedSection.undoOf(["pinned": false, "sectionId": "work", "sectionName": "Work"],
                                     ["pinned": true, "sectionId": .string(P), "sectionName": "Pinned", "pinnedFrom": .null])
                == ["pinned": false, "sectionId": "work", "sectionName": "Work", "pinnedFrom": false])
    }

    /// §5.2's wire example: pin Ivy (in Work).
    @Test func pinSamWritesTheSpecExample() {
        let fresh: [String: JSONValue] = ["sectionId": "sec-work", "sectionName": "Work", "created": 1790000000001]
        let patch = PinnedSection.pinPatch(fresh, pinned: true) { $0 == "sec-work" ? "Work" : nil }
        #expect(apply(fresh, patch) == ["sectionId": .string(P), "sectionName": "Pinned", "created": 1790000000001, "pinned": true,
                                        "pinnedFrom": home("sec-work", "Work")])
        let pinned = apply(fresh, patch)
        let unpin = PinnedSection.pinPatch(pinned, pinned: false) { $0 == "sec-work" ? "Work" : nil }
        #expect(unpin == ["pinned": false, "sectionId": "sec-work", "sectionName": "Work", "pinnedFrom": false])
    }
}

// MARK: - U4 identity (`HB/labels.profile-name.test.ts`, `HB/soul.ts`)

@Suite struct BotIdentityTests {
    @Test func derivesAStableASCIIProfileId() {
        #expect(BotIdentity.slugifyProfileName("小助手") == "u5c0f-u52a9-u624b")
        #expect(BotIdentity.slugifyProfileName("test机器人") == "test-u673a-u5668-u4eba")
        #expect(BotIdentity.slugifyProfileName("u5c0f-u52a9-u624b") == "u5c0f-u52a9-u624b")
        #expect(BotIdentity.slugifyProfileName("Inbox Triage") == "inbox-triage")
        #expect(BotIdentity.profileIdentity(name: "小助手", title: "") == ("u5c0f-u52a9-u624b", "小助手"))
        #expect(BotIdentity.profileIdentity(name: "小助手", title: "Helper") == ("u5c0f-u52a9-u624b", "Helper"))
        #expect(BotIdentity.profileIdentity(name: "Test", title: "") == ("test", ""))
        #expect(BotIdentity.profileIdentity(name: "🤖", title: "") == ("", "🤖"))
    }

    @Test func foldsAccentedLatin() {
        #expect(BotIdentity.slugifyProfileName("Café Résumé") == "cafe-resume")
        #expect(BotIdentity.profileIdentity(name: "Café", title: "") == ("cafe", "Café"))
    }

    @Test func neverSplitsATokenAtTheCap() {
        #expect(BotIdentity.slugifyProfileName("한글") == "ud55c-uae00")
        #expect(BotIdentity.slugifyProfileName("ガ") != BotIdentity.slugifyProfileName("カ"))
        let long = BotIdentity.slugifyProfileName(String(repeating: "小助手", count: 7))
        #expect(long == "u5c0f-u52a9-u624b-u5c0f-u52a9-u624b-u5c0f-u52a9-u624b-u5c0f")
        #expect(BotIdentity.isValidProfileId(long))
        #expect(!BotIdentity.isValidProfileId(""))
        #expect(!BotIdentity.isValidProfileId("-x"))
    }

    @Test func descriptionTextJoinsTitleAndDescription() {
        #expect(BotIdentity.descriptionText(title: "", description: "Sorts my email") == "Sorts my email")
        #expect(BotIdentity.descriptionText(title: "Triage", description: " Sorts my email ") == "Triage — Sorts my email")
        #expect(BotIdentity.descriptionText(title: "", description: "  ") == "")
    }

    @Test func composesTheSoulAsTheSpecExample() {
        let soul = BotIdentity.composeSoul(slug: "inbox-triage", title: "", description: "Sorts my email", serverInjectsProtocol: true)
        #expect(soul == "# Inbox Triage\n\n**Mission:** Sorts my email\n\nYou are Inbox Triage, a persistent named agent (profile `inbox-triage`) on this machine.\nYou keep your own memory, skills, and conversation history across sessions.")
        let titled = BotIdentity.composeSoul(slug: "u5c0f-u52a9-u624b", title: "小助手", description: "", serverInjectsProtocol: true)
        #expect(titled.hasPrefix("# 小助手\n\n**Role:** 小助手\n\nYou are 小助手"))
        let bare = BotIdentity.composeSoul(slug: "notes", title: "", description: "", serverInjectsProtocol: true)
        #expect(bare == "# Notes\n\n\nYou are Notes, a persistent named agent (profile `notes`) on this machine.\nYou keep your own memory, skills, and conversation history across sessions.")
        let older = BotIdentity.composeSoul(slug: "notes", title: "", description: "", serverInjectsProtocol: false,
                                            teammates: [("ivy", "Plans trips"), ("notes", nil)])
        #expect(older.contains("## Messaging other agents"))
        #expect(older.contains("- `ivy` — Plans trips"))
        #expect(!older.contains("- `notes`"))
    }
}

// MARK: - U5 gateway names (`S/connection-offline.test.ts`, `S/gateway-accounts.test.ts`)

@Suite struct GatewayNamingTests {
    @Test func namesTheGatewayByItsComputer() {
        let cases: [(String, String)] = [
            ("http://100.101.102.103:9119", "Your Gateway"), ("http://127.0.0.1:9241", "Your Gateway"),
            ("http://[::1]:9119", "Your Gateway"), ("http://localhost:9119", "Your Gateway"),
            ("https://mac-mini.tail1234.ts.net", "Mac mini"), ("http://alexs-Mac-Studio.local:9119", "Alex’s Mac Studio"),
            ("http://alexs-macbook-pro.local:9119", "Alex’s MacBook Pro"), ("", "Your Gateway"), ("not a url", "Your Gateway"),
        ]
        for (url, expected) in cases { #expect(GatewayNaming.friendlyName(URL(string: url)) == expected, "\(url)") }
    }

    @Test func putsTheAddressOnItsOwnLine() {
        #expect(GatewayNaming.host(URL(string: "http://100.101.102.103:9119/"), port: true) == "100.101.102.103:9119")
        #expect(GatewayNaming.host(URL(string: "https://gw.example.com/path"), port: true) == "gw.example.com")
        #expect(GatewayNaming.host(nil, port: true) == "")
    }

    @Test func rowsNameEachGatewayWithWhoIsSignedIn() {
        let a = GatewayNaming.row(url: URL(string: "https://office-mac.tail1234.ts.net")!, label: nil, accountName: "owner", hasSession: true)
        #expect(a.title == "Office Mac" && a.subtitle == "office-mac.tail1234.ts.net · owner")
        let b = GatewayNaming.row(url: URL(string: "http://100.101.102.103:9400")!, label: nil, accountName: "qa", hasSession: false)
        #expect(b.title == "100.101.102.103:9400" && b.subtitle == "qa · Signed Out")
        let named = GatewayNaming.row(url: URL(string: "http://100.101.102.103:9400")!, label: "Work Server", accountName: "qa", hasSession: true)
        #expect(named.title == "Work Server" && named.subtitle == "100.101.102.103:9400 · qa")
        let blank = GatewayNaming.row(url: URL(string: "http://100.101.102.103:9400")!, label: "  ", accountName: "qa", hasSession: true)
        #expect(blank.title == "100.101.102.103:9400")
    }

    /// UX study #120, #129, #269: Sign Out and Remove name the gateway, where the app goes and what this phone deletes.
    @Test func signOutAndRemoveSayWhatGoes() {
        let device = DeviceWord.name
        #expect(SignOutWords.lost(unsent: 0, recordings: 0) == "its drafts")
        #expect(SignOutWords.lost(unsent: 1, recordings: 0) == "its drafts and 1 unsent message")
        #expect(SignOutWords.lost(unsent: 2, recordings: 1) == "its drafts, 2 unsent messages and 1 voice recording")
        let only = SignOutWords.signOut(name: "Home Mac", next: nil, unsent: 0, recordings: 0)
        #expect(only.title == "Sign out of Home Mac?")
        #expect(only.message == "Its drafts on this \(device) are deleted. Your bots and chats stay on Home Mac. You can sign in again any time.")
        let two = SignOutWords.signOut(name: "Studio", next: "Mac Mini", unsent: 2, recordings: 3)
        #expect(two.message == "Studio leaves this list and Hermes HQ switches to Mac Mini. Its drafts, 2 unsent messages and "
                + "3 voice recordings on this \(device) are deleted. Your bots and chats stay on Studio. You can sign in again any time.")
        #expect(SignOutWords.remove(accountName: "qa", unsent: 0, recordings: 0)
                == "qa is signed out of this gateway on this \(device), and its drafts here are deleted. You can add it again.")
    }

    @Test func nousAccountsReadNousAccount() {
        let nous = GatewayAccount(id: "x", baseURL: URL(string: "http://127.0.0.1:9739")!, kind: .nous, username: nil, label: "x")
        #expect(GatewayNaming.accountName(nous) == "Nous account")
        let password = GatewayAccount(id: "y", baseURL: URL(string: "http://127.0.0.1:9738")!, kind: .password, username: "qa", label: "y")
        #expect(GatewayNaming.accountName(password) == "qa")
        #expect(SettingsHub.cleanVersion("v0.21.5+abc") == "0.21.5")
        #expect(SettingsHub.cleanVersion("0.21.5-dev") == "0.21.5")
    }
}

// MARK: - U6 news (`S/gateway-switcher.test.ts`)

@Suite struct GatewayNewsTests {
    private func row(_ name: String, _ id: String, last: Double, count: Int = 6, resolved: String? = nil, meta: [String: JSONValue]? = nil) -> JSONValue {
        var session: [String: JSONValue] = ["id": .string(id), "last_active": .number(last), "message_count": .number(Double(count))]
        if let resolved { session["resolved_id"] = .string(resolved) }
        var o: [String: JSONValue] = ["name": .string(name), "canonical_session": .object(session)]
        if let meta { o["ui_meta"] = ["hermes-bots": .object(meta)] }
        return .object(o)
    }

    private func state(baselines: [String: Double] = [:], markers: [String: [String]] = [:]) -> BotDeviceState {
        var state = BotDeviceState()
        state.unread.baselines = baselines
        state.unread.markers = markers
        return state
    }

    @Test func readsTheParkedRosterWithBaselinesAndMarkers() {
        let chats = GatewayNews.parkedChats(roster: [row("default", "c1", last: 100), row("mail", "c2", last: 200, resolved: "c2b")],
                                            state: state(baselines: ["default": 100], markers: ["mail": ["c2"]]))
        #expect(chats == [ParkedChat(owner: "default", id: "c1", ids: ["c1"], profile: nil, baseline: 100, marked: false),
                          ParkedChat(owner: "mail", id: "c2b", ids: ["c2", "c2b"], profile: "mail", baseline: nil, marked: true)])
    }

    @Test func leavesOutHiddenBotsEmptyChatsAndBotsWithNoChat() {
        let rows = [row("hidden", "h", last: 1, meta: ["hidden": true]), row("empty", "e", last: 1, count: 0), .object(["name": "new"]),
                    row("kept", "k", last: 1)]
        #expect(GatewayNews.parkedChats(roster: rows, state: nil).map(\.id) == ["k"])
        #expect(GatewayNews.parkedChats(roster: [], state: nil).isEmpty)
    }

    @Test func capsAtForty() {
        let rows = (0..<50).map { row("b\($0)", "s\($0)", last: 1) }
        #expect(GatewayNews.parkedChats(roster: rows, state: nil).count == 40)
    }

    @Test func countsAnsweredAndMarkedBots() {
        let chats = GatewayNews.parkedChats(roster: ["a", "b", "c", "d"].map { row($0, $0, last: 10) },
                                            state: state(baselines: ["a": 10, "b": 10, "d": 10], markers: ["c": ["c"]]))
        let live = [ParkedChatLive(id: "a", lastActive: 11, messageCount: 8), ParkedChatLive(id: "b", lastActive: 10, messageCount: nil),
                    ParkedChatLive(id: "d", lastActive: 12, messageCount: 0)]
        #expect(GatewayNews.unreadCount(chats, live: live) == 2)
    }

    @Test func neverCountsABotWithNoBaselineOrNoAnswer() {
        let unseen = GatewayNews.parkedChats(roster: [row("x", "x", last: 1)], state: nil)
        #expect(GatewayNews.unreadCount(unseen, live: [ParkedChatLive(id: "x", lastActive: 99, messageCount: 2)]) == 0)
        let chats = GatewayNews.parkedChats(roster: ["a", "c"].map { row($0, $0, last: 10) }, state: state(baselines: ["a": 10], markers: ["c": ["c"]]))
        #expect(GatewayNews.unreadCount(chats, live: []) == 1)
        #expect(GatewayNews.newsLabel(1) == "1 New" && GatewayNews.newsLabel(12) == "9+ New" && GatewayNews.newsLabel(0) == nil)
    }
}

// MARK: - U7 heads (web values generated from `S/ui-heads/head.ts` + `labels.ts` with Node)

@Suite struct HeadRecordTests {
    private func web() throws -> JSONValue { try JSONValue.parse(try BotsFixture.data("settings-web-heads")) }

    /// Compares every field, except `hat`, which native always writes as "none" (§7.6).
    private func same(_ record: HeadRecord, _ expected: JSONValue?, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .object(var want)? = expected, case .object(var got) = record.stored else { Issue.record("not objects"); return }
        want["hat"] = nil; got["hat"] = nil
        #expect(got == want, sourceLocation: sourceLocation)
    }

    @Test func storedHeadOfTheDefaultAndOfAnEditMatchTheSpec() throws {
        let web = try web()
        same(HeadRecord.defaultShapeRecord(profile: "ivy"), web["defaultIvy"])
        var edited = HeadRecord.defaultShapeRecord(profile: "ivy")
        edited.form = "hex"; edited.look = "ovals"
        #expect(edited.stored == web["editedIvy"])          // hat "none" both sides: the §7.5 example exactly
    }

    @Test func rollHeadAndIdeasMatchTheWebWithAFixedSeed() throws {
        let web = try web()
        var random = SeededRandom(seed: 42)
        let roll = HeadRecord.roll({ random.next() }, theme: "shape")
        same(roll, web["roll42"])
        #expect(roll.hat == "none")
        var hashed = SeededRandom(seed: Head.nameHash("research|shape|3"))
        same(HeadRecord.roll({ hashed.next() }, theme: "shape"), web["rollHash"])
        let ideas = HeadRecord.ideas(profile: "ivy", about: "Ivy Plans trips", round: 0)
        #expect(ideas.count == 10)
        for (index, idea) in ideas.enumerated() { same(idea, web["ideasIvy"]?[index]) }
        let inbox = HeadRecord.ideas(profile: "inbox", about: "Inbox Sorts my email", round: 1)
        for (index, idea) in inbox.enumerated() { same(idea, web["ideasInbox"]?[index]) }
    }

    @Test func parseHeadMatchesTheWebForOldRecords() throws {
        let web = try web()
        let old = HeadRecord.parse(["theme": "shape", "color": "teal", "seed": 5.5, "form": "star", "mouth": "smile", "blush": true, "tile": "dark", "v": 4])
        var want = web["parsedOld"]?.object ?? [:]
        want["headset"] = false
        #expect(old?.stored == .object(want))
        var dots = web["parsedDots"]?.object ?? [:]
        dots["headset"] = false
        #expect(HeadRecord.parse(["theme": "dots", "pattern": "face", "seed": 1234, "v": 3])?.stored == .object(dots))
        #expect(HeadRecord.parse(.string("x")) == nil)
        #expect(HeadRecord.parse(["color": "teal"]) == nil)
        // Round trip, the web's default and the app's.
        let record = HeadRecord.defaultShapeRecord(profile: "research")
        #expect(HeadRecord.parse(record.stored) == record)
        let matrix = HeadRecord.defaultMatrixRecord(profile: "research")
        #expect(matrix.theme == "matrix")
        #expect(HeadRecord.parse(matrix.stored) == matrix)
    }

    @Test func savesNeverWriteAHat() {
        var record = HeadRecord.defaultRecord(profile: "x")
        record.hat = "crown"
        #expect(record.forSaving.hat == "none")
        #expect(record.forSaving.stored["hat"] == "none")
        #expect(HeadRecord.parse(["theme": "robot", "shape": "dome"])?.themedAsShape.tile == "none")
    }

    @Test func recognisesTheDesktopCopyBy288Square() {
        func png(_ w: UInt32, _ h: UInt32) -> String {
            var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
            for value in [w, h] { bytes += [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
            bytes += [8, 6, 0, 0, 0]
            return "data:image/png;base64," + Data(bytes).base64EncodedString()
        }
        #expect(HeadRecord.isHeadMirror(png(288, 288)))
        #expect(!HeadRecord.isHeadMirror(png(288, 512)))
        #expect(!HeadRecord.isHeadMirror(png(512, 512)))
        #expect(!HeadRecord.isHeadMirror("data:image/jpeg;base64,/9j/4AAQ"))
        #expect(!HeadRecord.isHeadMirror(nil))
        // The app's own copy really is 288 × 288.
        let mirror = EditHeadModel.mirrorPNG(Head.defaultHead(profile: "ivy"))
        #expect(HeadRecord.isHeadMirror(mirror))
    }
}

// MARK: - U8 install-blocked parsing (`V/store/hub-actions.ts:201-222`)

@Suite struct InstallBlockedTests {
    @Test func currentAndLegacyShapes() {
        let current = ["Scanning…", "Not installed: the security scan found 2 high-risk pattern(s) in 'org/skill' (listed above).",
                       "Hermes never installs unverified skills with high-risk findings, even with --force."]
        #expect(CapabilitiesStore.installBlocked(current)! == (2, true))
        let wrapped = ["Not installed:   the security scan found", "high-risk pattern(s) in 'official/x'. Re-run with --force."]
        #expect(CapabilitiesStore.installBlocked(wrapped)! == (0, false))
        let legacy = ["Installation blocked: Blocked (community source + caution verdict, 3 findings). Use --force to override."]
        #expect(CapabilitiesStore.installBlocked(legacy)! == (3, true))
        let official = ["Installation blocked: Blocked (official source + caution verdict, 1 finding)."]
        #expect(CapabilitiesStore.installBlocked(official)! == (1, false))
        #expect(CapabilitiesStore.installBlocked(["Installed blender-mcp"]) == nil)
        #expect(CapabilitiesStore.blockedMessage(findings: 2, unverified: true)
                == "The security scan flagged 2 items to review and the skill comes from an unverified source. Read the scan before deciding whether to trust the author.")
        #expect(CapabilitiesStore.blockedMessage(findings: 0, unverified: false)
                == "The security scan flagged risky patterns to review. Read the scan before deciding whether to trust the author.")
    }
}

@Suite struct LicenceReflowTests {
    @Test func paragraphsJoinAndBlankLinesStay() {
        let text = "MIT License\n\nCopyright (c) 2025 Nous Research\n\nPermission is hereby granted, free of charge,\n   to any person obtaining a copy\r\n\n\nTHE SOFTWARE IS PROVIDED \"AS IS\"\n"
        #expect(LicensesView.reflow(text) == "MIT License\n\nCopyright (c) 2025 Nous Research\n\n"
                + "Permission is hereby granted, free of charge, to any person obtaining a copy\n\nTHE SOFTWARE IS PROVIDED \"AS IS\"")
    }

    // [morepages] The list is generated now (Tests/Settings/LicenseNoticesTests.swift checks it against Package.resolved).
    @Test func everyBundledLicenceLoads() async {
        let notices = await LicenseNotices.load(bundle: Bundle(for: AppDelegate.self)) ?? []
        #expect(notices.count >= 4)
        for notice in notices {
            let text = LicensesView.reflow(notice.text)
            #expect(text.count > 500, "\(notice.name)")
            #expect(!text.contains("\n\n\n"))
        }
    }
}

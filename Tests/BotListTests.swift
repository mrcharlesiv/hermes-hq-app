import Foundation
import Testing
@testable import HermesHQNative

struct BotListTests {
    private func bot(_ id: String, minutes: Double? = nil, pinned: Bool = false, pinOrder: Int? = nil,
                     section: String? = nil, hidden: Bool = false, unread: Bool = false, working: Bool = false,
                     preview: String? = nil, role: String? = nil) -> Bot {
        Bot(id: id, name: id.capitalized, role: role, preview: preview,
            lastActive: minutes.map { Date(timeIntervalSince1970: 1_800_000_000 - $0 * 60) }, isWorking: working,
            unread: unread, pinned: pinned, pinOrder: pinOrder, sectionName: section, hidden: hidden,
            canonicalSessionId: nil, head: nil)
    }

    @Test func sortPinnedFirstThenRecentStable() {
        let bots = [bot("a", minutes: 50), bot("b", minutes: 5), bot("c", pinned: true), bot("d"), bot("e", minutes: 5), bot("f")]
        #expect(BotList.sorted(bots).map(\.id) == ["c", "b", "e", "a", "d", "f"])
    }

    @Test func layoutTopToBottom() {
        let bots = [
            bot("x", minutes: 1, section: "Work"),
            bot("p1", minutes: 9, pinned: true),
            bot("y", minutes: 2),
            bot("p2", minutes: 3, pinned: true, pinOrder: 1),
            bot("h", minutes: 0, hidden: true),
            bot("z", minutes: 3, section: "Play"),
            bot("w", minutes: 4, section: "Work"),
            bot("lost", minutes: 5, section: "Pinned"),       // filed in Pinned by hand, not pinned: no home here
        ]
        let sections = BotList.compose(bots)
        #expect(sections.map(\.id) == [.tiles, .user("Work"), .user("Play"), .unassigned, .hidden])
        #expect(sections[0].bots.map(\.id) == ["p2", "p1"])          // dragged order first
        #expect(sections[1].bots.map(\.id) == ["x", "w"])
        #expect(sections[3].bots.map(\.id) == ["y", "lost"])
        #expect(sections[4].bots.map(\.id) == ["h"])
        #expect(sections[1].title == "Work" && sections[0].title == nil && sections[3].title == nil)
    }

    @Test func pinsBeyondSixFillThePinnedSection() {
        let bots = (0..<8).map { bot("p\($0)", minutes: Double($0), pinned: true) }
        let sections = BotList.compose(bots)
        #expect(sections.map(\.id) == [.tiles, .pinned])
        #expect(sections[0].bots.count == 6)
        #expect(sections[1].bots.map(\.id) == ["p6", "p7"])
        #expect(sections[1].title == "Pinned")
    }

    @Test func noSectionsIsAPlainList() {
        let sections = BotList.compose([bot("a", minutes: 1), bot("b", minutes: 2)])
        #expect(sections.map(\.id) == [.unassigned])
        #expect(BotList.compose([]).isEmpty)
    }

    @Test func secondLineRanking() {
        #expect(BotList.secondLine(bot("a", working: true, preview: "hi")) == ("Working…", .tint))
        #expect(BotList.secondLine(bot("a", preview: "  hi  ")).text == "hi")
        #expect(BotList.secondLine(bot("a", preview: " ", role: "Bookings")).text == "Bookings")
        #expect(BotList.secondLine(bot("a")).text == "No messages yet")
    }

    @Test func searchAndBadges() {
        let bots = [bot("ivy", preview: "Lunch at noon"), bot("otto", role: "Marketing"), bot("pool", hidden: true, unread: true),
                    bot("wren", unread: true)]
        #expect(BotList.search(bots, query: "lunch").map(\.id) == ["ivy"])
        #expect(BotList.search(bots, query: "MARK").map(\.id) == ["otto"])
        #expect(BotList.search(bots, query: "po").map(\.id) == ["pool"])     // hidden bots are found too
        #expect(BotList.search(bots, query: "  ").isEmpty)
        #expect(BotList.unreadCount(bots) == 1)                               // hidden bots don't count
        #expect(BotList.accessibilityLabel(bot("wren", pinned: true, unread: true, preview: "Hi"), time: "9:05 AM")
                == "Wren. Hi. 9:05 AM. Unread. Pinned")
    }

    /// A running turn moves the chat's last_active, so a working bot is often marked unread: the circle, the tint time,
    /// "Unread" and the tab badge wait for the turn to end (owner, 2026-10-30: a solid circle beside the typing dots).
    @Test func aWorkingBotHidesItsUnreadCircle() {
        let working = bot("wren", unread: true, working: true, preview: "Hi")
        #expect(!BotList.showsUnread(working))
        #expect(BotList.unreadCount([working]) == 0)
        #expect(!BotList.accessibilityLabel(working, time: "9:05 AM").contains("Unread"))
        #expect(BotList.showsUnread(bot("wren", unread: true)))                 // the mark shows once the turn ends
        #expect(!BotList.showsUnread(bot("wren", working: true)))
    }

    @Test func aTimedMuteIsSpokenWithItsEnd() {
        let noon = Date(timeIntervalSince1970: 1_800_000_000)
        let us = Locale(identifier: "en_US"), utc = TimeZone(identifier: "UTC")!
        let hour = BotMute(always: false, until: noon.addingTimeInterval(3600))
        #expect(BotList.mutedWords(hour, now: noon, locale: us, timeZone: utc).hasPrefix("Muted until "))
        #expect(BotList.mutedWords(.forever, now: noon) == "Muted")
        #expect(BotList.mutedWords(nil, now: noon) == "Muted")
        #expect(BotList.accessibilityLabel(bot("wren", preview: "Hi"), time: "", muted: true, mute: .forever) == "Wren. Hi. Muted")
    }

    @Test func readableProfileNames() {
        #expect(SessionsViewController.readableProfileName("default") == "Hermes")
        #expect(SessionsViewController.readableProfileName("research-buddy") == "Research Buddy")
        #expect(SessionsViewController.readableProfileName("bike_shop") == "Bike Shop")
    }
}

struct SignInTests {
    @Test func waysFromProbe() {
        #expect(SignInWays(nil) == .both)
        #expect(SignInWays(SignInOptions(reachable: false, offersNous: true, offersPassword: false)) == .both)
        #expect(SignInWays(SignInOptions(reachable: true, offersNous: true, offersPassword: false)) == .nous)
        #expect(SignInWays(SignInOptions(reachable: true, offersNous: false, offersPassword: true)) == .password)
        #expect(SignInWays(SignInOptions(reachable: true, offersNous: true, offersPassword: true)) == .both)
        #expect(SignInWays(SignInOptions(reachable: true, offersNous: false, offersPassword: false)) == .both)
    }

    @Test func addressNormalisation() {
        #expect(SignInAddress.normalize("  mac-mini.tail1234.ts.net ") == "http://mac-mini.tail1234.ts.net")
        #expect(SignInAddress.normalize("hermes.example.com") == "https://hermes.example.com")
        #expect(SignInAddress.normalize("HTTPS://Hermes.example.com/x") == "https://Hermes.example.com/x")
        #expect(SignInAddress.normalize("192.168.1.20:9119") == "http://192.168.1.20:9119")
        #expect(SignInAddress.normalize("100.119.0.1") == "http://100.119.0.1")
        #expect(SignInAddress.normalize("8.8.8.8") == "https://8.8.8.8")
        #expect(SignInAddress.normalize("localhost:9119") == "http://localhost:9119")
        #expect(SignInAddress.normalize("mac-mini") == "http://mac-mini")
        #expect(SignInAddress.normalize("[::1]:9119") == "http://[::1]:9119")
        // Digits other than ASCII are not an IP address (and never crash): "١٠.٠.٠.١" is Arabic-Indic 10.0.0.1.
        #expect(SignInAddress.normalize("١٠.٠.٠.١") == "https://١٠.٠.٠.١")
        #expect(SignInAddress.normalize("¹⁰.0.0.1") == "https://¹⁰.0.0.1")
        #expect(!SignInAddress.isLocalHost("١٠.٠.٠.١") && !SignInAddress.isLocalHost("١٢٧.0.0.1"))
        #expect(SignInAddress.isLocalHost("10.0.0.1") && !SignInAddress.isLocalHost("300.0.0.1"))
        #expect(SignInAddress.looksLikeAddress("my-mac.tail1234.ts.net"))
        #expect(SignInAddress.looksLikeAddress("https://a.b"))
        #expect(!SignInAddress.looksLikeAddress("mac-mini"))
        #expect(!SignInAddress.looksLikeAddress("localhost:9119"))
    }

    @Test func errorCopy() {
        #expect(SignInCopy.code(for: SignInError("auth-rejected")) == "auth-rejected")
        #expect(SignInCopy.code(for: SignInError("something-new")) == "gateway-error")
        #expect(SignInCopy.code(for: URLError(.timedOut)) == "timeout")
        #expect(SignInCopy.code(for: URLError(.cannotFindHost)) == "unreachable")
        #expect(SignInCopy.code(for: URLError(.serverCertificateUntrusted)) == "tls")
        #expect(SignInCopy.code(for: HTTPError(status: 429, body: nil)) == "rate-limited")
        #expect(SignInCopy.message(for: SignInError("nous-cancelled")) == "")
        #expect(SignInCopy.message(for: SignInError("auth-rejected")) == "Hermes didn’t accept that username or password.")
        #expect(SignInCopy.marksAddress("unreachable") && !SignInCopy.marksAddress("tailscale-off"))
    }
}

/// The screen's model against a scripted driver whose answers the test releases, so nothing waits on the clock.
struct SignInModelTests {
    final class Driver: SignInDriving {
        var probes: [String] = []
        private var pending: [CheckedContinuation<SignInOptions, Never>] = []
        var passwordError: Error?
        var signIns = 0
        /// Probes asked and not yet answered.
        var waiting: Int { pending.count }

        func probe(_ address: String) async -> SignInOptions {
            probes.append(address)
            return await withCheckedContinuation { pending.append($0) }
        }
        /// Answers the oldest unanswered probe.
        func answer(_ options: SignInOptions) { pending.removeFirst().resume(returning: options) }
        func signInWithPassword(address: String, username: String, password: String) async throws {
            signIns += 1
            if let passwordError { throw passwordError }
        }
        func signInWithNous(address: String) async throws { signIns += 1; throw SignInError("nous-cancelled") }
    }

    static let nousOnly = SignInOptions(reachable: true, offersNous: true, offersPassword: false)
    static let passwordOnly = SignInOptions(reachable: true, offersNous: false, offersPassword: true)

    /// Waits until `condition` holds (yielding, then 1 ms naps), up to 5 s: waits on state, never a fixed time.
    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    @Test func probesAfterThePauseAndAppliesTheAnswer() async {
        let driver = Driver()
        let model = SignInModel(driver: driver, onSignedIn: {})
        model.delay = .milliseconds(1)
        #expect(model.ways == nil)
        model.address = "mac-mini.tail1234.ts.net"
        #expect(await until { driver.waiting == 1 })
        #expect(driver.probes == ["http://mac-mini.tail1234.ts.net"])
        #expect(model.checking && model.ways == nil)
        driver.answer(Self.nousOnly)
        await model.probeTask?.value
        #expect(model.ways == .nous && !model.checking && model.waysAreCurrent)
        model.ask()                              // same text: not asked again
        #expect(driver.probes.count == 1 && driver.waiting == 0)
        model.address = ""
        #expect(model.ways == nil && !model.checking)
    }

    /// The field changed while its address was asked about, then came back: the old answer is dropped, the address
    /// is asked afresh, and the spinner never sticks.
    @Test func answerForAnOlderFieldIsNeverApplied() async {
        let driver = Driver()
        let model = SignInModel(driver: driver, onSignedIn: {})
        model.delay = .seconds(600)              // the pause never ends by itself; `ask()` stands in for it
        model.address = "a.example.com"
        model.ask()
        let first = model.probeTask
        #expect(await until { driver.waiting == 1 })
        model.address = "a.example.comx"         // typed while asking
        #expect(!model.waysAreCurrent)
        driver.answer(Self.nousOnly)
        await first?.value
        #expect(model.ways == nil)               // dropped: the field holds other text
        #expect(model.checking)
        model.address = "a.example.com"          // deleted again before the pause ended
        model.ask()
        #expect(await until { driver.waiting == 1 })
        #expect(driver.probes.count == 2)        // asked afresh, not skipped as "already asked"
        driver.answer(Self.passwordOnly)
        await model.probeTask?.value
        #expect(model.ways == .password && !model.checking && model.waysAreCurrent)
    }

    /// Two asks in flight: only the newer one's answer counts, whichever arrives first.
    @Test func olderAskNeverOverwritesANewerOne() async {
        let driver = Driver()
        let model = SignInModel(driver: driver, onSignedIn: {})
        model.delay = .seconds(600)
        model.address = "a.example.com"
        model.ask()
        let first = model.probeTask
        #expect(await until { driver.waiting == 1 })
        model.address = "b.example.com"
        model.ask()
        #expect(await until { driver.waiting == 2 })
        driver.answer(Self.nousOnly)             // a.example.com's answer
        await first?.value
        #expect(model.ways == nil && model.checking)
        driver.answer(Self.passwordOnly)         // b.example.com's answer
        await model.probeTask?.value
        #expect(model.ways == .password && !model.checking)
        #expect(driver.probes == ["https://a.example.com", "https://b.example.com"])
    }

    @Test func notAnAddressShowsBothWithoutAsking() async {
        let driver = Driver()
        let model = SignInModel(driver: driver, onSignedIn: {})
        model.address = "mac-mini"
        model.ask()
        #expect(model.ways == .both)
        #expect(driver.probes.isEmpty)
    }

    @Test func passwordFailuresAreSaidOnce() async {
        let driver = Driver()
        driver.passwordError = SignInError("auth-rejected")
        var signedIn = false
        let model = SignInModel(driver: driver, onSignedIn: { signedIn = true })
        model.delay = .seconds(600)
        model.signInWithPassword()
        #expect(model.error == SignInCopy.messages["missing-fields"])
        #expect(driver.signIns == 0)
        model.address = "fleet.example.com"; model.username = "fleet"; model.password = "nope"
        model.signInWithPassword()
        await model.attemptTask?.value
        #expect(driver.signIns == 1)             // one attempt per tap, never retried
        #expect(model.error == SignInCopy.messages["auth-rejected"])
        #expect(model.passwordInvalid && !model.addressInvalid)
        #expect(model.busy == nil && !signedIn)
        model.password = "fleet"                 // typing clears the mark
        #expect(!model.passwordInvalid)
        driver.passwordError = nil
        model.signInWithPassword()
        await model.attemptTask?.value
        #expect(signedIn && driver.signIns == 2)
    }

    @Test func cancelledNousSheetSaysNothing() async {
        let driver = Driver()
        let model = SignInModel(driver: driver, address: "", onSignedIn: {})
        model.delay = .seconds(600)
        model.signInWithNous()
        #expect(model.error == "Enter the address, then tap Sign in with Nous.")
        model.address = "nous.example.com"
        model.signInWithNous()
        await model.attemptTask?.value
        #expect(driver.signIns == 1)
        #expect(model.error == nil && model.busy == nil)
    }
}

// Screen-side regression tests for integration verification round 1: voice memos in your bubble, the delivery caption
// under an unconfirmed send, the error card's ✕ and Details, code that never wraps, and the Sessions twins.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
struct VerificationRoundOneScreenTests {
    let style = ChatStyle.make(category: .large)

    private func input(_ messages: [ChatMessage], expanded: Set<String> = []) -> ChatRowBuilder.Input {
        ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Ivy", expanded: expanded, scope: "test|ivy|s1")
    }

    // MARK: Voice memos (R:src/voice-memo.ts memoParts)

    @Test func voiceMemoParsesTheStoredShape() throws {
        let stored = "MEDIA:\"/home/hermes/uploads/voice-memo.wav\"\n\nVoice memo transcript: Remind me to review the pump quote."
        let memo = try #require(VoiceMemo.parse(stored))
        #expect(memo.path == "/home/hermes/uploads/voice-memo.wav")
        #expect(memo.transcript == .text("Remind me to review the pump quote."))
        #expect(memo.title == "Voice Memo")
        #expect(memo.rest.isEmpty)
        let typed = try #require(VoiceMemo.parse("MEDIA:\"/tmp/voice-memo-2.m4a\"\nVoice memo transcript: (unavailable)\n\nAnd this too"))
        #expect(typed.transcript == .failed)
        #expect(typed.rest == "And this too")
        #expect(VoiceMemo.parse("MEDIA:\"/tmp/report.pdf\"\nhello") == nil)           // not audio
        #expect(VoiceMemo.parse("see MEDIA:\"/tmp/voice-memo.wav\"") == nil)          // not leading
        #expect(VoiceMemo.parse("MEDIA:\"/tmp/song.mp3\"")?.title == "song.mp3")
        #expect(VoiceMemo.parse("MEDIA:\"/tmp/voice-memo.wav\"\nVoice memo transcript: (unavailable: speech-to-text is off on the gateway)")?.transcript == .off)
    }

    @Test func voiceMemoBubbleNeverShowsTheDirective() throws {
        let text = "MEDIA:\"/home/hermes/uploads/voice-memo.wav\"\n\nVoice memo transcript: Remind me at nine."
        let message = ChatMessage(id: "stored-row-4-user", role: .user, parts: [.text(text)], timestamp: Date(), rowId: 4)
        let rows = ChatRowBuilder.build(input([message]))
        let bubbles = rows.compactMap { row -> BubbleRow? in if case .bubble(let b) = row.kind { return b } else { return nil } }
        #expect(bubbles.count == 1)
        // VOICE (spec 1x-voice §5): the memo is an audio message now; its transcript is the only text drawn.
        #expect(bubbles[0].memo?.title == "Voice Memo")
        #expect(bubbles[0].text == "Remind me at nine.")
        let layout = TextLayout.make(rows.first { $0.isBubble }!, width: 402, style: style)
        guard case .bubble(let b) = layout.content, let memo = b.memo else { Issue.record("expected a memo bubble"); return }
        let drawn = memo.words.text.string
        #expect(b.blocks.isEmpty)
        #expect(!drawn.contains("MEDIA"))
        #expect(!drawn.contains("/home/hermes"))
        #expect(drawn == "Remind me at nine.")
        #expect(memo.info.path == "/home/hermes/uploads/voice-memo.wav")
    }

    // MARK: Delivery unconfirmed (spec 04 §2.5, spec 06 §5.6.4)

    @Test func unconfirmedSendShowsACheckCaption() {
        var message = ChatMessage(id: "local-user-1", role: .user, parts: [.text("lost ack")], timestamp: Date(), rowId: nil)
        message.error = LiveChatSession.unconfirmedMark
        let rows = ChatRowBuilder.build(input([message]))
        guard case .sendState(let state)? = rows.last?.kind else { Issue.record("expected the delivery caption"); return }
        #expect(state.text == "Delivery Unconfirmed · Check")
        #expect(state.actionable)
        guard case .line(let line) = TextLayout.make(rows.last!, width: 402, style: style).content else { Issue.record("a line"); return }
        #expect((line.tapFrame?.width ?? 0) >= 44 && (line.tapFrame?.height ?? 0) >= 32)
        // While the check runs.
        let checking = ChatRowBuilder.build(input([message], expanded: [ChatRowBuilder.checkingKey(message.id)]))
        guard case .sendState(let busy)? = checking.last?.kind else { Issue.record("expected the caption"); return }
        #expect(busy.text == "Checking Delivery…")
        #expect(!busy.actionable)
    }

    // MARK: The error card (spec 06 §5.6.1)

    @Test func errorCardHasCloseAndDetailsAndCanBeDismissed() {
        var card = ChatMessage(id: "local-error-1", role: .assistant, parts: [], timestamp: Date(), rowId: nil)
        card.error = "Model provider is out of credits."
        let rows = ChatRowBuilder.build(input([card]))
        guard let row = rows.last, case .error = row.kind else { Issue.record("expected the card"); return }
        guard case .error(let e) = TextLayout.make(row, width: 402, style: style).content else { Issue.record("card layout"); return }
        #expect(e.closeFrame.width >= 44 && e.closeFrame.height >= 44)
        #expect(e.detailsFrame.height >= 44)
        #expect(e.detailsFrame.maxY <= e.cardFrame.height)
        #expect(e.titleFrame.maxX <= e.closeFrame.minX + 4)        // the title never runs under the ✕
        let dismissed = ChatRowBuilder.build(input([card], expanded: [ChatRowBuilder.dismissedErrorKey(card.id)]))
        #expect(!dismissed.contains { if case .error = $0.kind { return true } else { return false } })
    }

    // MARK: Code never wraps (spec 06 §2.6)

    @Test func longCodeLinesScrollSideways() {
        let line = String(repeating: "let value = compute(); ", count: 8)
        let markdown = "```swift\n\(line)\n```"
        let row = ChatRow(id: "m|b0", messageId: "m", scope: "s", fingerprint: 7,
                          kind: .bubble(BubbleRow(mine: false, text: markdown, markdown: true, partIndex: 0, joinsAbove: false,
                                                  joinsBelow: false, tail: false, time: nil, pending: false, streaming: false,
                                                  speaker: nil)),
                          gapAbove: 0, variant: 0)
        guard case .bubble(let b) = TextLayout.make(row, width: 402, style: style).content, let code = b.blocks.first else {
            Issue.record("expected a code block"); return
        }
        #expect(code.layoutWidth == nil)                            // laid out unbounded
        #expect(code.contentWidth > code.textFrame.width + 1)        // wider than the card: it scrolls
        #expect(code.pieces.first.map { $0.frame.height < style.codeLineHeight * 1.5 } == true)   // one line
    }

    // MARK: Sessions twins (fix161 D18/D22)

    @Test func profileTwinsKeepBothRows() {
        let a = SessionSummary(id: "20261005_120000_ff000001", profile: "bot000", title: "Twin A", preview: nil, lastActive: Date(),
                               source: "desktop", unread: true, isRunning: false)
        var b = a
        b.profile = "bot001"
        b.title = "Twin B"
        #expect(SessionsViewController.key(a) != SessionsViewController.key(b))
        let services = FakeAppServices()
        services.sessions = [a, b]
        let list = SessionsViewController(services: services, makeChat: { _ in UIViewController() })
        list.loadViewIfNeeded()
        list.reload(animated: false)
        let view = list.collectionView!
        let rows = (0..<view.numberOfSections).reduce(0) { $0 + view.numberOfItems(inSection: $1) }
        #expect(rows == 2)                                           // both twins listed
    }
}

/// Records what the tab controller reports (the Sessions list's refresh cadence follows it, spec 03 §7.7).
@MainActor
final class TabRecordingServices: AppServices {
    var account: GatewayAccount?
    var bots: [Bot] = []
    var sessions: [SessionSummary] = []
    var connection: ConnectionState = .ready
    var onBotsChange: (() -> Void)?
    var onSessionsChange: (() -> Void)?
    var onConnectionChange: (() -> Void)?
    var shown: [Bool] = []
    var loaded = true
    var botsLoaded: Bool { loaded }
    func refreshBots() {}
    func refreshSessions() {}
    func chat(for bot: Bot) -> ChatSessionModel { UnavailableChat(title: bot.name, profile: bot.id, head: nil) }
    func chat(for session: SessionSummary) -> ChatSessionModel { UnavailableChat(title: session.title, profile: session.profile, head: nil) }
    func markRead(_ bot: Bot) {}
    func signOut() {}
    func setSessionsListShown(_ shown: Bool) { self.shown.append(shown) }
}

@MainActor
struct VerificationRoundOneListTests {
    @Test func tabsReportWhichListShows() {
        let services = TabRecordingServices()
        let tabs = MainTabController(services: services) { _ in UIViewController() }
        tabs.loadViewIfNeeded()
        #expect(services.shown.last == false)                       // starts on Bots
        tabs.selectedIndex = 1
        #expect(services.shown.last == true)
        tabs.selectedIndex = 0
        #expect(services.shown.last == false)
    }

    /// Connected but no roster answer yet: skeleton rows, not "No Bots Yet".
    @Test func emptyStateWaitsForTheFirstRoster() {
        let services = TabRecordingServices()
        services.loaded = false
        let list = BotsViewController(services: services) { _ in UIViewController() }
        list.loadViewIfNeeded()
        list.reload(animated: false)
        #expect(list.contentUnavailableConfiguration == nil)
        #expect(list.collectionView.numberOfSections == 1 && list.collectionView.numberOfItems(inSection: 0) == 5)   // skeletons
        services.loaded = true
        list.reload(animated: false)
        #expect(list.contentUnavailableConfiguration != nil)        // now it is really empty
    }
}

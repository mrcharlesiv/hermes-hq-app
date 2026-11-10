// Read Aloud (docs/spec/3x-talk.md §7): one reply at a time through the shared speaker, the button's three states,
// the failure wording, and the hold menu's tile.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Read aloud", .serialized)
@MainActor
struct ReadAloudTests {
    @MainActor final class Failures {
        var all: [(scope: String, reason: String)] = []
    }

    private func make(live: Bool = false) -> (ReadAloudCenter, FakeSpeaker, Failures) {
        let center = ReadAloudCenter()
        let speaker = FakeSpeaker()
        let failures = Failures()
        center.speaker = speaker
        center.holdsLeases = false
        center.conversationLive = { live }
        center.onFailure = { scope, failure in failures.all.append((scope, failure.reason)) }
        return (center, speaker, failures)
    }

    @Test func aReplyIsPreparedSpokenAndDone() async {
        let (center, speaker, failures) = make()
        let chat = FakeTalkChat()
        #expect(center.state == .idle)
        #expect(center.button(for: "m1") == .idle)
        center.toggle(messageId: "m1", markdown: "Here is **the plan**.", in: chat)
        #expect(center.state == .preparing("m1"))
        #expect(center.button(for: "m1") == .preparing)
        #expect(center.button(for: "m2") == .idle)
        #expect(center.scope == chat.memoScope)
        // The whole reply is handed over at once and closed.
        #expect(speaker.sessions.count == 1)
        #expect(speaker.sessions.first?.appended == ["Here is **the plan**."])
        #expect(speaker.sessions.first?.finished == true)
        #expect(speaker.owner == .readAloud)
        speaker.begin()
        #expect(center.state == .speaking("m1"))
        #expect(center.button(for: "m1") == .speaking)
        #expect(center.spokenMessageId == "m1")
        speaker.complete()
        #expect(await waitUntil { center.state == .idle })
        #expect(center.spokenMessageId == nil)
        #expect(failures.all.isEmpty)
    }

    @Test func tappingTheSameReplyStopsAndAnotherReplyTakesOver() async {
        let (center, speaker, _) = make()
        let chat = FakeTalkChat()
        center.toggle(messageId: "m1", markdown: "One.", in: chat)
        speaker.begin()
        // Another reply switches (T30): one voice at a time.
        center.toggle(messageId: "m2", markdown: "Two.", in: chat)
        #expect(center.state == .preparing("m2"))
        #expect(speaker.sessions.count == 2)
        #expect(center.button(for: "m1") == .idle)
        speaker.begin()
        #expect(center.state == .speaking("m2"))
        // The same reply again stops.
        center.toggle(messageId: "m2", markdown: "Two.", in: chat)
        #expect(center.state == .idle)
        #expect(speaker.stops >= 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(center.state == .idle)
    }

    @Test func aReplyWithNothingToSaySaysSoAndReadRepliesAloudSkipsItQuietly() {
        let (center, speaker, failures) = make()
        let chat = FakeTalkChat()
        center.toggle(messageId: "m1", markdown: "```swift\nlet a = 1\n```", in: chat)
        #expect(center.state == .idle)
        #expect(speaker.sessions.isEmpty)
        #expect(failures.all.map(\.reason) == ["There’s nothing to read in this reply."])
        #expect(!center.read(messageId: "m1", markdown: "   ", in: chat, auto: true))
        #expect(failures.all.count == 1)
        #expect(ReadAloudCenter.failureTitle == "Couldn’t Read Aloud")
    }

    @Test func anUnreachableGatewaySaysSo() {
        let (center, speaker, failures) = make()
        let chat = FakeTalkChat()
        chat.connection = .reconnecting(attempt: 1)
        center.toggle(messageId: "m1", markdown: "Hello.", in: chat)
        #expect(speaker.sessions.isEmpty)
        #expect(failures.all.map(\.reason) == ["The computer running Hermes isn’t reachable right now. Try again when it reconnects."])
    }

    @Test func aFailureCarriesTheGatewaysWordsAndNothingStaysOn() async {
        let (center, speaker, failures) = make()
        let chat = FakeTalkChat()
        center.toggle(messageId: "m1", markdown: "Hello.", in: chat)
        speaker.complete(.failed(reason: "TTS provider is not configured", fatal: false))
        #expect(await waitUntil { failures.all.count == 1 })
        // The card says it plainly (VoicePlainWords); the gateway's words go to the details.
        #expect(failures.all.first?.reason == VoicePlainWords.speechNotSetUp)
        #expect(failures.all.first?.scope == chat.memoScope)
        #expect(center.state == .idle)
    }

    @Test func noAudioInTimeGivesUpWithItsOwnWords() async {
        let (center, speaker, failures) = make()
        center.answerTimeout = 0.2
        let chat = FakeTalkChat()
        center.toggle(messageId: "m1", markdown: "Hello.", in: chat)
        #expect(await waitUntil { failures.all.count == 1 })
        #expect(failures.all.first?.reason == "The voice didn’t answer in time. Try again.")
        #expect(center.state == .idle)
        #expect(speaker.stops == 1)
        // Audio that began in time is never cut off by the timer.
        center.toggle(messageId: "m2", markdown: "Hello again.", in: chat)
        speaker.begin()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(center.state == .speaking("m2"))
        #expect(failures.all.count == 1)
        center.stop()
    }

    @Test("T13: Read Aloud tapped during a conversation plays; Read Replies Aloud and the conversation's own voice are left alone")
    func readAloudDuringAConversation() {
        let (center, speaker, failures) = make(live: true)
        let chat = FakeTalkChat()
        // Read Replies Aloud: the conversation speaks its own replies.
        #expect(!center.read(messageId: "m1", markdown: "Hello.", in: chat, auto: true))
        #expect(speaker.sessions.isEmpty)
        #expect(failures.all.isEmpty)
        // The person's tap plays it (the conversation mutes itself when it takes the session's speaker).
        center.toggle(messageId: "m1", markdown: "Hello.", in: chat)
        #expect(speaker.sessions.count == 1)
        #expect(speaker.owner == .readAloud)
        #expect(center.state == .preparing("m1"))
        center.stop()
        // Not over the conversation's own voice: it says why instead of doing nothing.
        _ = speaker.open(messageId: "m0", profile: nil, client: chat.voiceClient, owner: .conversation, host: nil)
        center.toggle(messageId: "m2", markdown: "Hello again.", in: chat)
        #expect(speaker.owner == .conversation)
        #expect(center.state == .idle)
        #expect(failures.all.map(\.reason) == [ReadAloudCenter.conversationSpeaking])
    }

    @Test func leavingTheChatStopsOnlyItsOwnReading() {
        let (center, speaker, _) = make()
        let chat = FakeTalkChat()
        center.read(messageId: "m1", markdown: "Hello.", in: chat, auto: true)
        #expect(speaker.owner == .repliesAloud)
        center.stop(scope: "another chat")
        #expect(center.state == .preparing("m1"))
        center.stop(scope: chat.memoScope)
        #expect(center.state == .idle)
    }

    @Test func theButtonsThreeNames() {
        #expect(ReadAloudCenter.Button.idle.label == "Read Aloud")
        #expect(ReadAloudCenter.Button.preparing.label == "Preparing audio")
        #expect(ReadAloudCenter.Button.speaking.label == "Stop reading")
    }

    @Test func theHoldMenusTileSitsBetweenCopyAndShare() {
        var ctx = MessageMenuContext()
        // Where Read Aloud is not offered the tiles are as before.
        #expect(MessageMenuModel.tiles(.reply, ctx).map(\.id) == [.copy, .share])
        ctx.reading = false
        var tiles = MessageMenuModel.tiles(.reply, ctx)
        #expect(tiles.map(\.id) == [.copy, .readAloud, .share])
        #expect(tiles[1].title == "Read Aloud")
        #expect(tiles[1].symbol == "speaker.wave.2")
        #expect(!tiles[1].disabled)
        ctx.reading = true
        tiles = MessageMenuModel.tiles(.reply, ctx)
        #expect(tiles[1].title == "Stop Reading")
        #expect(tiles[1].symbol == "stop.fill")
        // While the reply streams, only Copy works.
        ctx.reading = false
        ctx.streaming = true
        tiles = MessageMenuModel.tiles(.reply, ctx)
        #expect(tiles[1].disabled)
        #expect(tiles[1].subtitle == "Still Replying")
        // Never on your own bubbles.
        #expect(!MessageMenuModel.tiles(.you, ctx).contains { $0.id == .readAloud })
        #expect(MessageMenuItemID.readAloud.rawValue == "readAloud")
    }

    /// Stress round 1: after Home and back during Thinking, the reply was read aloud beside "Voice paused".
    @Test func aReplyToAPausedConversationIsNotReadOut() {
        #expect(ChatReadAloudHost.readsCompletedReply(switchOn: true, voiceNotice: false))
        #expect(!ChatReadAloudHost.readsCompletedReply(switchOn: true, voiceNotice: true))
        #expect(!ChatReadAloudHost.readsCompletedReply(switchOn: false, voiceNotice: false))
    }

    @Test func theMenusSwitchRow() {
        var toggled = 0
        let on = ChatReadAloudHost.repliesItem(on: true) { toggled += 1 }
        #expect(on.title == "Read Replies Aloud")
        #expect(on.state == .on)
        #expect(on.attributes.contains(.keepsMenuPresented))
        #expect(on.accessibilityIdentifier == "chat.menu.read-replies")
        #expect(ChatReadAloudHost.repliesItem(on: false) {}.state == .off)
        #expect(ChatMenus.Slot.rename.rawValue < ChatMenus.Slot.readAloud.rawValue)
        #expect(ChatMenus.Slot.readAloud.rawValue < ChatMenus.Slot.more.rawValue)
    }
}

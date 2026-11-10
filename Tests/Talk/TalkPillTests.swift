// The away pill's content and where it leads (docs/spec/3x-talk.md §6.6, §6.8): what `TalkController` hands the pill
// while a conversation runs in a chat that is not in front, or while a paused / stopped notice waits in one.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Talk pill", .serialized)
@MainActor
struct TalkPillTests {
    private func make(script: String = "hold") -> TalkController {
        AudioSessionCoordinator.shared.reset()
        KeepAwake.reset()
        FixtureTalkCapture.script = TalkFixtureStep.parse(script)
        FixtureTalkCapture.permission = "granted"
        FixtureTalkCapture.startDelay = 0.02
        let talk = TalkController()
        var config = TalkConfig()
        config.silenceMs = 300
        talk.makeCapture = { FixtureTalkCapture(clock: $0) }
        talk.speaker = FakeSpeaker()
        talk.loadConfig = { _ in config }
        talk.transcribe = { _, _ in .success("What is the plan") }
        talk.holdsLeases = false
        talk.isOnScreen = { true }
        talk.speaksReplies = { true }
        return talk
    }

    @Test func theWordingOfEveryForm() {
        let live = TalkPillContent.live(label: "Ivy · Listening · 2:14", problem: false)
        #expect(live.label == "Ivy · Listening · 2:14")
        #expect(live.spoken == "Ivy · Listening · 2:14. Return to the conversation")
        #expect(live.showsEnd)
        let failed = TalkPillContent.live(label: "Ivy · Problem · 0:09", problem: true)
        #expect(failed.spoken == "Ivy · Problem · 0:09. Voice had a problem. Return to the conversation")
        let paused = TalkPillContent.notice(kind: .paused, label: "Ivy · Voice Paused · Tap for details")
        #expect(paused.spoken == "Ivy · Voice Paused · Tap for details. Opens the chat")
        #expect(!paused.showsEnd)
        #expect(TalkDockState.pillLabel(name: "Ivy", status: .listening, muted: false, elapsed: 134) == "Ivy · Listening · 2:14")
        #expect(TalkDockState.pillLabel(name: "Ivy", status: .idle, muted: false, elapsed: 0) == "Ivy · Listening · 0:00")
        #expect(TalkDockState.pillLabel(name: "Ivy", status: .speaking, muted: true, elapsed: 61) == "Ivy · Muted · 1:01")
        #expect(TalkDockState.pillLabel(name: "Ivy", status: .thinking, muted: false, elapsed: 9, problem: true) == "Ivy · Problem · 0:09")
        #expect(TalkDockState.pillLabel(notice: TalkDockState.stoppedNotice(title: "Voice Stopped", message: "m", detail: nil), name: "Ivy")
                == "Ivy · Voice Stopped · Tap for details")
    }

    @Test func noPillWhileTheConversationsChatIsInFront() async {
        let talk = make()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        #expect(talk.pillContent == nil)
        #expect(talk.pillTarget == nil)
        // The chat leaves the screen: the pill names the conversation and leads back to it.
        talk.setFront(chat, onScreen: false)
        guard case .live(let label, let problem)? = talk.pillContent else { Issue.record("no live pill"); return }
        #expect(label.hasPrefix("Ivy · Listening · 0:0"))
        #expect(!problem)
        #expect(talk.pillTarget?.chat === chat)
        #expect(talk.pillTarget?.storedSessionId == "20260929_120000_aabbcc02")
        #expect(talk.pillTarget?.profile == "ivy")
        // Another chat in front still shows it; the conversation's own chat coming back hides it.
        let other = FakeTalkChat(profile: "ada", stored: "20260929_120000_ddeeff03")
        talk.setFront(other, onScreen: true)
        #expect(talk.pillContent != nil)
        talk.setFront(chat, onScreen: true)
        #expect(talk.pillContent == nil)
        await talk.resetForTests()
    }

    @Test func aFailedTurnWhileAwayShowsTheWarningUntilTheChatIsBack() async {
        let talk = make(script: "say:0.4;hold")
        talk.transcribe = { _, _ in .failure(VoiceFailure(reason: "Couldn’t understand that.", detail: "HTTP 500")) }
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        talk.setFront(chat, onScreen: false)
        #expect(await waitUntil(timeout: .seconds(6)) {
            if case .live(_, true)? = talk.pillContent { true } else { false }
        })
        if case .live(let label, _)? = talk.pillContent { #expect(label.hasPrefix("Ivy · Problem · "), "the words say so too: \(label)") }
        // Coming back clears it.
        talk.setFront(chat, onScreen: true)
        talk.setFront(chat, onScreen: false)
        if case .live(_, let problem)? = talk.pillContent { #expect(!problem) } else { Issue.record("no live pill") }
        await talk.resetForTests()
    }

    @Test func aNoticeWaitingInAChatThatIsNotInFront() async {
        let talk = make()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        talk.debugInterrupt(.interrupted, detail: "interruption began")
        #expect(await waitUntil { !talk.isLive })
        #expect(talk.notice(for: chat.memoScope)?.kind == .paused)
        // In its own chat the notice dock shows; no pill.
        #expect(talk.pillContent == nil)
        talk.setFront(chat, onScreen: false)
        #expect(talk.pillContent == .notice(kind: .paused, label: "Ivy · Voice Paused · Tap for details"))
        #expect(talk.pillTarget?.storedSessionId == chat.storedSessionId)
        #expect(talk.pillTarget?.chat === chat)
        // Done in the chat clears it everywhere.
        talk.dismissNotice(scope: chat.memoScope)
        #expect(talk.pillContent == nil)
        #expect(talk.pillTarget == nil)
        await talk.resetForTests()
    }

    @Test func aStoppedNoticeReadsStopped() async {
        let talk = make()
        let chat = FakeTalkChat()
        talk.debugKeep(TalkDockState.stoppedNotice(title: "Voice Stopped", message: "Couldn’t understand that.", detail: nil), chat: chat, name: "Ivy")
        #expect(talk.pillContent == .notice(kind: .stopped, label: "Ivy · Voice Stopped · Tap for details"))
        talk.setFront(chat, onScreen: true)
        #expect(talk.pillContent == nil)
        await talk.resetForTests()
    }

    @Test func aLiveConversationWinsOverANoticeElsewhere() async {
        let talk = make()
        let old = FakeTalkChat(profile: "ada", stored: "20260929_120000_ddeeff03")
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        // A start always begins clean, so a notice can only arrive afterwards; the live conversation still leads.
        talk.debugKeep(TalkDockState.pausedNotice(.background, name: "Ada", app: "Hermes HQ"), chat: old, name: "Ada")
        talk.setFront(chat, onScreen: false)
        if case .live? = talk.pillContent {} else { Issue.record("the live conversation should lead") }
        #expect(talk.pillTarget?.chat === chat)
        await talk.resetForTests()
    }

    @Test func signingOutEndsTheConversationAndForgetsEveryNotice() async {
        let talk = make()
        let chat = FakeTalkChat()
        let other = FakeTalkChat(profile: "ada", stored: "20260929_120000_ddeeff03")
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        talk.debugKeep(TalkDockState.pausedNotice(.silence, name: "Ada", app: "Hermes HQ"), chat: other, name: "Ada")
        talk.accountGone()
        #expect(!talk.isLive)
        #expect(talk.waitingNotices.isEmpty)
        #expect(talk.pillContent == nil)
        #expect(talk.endedCaption(for: chat.memoScope) == nil)
        #expect(!chat.voiceHold)
        #expect(!KeepAwake.isHeld(.conversation))
        await talk.resetForTests()
    }

    @Test func endingFromThePillLeavesNoCaptionInAChatThatIsOffScreen() async {
        let talk = make()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        talk.setFront(chat, onScreen: false)
        talk.end()
        #expect(await waitUntil { !talk.isLive })
        #expect(talk.pillContent == nil)
        #expect(talk.endedCaption(for: chat.memoScope) == nil)
        await talk.resetForTests()
    }
}

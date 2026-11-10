// Live Words' tidy pass (docs/spec/3x-live-words.md §2.1): "uh" and "um" left out, the person's fixes and names written,
// fixes learned from words fixed in review (§3.1.1, §5), and a queued memo riding the queue off screen (1x-voice §4.4).
// The sentences are the owner's own memos from 2026-11-01/02, as Apple's engine heard them.

import Foundation
import QuartzCore
import Testing
@testable import HermesHQNative

@Suite struct LiveWordsTidyTests {
    private let tidy = LiveWordsTidy(fixes: [WordFix(heard: "Kua", meant: "CUA"), WordFix(heard: "from mountain", meant: "for Robin")],
                                     names: LiveWordsTidy.builtInNames + ["Ivy", "Home"])

    @Test func fillersAreLeftOutAndTheSentenceStillReads() {
        #expect(tidy.apply("So where exactly are the calls? And, uh, scored by an AI.") == "So where exactly are the calls? And scored by an AI.")
        #expect(tidy.apply("Uh, yeah, I'm okay with that.") == "Yeah, I'm okay with that.")
        #expect(tidy.apply("I need you to find there's a realistic toy robot. Uh, toy that I need.")
                == "I need you to find there's a realistic toy robot. Toy that I need.")
        #expect(tidy.apply("I think, um.") == "I think.")
        #expect(tidy.apply("Um") == "")
        #expect(tidy.apply("Ummm, erm, uhm") == "")
    }

    @Test func namesHeardAsOtherWordsAreWrittenAsNames() {
        #expect(tidy.apply("If that crash has not been fixed yet, create a, uh, clawed code session on my desktop to look into it.")
                == "If that crash has not been fixed yet, create a Claude Code session on my desktop to look into it.")
        #expect(tidy.apply("Have we had any recent crashes or test flight feedback submitted that we have not reviewed?")
                == "Have we had any recent crashes or TestFlight feedback submitted that we have not reviewed?")
        #expect(tidy.apply("Use cloud code and the testflight build on my iphone.") == "Use Claude Code and the TestFlight build on my iPhone.")
        #expect(tidy.apply("Open the github page and chat gpt.") == "Open the GitHub page and ChatGPT.")
        #expect(tidy.apply("Ask Hermes about the home assistant setup.") == "Ask Hermes about the Home Assistant setup.")
    }

    @Test func everydayWordsThatSoundLikeANameAreLeftAlone() {
        // "her mess" sounds like Hermes, and "Home" is a bot's name: one-word names are only cased when they have their
        // own casing, and sounds are matched for names of two words or more.
        #expect(tidy.apply("Go home and tidy the kitchen, some of it.") == "Go home and tidy the kitchen, some of it.")
        #expect(tidy.apply("Code the cloud function.") == "Code the cloud function.")
    }

    @Test func thePersonsFixesAreWritten() {
        #expect(tidy.apply("I need you to always remember that you, that you can use, Kua, like that.")
                == "I need you to always remember that you, that you can use, CUA, like that.")
        #expect(tidy.apply("Can you make me an image of, um, a rainbow with a bunch of hearts all over the page, from mountain to color?")
                == "Can you make me an image of a rainbow with a bunch of hearts all over the page, for Robin to color?")
        // A fix never reaches across a sentence's end.
        #expect(tidy.apply("Go from. Mountain air is cold.") == "Go from. Mountain air is cold.")
    }

    @Test func shownWordsAreTidiedTooButTheNewestStayPending() {
        let shown = tidy.apply(LiveWordsText(settled: "Uh, start a", pending: "clawed code session"))
        #expect(shown.whole == "Start a Claude Code session")
        #expect(!shown.pending.isEmpty)
    }

    @Test func soundKeysMatchWhatTheEngineMishears() {
        #expect(Phonetic.key("clawed") == Phonetic.key("Claude"))
        #expect(Phonetic.key("cloud") == Phonetic.key("Claude"))
        #expect(Phonetic.key("knight") == Phonetic.key("night"))
        #expect(Phonetic.key("Skeleton") != Phonetic.key("Skellington"))
        #expect(Phonetic.key("her") != Phonetic.key("Hermes"))
    }
}

@Suite struct WordFixLessonTests {
    @Test func aFixedNameIsLearned() {
        #expect(WordFixes.lessons(from: "you can use, Kua, like that", to: "you can use, CUA, like that")
                == [WordFix(heard: "Kua", meant: "CUA")])
        #expect(WordFixes.lessons(from: "the page, from mountain to color?", to: "the page, for Robin to color?")
                == [WordFix(heard: "from mountain", meant: "for Robin")])
        #expect(WordFixes.lessons(from: "a Jack Skeleton toy", to: "a Jack Skellington toy")
                == [WordFix(heard: "Skeleton", meant: "Skellington")])
    }

    @Test func everydayEditsAreNotLearned() {
        // Rewording one memo isn't a fix for every memo.
        #expect(WordFixes.lessons(from: "Can you check it", to: "Can we check it").isEmpty)
        #expect(WordFixes.lessons(from: "Send it to him", to: "Send it to her now").isEmpty)
        #expect(WordFixes.lessons(from: "same words", to: "same words").isEmpty)
        #expect(WordFixes.lessons(from: "Ask Ivy", to: "").isEmpty)
        // Two sentences joined: the second one's first word made lowercase is no fix.
        #expect(WordFixes.lessons(from: "That's done. Tomorrow we ship", to: "That's done, tomorrow we ship").isEmpty)
    }

    @MainActor @Test func learnedFixesAreKeptNewestFirstWithoutRepeats() {
        let kept = UserDefaults.standard.data(forKey: WordFixes.key)
        defer { UserDefaults.standard.set(kept, forKey: WordFixes.key) }
        WordFixes.removeAll()
        #expect(WordFixes.learn(from: "use Kua now", to: "use CUA now") == 1)
        #expect(WordFixes.learn(from: "use kua now", to: "use Kuah now") == 1)   // the same heard word: replaced
        WordFixes.add(WordFix(heard: "Jack Skeleton", meant: "Jack Skellington"))
        #expect(WordFixes.all == [WordFix(heard: "Jack Skeleton", meant: "Jack Skellington"), WordFix(heard: "kua", meant: "Kuah")])
        #expect(LiveWordsTidy(fixes: WordFixes.all, names: []).apply("Ask kua about Jack Skeleton.") == "Ask Kuah about Jack Skellington.")
        WordFixes.remove(heard: "kua")
        #expect(WordFixes.all.map(\.heard) == ["Jack Skeleton"])
        WordFixes.removeAll()
        #expect(WordFixes.all.isEmpty)
    }

    /// The listener the engine's words go through: what it settles on is tidied as what it shows is.
    @MainActor @Test func theListenersSettledWordsAreTidied() async {
        let inner = CountingListener(words: "Um, open clawed code")
        let tidied = TidiedLiveWords(inner, tidy: LiveWordsTidy(fixes: [], names: LiveWordsTidy.builtInNames))
        #expect(await tidied.finish() == "Open Claude Code")
        #expect(inner.finished)
    }

    @MainActor @Test func aMemosLogLineNeverHoldsItsWords() {
        var memo = MemoFile(path: "/x/voice-memo.m4a", seconds: 4.4, peaks: [], mime: "audio/x-m4a")
        memo.words = "Remind me to call the dentist"
        let line = LiveChatSession.memoLogWords(MemoSendContext(memo: memo, typed: "and eggs", epoch: 0, accountId: "a"))
        #expect(line == "memo 4s, words 29 chars from this device, typed 8 chars")
        #expect(!line.contains("dentist") && !line.contains("eggs"))
        memo.words = nil
        #expect(LiveChatSession.memoLogWords(MemoSendContext(memo: memo, typed: "", epoch: 0, accountId: "a"))
                == "memo 4s, no words (the gateway transcribes), typed 0 chars")
    }
}

@Suite("Live Words: fixing words in review", .serialized)
@MainActor
struct LiveWordsReviewTests {
    @Test func wordsFixedInReviewAreSentAndTheFixIsLearned() async throws {
        let kept = UserDefaults.standard.data(forKey: WordFixes.key)
        defer {
            UserDefaults.standard.set(kept, forKey: WordFixes.key)
            MemoController.debugSendOnRelease = nil
        }
        WordFixes.removeAll()
        MemoController.debugSendOnRelease = false   // let go → review
        let accountId = "words-\(UUID().uuidString)"
        VoiceTestStores.activate(accountId)
        let controller = MemoController(capture: FakeCapture(file: try VoiceTestStores.recording(accountId, seconds: 3)))
        controller.tapsMicrophone = false
        controller.makeWords = { ScriptedLiveWords(script: "Ask Kua to look at it", onText: $0) }
        let target = MemoTarget(scope: "acct|ivy|\(UUID().uuidString)", host: nil, session: nil, botName: "Ivy",
                                accountKey: MemoPaths.accountKey(accountId))
        controller.memoDown(target, width: 402)
        #expect(await waitUntil { controller.state.phase == .holding })
        #expect(await waitUntil(timeout: .seconds(3)) { controller.words.whole == "Ask Kua to look at it" })
        controller.input(.up(at: CACurrentMediaTime() * 1000 + 5000))
        #expect(await waitUntil { controller.state.phase == .review })
        #expect(controller.words.whole == "Ask Kua to look at it")

        controller.reviseWords("Ask CUA to look at it")
        #expect(controller.words.whole == "Ask CUA to look at it")
        controller.input(.send)
        #expect(await waitUntil { controller.state.phase == .idle })
        // No chat on screen: the memo waits as a draft, with the fixed words; the fix is kept for later memos.
        let draft = try #require(MemoAccountStores.shared.drafts?.draft(for: target.scope))
        #expect(draft.words == "Ask CUA to look at it")
        #expect(WordFixes.all == [WordFix(heard: "Kua", meant: "CUA")])
        WordFixes.removeAll()
    }

    @Test func wordsClearedInReviewLeaveTheMemoToTheGateway() async throws {
        let kept = UserDefaults.standard.data(forKey: WordFixes.key)
        defer {
            UserDefaults.standard.set(kept, forKey: WordFixes.key)
            MemoController.debugSendOnRelease = nil
        }
        MemoController.debugSendOnRelease = false
        let accountId = "words-\(UUID().uuidString)"
        VoiceTestStores.activate(accountId)
        let controller = MemoController(capture: FakeCapture(file: try VoiceTestStores.recording(accountId, seconds: 3)))
        controller.tapsMicrophone = false
        controller.makeWords = { ScriptedLiveWords(script: "Something misheard", onText: $0) }
        let target = MemoTarget(scope: "acct|ivy|\(UUID().uuidString)", host: nil, session: nil, botName: "Ivy",
                                accountKey: MemoPaths.accountKey(accountId))
        controller.memoDown(target, width: 402)
        #expect(await waitUntil { controller.state.phase == .holding })
        #expect(await waitUntil(timeout: .seconds(3)) { !controller.words.isEmpty })
        controller.input(.up(at: CACurrentMediaTime() * 1000 + 5000))
        #expect(await waitUntil { controller.state.phase == .review })
        controller.reviseWords("  ")
        controller.input(.send)
        #expect(await waitUntil { controller.state.phase == .idle })
        let draft = try #require(MemoAccountStores.shared.drafts?.draft(for: target.scope))
        #expect(draft.words == nil)
    }
}

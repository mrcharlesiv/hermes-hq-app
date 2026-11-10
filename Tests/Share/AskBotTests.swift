// [ask-bot] Ask Bot (Shortcuts) sends like the Share sheet and can wait for the reply (tester, 2026-11-08):
// the reply watcher reads only this chat's turn ends, a queued prompt is answered by the turn after the running one, a
// question from the bot or a closed socket stops the wait, and a share still waits for nothing.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Ask Bot")
struct AskBotTests {
    private static func event(_ type: String, _ session: String = "runtime-1", _ payload: [String: Any] = [:]) -> ShareSocketEvent {
        .event(type: type, session: session, payload: ShareJSON(payload))
    }

    // MARK: The watcher

    @Test func theTurnEndsTextIsTheReply() async {
        let watch = ShareReplyWatch(runtime: "runtime-1")
        watch.take(Self.event("message.start"))
        watch.take(Self.event("message.delta", "runtime-1", ["text": "Hel"]))
        watch.take(Self.event("message.complete", "runtime-1", ["text": "Hello there.", "status": "complete"]))
        #expect(await watch.wait(skip: 0, timeout: 5) == .text("Hello there."))
    }

    @Test func aTurnEndWithoutTextUsesWhatWasStreamed() async {
        let watch = ShareReplyWatch(runtime: "runtime-1")
        watch.take(Self.event("message.start"))
        watch.take(Self.event("message.delta", "runtime-1", ["text": "Saved "]))
        watch.take(Self.event("message.delta", "runtime-1", ["text": [["type": "text", "text": "your data."]]]))
        watch.take(Self.event("message.complete"))
        #expect(await watch.wait(skip: 0, timeout: 5) == .text("Saved your data."))
    }

    @Test func anotherChatsFramesAreNotTheReply() async {
        let watch = ShareReplyWatch(runtime: "runtime-1")
        watch.take(Self.event("message.complete", "runtime-9", ["text": "Not yours."]))
        watch.take(.request(method: "approval.request", session: "runtime-9"))
        #expect(await watch.wait(skip: 0, timeout: 0.3) == .stillWorking)
    }

    @Test func aQueuedPromptIsAnsweredByTheNextTurn() async {
        let watch = ShareReplyWatch(runtime: "runtime-1")
        let waiting = Task { await watch.wait(skip: 1, timeout: 5) }
        watch.take(Self.event("message.complete", "runtime-1", ["text": "The turn that was running."]))
        try? await Task.sleep(for: .milliseconds(50))
        watch.take(Self.event("message.start"))
        watch.take(Self.event("message.complete", "runtime-1", ["text": "Your answer."]))
        #expect(await waiting.value == .text("Your answer."))
    }

    @Test func aQuestionAnErrorOrAClosedSocketEndsTheWait() async {
        let asking = ShareReplyWatch(runtime: "runtime-1")
        asking.take(.request(method: "clarify.request", session: "runtime-1"))
        #expect(await asking.wait(skip: 0, timeout: 5) == .asking)

        let failed = ShareReplyWatch(runtime: "runtime-1")
        failed.take(Self.event("error", "", ["message": " Model not found "]))
        #expect(await failed.wait(skip: 0, timeout: 5) == .failed("Model not found"))

        let errored = ShareReplyWatch(runtime: "runtime-1")
        errored.take(Self.event("message.complete", "runtime-1", ["text": "", "status": "error"]))
        #expect(await errored.wait(skip: 0, timeout: 5) == .failed(""))

        let closed = ShareReplyWatch(runtime: "runtime-1")
        closed.take(.closed)
        #expect(await closed.wait(skip: 0, timeout: 5) == .stillWorking)
    }

    @Test func noAnswerInTimeIsStillWorking() async {
        let watch = ShareReplyWatch(runtime: "runtime-1")
        let began = Date()
        #expect(await watch.wait(skip: 0, timeout: 0.2) == .stillWorking)
        #expect(Date().timeIntervalSince(began) < 3)
    }

    // MARK: The sender

    @Test func askingWaitsForTheReplyWhetherItComesBeforeOrAfterTheAnswer() async throws {
        for early in [true, false] {
            let gateway = ShareStubGateway(), keychain = gateway.keychain()
            gateway.afterSubmit([Self.event("message.start"), Self.event("message.delta", "runtime-1", ["text": "Got it: 3 rows."]),
                                 Self.event("message.complete")], beforeAnswer: early)
            let request = ShareRequest(bot: ShareSamples.bot(), message: "Today's export", replyWait: 5)
            let result = try await gateway.sender(keychain).send(request, roster: gateway.roster())
            #expect(result.status == "streaming")
            #expect(result.reply == .text("Got it: 3 rows."), "events before the answer: \(early)")
            #expect(gateway.event("prompt.submit")?.text == "Today's export")
            #expect(gateway.closed == 1)
        }
    }

    @Test func aPromptQueuedBehindARunningTurnGetsTheNextTurnsReply() async throws {
        let gateway = ShareStubGateway(), keychain = gateway.keychain()
        gateway.onRPC { method, _ in method == "prompt.submit" ? ["status": "queued"] : nil }
        gateway.afterSubmit([Self.event("message.complete", "runtime-1", ["text": "Earlier work done."]),
                             Self.event("message.start"), Self.event("message.complete", "runtime-1", ["text": "Your reply."])])
        let request = ShareRequest(bot: ShareSamples.bot(), message: "Next", replyWait: 5)
        let result = try await gateway.sender(keychain).send(request, roster: gateway.roster())
        #expect(result.reply == .text("Your reply."))
    }

    @Test func aShareWaitsForNothing() async throws {
        let gateway = ShareStubGateway(), keychain = gateway.keychain()
        gateway.afterSubmit([Self.event("message.complete", "runtime-1", ["text": "Ignored."])])
        let result = try await gateway.sender(keychain).send(ShareRequest(bot: ShareSamples.bot(), message: "Hi"), roster: gateway.roster())
        #expect(result.reply == nil)
    }

    // MARK: The app's side

    @Test func theRosterIsKeptInTheAppsOwnDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "ask-roster-" + UUID().uuidString))
        #expect(AskRoster.read(defaults) == nil)
        let roster = ShareSamples.roster()
        AskRoster.save(roster, defaults)
        #expect(AskRoster.read(defaults) == roster)
        AskRoster.clear(defaults)
        #expect(AskRoster.read(defaults) == nil)
    }

    @Test func failuresAreSaidInAShortcutsWords() {
        let words = [ShareFailure.signedOut, .noRoster, .noChat, .unconfirmed, .nothingToSend].map { AskBotError.words($0, bot: "Ivy").errorDescription ?? "" }
        #expect(words.allSatisfy { !$0.lowercased().contains("share") }, "\(words)")
        #expect(AskBotError.words(.noChat, bot: "Ivy").errorDescription == "Open Ivy’s chat in Hermes HQ once, then run the shortcut again.")
        #expect(AskBotError.words(.tailscaleOff, bot: "Ivy").errorDescription == ShareFailure.tailscaleOff.message)
    }
}

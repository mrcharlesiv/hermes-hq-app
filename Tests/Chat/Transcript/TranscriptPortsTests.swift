// [transcript] The pure ports of docs/spec/3x-transcript.md, each against the web's own vectors
// (/Users/me/Projects/hermes-hq-native-ref240/src): cron deliveries, timeline notes, tool wording, the failed
// turn's copy, the status grace, the reply reveal plan, changed files, deep links, table text, image sources.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct CronDeliveryTests {
    let roster = [DeliveryMessages.Seat(profile: "default", name: "Hermes", head: nil),
                  DeliveryMessages.Seat(profile: "scout", name: "Scout", head: nil),
                  DeliveryMessages.Seat(profile: "scout-pro", name: "Scout Pro", head: nil)]

    @Test func theThreeWrapperShapes() {
        #expect(CronDeliveries.parse("[Cron delivery: Morning brief]\nAll quiet.") == .init(job: "Morning brief", body: "All quiet."))
        #expect(CronDeliveries.parse("Cronjob Response: Morning brief\n(job_id: abc123)\n-------------\n\nAll quiet.\n\nTo stop or manage this job, send me a new message (e.g. \"stop reminder\").")
                == .init(job: "Morning brief", body: "All quiet."))
        #expect(CronDeliveries.parse("[Cronjob \"Morning brief\" output — scheduled job, not the user. Reply if useful.]\nAll quiet.")
                == .init(job: "Morning brief", body: "All quiet."))
        #expect(CronDeliveries.parse("  \n[Cron delivery: x]\nbody\n\nNote: The agent cannot see this message, and therefore cannot respond to it.")?.body == "body")
    }

    @Test func badWrappersStayMessages() {
        #expect(CronDeliveries.parse("[Cron delivery: x") == nil)                       // unterminated
        #expect(CronDeliveries.parse("[Cron delivery: " + String(repeating: "j", count: 161) + "]\nbody") == nil)
        #expect(CronDeliveries.parse("[Cron delivery: " + String(repeating: "j", count: 160) + "]\nbody")?.job.count == 160)
        #expect(CronDeliveries.parse("[Cron delivery: a\nb]\nbody") == nil)             // a newline in the name
        #expect(CronDeliveries.parse("```\n[Cron delivery: x]\nbody\n```") == nil)      // inside a code block
        #expect(CronDeliveries.parse("He said [Cron delivery: x]\nbody") == nil)
        #expect(CronDeliveries.parse("[Cron delivery: x] trailing words\nbody") == nil)
        // A body that is only a footer leaves nothing.
        #expect(CronDeliveries.parse("[Cron delivery: x]\nTo stop or manage this job, send me a new message")?.body == "")
    }

    @Test func theJobsBotIsTheLongestNameItStartsWith() {
        #expect(CronDeliveries.bot(job: "Scout morning brief", roster: roster)?.profile == "scout")
        #expect(CronDeliveries.bot(job: "Scout Pro: weekly", roster: roster)?.profile == "scout-pro")
        #expect(CronDeliveries.bot(job: "Scouting report", roster: roster) == nil)      // not at a word boundary
        #expect(CronDeliveries.bot(job: "hermes — digest", roster: roster)?.profile == "default")
        #expect(CronDeliveries.bot(job: "Morning brief", roster: roster) == nil)
    }

    @Test func resolveTurnsAWrapperIntoItsBotsMessage() {
        let own = roster[0]
        let messages = [
            ChatMessage(id: "u1", role: .user, parts: [.text("[Cron delivery: Morning brief]\n**All** quiet.")]),
            ChatMessage(id: "u2", role: .user, parts: [.text("[Cron delivery: Scout morning brief]\nNews.")]),
            ChatMessage(id: "u3", role: .user, parts: [.text("[Cron delivery: Nightly]\n[SILENT]  ")]),
            ChatMessage(id: "u4", role: .user, parts: [.text("hello")]),
            ChatMessage(id: "a5", role: .assistant, parts: [.text("[Cron delivery: Digest]\nDone.")]),
        ]
        let out = CronDeliveries.resolve(messages, roster: roster, own: own)
        #expect(out.found)
        #expect(out.messages.count == messages.count)
        #expect(out.messages[0].sender?.name == "Hermes" && out.messages[0].job == "Morning brief")
        #expect(out.messages[0].plainText == "**All** quiet.")
        #expect(out.messages[1].sender?.profile == "scout" && out.messages[1].sender?.key == "cron:scout")
        #expect(out.messages[2].role == .system && out.messages[2].plainText == "Nightly: Nothing to report — this run was silent")
        #expect(out.messages[3] == messages[3])
        #expect(out.messages[4].sender != nil && out.messages[4].job == "Digest" && out.messages[4].plainText == "Done.")
        // Nothing to do: the same array.
        #expect(CronDeliveries.resolve([messages[3]], roster: roster, own: own).found == false)
        // A message that already has a sender (a room member quoting a wrapper) is never touched.
        var member = messages[0]
        member.sender = ChatSender(key: "m", name: "Ivy", head: nil, profile: "ivy", colorHex: nil)
        #expect(CronDeliveries.resolve([member], roster: roster, own: own).messages[0].job == nil)
    }

    @Test func lowercaseSilentIsNotSilent() {
        let out = CronDeliveries.resolve([ChatMessage(id: "u", role: .user, parts: [.text("[Cron delivery: N]\n[silent]")])],
                                         roster: roster, own: roster[0])
        #expect(out.messages[0].role == .user && out.messages[0].plainText == "[silent]")
    }
}

@Suite struct TimelineNoteTests {
    @Test func modelSwitchReadsInWords() {
        let text = "[System: The active model for this chat has changed to claude-opus-5-5 via provider anthropic. From this point on, respond as that model.]"
        #expect(TimelineNotes.modelSwitchLabel(text, displayName: { _ in "Opus 5.5" }) == "Model changed to Opus 5.5")
        #expect(TimelineNotes.modelSwitchLabel(text, displayName: { _ in "" }) == "Model changed to claude-opus-5-5")
        #expect(TimelineNotes.modelSwitchLabel("[System: something else]") == "Model changed")
        #expect(TimelineNotes.note(text, displayName: { _ in "Opus 5.5" }) == .words("Model changed to Opus 5.5"))
        // No model, and a 300-character id: the row says what happened, nothing more.
        #expect(TimelineNotes.note("[System: The active model for this chat has changed to . From this point on]") == .words("Model changed"))
        let long = "[System: The active model for this chat has changed to \(String(repeating: "m", count: 300)). From this point on]"
        #expect(TimelineNotes.note(long) == .words("Model changed"))
    }

    @Test func otherSystemTextLosesItsBrackets() {
        #expect(TimelineNotes.note("[System: Context was compacted.]") == .words("Context was compacted."))
        #expect(TimelineNotes.note("plain words") == .raw("plain words"))
    }

    @Test func aFailedTurnNoteBesideItsErrorCardIsNotDrawn() {
        #expect(TimelineNotes.note("Your request was not processed. Try again.", errorNearby: true) == .hidden)
        #expect(TimelineNotes.note("This turn did not complete.", errorNearby: false) == .raw("This turn did not complete."))
        var failed = ChatMessage(id: "a", role: .assistant, parts: [])
        failed.error = "boom"
        let messages = [ChatMessage(id: "u", role: .user, parts: [.text("hi")]), failed,
                        ChatMessage(id: "s", role: .system, parts: [.text("This turn did not complete.")])]
        let out = TimelineNotes.resolve(messages)
        #expect(out.count == 3 && out[2].plainText.isEmpty)
    }

    @Test func aLiveSilentRunKeepsItsToolRows() {
        let call = ToolCall(id: "t1", name: "terminal", title: "Ran ls", argsText: nil, summary: nil, state: .done, durationSeconds: nil)
        let withTools = ChatMessage(id: "a", role: .assistant, parts: [.tool(call), .text(" [SILENT] ")])
        let bare = ChatMessage(id: "b", role: .assistant, parts: [.text("[SILENT]")])
        var streaming = ChatMessage(id: "c", role: .assistant, parts: [.text("[SILENT]")])
        streaming.isStreaming = true
        let out = TimelineNotes.resolve([withTools, bare, streaming])
        #expect(out[0].silentNote && out[0].parts.count == 1)
        #expect(out[1].role == .system && out[1].plainText == "Nothing to report — this run was silent")
        #expect(out[2] == streaming)
        #expect(TimelineNotes.holdsBack(streamingText: "[SIL"))
        #expect(TimelineNotes.holdsBack(streamingText: "[SILENT]"))
        #expect(!TimelineNotes.holdsBack(streamingText: "[SILENT] and more"))
        #expect(!TimelineNotes.holdsBack(streamingText: "Hello"))
    }

    @Test func silentSentinelPartsPaddingAndLongReplies() {
        let padded = ChatMessage(id: "a", role: .assistant, parts: [.text("  [SILENT]\n")])
        let split = ChatMessage(id: "b", role: .assistant, parts: [.text("[SIL"), .text("ENT]")])
        let withBlank = ChatMessage(id: "c", role: .assistant, parts: [.text("[SILENT]"), .text("  ")])
        let long = ChatMessage(id: "d", role: .assistant, parts: [.text(String(repeating: "word ", count: 20_000))])
        let paddedPastLimit = ChatMessage(id: "e", role: .assistant,
                                          parts: [.text(String(repeating: " ", count: TimelineNotes.silentScanLimit) + "[SILENT]")])
        var failed = ChatMessage(id: "f", role: .assistant, parts: [.text("[SILENT]")])
        failed.error = "boom"
        let out = TimelineNotes.resolve([padded, split, withBlank, long, paddedPastLimit, failed])
        #expect(out[0].role == .system, "whitespace around the sentinel still matches")
        #expect(out[1].role == .system, "text parts are joined before the match")
        #expect(out[2].role == .system)
        #expect(out[3] == long, "a long reply is left as it is")
        #expect(out[4] == paddedPastLimit, "past the scan limit nothing is joined")
        #expect(out[5] == failed)
        let plain = [long, ChatMessage(id: "g", role: .assistant, parts: [.text("Hello")])]
        #expect(TimelineNotes.resolve(plain) == plain)
    }

    @Test func aModelSwitchWithNoKindAndAProcessNote() {
        let out = TimelineNotes.resolve([
            ChatMessage(id: "u", role: .user, parts: [.text("[System: The active model for this chat has changed to gpt-5.5 via provider openai. From this point on.]")]),
            ChatMessage(id: "p", role: .user, parts: [.text("[IMPORTANT: Background process 7 finished with exit code 0.]")]),
        ])
        #expect(out[0].role == .system && out[0].plainText.hasPrefix("Model changed to "))
        #expect(out[1].role == .system && out[1].plainText == "Background task finished")
        #expect(out[1].report == "Background process 7 finished with exit code 0.", "the id and exit code open under it")
    }
}

@Suite struct ToolWordsTests {
    @Test func sizesInWords() {
        #expect(ToolWords.byteCountLabel(850) == "850 bytes output")
        #expect(ToolWords.byteCountLabel(10_240) == "10 KB output")
        #expect(ToolWords.byteCountLabel(1_200_000) == "1.2 MB output")
        #expect(ToolWords.byteCountLabel(5_000_000) == "5 MB output")
        #expect(ToolWords.byteCountLabel(10_240, what: "error output") == "10 KB error output")
        #expect(ToolWords.byteCountLabel(.nan) == "")
        #expect(ToolWords.outputSize(stdout: String(repeating: "x", count: 10_240), stderr: nil) == "10 KB output")
        #expect(ToolWords.outputSize(stdout: nil, stderr: String(repeating: "x", count: 10_240)) == "10 KB error output")
        #expect(ToolWords.outputSize(stdout: "short", stderr: nil) == nil)
    }

    @Test func lookedUpAndBackgroundProcesses() {
        #expect(ToolWords.plainLabel(name: "tool_describe", args: ["name": .string("web_search")]) == "Checked how to use web search")
        #expect(ToolWords.plainLabel(name: "tool_describe", args: ["names": .array([.string("a"), .string("b")])]) == "Checked how to use 2 tools")
        #expect(ToolWords.plainLabel(name: "tool_describe", args: [:]) == "Checked how to use a tool")
        #expect(ToolWords.plainLabel(name: "tool_describe", args: ["name": .string("mcp__github__list_issues")]) == "Checked how to use github list issues")
        #expect(ToolWords.plainLabel(name: "process", args: ["action": .string("log")]) == "Checked a background process’s log")
        #expect(ToolWords.plainLabel(name: "process", args: ["action": .string("spawn")]) == "Started a background process")
        #expect(ToolWords.plainLabel(name: "process_manage", args: [:], preview: "kill 1234") == "Stopped a background process")
        #expect(ToolWords.plainLabel(name: "process", args: ["action": .string("dance")]) == "Managed a background process")
        #expect(ToolWords.plainLabel(name: "terminal", args: [:]) == nil)
    }

    @Test func aFailedToolSaysItOnce() {
        #expect(ToolWords.failedToolTitle("Read notes.txt") == "Failed: Read notes.txt")
        #expect(ToolWords.failedToolTitle("Couldn’t read notes.txt") == "Couldn’t read notes.txt")
        #expect(ToolWords.toolErrorBody(summary: "No such file", body: "- Error: No such file\n- Success: false\nCheck the path.") == "Check the path.")
        #expect(ToolWords.failedProse(errorText: #"{"status":"error","error":"No such file"}"#) == "No such file")
        #expect(ToolWords.failedProse(errorText: "status: error\nexit_code: 1\nsuccess: false") == "This step didn’t finish.")
        #expect(ToolWords.failedProse(errorText: "status: error\nerror: No such file") == "No such file")
        #expect(ToolWords.failedProse(errorText: nil) == "This step didn’t finish.")
        #expect(ToolWords.failedProse(errorText: "not json {") == "not json {")
    }

    @Test func oneLineShellOutput() {
        #expect(ToolWords.oneLineOutput("main\n") == "main")
        #expect(ToolWords.oneLineOutput("a\nb") == nil)
        #expect(ToolWords.oneLineOutput(String(repeating: "x", count: 121)) == nil)
        #expect(ToolWords.oneLineOutput("") == nil)
    }

    @Test func heredocScriptsAreNamedByTheirCommand() {
        #expect(ToolWords.collapseHeredocs("python3 - <<'PY'\nimport os\nprint(1)\nPY") == "python3 script")
        #expect(ToolWords.collapseHeredocs("FOO=1 /usr/bin/node <<EOF\nconsole.log(1)\nEOF\necho done") == "node script\necho done")
        #expect(ToolWords.collapseHeredocs("cat > notes.txt <<EOF\nhello\nEOF") == "cat > notes.txt")
        #expect(ToolWords.collapseHeredocs("cat <<-EOF\n\thello\n\tEOF\nls") == "cat\nls")
        #expect(ToolWords.collapseHeredocs("echo 1 << 2") == "echo 1 << 2")
        #expect(ToolWords.collapseHeredocs("ls -la") == "ls -la")
        #expect(ToolWords.setupSegment(["SM=/path"]))
        #expect(ToolWords.setupSegment(["#", "a", "comment"]))
        #expect(!ToolWords.setupSegment(["SM=/path", "ls"]))
        #expect(ToolWords.scriptTitleSource("SM=/tmp/x\npython3 - <<'PY'\nprint(1)\nPY") == "python3 script")
    }
}

@Suite struct TurnErrorCopyTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let utc = TimeZone(identifier: "UTC")!
    let us = Locale(identifier: "en_US")

    @Test func theKnownKinds() {
        let limit = TurnErrors.copy("Anthropic provider quota exhausted: usage_limit reached, retry after 3600s", now: now, locale: us, timeZone: utc)
        #expect(limit?.kind == .usageLimit)
        #expect(limit?.title.hasPrefix("Anthropic usage limit reached until ") == true)
        #expect(limit?.body == "Choose another model, or wait until then.")
        #expect(limit?.primary == .chooseModel)
        let bare = TurnErrors.copy("HTTP 429 too many requests", now: now)
        #expect(bare?.title == "Usage limit reached" && bare?.body == "Choose another model, or try again later.")
        let owned = TurnErrors.copy("This session is open in another Hermes window", now: now)
        #expect(owned?.title == "This chat is open somewhere else" && owned?.primary == .newChat)
        #expect(owned?.body == "The computer running Hermes, or another window, has this chat open, so it can’t answer here. Start a new chat, or close it there and try again.")
        let start = TurnErrors.copy("Could not find the 'claude' CLI command", now: now)
        #expect(start?.title == "This chat’s model couldn’t start" && start?.primary == .chooseModel)
        // The chat's bot is named on the card's title, so the body names the computer, never "Hermes" as if the bot.
        #expect(start?.body == "The computer running Hermes couldn’t start this chat’s model. Choose another model, or check the model’s provider there.")
        let busy = TurnErrors.copy("agent readiness probe exceeded its budget (5097)", now: now)
        #expect(busy?.title == "The computer running Hermes is busy" && busy?.body == "It didn’t answer in time while it checked its model. Try again in a moment.")
        let cut = TurnErrors.copy("The connection was lost before the reply finished.", now: now)
        #expect(cut?.title == "The reply was cut off" && cut?.primary == .retry)
        #expect(TurnErrors.copy("Something odd happened", now: now) == nil)
        #expect(TurnErrors.copy("", now: now) == nil)
    }

    @Test func precedenceWhenTwoKindsMatch() {
        // The web's order: open elsewhere, usage limit, model start, gateway busy.
        #expect(TurnErrors.copy("rate limit; session has another owner", now: now)?.kind == .anotherWindow)
        #expect(TurnErrors.copy("429 while it could not start the assistant", now: now)?.kind == .usageLimit)
        #expect(TurnErrors.copy("could not start the assistant: readiness probe", now: now)?.kind == .modelStart)
        // Provider words in a usage-limit text don't steal the card: usage limit is checked first.
        #expect(TurnErrors.copy("Anthropic provider quota exhausted: usage_limit reached (billing issue), retry after 3600s", now: now)?.kind == .usageLimit)
        #expect(TurnErrors.copy("429 too many requests: Anthropic rejected the API key (401)", now: now)?.kind == .usageLimit)
    }

    /// n20 ec0a3896's real error texts (its own ErrorRecovery/Switch Provider card is not ported; this card keeps its
    /// one "Choose a Model" button, no new UI).
    @Test func theNewProviderFailureKinds() {
        let billing = TurnErrors.copy("Anthropic: your credit balance is too low (402).", now: now)
        #expect(billing?.kind == .billing && billing?.primary == .chooseModel)
        #expect(billing?.title == "Low on credit")
        #expect(billing?.body == "Choose another model, or add credit with its provider.")

        let key = TurnErrors.copy("Anthropic rejected the API key (401).", now: now)
        #expect(key?.kind == .badApiKey && key?.primary == .chooseModel)
        #expect(key?.title == "This model’s API key failed")
        let forbidden = TurnErrors.copy("Forbidden (403): invalid_api_key", now: now)
        #expect(forbidden?.kind == .badApiKey)
        let authFailed = TurnErrors.copy("OpenAI authentication failed", now: now)
        #expect(authFailed?.kind == .badApiKey)

        let down = TurnErrors.copy("Overloaded", now: now)
        #expect(down?.kind == .providerDown && down?.primary == .chooseModel)
        #expect(down?.title == "This model’s provider is overloaded")
        // A retry can work here, so the body still names it (no separate Switch Provider / Retry button pair).
        #expect(down?.body == "Choose another model, or try again in a moment.")
        let five29 = TurnErrors.copy("HTTP 529", now: now)
        #expect(five29?.kind == .providerDown)
        let five03 = TurnErrors.copy("503 Service Unavailable from the provider", now: now)
        #expect(five03?.kind == .providerDown)
        #expect(five29?.title == "This model’s provider is overloaded" && five03?.title == "This model’s provider is overloaded")
        // Any other server error isn't "overloaded": it is a problem at the provider.
        for text in ["Error code: 500 - internal server error", "502 Bad Gateway", "HTTP 504", "Internal Server Error"] {
            let copy = TurnErrors.copy(text, now: now)
            #expect(copy?.kind == .providerDown && copy?.title == "This model’s provider had a problem", "\(text)")
        }
        // A reset time in the text still shows, as the usage limit kind does.
        let untilLater = TurnErrors.copy("Overloaded, retry after 7200s", now: now, locale: us, timeZone: utc)
        #expect(untilLater?.title.hasPrefix("This model’s provider is overloaded until ") == true)
        #expect(untilLater?.body == "Choose another model, or wait until then.")

        let gone = TurnErrors.copy("The model 'x' does not exist (404).", now: now)
        #expect(gone?.kind == .modelGone && gone?.primary == .chooseModel)
        #expect(gone?.title == "This model is gone")
        #expect(gone?.body == "Choose another model to continue this chat.")
        let notFound = TurnErrors.copy("model_not_found: gpt-ancient", now: now)
        #expect(notFound?.kind == .modelGone)

        // The way providers' SDKs word them.
        #expect(TurnErrors.copy("Error code: 529 - {'type': 'error', 'error': {'type': 'overloaded_error'}}", now: now)?.kind == .providerDown)
        #expect(TurnErrors.copy("Error code: 404 - {'error': {'type': 'not_found_error', 'message': 'model: claude-x'}}", now: now)?.kind == .modelGone)
        #expect(TurnErrors.copy("Error code: 401 - invalid x-api-key", now: now)?.kind == .badApiKey)
        // A bare number is not a status: these stay the card's own words.
        #expect(TurnErrors.copy("The fetch tool got 404 from example.com and the turn stopped", now: now) == nil)
        #expect(TurnErrors.copy("Stopped after 512 steps", now: now) == nil)
        #expect(TurnErrors.copy("The file does not exist", now: now) == nil)

        // None of the new words show a developer term in the card.
        for copy in [billing, key, down, gone] {
            #expect(copy?.title.localizedCaseInsensitiveContains("switch provider") == false)
        }
    }

    @Test func aWaitThatHasPassedNamesNoTime() {
        let old = TurnErrors.copy("rate limit, retry after 60s", now: now, at: now.addingTimeInterval(-3600))
        #expect(old?.title == "Usage limit reached" && old?.body == "Choose another model, or try again later.")
        #expect(TurnErrors.resetsAt("resets_at: 1790003600", now: now) == 1_790_003_600)
        #expect(TurnErrors.resetTimeLabel(1_790_003_600, now: now, locale: us, timeZone: utc).contains(":"))
    }

    @Test func detailsStartClosedForProviderAndStartFailures() {
        #expect(TurnErrors.detailClosed("usage_limit reached"))
        #expect(TurnErrors.detailClosed("failed to start the agent"))
        #expect(TurnErrors.detailClosed("credit balance is too low (402)"))
        #expect(TurnErrors.detailClosed("Anthropic rejected the API key (401)"))
        #expect(TurnErrors.detailClosed("Overloaded"))
        #expect(TurnErrors.detailClosed("The model 'x' does not exist (404)"))
        #expect(!TurnErrors.detailClosed("Something odd"))
        #expect(!TurnErrors.detailClosed(nil))
        #expect(TurnErrors.detailRepeatsBody("No such file.", "No such file"))
        #expect(TurnErrors.detailRepeatsBody("  ", "x"))
        #expect(!TurnErrors.detailRepeatsBody("Traceback: line 4", "No such file"))
    }

    @Test func noRetryWordsWithoutARetryButton() {
        #expect(TurnErrors.withoutRetryWords("Retry, or copy the details if it keeps happening.") == "Copy the details if it keeps happening.")
        #expect(TurnErrors.withoutRetryWords("Wait a minute, then retry.") == "Wait a minute, then send it again.")
        #expect(TurnErrors.withoutRetryWords("The connection dropped before the reply finished. Retry to send it again.")
                == "The connection dropped before the reply finished.")
        #expect(TurnErrors.withoutRetryWords("Try again in a moment.") == "Send it again in a moment.")
        #expect(TurnErrors.withoutRetryWords("Try again later.") == "Send it again later.")
        #expect(TurnErrors.withoutRetryWords("Retry.") == "Retry.")           // nothing left: the body stays
        #expect(TurnErrors.withoutRetryHint("The connection dropped before the reply finished. Retry to send it again.")
                == "The connection dropped before the reply finished.")
        // The card's own words name its "Try Again" button.
        #expect(TurnErrors.withoutRetryWords("The connection dropped before the reply finished. Tap Try Again to send it again.")
                == "The connection dropped before the reply finished.")
        #expect(TurnErrors.withoutRetryWords("Try again, or copy the details if it keeps happening.") == "Copy the details if it keeps happening.")
        #expect(TurnErrors.withoutRetryHint("The connection dropped before the reply finished. Tap Try Again to send it again.")
                == "The connection dropped before the reply finished.")
        #expect(TurnErrors.withoutRetryWords("Try again in a moment.") == "Send it again in a moment.")
    }

    @Test func oneCardPerFailedTurn() {
        func failed(_ id: String, _ error: String, parts: [ChatPart] = []) -> ChatMessage {
            var m = ChatMessage(id: id, role: .assistant, parts: parts)
            m.error = error
            return m
        }
        let user = ChatMessage(id: "u", role: .user, parts: [.text("hi")])
        let out = TurnErrors.withoutDuplicateTurnErrors([user, failed("a", "HTTP 429"), failed("b", "rate limit reached")])
        #expect(out.count == 3 && out[1].error == nil && out[2].error != nil)
        let withOutput = TurnErrors.withoutDuplicateTurnErrors([user, failed("a", "boom", parts: [.text("partial")]), failed("b", "boom")])
        #expect(withOutput[1].error != nil && withOutput[2].error == nil)
        let different = [user, failed("a", "boom"), failed("b", "other")]
        #expect(TurnErrors.withoutDuplicateTurnErrors(different) == different)
        // An older turn's failure is not this turn's.
        let twoTurns = [failed("old", "boom"), user, failed("b", "boom")]
        #expect(TurnErrors.withoutDuplicateTurnErrors(twoTurns) == twoTurns)
    }

    @Test func theSessionProblemCard() {
        let start = SessionProblem.make(text: "could not start the assistant", botName: "Ivy")
        #expect(start?.title == "This chat’s model couldn’t start" && start?.primary == .chooseModel)
        #expect(SessionProblem.make(text: "could not start the assistant", botName: "Ivy", room: true)?.primary == .tryAgain)
        #expect(SessionProblem.make(text: "Could not reopen that session", botName: "Ivy")?.title == "Couldn’t reopen this chat")
        #expect(SessionProblem.make(text: "Disk is full", botName: "Ivy")?.title == "Ivy reported a problem")
        #expect(SessionProblem.make(text: "Disk is full", botName: "")?.title == "Hermes reported a problem")
        #expect(SessionProblem.make(text: "Turn cancelled before the agent was ready", botName: "Ivy") == nil)
        #expect(SessionProblem.make(text: "Session no longer running before the agent was ready to go", botName: "Ivy") == nil)
        #expect(SessionProblem.make(text: "  ", botName: "Ivy") == nil)
        #expect(SessionProblem.reopenFailed(starting: true).body == "This chat is still starting on the computer running Hermes.")
        #expect(SessionProblem.reopenFailed(starting: false).body == "The computer running Hermes didn’t answer in time.")
        let long = SessionProblem.make(text: String(repeating: "x", count: 10_000), botName: "Ivy")
        #expect((long?.body.count ?? 0) < 200 && long?.detail.count == 10_000)
    }

    @Test func couldntSendWording() {
        #expect(SendFailure.title == "Couldn’t Send")
        #expect(SendFailure.make(reason: "The request timed out.").body == "The computer running Hermes didn’t answer in time. Your message is still in the box below.")
        #expect(SendFailure.make(reason: "You’re offline. Check your connection.").body == "You’re offline. Your message is still in the box below.")
        #expect(SendFailure.make(reason: "session busy").body == "Your message is still in the box below. Session busy.")
        #expect(SendFailure.make(reason: nil).body == "Your message is still in the box below.")
        #expect(SendFailure.make(reason: String(repeating: "r", count: 400)).body.count <= 40 + 161)
    }
}

@Suite struct StatusGraceTests {
    @Test func aWaitingWordShowsOnlyAfterASecond() {
        var grace = StatusGrace()
        let t0 = ContinuousClock.now
        let first = grace.next(raw: "Reconnecting…", now: t0)
        #expect(first.shown == nil && first.recheckAfter == .milliseconds(1000))
        let early = grace.next(raw: "Reconnecting…", now: t0 + .milliseconds(400))
        #expect(early.shown == nil && early.recheckAfter == .milliseconds(600))
        #expect(grace.next(raw: nil, now: t0 + .milliseconds(450)).shown == nil)          // a 400 ms blip shows nothing
        // A new wait starts its own second.
        #expect(grace.next(raw: "Reconnecting…", now: t0 + .milliseconds(500)).shown == nil)
        #expect(grace.next(raw: "Reconnecting…", now: t0 + .milliseconds(1400)).shown == nil)
        #expect(grace.next(raw: "Reconnecting…", now: t0 + .milliseconds(1500)).shown == "Reconnecting…")
        #expect(grace.next(raw: nil, now: t0 + .milliseconds(1501)).shown == nil)          // clears at once
    }

    @Test func workingWordsShowAtOnceAndAChangeOfWordsIsImmediate() {
        var grace = StatusGrace()
        let t0 = ContinuousClock.now
        #expect(grace.next(raw: "Thinking…", now: t0).shown == "Thinking…")
        #expect(grace.next(raw: "Reconnecting…", now: t0 + .milliseconds(10)).shown == "Reconnecting…")   // no blank gap
        #expect(grace.next(raw: "Offline", now: t0 + .milliseconds(20)).shown == "Offline")
        var other = StatusGrace()
        #expect(other.next(raw: "Offline", now: t0).shown == "Offline")
        #expect(other.next(raw: "Can’t reach this bot", now: t0).shown == "Can’t reach this bot")
        var waking = StatusGrace()
        #expect(waking.next(raw: "Waking up…", now: t0).shown == nil)
        #expect(waking.next(raw: "Connecting…", now: t0 + .milliseconds(1000)).shown == "Connecting…")
        #expect(waking.next(raw: "Still waking up…", now: t0 + .milliseconds(1001)).shown == "Still waking up…")
    }
}

@Suite struct ReplyRevealTests {
    @Test func aWholeReplyIsDrawnInSteps() {
        let text = String(repeating: "word ", count: 180)      // 900 characters
        let ends = ReplyReveal.ends(text)
        #expect(ends.count >= 5)
        #expect(ends.last == text.count)
        #expect(ends == ends.sorted())
        #expect(Set(ends).count == ends.count)
        // Cuts land after a space.
        let chars = Array(text)
        for end in ends.dropLast() { #expect(chars[end - 1] == " ") }
        #expect(ReplyReveal.duration(chars: 900) == 562.5)
        #expect(ReplyReveal.duration(chars: 100) == 280)
        #expect(ReplyReveal.duration(chars: 20_000) == 700)
    }

    @Test func onlyTheFirstScreenfulIsPaced() {
        let text = String(repeating: "word ", count: 4_000)     // 20,000 characters
        let ends = ReplyReveal.ends(text)
        #expect(ends.dropLast().allSatisfy { $0 <= ReplyReveal.revealChars + 16 })
        #expect(ends.last == 20_000)
        #expect(ReplyReveal.limit(ends: ends, elapsedMs: 0) == ends[0])
        #expect(ReplyReveal.limit(ends: ends, elapsedMs: 10_000) == nil)
    }

    @Test func emojiAreNeverCutAndShortTextsStillEnd() {
        let text = String(repeating: "👩‍👩‍👧‍👦", count: 80)
        let ends = ReplyReveal.ends(text)
        #expect(ends.last == 80)
        for end in ends { #expect(String(Array(text).prefix(end)).unicodeScalars.count % 7 == 0) }
        #expect(ReplyReveal.ends("hi") == [2] || ReplyReveal.ends("hi").last == 2)
        #expect(ReplyReveal.ends("").last == 0)
    }

    @Test func whichDeltasStartAReveal() {
        #expect(ReplyReveal.isWhole(deltaLength: 900, msSincePreviousDelta: nil, replayed: false))
        #expect(ReplyReveal.isWhole(deltaLength: 900, msSincePreviousDelta: 1500, replayed: false))
        #expect(!ReplyReveal.isWhole(deltaLength: 900, msSincePreviousDelta: 40, replayed: false))    // it streams
        #expect(!ReplyReveal.isWhole(deltaLength: 59, msSincePreviousDelta: nil, replayed: false))
        #expect(!ReplyReveal.isWhole(deltaLength: 900, msSincePreviousDelta: nil, replayed: true))
    }
}

@Suite struct ChangedFilesTests {
    func call(_ id: String, _ name: String = "patch", state: ToolCall.State = .done) -> ToolCall {
        ToolCall(id: id, name: name, title: name, argsText: nil, summary: nil, state: state, durationSeconds: nil)
    }
    let diffA = "--- a/src/app.py\n+++ b/src/app.py\n@@ -1,3 +1,4 @@\n import os\n-print(1)\n+print(2)\n+print(3)\n"

    @Test func oneRowPerFileWithSummedCounts() {
        let files = ChangedFiles.derive(calls: [
            (call("1"), ["path": .string("src/app.py")], diffA),
            (call("2", "write_file"), ["path": .string("README.md")], "+++ b/README.md\n+hello\n"),
            (call("3"), ["path": .string("src/app.py")], diffA),
            (call("4", state: .failed), ["path": .string("x.py")], diffA),            // a failed edit changed nothing
            (call("5", state: .running), ["path": .string("y.py")], nil),
            (call("6", "terminal"), ["path": .string("z.py")], diffA),                 // not an edit tool
            (call("7"), [:], "+++ b/from/header.txt\n+x\n"),                           // the path from the diff's header
        ])
        #expect(files.map(\.path) == ["src/app.py", "README.md", "from/header.txt"])
        #expect(files[0] == ChangedFile(path: "src/app.py", name: "app.py", added: 4, removed: 2, edits: 2))
        #expect(ChangedFiles.title(1) == "1 file changed" && ChangedFiles.title(3) == "3 files changed")
    }

    @Test func lineStatsIgnoreHeaders() {
        let stats = ChangedFiles.lineStats(diffA)
        #expect(stats.added == 2 && stats.removed == 1)
        #expect(ChangedFiles.lineStats("").added == 0)
        #expect(ChangedFiles.lineStats("--- a\n+++ b\n").added == 0)
        let crlf = ChangedFiles.lineStats("+a\r\n-b\r\n")
        #expect(crlf.added == 1 && crlf.removed == 1)
    }

    @Test func thePreviewShowsEightChangedLines() {
        let small = ChangedFiles.preview(diffA)
        #expect(small.lines.map(\.text) == [" import os", "−print(1)", "+print(2)", "+print(3)"])
        #expect(!small.more)
        let big = (0..<3000).map { "+line \($0)" }.joined(separator: "\n")
        let preview = ChangedFiles.preview(big)
        #expect(preview.lines.count == 8 && preview.more)
        #expect(ChangedFiles.preview("--- a\n+++ b\n").lines.isEmpty)                    // only a header
        #expect(ChangedFiles.preview("Binary files a/x.png and b/x.png differ").lines.isEmpty)
        #expect(ChangedFiles.preview("+a\n\\ No newline at end of file").lines.count == 1)
    }

    @Test func matchingACardRowToTheChangesList() {
        #expect(ChangedFiles.match("/work/demo/src/app.py", in: ["README.md", "src/app.py"]) == "src/app.py")
        #expect(ChangedFiles.match("src/app.py", in: ["src/app.py"]) == "src/app.py")
        #expect(ChangedFiles.match("./src/app.py", in: ["src/app.py"]) == "src/app.py")
        #expect(ChangedFiles.match("other.py", in: ["src/app.py"]) == nil)
    }

    @Test func resolvingAnEditToolsPathAgainstTheChatsFolder() {   // [transcript] §12, n20 F10
        #expect(ChangedFiles.resolve("src/app.py", in: "/work/demo") == "/work/demo/src/app.py")
        #expect(ChangedFiles.resolve("./src/app.py", in: "/work/demo") == "/work/demo/src/app.py")
        #expect(ChangedFiles.resolve("src/app.py", in: "/work/demo/") == "/work/demo/src/app.py")   // a trailing slash
        #expect(ChangedFiles.resolve("src/app.py", in: nil) == "src/app.py")                        // no folder known
        #expect(ChangedFiles.resolve("src/app.py", in: "") == "src/app.py")
        #expect(ChangedFiles.resolve("/abs/app.py", in: "/work/demo") == "/abs/app.py")              // already absolute
        #expect(ChangedFiles.resolve("~/app.py", in: "/work/demo") == "~/app.py")                    // home-relative
        #expect(ChangedFiles.resolve("C:\\app.py", in: "/work/demo") == "C:\\app.py")                // a Windows path
    }

    @Test func theDiffStoreStaysWithinItsBounds() {
        let store = ToolDiffStore()
        for n in 0..<250 { store.set("+line \(n)\n", for: "t\(n)") }
        #expect(store.counts.diffs == 200)
        #expect(store.diff(for: "t0") == nil && store.diff(for: "t249") != nil)
        let huge = String(repeating: "x", count: 700_000)
        store.set(huge, for: "h1")
        store.set(huge, for: "h2")
        #expect(store.counts.characters <= ToolDiffStore.maxCharacters)
        #expect(store.diff(for: "h2") != nil)                    // the newest is always kept
        store.set(String(repeating: "y", count: 2_000_000), for: "h3")
        #expect(store.counts.diffs == 1 && store.diff(for: "h3") != nil)
        store.clear()
        #expect(store.counts.diffs == 0 && store.counts.characters == 0)
    }
}

@Suite struct DeepLinkTests {
    func parse(_ text: String) -> DeepLink? { URL(string: text).flatMap { DeepLink.parse($0, scheme: "hermes") } }

    @Test func sessionAndConnectKeepTheirRules() {
        #expect(parse("hermes://session/abc_123-x") == .session("abc_123-x"))
        #expect(parse("hermes://session/abc?x=1") == nil)
        #expect(parse("hermes://session/a%2Fb") == nil)
        #expect(parse("hermes://session/" + String(repeating: "a", count: 161)) == nil)
        #expect(parse("hermes://connect?url=https://gw.example.com") == .connect("https://gw.example.com"))
        #expect(parse("https://example.com/session/abc") == nil)
    }

    @Test func otherKindsAreParsedWithinTheBounds() {
        #expect(parse("hermes://blueprint/weekly?team=core") == .other(kind: "blueprint", name: "weekly", params: [.init(key: "team", value: "core")]))
        #expect(parse("hermes://nonsense/x") == .other(kind: "nonsense", name: "x", params: []))
        #expect(parse("hermes://skill/install?identifier=acme/tool") == .other(kind: "skill", name: "install", params: [.init(key: "identifier", value: "acme/tool")]))
        #expect(parse("hermes://Bad_Kind/x") == nil)
        #expect(parse("hermes://-bad/x") == nil)
        #expect(parse("hermes://" + String(repeating: "k", count: 64) + "/x") != nil)
        #expect(parse("hermes://" + String(repeating: "k", count: 65) + "/x") == nil)
        #expect(parse("hermes://open/" + String(repeating: "n", count: 1024)) != nil)
        #expect(parse("hermes://open/" + String(repeating: "n", count: 1025)) == nil)
        #expect(parse("hermes://x/y?" + (0..<32).map { "k\($0)=v" }.joined(separator: "&")) != nil)
        #expect(parse("hermes://x/y?" + (0..<33).map { "k\($0)=v" }.joined(separator: "&")) == nil)
        #expect(parse("hermes://x/y?" + String(repeating: "k", count: 65) + "=v") == nil)
        #expect(parse("hermes://x/y?k=" + String(repeating: "v", count: 16_384)) != nil)
        #expect(parse("hermes://x/y?k=" + String(repeating: "v", count: 16_385)) == nil)
        #expect(parse("hermes://x/y?a=" + String(repeating: "v", count: 16_000) + "&b=" + String(repeating: "v", count: 16_000) + "&c=" + String(repeating: "v", count: 2_000)) == nil)   // over 32,768 bytes
        #expect(parse("hermes://x/y?k=a%00b") == nil)
        #expect(parse("hermes://x/y%0Az") == nil)
        #expect(parse("hermes://x/y#frag") == nil)
    }

    @Test func aBlueprintLinkBecomesACommand() {
        #expect(DeepLink.blueprintCommand(name: "weekly", params: [.init(key: "team", value: "core")]) == "/blueprint weekly team=core")
        #expect(DeepLink.blueprintCommand(name: "weekly", params: [.init(key: "b", value: "two words"), .init(key: "a", value: "1")])
                == "/blueprint weekly b=\"two words\" a=1")
        #expect(DeepLink.blueprintCommand(name: "", params: []) == nil)
        #expect(DeepLink.unavailable(device: "iPhone") == "That isn’t available on iPhone yet.")
        #expect(DeepLink.unavailable(device: "iPad") == "That isn’t available on iPad yet.")
    }

    @Test func theLastFourLinksWaitForSignIn() {
        var queue = DeepLinkQueue()
        for n in 0..<6 { queue.hold(URL(string: "hermes://x/\(n)")!) }
        #expect(queue.drain().map(\.lastPathComponent) == ["2", "3", "4", "5"])
        #expect(queue.drain().isEmpty)
    }
}

@Suite struct TableAndImageTests {
    @Test func tableTextIsTabSeparated() {
        #expect(TableText.text([["Name", "Qty"], ["Tab\there", " line\nbreak "], ["a|b", "🙂"]]) == "Name\tQty\nTab here\tline break\na|b\t🙂")
        #expect(TableText.copyable([]) == nil)
        #expect(TableText.copyable([[""]]) == nil)
        #expect(TableText.failure == "Couldn’t copy. Select the table text and try again.")
    }

    @Test func relativeImagesAreReadFromTheChatsFolder() {
        #expect(ImageSources.relative("plot.png", base: "/work/demo") == "/work/demo/plot.png")
        #expect(ImageSources.relative("./out/a%20b.png", base: "/work/demo/") == "/work/demo/out/a b.png")
        #expect(ImageSources.relative("../out/a.png?x=1", base: "/work/demo") == "/work/out/a.png")
        #expect(ImageSources.relative("../../etc/passwd", base: "/work") == "/etc/passwd")      // the gateway decides
        #expect(ImageSources.relative("plot.png", base: nil) == nil)
        #expect(ImageSources.relative("/abs.png", base: "/work") == nil)
        #expect(ImageSources.relative("https://x.example/a.png", base: "/work") == nil)
        #expect(ImageSources.resolve(src: "plot.png", folder: "/work/demo") == .gateway("/work/demo/plot.png"))
        #expect(ImageSources.resolve(src: "plot.png", folder: nil) == .blocked(.relative))
        #expect(ImageSources.resolve(src: "data:image/png;base64,AAAA", folder: "/w") == .blocked(.embedded))
        #expect(ImageSources.resolve(src: "http://insecure.example/x.png", folder: "/w") == .blocked(.other))
        #expect(ImageSources.resolve(src: "https://10.0.0.5/x.png", folder: "/w") == .blocked(.other))
        #expect(ImageSources.resolve(src: "/abs/x.png", folder: nil) == .gateway("/abs/x.png"))
    }

    @Test func blockedImagesSayWhy() {
        #expect(ImageSources.blockedText(alt: "Plot", reason: .relative) == "Couldn’t show “Plot”: its path is relative, and this chat has no folder to find it in.")
        #expect(ImageSources.blockedText(alt: "Inline", reason: .embedded) == "Couldn’t show “Inline”: an image embedded in a reply can’t be shown here.")
        #expect(ImageSources.blockedText(alt: "", reason: .other) == "Couldn’t show this image.")
        #expect(ImageSources.blockedText(alt: "Plot", reason: .notSent) == "Couldn’t show “Plot”: your gateway didn’t send it.")
        #expect(ImageSources.altOrFile(alt: "", src: "./out/missing.png", reason: .relative) == "missing.png")
    }
}

@Suite struct TurnMarkTests {
    @Test func durationsInWords() {
        #expect(TurnDuration.short(0.4) == nil)
        #expect(TurnDuration.short(4.2) == "4s")
        #expect(TurnDuration.short(72) == "1m 12s")
        #expect(TurnDuration.short(3780) == "1h 3m")
        #expect(TurnDuration.short(.nan) == nil)
        #expect(TurnDuration.short(-3) == nil)
        #expect(TurnDuration.spoken(72) == "Took 1 minute 12 seconds")
        #expect(TurnDuration.spoken(1) == "Took 1 second")
        #expect(TurnDuration.spoken(3780) == "Took 1 hour 3 minutes")
    }

    @Test func marksBelongToTheirChatAndTheOldestGoesFirst() {
        let store = TurnMarkStore(defaults: nil)
        store.set(6, scope: "acct|ivy|s1", messageId: "stored-row-12-assistant")
        #expect(store.seconds(scope: "acct|ivy|s1", messageId: "stored-row-12-assistant") == 6)
        #expect(store.seconds(scope: "acct|max|s9", messageId: "stored-row-12-assistant") == nil)     // same ids, another chat
        for n in 0..<200 { store.set(1, scope: "s", messageId: "m\(n)") }
        #expect(store.count == 200)
        #expect(store.seconds(scope: "acct|ivy|s1", messageId: "stored-row-12-assistant") == nil)     // the 201st evicts the oldest
        store.move(scope: "s", from: "m199", to: "stored-9")
        #expect(store.seconds(scope: "s", messageId: "stored-9") == 1)
    }

    @Test func marksSurviveARelaunch() {
        let suite = "hqn.tests.turnmarks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        TurnMarkStore(defaults: defaults).set(72, scope: "a", messageId: "m")
        #expect(TurnMarkStore(defaults: defaults).seconds(scope: "a", messageId: "m") == 72)
        SeenStore(defaults: defaults).mark("chat", newestID: "m9", count: 9)
        #expect(SeenStore(defaults: defaults).mark(for: "chat")?.newestID == "m9")
    }

    @Test func whereAReopenedChatLands() {
        let ids = ["u1", "a1", "u2", "a2", "a3"]
        let incoming = [false, true, false, true, true]
        #expect(SeenStore.landing(mark: nil, ids: ids, incoming: incoming) == .usual)
        #expect(SeenStore.landing(mark: SeenMark(newestID: "a3", count: 5, at: Date()), ids: ids, incoming: incoming) == .usual)
        #expect(SeenStore.landing(mark: SeenMark(newestID: "a1", count: 2, at: Date()), ids: ids, incoming: incoming) == .unseen(firstIndex: 3))
        // The seen id is gone (a resync renamed it): the count finds the place.
        #expect(SeenStore.landing(mark: SeenMark(newestID: "local-1", count: 3, at: Date()), ids: ids, incoming: incoming) == .unseen(firstIndex: 3))
        // Only your own message is new: nothing to land on.
        #expect(SeenStore.landing(mark: SeenMark(newestID: "a1", count: 2, at: Date()), ids: ["u1", "a1", "u2"], incoming: [false, true, false]) == .usual)
        let store = SeenStore(defaults: nil)
        for n in 0..<130 { store.mark("chat\(n)", newestID: "m", count: 1) }
        #expect(store.count == 120 && store.mark(for: "chat0") == nil && store.mark(for: "chat129") != nil)
    }
}

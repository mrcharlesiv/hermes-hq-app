// A live voice chat's words are kept with the chat (`VoiceChatRecord`): the message a finished conversation sends, how
// the chat reads it back, its row, folding heard delegated turns, and the controller sending it.

import Foundation
import Testing
@testable import HermesHQNative

struct VoiceChatRecordTests {
    private func fragment(_ user: Bool, _ text: String) -> LiveTranscriptFragment {
        LiveTranscriptFragment(speaker: user ? .user : .assistant, text: text, startMs: 0, endMs: 0)
    }

    private func turns(_ pieces: [(Bool, String)]) -> [VoiceChatRecord.Turn] {
        var out: [VoiceChatRecord.Turn] = []
        for piece in pieces { VoiceChatRecord.add(fragment(piece.0, piece.1), to: &out) }
        return out
    }

    private func foldTag(_ user: String, _ assistant: String? = nil) throws -> String {
        let u = ChatMessage(id: "u", role: .user, parts: [.text(user)], timestamp: nil, rowId: nil)
        let a = assistant.map { [ChatMessage(id: "a", role: .assistant, parts: [.text($0)], timestamp: nil, rowId: nil)] } ?? []
        return try #require(VoiceChatRecord.turnFoldTag(users: [u], assistants: a))
    }

    @Test func piecesOfOneSpeakerAreOneTurn() {
        let said = turns([(false, "Hi "), (false, "there."), (true, "What's on "), (true, "my calendar?"), (false, "Two things.")])
        #expect(said.count == 3)
        #expect(VoiceChatRecord.settled(said).map(\.text) == ["Hi there.", "What's on my calendar?", "Two things."])
    }

    @Test func separateSentencesGetCleanSpacingWithoutBreakingDecimalsInitialsLinksOrGrokJitter() {
        var said: [VoiceChatRecord.Turn] = []
        // Back-to-back sentences and closing quotes/parens get spaces.
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .assistant, text: "Checking now.", startMs: 0, endMs: 500), to: &said)
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .assistant, text: "The park trail opens at nine.", startMs: 600, endMs: 1_500), to: &said)
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .assistant, text: "\"Done.\"", startMs: 1_600, endMs: 1_900), to: &said)
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .assistant, text: "Next item.", startMs: 2_000, endMs: 2_300), to: &said)
        // Decimals, prices, versions, multi-letter initials, domains, Markdown links, and slow Grok arrival pauses stay
        // intact, while "Plan B. Then", "U.S. Army", and "done. 3 items" get clean spacing.
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .user, text: "Check the U.", startMs: 2_400, endMs: 2_400), to: &said)
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .user, text: "S.", startMs: 2_450, endMs: 2_450), to: &said)
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .user, text: "Army calen", startMs: 2_500, endMs: 2_500), to: &said)
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .user, text: "dar at example.", startMs: 3_400, endMs: 3_400), to: &said)
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .user, text: "com for $4.", startMs: 3_500, endMs: 3_500), to: &said)
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .user, text: "99 and v3.", startMs: 4_200, endMs: 4_200), to: &said)
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .user, text: "14 [Guide]", startMs: 4_300, endMs: 4_300), to: &said)
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .user, text: "(https://example.com). Plan B.", startMs: 4_900, endMs: 4_900), to: &said)
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .user, text: "Then done.", startMs: 5_000, endMs: 5_000), to: &said)
        VoiceChatRecord.add(LiveTranscriptFragment(speaker: .user, text: "3 items.", startMs: 5_100, endMs: 5_100), to: &said)
        let settled = VoiceChatRecord.settled(said)
        #expect(settled.count == 2)
        #expect(settled[0].text == "Checking now. The park trail opens at nine. \"Done.\" Next item.")
        #expect(settled[1].text == "Check the U.S. Army calendar at example.com for $4.99 and v3.14 [Guide](https://example.com). Plan B. Then done. 3 items.")
    }

    @Test func foldedTurnTagsRoundTripBeforeNoReplyInstruction() throws {
        let said = turns([(true, "What's the latest on the launch?"), (false, "Still on for Thursday.")])
        let tag = try foldTag("What's the latest on the launch?", "Still on for Thursday.")
        let message = try #require(VoiceChatRecord.message(said, seconds: 50, foldedTags: [tag], includeExplicitMarker: true))
        let tagRange = try #require(message.range(of: "[folded: \(tag)]"))
        let noReplyRange = try #require(message.range(of: "reply with exactly NO_REPLY.)"))
        #expect(tagRange.upperBound < noReplyRange.lowerBound)
        let found = try #require(VoiceChatRecord.parse(message))
        #expect(found.title == "Voice Chat · 0:50")
        #expect(found.durationSeconds == 50)
        #expect(found.hasExplicitFoldMetadata)
        #expect(found.foldedTurns.map(\.token) == [tag])
        #expect(!found.words.contains("[folded:"))
        #expect(!found.words.contains("From the app"))
        #expect(found.words == "You: What's the latest on the launch?\n\nVoice: Still on for Thursday.")

        // Empty tags with explicit marker emit `[folded: none]` before `NO_REPLY`.
        let noneMsg = try #require(VoiceChatRecord.message(said, seconds: 50, foldedTags: [], includeExplicitMarker: true))
        #expect(noneMsg.contains("[folded: none] Do not act on this message"))
        let noneFound = try #require(VoiceChatRecord.parse(noneMsg))
        #expect(noneFound.hasExplicitFoldMetadata)
        #expect(noneFound.foldedTurns.isEmpty)
    }

    /// Explicit `[folded: none]` disables legacy retrospective matching so turns deliberately unhidden at hang-up
    /// never vanish again when the queued Voice Chat card lands.
    @Test func explicitFoldedNoneNeverRehidesUnhiddenTurn() throws {
        let base = Date(timeIntervalSince1970: 1_791_600_000)
        let said = turns([
            (true, "What's on my calendar tomorrow morning?"),
            (false, "You have a design sync at nine and a lunch at noon."),
        ])
        let recordText = try #require(VoiceChatRecord.message(said, seconds: 30, foldedTags: [], includeExplicitMarker: true))
        let messages: [ChatMessage] = [
            ChatMessage(id: "u1", role: .user, parts: [.text("What's on my calendar tomorrow morning?")], timestamp: base.addingTimeInterval(5), rowId: 10),
            ChatMessage(id: "a1", role: .assistant, parts: [.text("You have a design sync at nine, a lunch at noon, and six more items in the afternoon.")], timestamp: base.addingTimeInterval(15), rowId: 11),
            ChatMessage(id: "vr", role: .user, parts: [.text(recordText)], timestamp: base.addingTimeInterval(30), rowId: 12),
        ]
        let built = ChatRowBuilder.build(.init(messages: messages, isRunning: false, botName: "Ivy", expanded: []))
        let bubbles = built.compactMap { row -> String? in if case .bubble(let b) = row.kind { return b.text } else { return nil } }
        #expect(bubbles.count == 2)
        #expect(bubbles[1].contains("six more items"))
    }

    /// Delegated voice turns named by `[folded: ...]` content hashes survive SQLite row-id renumbering (after
    /// Regenerate / Edit / Rewind), fold lookup tool steps, and keep earlier typed bubbles visible.
    @Test func foldedTurnsSurviveRowIdRenumberingAndSkipDuplicateSeed() throws {
        let base = Date(timeIntervalSince1970: 1_791_600_000)
        let prompt = "What's the latest on the launch schedule?"
        let reply = "Still on for Thursday afternoon, waiting on QA sign-off."
        let said = turns([(true, prompt), (false, "Checking now. " + reply)])
        let tag = try foldTag(prompt, reply)
        let recordText = try #require(VoiceChatRecord.message(said, seconds: 50, foldedTags: [tag], includeExplicitMarker: true))
        let lookup = ToolCall(id: "t1", name: "web_search", title: "Searched launch notes", argsText: nil,
                              summary: "Found 2 results", state: .done, durationSeconds: 1.4)
        // Simulate renumbered row IDs after a rewind later in the chat (row IDs completely changed).
        let messages: [ChatMessage] = [
            ChatMessage(id: "u0", role: .user, parts: [.text("Morning check-in")], timestamp: base.addingTimeInterval(-600), rowId: 901),
            ChatMessage(id: "a0", role: .assistant, parts: [.text("All clear this morning.")], timestamp: base.addingTimeInterval(-590), rowId: 902),
            ChatMessage(id: "u1", role: .user, parts: [.text(prompt)], timestamp: base.addingTimeInterval(15), rowId: 950),
            ChatMessage(id: "a1", role: .assistant, parts: [.tool(lookup), .text(reply)], timestamp: base.addingTimeInterval(40), rowId: 951),
            ChatMessage(id: "vr", role: .user, parts: [.text(recordText)], timestamp: base.addingTimeInterval(50), rowId: 952),
        ]
        let built = ChatRowBuilder.build(.init(messages: messages, isRunning: false, botName: "Ivy", expanded: []))
        let bubbles = built.compactMap { row -> String? in if case .bubble(let b) = row.kind { return b.text } else { return nil } }
        let voice = built.compactMap { row -> BackgroundResultRow? in if case .backgroundResult(let b) = row.kind, b.voice { return b } else { return nil } }
        let tools = built.filter { if case .toolRun = $0.kind { return true } else { return false } }
        #expect(bubbles == ["Morning check-in", "All clear this morning."])
        #expect(voice.map(\.title) == ["Voice Chat · 0:50"])
        #expect(tools.isEmpty)
        let seed = LiveChatSession.spokenTurns(messages)
        #expect(seed.count == 3)
        #expect(seed[2].text.hasPrefix("(Said in an earlier voice chat)"))
    }

    /// Repeating the same question in one call (first heard, second unheard) folds ONLY the heard turn, and quick
    /// redials where call 1's record lands after call 2's prompt still fold both calls cleanly.
    @Test func repeatedQuestionFoldsOnlyHeardTurnAndQuickRedialFoldsAcrossInterleavedRecords() throws {
        let base = Date(timeIntervalSince1970: 1_791_600_000)
        let heardTag = try foldTag("Check server status", "All nodes are healthy.")
        let rec = try #require(VoiceChatRecord.message(turns([(true, "Check server status"), (false, "All nodes are healthy.")]),
                                                       seconds: 40, foldedTags: [heardTag], includeExplicitMarker: true))
        let repeated: [ChatMessage] = [
            ChatMessage(id: "u1", role: .user, parts: [.text("Check server status")], timestamp: base, rowId: 1),
            ChatMessage(id: "a1", role: .assistant, parts: [.text("All nodes are healthy.")], timestamp: base.addingTimeInterval(5), rowId: 2),
            ChatMessage(id: "u2", role: .user, parts: [.text("Check server status")], timestamp: base.addingTimeInterval(20), rowId: 3),
            ChatMessage(id: "a2", role: .assistant, parts: [.text("Worker two restarted just now.")], timestamp: base.addingTimeInterval(35), rowId: 4),
            ChatMessage(id: "vr", role: .user, parts: [.text(rec)], timestamp: base.addingTimeInterval(40), rowId: 5),
        ]
        let folded = VoiceChatRecord.foldedIndices(in: repeated)
        #expect(folded == [0, 1])

        // Quick redial: call 1's queued record lands between call 2's prompt and reply.
        let call1Tag = try foldTag("First call question", "First call answer.")
        let call2Tag = try foldTag("Second call question", "Second call answer.")
        let rec1 = try #require(VoiceChatRecord.message(turns([(true, "First call question"), (false, "First call answer.")]),
                                                        seconds: 20, foldedTags: [call1Tag], includeExplicitMarker: true))
        let rec2 = try #require(VoiceChatRecord.message(turns([(true, "Second call question"), (false, "Second call answer.")]),
                                                        seconds: 25, foldedTags: [call2Tag], includeExplicitMarker: true))
        let interleaved: [ChatMessage] = [
            ChatMessage(id: "c1u", role: .user, parts: [.text("First call question")], timestamp: base, rowId: 10),
            ChatMessage(id: "c1a", role: .assistant, parts: [.text("First call answer.")], timestamp: base.addingTimeInterval(5), rowId: 11),
            ChatMessage(id: "c2u", role: .user, parts: [.text("Second call question")], timestamp: base.addingTimeInterval(15), rowId: 12),
            ChatMessage(id: "r1", role: .user, parts: [.text(rec1)], timestamp: base.addingTimeInterval(20), rowId: 13),
            ChatMessage(id: "c2a", role: .assistant, parts: [.text("Second call answer.")], timestamp: base.addingTimeInterval(22), rowId: 14),
            ChatMessage(id: "r2", role: .user, parts: [.text(rec2)], timestamp: base.addingTimeInterval(25), rowId: 15),
        ]
        #expect(VoiceChatRecord.foldedIndices(in: interleaved) == [0, 1, 2, 4])
    }

    /// Rich deliverables (HTML previews, bare image paths, case-insensitive MEDIA:, fenced code blocks, Markdown
    /// tables, links, diff previews) stay visible and remain in the next call's seed even when the surrounding voice
    /// turn folds.
    @Test func richDeliverablesStayVisibleAndStayInSeedWhenVoiceTurnFolds() throws {
        let base = Date(timeIntervalSince1970: 1_791_600_000)
        let pairs: [(String, String)] = [
            ("Build the summary page.", "Here is the report:\n\n::preview{file=\"/Users/me/report.html\"}"),
            ("Save the chart image.", "Saved chart at /Users/me/shots/01.png"),
            ("Show the screenshot path.", "Captured preview: `/Users/me/shots/02.jpg`"),
            ("Attach the banner.", "media: /Users/me/banner.png"),
            ("Write a Swift snippet.", "```swift\nlet total = 42\n```"),
            ("Compare the plans.", "| Plan | Cost |\n| --- | --- |\n| Basic | $5 |"),
            ("Share the links.", "Docs: https://example.com/guide, deep link hermes://settings, email demo@example.com"),
            ("Plain spoken answer.", "Everything looks good today."),
            ("Social media note.", "Our social media: post schedule looks great."),
        ]
        let tags = try pairs.map { try foldTag($0.0, $0.1) }
        let said = turns([(true, "Build everything and check status."), (false, "All done.")])
        let recordText = try #require(VoiceChatRecord.message(said, seconds: 60, foldedTags: tags, includeExplicitMarker: true))
        var messages: [ChatMessage] = []
        for (i, pair) in pairs.enumerated() {
            messages.append(ChatMessage(id: "u\(i)", role: .user, parts: [.text(pair.0)], timestamp: base.addingTimeInterval(Double(i * 4)), rowId: 100 + i * 2))
            messages.append(ChatMessage(id: "a\(i)", role: .assistant, parts: [.text(pair.1)], timestamp: base.addingTimeInterval(Double(i * 4 + 2)), rowId: 101 + i * 2))
        }
        messages.append(ChatMessage(id: "vr", role: .user, parts: [.text(recordText)], timestamp: base.addingTimeInterval(60), rowId: 200))

        let built = ChatRowBuilder.build(.init(messages: messages, isRunning: false, botName: "Ivy", expanded: []))
        let bubbles = built.compactMap { row -> String? in if case .bubble(let b) = row.kind { return b.text } else { return nil } }
        // The 7 deliverable replies stay visible; all 9 user prompts, the plain reply, and "social media:" prose fold.
        #expect(bubbles.count == 7)
        #expect(!bubbles.contains { $0.contains("social media:") })
        #expect(bubbles.contains { $0.contains("::preview{") })
        #expect(bubbles.contains { $0.contains("/Users/me/shots/01.png") })
        #expect(bubbles.contains { $0.contains("/Users/me/shots/02.jpg") })
        #expect(bubbles.contains { $0.contains("media: /Users/me/banner.png") })
        #expect(bubbles.contains { $0.contains("```swift") })
        #expect(bubbles.contains { $0.contains("| Plan | Cost |") })
        #expect(bubbles.contains { $0.contains("hermes://settings") })
        #expect(!bubbles.contains { $0.contains("Everything looks good today.") })

        // `.diffPreview` stays visible in a folded turn while `.toolBubble` folds away.
        let editCall = ToolCall(id: "t-edit", name: "patch", title: "Edited App.swift", argsText: nil,
                                summary: nil, state: .done, durationSeconds: 0.4)
        let diffRow = ChatRow(id: "a|diff", messageId: "a", scope: "", fingerprint: 1,
                              kind: .activity(.diffPreview(DiffPreviewRow(call: editCall, path: "App.swift", added: 2, removed: 1, lines: [], more: false))),
                              gapAbove: 4, variant: 0)
        let toolRow = ChatRow(id: "a|tool", messageId: "a", scope: "", fingerprint: 2,
                              kind: .activity(.toolBubble(ToolBubbleRow(lines: [], earlier: 0, time: nil, calls: [editCall]))),
                              gapAbove: 4, variant: 0)
        #expect(ChatRowBuilder.keepsInFoldedVoiceTurn(diffRow))
        #expect(!ChatRowBuilder.keepsInFoldedVoiceTurn(toolRow))

        // Next call's seed still knows about visible deliverables without re-seeding plain folded turns.
        let seed = LiveChatSession.spokenTurns(messages)
        #expect(seed.contains { $0.assistant && $0.text.contains("Here is the report.") })
        #expect(seed.contains { $0.assistant && $0.text.contains("hermes://settings") })
        #expect(!seed.contains { $0.assistant && $0.text.contains("Everything looks good today.") })
    }

    /// Errors, Tapback reactions, and attached threads never leave orphaned badges or Retry cards under a hidden bubble.
    @Test func errorsReactionsAndThreadsNeverLeaveOrphanedRows() throws {
        let base = Date(timeIntervalSince1970: 1_791_600_000)
        let t1 = try foldTag("First prompt", "First reply.")
        let t2 = try foldTag("Second prompt", "Second reply.")
        let t3 = try foldTag("Third prompt", "Third reply.")
        let rec = try #require(VoiceChatRecord.message(turns([(true, "First prompt"), (false, "First reply.")]),
                                                       seconds: 30, foldedTags: [t1, t2, t3], includeExplicitMarker: true))
        var errReply = ChatMessage(id: "a1", role: .assistant, parts: [.text("First reply.")], timestamp: base.addingTimeInterval(2), rowId: 2)
        errReply.error = "Gateway timed out"
        var reactedReply = ChatMessage(id: "a2", role: .assistant, parts: [.text("Second reply.")], timestamp: base.addingTimeInterval(6), rowId: 4)
        reactedReply.reactions = [MessageReaction(emoji: "❤️", author: "user", at: nil)]
        let messages: [ChatMessage] = [
            ChatMessage(id: "u1", role: .user, parts: [.text("First prompt")], timestamp: base, rowId: 1),
            errReply,
            ChatMessage(id: "u2", role: .user, parts: [.text("Second prompt")], timestamp: base.addingTimeInterval(4), rowId: 3),
            reactedReply,
            ChatMessage(id: "u3", role: .user, parts: [.text("Third prompt")], timestamp: base.addingTimeInterval(8), rowId: 5),
            ChatMessage(id: "a3", role: .assistant, parts: [.text("Third reply.")], timestamp: base.addingTimeInterval(10), rowId: 6),
            ChatMessage(id: "vr", role: .user, parts: [.text(rec)], timestamp: base.addingTimeInterval(20), rowId: 7),
        ]
        var input = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Ivy", expanded: [])
        let thread = ChatThread(id: "th1", storedId: nil, title: "Follow up", startedAt: base, anchorMessageId: "a3",
                                anchorRow: 6, messages: [], running: false, problem: nil, scope: "")
        input.threads["a3"] = [ThreadRowInput(thread: thread, open: false)]
        let built = ChatRowBuilder.build(input)
        let bubbles = built.compactMap { row -> String? in if case .bubble(let b) = row.kind { return b.text } else { return nil } }
        // Turn 1 (error), Turn 2 (reaction), and Turn 3 (attached thread) all keep BOTH prompt and reply visible.
        #expect(bubbles.contains("First prompt"))
        #expect(bubbles.contains("Second prompt"))
        #expect(bubbles.contains("Second reply."))
        #expect(bubbles.contains("Third prompt"))
        #expect(bubbles.contains("Third reply."))
        // ChatFind agrees with ChatRowBuilder on threaded turns and media attachments.
        let findThreaded = ChatFind.matches("Third", in: messages, excludedIds: ["a3"])
        #expect(findThreaded.map(\.messageId) == ["u3", "a3"])
    }

    /// Historical pre-metadata VoiceChatRecord rows still fold matching call-window turns while rejecting short
    /// bag-of-words prompts, non-word-bounded substrings, unpaired user messages, and unspoken/interrupted replies.
    @Test func legacyRecordMatcherFoldsValidCallWindowAndRejectsFalseMatches() throws {
        let base = Date(timeIntervalSince1970: 1_791_600_000)
        let said = turns([
            (true, "Hey what are the weekend hours for the Maple Street bookshop in Riverton?"),
            (false, "Checking now. The Maple Street bookshop opens at ten on Saturday and stays open until six both days for this item."),
        ])
        let legacyRecord = try #require(VoiceChatRecord.message(said, seconds: 50))
        var stoppedReply = ChatMessage(id: "int-a", role: .assistant, parts: [.text("The Maple Street bookshop opens at ten on Saturday.")], timestamp: base.addingTimeInterval(35), rowId: 17)
        stoppedReply.interrupted = true
        let messages: [ChatMessage] = [
            ChatMessage(id: "old-u", role: .user, parts: [.text("Can you check my reminders?")], timestamp: base.addingTimeInterval(-300), rowId: 10),
            ChatMessage(id: "old-a", role: .assistant, parts: [.text("You have two reminders today.")], timestamp: base.addingTimeInterval(-295), rowId: 11),
            // Non-word-bounded substring ("is it" inside "this item") must NOT match.
            ChatMessage(id: "sub-u", role: .user, parts: [.text("is it")], timestamp: base.addingTimeInterval(2), rowId: 12),
            ChatMessage(id: "sub-a", role: .assistant, parts: [.text("The Maple Street bookshop opens at ten on Saturday.")], timestamp: base.addingTimeInterval(3), rowId: 13),
            // Short bag-of-words prompt ("hours Riverton") must NOT match.
            ChatMessage(id: "short-u", role: .user, parts: [.text("hours Riverton")], timestamp: base.addingTimeInterval(6), rowId: 14),
            ChatMessage(id: "short-a", role: .assistant, parts: [.text("The Maple Street bookshop opens at ten on Saturday.")], timestamp: base.addingTimeInterval(7), rowId: 15),
            // Unpaired matching user message (followed directly by another user message) must NOT fold.
            ChatMessage(id: "unpaired-u", role: .user, parts: [.text("weekend hours for the Maple Street bookshop")], timestamp: base.addingTimeInterval(10), rowId: 16),
            // Interrupted reply with non-empty text must NOT fold.
            ChatMessage(id: "int-u", role: .user, parts: [.text("What are the weekend hours for the Maple Street bookshop in Riverton?")], timestamp: base.addingTimeInterval(32), rowId: 18),
            stoppedReply,
            // Valid matching turn inside the call window DOES fold.
            ChatMessage(id: "del-u", role: .user, parts: [.text("What are the weekend hours for the Maple Street bookshop in Riverton?")], timestamp: base.addingTimeInterval(40), rowId: 19),
            ChatMessage(id: "del-a", role: .assistant, parts: [.text("The Maple Street bookshop in Riverton opens at ten on Saturday and stays open until six on both weekend days.")], timestamp: base.addingTimeInterval(45), rowId: 20),
            ChatMessage(id: "vr", role: .user, parts: [.text(legacyRecord)], timestamp: base.addingTimeInterval(50), rowId: 21),
        ]
        let folded = VoiceChatRecord.foldedIndices(in: messages)
        #expect(folded == [9, 10])
    }

    /// An unspoken short assistant reply is never folded by legacy matching just because it shares two topic words.
    @Test func legacyRecordNeverFoldsShortUnspokenReply() throws {
        let base = Date(timeIntervalSince1970: 1_791_600_000)
        let said = turns([
            (true, "Research the quarterly budget numbers and summarize them."),
            (false, "Let me check the quarterly budget right now."),
        ])
        let legacyRecord = try #require(VoiceChatRecord.message(said, seconds: 20))
        let messages: [ChatMessage] = [
            ChatMessage(id: "u1", role: .user, parts: [.text("Research the quarterly budget numbers and summarize them.")], timestamp: base.addingTimeInterval(5), rowId: 21),
            ChatMessage(id: "a1", role: .assistant, parts: [.text("The quarterly budget is on track.")], timestamp: base.addingTimeInterval(15), rowId: 22),
            ChatMessage(id: "vr", role: .user, parts: [.text(legacyRecord)], timestamp: base.addingTimeInterval(20), rowId: 23),
        ]
        let folded = VoiceChatRecord.foldedIndices(in: messages)
        #expect(folded.isEmpty)
    }

    /// Waiting capsule stays hidden while answering `VoiceChatRecord` (`NO_REPLY`), shows while a folded live-voice
    /// turn is thinking or running tools (middle-ground UX), retires once a folded live-voice reply begins writing
    /// plain text, and still shows normally for a later unrelated turn after an older Voice Chat card.
    @Test func waitingRowSuppressionIsScopedToVoiceRecordAndLiveVoiceWriting() throws {
        let recordText = try #require(VoiceChatRecord.message(turns([(true, "Check status."), (false, "All green.")]), seconds: 15))
        let recMsg = ChatMessage(id: "vr", role: .user, parts: [.text(recordText)], timestamp: Date(), rowId: 90)
        let whileRecord = ChatRowBuilder.build(.init(messages: [recMsg], isRunning: true, botName: "Ivy", expanded: []))
        #expect(!whileRecord.contains { if case .waiting = $0.kind { return true } else { return false } })

        // Later unrelated assistant turn running after an older record still shows waiting capsule when `answeringVoiceRecord == false`.
        let foreignAssistant = ChatMessage(id: "a-foreign", role: .assistant, parts: [.tool(ToolCall(id: "t1", name: "web_search", title: "Searching", argsText: nil, summary: nil, state: .running, durationSeconds: nil))], timestamp: Date(), rowId: nil)
        var foreignInput = ChatRowBuilder.Input(messages: [recMsg, foreignAssistant], isRunning: true, botName: "Ivy", expanded: [])
        foreignInput.answeringVoiceRecord = false
        let forForeign = ChatRowBuilder.build(foreignInput)
        #expect(forForeign.contains { if case .waiting = $0.kind { return true } else { return false } })

        // Middle-ground UX: folded live-voice turn shows the live status pill while thinking or running tools,
        // then retires once plain reply text begins streaming (no bubbles drawn either way).
        let liveUser = ChatMessage(id: "live-u", role: .user, parts: [.text("Check status")], timestamp: Date(), rowId: nil)
        var foldedPromptInput = ChatRowBuilder.Input(messages: [liveUser], isRunning: true, botName: "Ivy", expanded: [])
        foldedPromptInput.voiceFoldedIds = ["live-u"]
        let forFoldedPrompt = ChatRowBuilder.build(foldedPromptInput)
        #expect(forFoldedPrompt.contains { if case .waiting = $0.kind { return true } else { return false } })
        #expect(!forFoldedPrompt.contains { $0.isBubble })

        let liveTool = ChatMessage(id: "live-a", role: .assistant,
                                   parts: [.tool(ToolCall(id: "t2", name: "web_search", title: "Checking calendar", argsText: nil, summary: nil, state: .running, durationSeconds: nil))],
                                   timestamp: Date(), rowId: nil)
        var foldedToolInput = ChatRowBuilder.Input(messages: [liveUser, liveTool], isRunning: true, botName: "Ivy", expanded: [])
        foldedToolInput.voiceFoldedIds = ["live-u", "live-a"]
        let forFoldedTool = ChatRowBuilder.build(foldedToolInput)
        #expect(forFoldedTool.contains { if case .waiting = $0.kind { return true } else { return false } })
        #expect(!forFoldedTool.contains { $0.isBubble })

        let liveWriting = ChatMessage(id: "live-a", role: .assistant,
                                      parts: [.tool(ToolCall(id: "t2", name: "web_search", title: "Checked calendar", argsText: nil, summary: "Done", state: .done, durationSeconds: 1.0)),
                                              .text("You have two meetings tomorrow.")],
                                      timestamp: Date(), rowId: nil)
        var foldedWritingInput = ChatRowBuilder.Input(messages: [liveUser, liveWriting], isRunning: true, botName: "Ivy", expanded: [])
        foldedWritingInput.voiceFoldedIds = ["live-u", "live-a"]
        let forFoldedWriting = ChatRowBuilder.build(foldedWritingInput)
        #expect(!forFoldedWriting.contains { if case .waiting = $0.kind { return true } else { return false } })
        #expect(!forFoldedWriting.contains { $0.isBubble })
    }

    /// Find in chat skips collapsed Voice Chat records and folded plain turns, while still indexing earlier typed
    /// bubbles and visible deliverable parts inside folded turns.
    @Test func chatFindExcludesFoldedTurnsAndRecordsButIndexesVisibleDeliverables() throws {
        let base = Date(timeIntervalSince1970: 1_791_600_000)
        let t1 = try foldTag("Find Riverton trail", "The Riverton trail is open.")
        let t2 = try foldTag("Send Riverton map", "Map link: https://example.com/riverton")
        let rec = try #require(VoiceChatRecord.message(turns([(true, "Find Riverton trail"), (false, "The Riverton trail is open.")]),
                                                       seconds: 30, foldedTags: [t1, t2], includeExplicitMarker: true))
        let messages: [ChatMessage] = [
            ChatMessage(id: "u0", role: .user, parts: [.text("Earlier Riverton note")], timestamp: base.addingTimeInterval(-60), rowId: 1),
            ChatMessage(id: "u1", role: .user, parts: [.text("Find Riverton trail")], timestamp: base, rowId: 2),
            ChatMessage(id: "a1", role: .assistant, parts: [.text("The Riverton trail is open.")], timestamp: base.addingTimeInterval(5), rowId: 3),
            ChatMessage(id: "u2", role: .user, parts: [.text("Send Riverton map")], timestamp: base.addingTimeInterval(10), rowId: 4),
            ChatMessage(id: "a2", role: .assistant, parts: [.text("Map link: https://example.com/riverton")], timestamp: base.addingTimeInterval(15), rowId: 5),
            ChatMessage(id: "vr", role: .user, parts: [.text(rec)], timestamp: base.addingTimeInterval(30), rowId: 6),
        ]
        let matches = ChatFind.matches("Riverton", in: messages)
        #expect(matches.map(\.messageId) == ["u0", "a2"])
        // A folded message carrying media/attachments remains searchable in Find (matching ChatRowBuilder).
        let withMedia = ChatFind.matches("Riverton", in: messages, mediaMessageIds: ["a1"])
        #expect(withMedia.map(\.messageId) == ["u0", "a1", "a2"])
    }

    /// Live-built messages and the same gateway rows hydrated via `Hydration.fold` produce matching fold tags even
    /// when a tool-step reply includes commentary before the tool call or re-folds on reload.
    @Test func liveAndHydratedMessagesMatchExplicitFoldTags() throws {
        let prompt = "Check the Riverton train schedule"
        let finalReply = "Next train leaves Riverton at 4:15 PM."
        let lookup = ToolCall(id: "tc1", name: "web_search", title: "Searched schedule", argsText: nil,
                              summary: "Found times", state: .done, durationSeconds: 1.0)
        let liveUser = ChatMessage(id: "local-u", role: .user, parts: [.text(prompt)], timestamp: nil, rowId: 10)
        let liveAssistant = ChatMessage(id: "local-a", role: .assistant,
                                        parts: [.text("Checking the schedule."), .tool(lookup), .text(finalReply)],
                                        timestamp: nil, rowId: 11)
        let tag = try #require(VoiceChatRecord.turnFoldTag(users: [liveUser], assistants: [liveAssistant]))
        let recordText = try #require(VoiceChatRecord.message(turns([(true, prompt), (false, finalReply)]),
                                                              seconds: 25, foldedTags: [tag], includeExplicitMarker: true))
        // Hydrate the stored gateway rows (where the commentary before the tool is absent or folded differently).
        let rawRows: [JSONValue] = [
            .object(["role": "user", "content": .string(prompt), "row_id": 501, "timestamp": 1_791_600_010]),
            .object(["role": "assistant", "content": "", "tool_calls": .array([
                .object(["id": "tc1", "type": "function", "function": .object(["name": "web_search", "arguments": "{}"])])
            ]), "row_id": 502, "timestamp": 1_791_600_012]),
            .object(["role": "tool", "tool_call_id": "tc1", "name": "web_search", "content": "4:15 PM", "row_id": 503, "timestamp": 1_791_600_013]),
            .object(["role": "assistant", "content": .string(finalReply), "row_id": 504, "timestamp": 1_791_600_015]),
            .object(["role": "user", "content": .string(recordText), "row_id": 505, "timestamp": 1_791_600_025]),
            .object(["role": "assistant", "content": "NO_REPLY", "row_id": 506, "timestamp": 1_791_600_026]),
        ]
        let hydrated = Hydration.fold(rawRows).messages
        let folded = VoiceChatRecord.foldedIndices(in: hydrated)
        #expect(folded == [0, 1])
        let built = ChatRowBuilder.build(.init(messages: TimelineNotes.resolve(hydrated), isRunning: false, botName: "Ivy", expanded: []))
        #expect(built.filter(\.isBubble).isEmpty)
        let voice = built.compactMap { row -> BackgroundResultRow? in if case .backgroundResult(let b) = row.kind, b.voice { return b } else { return nil } }
        #expect(voice.map(\.title) == ["Voice Chat · 0:25"])
    }

    /// A long call truncated past `maxChars` emits `[folded: none]` so early turns whose words were trimmed from the
    /// Voice Chat card are never hidden from chat, and `SteerRule.steerable` never allows steering a Voice Chat record.
    @Test func truncatedLongCallNeverFoldsAndRecordIsNeverSteerable() throws {
        var pieces: [(Bool, String)] = []
        for i in 0..<400 { pieces.append((i % 2 == 0, "Turn number \(i) " + String(repeating: "word ", count: 30))) }
        let longTurns = turns(pieces)
        #expect(VoiceChatRecord.willTruncate(longTurns))
        let tag = try foldTag("Turn number 0", "Turn number 1")
        let truncatedMsg = try #require(VoiceChatRecord.message(longTurns, seconds: 3_700, foldedTags: [tag], includeExplicitMarker: true))
        let parsed = try #require(VoiceChatRecord.parse(truncatedMsg))
        #expect(parsed.hasExplicitFoldMetadata)
        #expect(parsed.foldedTurns.isEmpty)
        #expect(truncatedMsg.contains("[folded: none]"))

        let shortRecord = try #require(VoiceChatRecord.message(turns([(true, "Check status."), (false, "All green.")]), seconds: 15))
        #expect(!SteerRule.steerable(QueuedMessage(id: "q1", text: shortRecord)))
    }

    /// Talking over the voice (`bargeIn`), filler ending while a new reply is queued, mid-reply pauses past the silence
    /// hangover, saying "stop" mid-answer, and connection drops mid-speech never mark a cut-off answer as heard;
    /// tapping Stop AFTER an earlier finished turn does not un-hear it, and `LiveServerEvent.parse` detects barge-in.
    @Test func liveTalkLoopBargeInFillerPauseStopWordAndDropDoNotMarkHeard() {
        #expect(LiveServerEvent.parse(#"{"type":"input_audio_buffer.speech_started"}"#) == .bargeIn)
        #expect(LiveServerEvent.parse(#"{"type":"response.cancelled"}"#) == .bargeIn)
        #expect(LiveServerEvent.parse(#"{"type":"response.done","response":{"status":"cancelled"}}"#) == .bargeIn)
        #expect(LiveServerEvent.parse(#"{"type":"response.done","response":{"status":"completed"}}"#) == .other(type: "response.done"))

        var state = TalkLoopState(now: 0, speaksReplies: true, clock: TalkClock())
        var live = LiveTalkState(engine: .gptLive)
        _ = LiveTalkLoop.reduce(&state, &live, .start, now: 0)
        _ = LiveTalkLoop.reduce(&state, &live, .sessionReady, now: 1)

        // 1. Voice is speaking filler ("Let me look.") when reply a1 is handed over: filler ending must NOT mark a1 heard!
        _ = LiveTalkLoop.reduce(&state, &live, .transcript(fragment(true, "Check my tasks.")), now: 2)
        _ = LiveTalkLoop.reduce(&state, &live, .delegation(id: "d1"), now: 3)
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(true), now: 3.5) // filler speaking
        _ = LiveTalkLoop.reduce(&state, &live, .turnRunning(true), now: 4)
        _ = LiveTalkLoop.reduce(&state, &live, .reply(SpokenReply(messageId: "a1", text: "You have three tasks today.", pending: false)), now: 5)
        _ = LiveTalkLoop.reduce(&state, &live, .turnRunning(false), now: 5)
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(false), now: 5.2) // filler ended before a1 played!
        #expect(!live.heardReplyIds.contains("a1"), "filler ending must not mark freshly handed reply heard")

        // 2. Voice starts playing a1, pauses >0.4s mid-reply (false silence), then resumes: must move back to speaking!
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(true), now: 6)
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(false), now: 8)
        #expect(live.heardReplyIds.contains("a1"))
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(true), now: 8.6) // resumed without new handoff!
        #expect(!live.heardReplyIds.contains("a1"), "resuming after pause must move reply back out of heard")
        // Now finishes cleanly -> heard!
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(false), now: 11)
        #expect(live.heardReplyIds.contains("a1"))

        // 3. Tapping Stop long after a1 finished must NOT un-hear a1!
        _ = LiveTalkLoop.reduce(&state, &live, .stopOrInterrupt, now: 20)
        #expect(live.heardReplyIds.contains("a1"))

        // 4. Turn 2: user talks over the voice (`bargeIn`) mid-speech -> silence hangover after barge-in must NOT mark a2 heard!
        _ = LiveTalkLoop.reduce(&state, &live, .transcript(fragment(true, "Read my ten emails.")), now: 21)
        _ = LiveTalkLoop.reduce(&state, &live, .delegation(id: "d2"), now: 22)
        _ = LiveTalkLoop.reduce(&state, &live, .turnRunning(true), now: 23)
        _ = LiveTalkLoop.reduce(&state, &live, .reply(SpokenReply(messageId: "a2", text: "Email one through ten.", pending: false)), now: 24)
        _ = LiveTalkLoop.reduce(&state, &live, .turnRunning(false), now: 24)
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(true), now: 25)
        _ = LiveTalkLoop.reduce(&state, &live, .bargeIn, now: 26)
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(false), now: 26.4)
        #expect(!live.heardReplyIds.contains("a2"), "talking over the voice must never mark reply heard")

        // 5. Turn 3: connection drops right after audio decays to silence -> revoked on `.closed`!
        _ = LiveTalkLoop.reduce(&state, &live, .transcript(fragment(true, "Check the flights.")), now: 30)
        _ = LiveTalkLoop.reduce(&state, &live, .delegation(id: "d3"), now: 31)
        _ = LiveTalkLoop.reduce(&state, &live, .turnRunning(true), now: 32)
        _ = LiveTalkLoop.reduce(&state, &live, .reply(SpokenReply(messageId: "a3", text: "Three flights available.", pending: false)), now: 33)
        _ = LiveTalkLoop.reduce(&state, &live, .turnRunning(false), now: 33)
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(true), now: 34)
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(false), now: 35)
        _ = LiveTalkLoop.reduce(&state, &live, .closed(reason: "dropped", usageSeconds: nil), now: 36.5)
        #expect(!live.heardReplyIds.contains("a3"), "mid-speech connection drop revokes just-ended audio")
        #expect(live.heardReplyIds.contains("a1"), "earlier genuinely heard turn stays heard")
    }

    /// `LiveTalkLoop` distinguishes handed-to-voice (`passedOn`), actively speaking, cut-off/barged-in, and truly heard
    /// replies so an unheard or partial reply is never marked heard.
    @Test func liveTalkLoopTracksTrulyHeardRepliesOnly() {
        var state = TalkLoopState(now: 0, speaksReplies: true, clock: TalkClock())
        var live = LiveTalkState(engine: .gptLive)
        _ = LiveTalkLoop.reduce(&state, &live, .start, now: 0)
        _ = LiveTalkLoop.reduce(&state, &live, .sessionReady, now: 1)
        _ = LiveTalkLoop.reduce(&state, &live, .transcript(fragment(true, "Check tomorrow's meetings.")), now: 2)
        _ = LiveTalkLoop.reduce(&state, &live, .delegation(id: "d1"), now: 3)
        _ = LiveTalkLoop.reduce(&state, &live, .turnRunning(true), now: 4)
        // Sentence 1 streams and starts playing, then stops while turn is still streaming.
        _ = LiveTalkLoop.reduce(&state, &live, .reply(SpokenReply(messageId: "a1", text: "First item is at nine. Working", pending: true)), now: 5)
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(true), now: 6)
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(false), now: 7)
        #expect(!live.heardReplyIds.contains("a1"), "still streaming — must not be marked heard yet")

        // Turn finishes with a second sentence; handed to voice but NOT played yet.
        _ = LiveTalkLoop.reduce(&state, &live, .reply(SpokenReply(messageId: "a1", text: "First item is at nine. Second item is at two.", pending: false)), now: 8)
        _ = LiveTalkLoop.reduce(&state, &live, .turnRunning(false), now: 8)
        #expect(live.passedOn["a1", default: 0] > 0)
        #expect(!live.heardReplyIds.contains("a1"), "handed to voice is not heard")

        // Voice starts playing second sentence (still not finished).
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(true), now: 9)
        #expect(!live.heardReplyIds.contains("a1"), "mid-playback is not heard")

        // Voice finishes playing -> now genuinely heard!
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(false), now: 10)
        #expect(live.heardReplyIds.contains("a1"))

        // Turn 2: handed to voice on Grok-style whole delivery, then cut off by Stop/Interrupt.
        _ = LiveTalkLoop.reduce(&state, &live, .transcript(fragment(true, "List all eight tasks.")), now: 11)
        _ = LiveTalkLoop.reduce(&state, &live, .delegation(id: "d2"), now: 12)
        _ = LiveTalkLoop.reduce(&state, &live, .turnRunning(true), now: 13)
        _ = LiveTalkLoop.reduce(&state, &live, .reply(SpokenReply(messageId: "a2", text: "Task one through eight.", pending: false)), now: 14)
        _ = LiveTalkLoop.reduce(&state, &live, .turnRunning(false), now: 14)
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(true), now: 15)
        _ = LiveTalkLoop.reduce(&state, &live, .stopOrInterrupt, now: 16)
        _ = LiveTalkLoop.reduce(&state, &live, .assistantSpeaking(false), now: 17)
        #expect(live.passedOn["a2"] == .max)
        #expect(!live.heardReplyIds.contains("a2"), "interrupted playback must never become heard")
        #expect(live.heardReplyIds.contains("a1"), "earlier heard reply stays heard")
    }

    @Test func theMessageOpensWithItsMarkAndReadsBack() throws {
        let said = turns([(false, "Hi there."), (true, "What's on my calendar?"), (false, "Two things: lunch at noon and a call at three.")])
        let message = try #require(VoiceChatRecord.message(said, seconds: 252))
        #expect(message.hasPrefix("[Voice chat transcript · 4:12]\n(From the app"))
        #expect(message.contains("reply with exactly NO_REPLY"))
        #expect(message.contains("\nUser: What's on my calendar?\nVoice assistant: Two things"))
        let found = try #require(VoiceChatRecord.parse(message))
        #expect(found.title == "Voice Chat · 4:12")
        #expect(found.words == "Voice: Hi there.\n\nYou: What's on my calendar?\n\nVoice: Two things: lunch at noon and a call at three.")
        #expect(!found.words.contains("From the app"))
        #expect(VoiceChatRecord.isRecord(message))
    }

    @Test func nothingIsSentWhenThePersonSaidNothingOrOnlyStop() {
        #expect(VoiceChatRecord.message([], seconds: 10) == nil)
        #expect(VoiceChatRecord.message(turns([(false, "Hello, I'm here.")]), seconds: 10) == nil)
        #expect(VoiceChatRecord.message(turns([(false, "Hello."), (true, " Stop. ")]), seconds: 10) == nil)
        #expect(VoiceChatRecord.message(turns([(true, "   ")]), seconds: 10) == nil)
    }

    @Test func aLongConversationKeepsItsNewestPart() throws {
        var pieces: [(Bool, String)] = []
        for i in 0..<400 { pieces.append((i % 2 == 0, "Turn number \(i) " + String(repeating: "word ", count: 30))) }
        let message = try #require(VoiceChatRecord.message(turns(pieces), seconds: 3_700))
        #expect(message.count < VoiceChatRecord.maxChars + 1_000)
        #expect(message.contains(VoiceChatRecord.cutNote))
        #expect(message.contains("Turn number 399"))
        #expect(!message.contains("Turn number 0 "))
        #expect(VoiceChatRecord.parse(message)?.title == "Voice Chat · 1:01:40")
    }

    @Test func ordinaryMessagesAreNotRecords() {
        #expect(VoiceChatRecord.parse("What did we say in the voice chat?") == nil)
        #expect(VoiceChatRecord.parse("[Voice chat transcript and more words") == nil)
        #expect(!VoiceChatRecord.isRecord("[Voice chat transcripts are great]"))
    }

    /// The next voice chat is told what was said, not the note written for the bot.
    @Test func theNextVoiceChatHearsTheWordsOnly() throws {
        let message = try #require(VoiceChatRecord.message(turns([(true, "Book the dentist for Friday."), (false, "Done.")]), seconds: 65))
        let record = ChatMessage(id: "m1", role: .user, parts: [.text(message)], timestamp: nil, rowId: nil)
        let typed = ChatMessage(id: "m2", role: .user, parts: [.text("And the vet?")], timestamp: nil, rowId: nil)
        let seed = LiveChatSession.spokenTurns([record, typed])
        #expect(seed.count == 2)
        #expect(seed[0].text == "(Said in an earlier voice chat) You: Book the dentist for Friday.\n\nVoice: Done.")
        #expect(!seed[0].text.contains("NO_REPLY"))
        #expect(seed[1].text == "And the vet?")
    }

    /// The chat draws the record as one line that opens on the words, never as your bubble.
    @Test func theChatShowsOneLine() throws {
        let message = try #require(VoiceChatRecord.message(turns([(true, "Book the dentist for Friday."), (false, "Done, Friday at ten.")]), seconds: 65))
        var m = ChatMessage(id: "m1", role: .user, parts: [.text(message)], timestamp: Date(timeIntervalSince1970: 1_791_600_000), rowId: nil)
        m.isPending = false
        let closed = ChatRowBuilder.build(.init(messages: [m], isRunning: false, botName: "Ivy", expanded: []))
        let lines = closed.compactMap { row -> BackgroundResultRow? in
            if case .backgroundResult(let b) = row.kind { return b } else { return nil }
        }
        #expect(lines.count == 1)
        #expect(lines.first?.title == "Voice Chat · 1:05")
        #expect(lines.first?.voice == true && lines.first?.glyph == .voice)
        #expect(lines.first?.result == "You: Book the dentist for Friday.\n\nVoice: Done, Friday at ten.")
        #expect(!closed.contains { $0.isBubble })
        let open = ChatRowBuilder.build(.init(messages: [m], isRunning: false, botName: "Ivy", expanded: ["m1|vc"]))
        #expect(open.contains { if case .backgroundResult(let b) = $0.kind { return b.expanded } else { return false } })
    }
}

@Suite("Voice record controller", .serialized)
@MainActor
struct VoiceChatRecordControllerTests {
    @MainActor final class Box { var transport: FixtureLiveVoice? }

    private func make() -> (TalkController, Box) {
        AudioSessionCoordinator.shared.reset()
        KeepAwake.reset()
        TalkController.chosenEngine = nil
        FixtureLiveVoice.failWith = nil
        FixtureLiveVoice.sent = []
        FixtureLiveVoice.exchanged = []
        FixtureLiveVoice.script = [(0.05, #"{"type":"session.started","session":{"id":"sess_test"}}"#)]
        let talk = TalkController()
        let box = Box()
        var config = TalkConfig()
        config.chatMode = .gptLive
        talk.makeCapture = { FixtureTalkCapture(clock: $0) }
        talk.speaker = FakeSpeaker()
        talk.loadConfig = { _ in config }
        talk.transcribe = { _, _ in .success("") }
        talk.loadLiveStatus = { _ in LiveVoiceStatus(mode: .gptLive, available: true) }
        talk.makeLiveTransport = {
            let transport = FixtureLiveVoice()
            box.transport = transport
            return transport
        }
        talk.exchangeLive = { _, _, _ in "v=0\r\nanswer" }
        talk.holdsLeases = false
        talk.isOnScreen = { true }
        talk.speaksReplies = { true }
        talk.playConnectedChime = { }
        return (talk, box)
    }

    private func openSession() async throws -> (ChatHarness, LiveChatSession) {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.queueDrainFallback = .milliseconds(30)
        #expect(await h.open())
        nonisolated final class RowSeq: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 500
            func next() -> Double { lock.lock(); defer { lock.unlock() }; value += 1; return Double(value) }
        }
        let seq = RowSeq()
        h.client.onCall { method, params in
            switch method {
            case "prompt.submit":
                return ["status": "streaming", "user_row_id": .number(seq.next())]
            case "session.redirect":
                return ["status": "redirected", "text": params["text"] ?? ""]
            default:
                return [:]
            }
        }
        return (h, s)
    }

    private func buildRows(_ s: LiveChatSession) -> [ChatRow] {
        var input = ChatRowBuilder.Input(messages: s.messages, isRunning: s.isRunning, botName: "Hermes", expanded: [])
        input.voiceFoldedIds = s.voiceFoldedMessageIds
        input.voiceFoldedRowIds = s.voiceFoldedRowIds
        input.answeringVoiceRecord = s.isAnsweringVoiceRecord
        return ChatRowBuilder.build(input)
    }

    /// Ending a live conversation sends everything said, both speakers, once.
    @Test func endingSendsWhatWasSaid() async throws {
        let (talk, box) = make()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        let transport = try #require(box.transport)
        transport.play(#"{"type":"session.output_transcript.delta","delta":"Hi, what can I do?","start_ms":0,"end_ms":800}"#)
        transport.play(#"{"type":"session.input_transcript.delta","delta":"Tell me a joke","start_ms":900,"end_ms":1800}"#)
        transport.play(#"{"type":"session.output_transcript.delta","delta":"Why did the otter cross the river?","start_ms":1900,"end_ms":2900}"#)
        #expect(await waitUntil { talk.live?.record.count == 3 })
        talk.end()
        #expect(await waitUntil { !talk.isLive })
        #expect(chat.records.count == 1)
        let found = try #require(VoiceChatRecord.parse(chat.records[0]))
        #expect(found.words == "Voice: Hi, what can I do?\n\nYou: Tell me a joke\n\nVoice: Why did the otter cross the river?")
        await talk.resetForTests()
    }

    /// End-to-end TalkController + LiveChatSession wiring: a completed reply whose playback finished folds into
    /// `[folded: ...]`, while a second completed reply interrupted mid-playback by hang-up unhides and stays visible.
    @Test func controllerWiresHeardFoldAndMidSpeechHangupUnhide() async throws {
        let (talk, box) = make()
        let (h, s) = try await openSession()
        let baseline = buildRows(s).filter(\.isBubble).count
        talk.setFront(s, onScreen: true)
        talk.start(in: s, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        let transport = try #require(box.transport)

        // Turn 1: delegated, completed, spoken AND finished speaking (heard!).
        transport.play(#"{"type":"session.input_transcript.delta","delta":"Check tomorrow's forecast","start_ms":0,"end_ms":800}"#)
        transport.play(#"{"type":"session.delegation.created","delegation":{"id":"del_1"}}"#)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 1 })
        await h.emit([
            h.event("message.start"),
            h.event("message.delta", ["text": "Clear skies tomorrow morning."]),
            h.event("message.complete", ["text": "Clear skies tomorrow morning.", "status": "complete"]),
            h.event("session.info", ["running": false]),
        ])
        #expect(await waitUntil { FixtureLiveVoice.sent.contains { $0.contains("Clear skies tomorrow morning.") } })
        transport.onSpeaking?(true)
        transport.play(#"{"type":"session.output_transcript.delta","delta":"Clear skies tomorrow morning.","start_ms":1000,"end_ms":2000}"#)
        transport.onSpeaking?(false)
        #expect(await waitUntil { talk.live?.heardLiveReplyIds.count == 1 })

        // Turn 2: delegated, completed, handed to voice and mid-speech when the user hangs up (NOT heard!).
        transport.play(#"{"type":"session.input_transcript.delta","delta":"List every item on my agenda","start_ms":2500,"end_ms":3500}"#)
        transport.play(#"{"type":"session.delegation.created","delegation":{"id":"del_2"}}"#)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        await h.emit([
            h.event("message.start"),
            h.event("message.delta", ["text": "Item one at nine, item two at eleven, item three at two, item four at four."]),
            h.event("message.complete", ["text": "Item one at nine, item two at eleven, item three at two, item four at four.", "status": "complete"]),
            h.event("session.info", ["running": false]),
        ])
        #expect(await waitUntil { FixtureLiveVoice.sent.contains { $0.contains("Item one at nine") } })
        transport.onSpeaking?(true)
        transport.play(#"{"type":"session.output_transcript.delta","delta":"Item one at nine,","start_ms":4000,"end_ms":4500}"#)

        // Hang up mid-speech!
        talk.end()
        #expect(await waitUntil { !talk.isLive })
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 3 })
        let bubbles = buildRows(s).compactMap { row -> String? in if case .bubble(let b) = row.kind { return b.text } else { return nil } }
        // Turn 1 folded; Turn 2 (prompt + full answer) unhidden and stays visible after the Voice Chat record lands!
        #expect(bubbles.count == baseline + 2)
        #expect(Array(bubbles.suffix(2)) == [
            "List every item on my agenda",
            "Item one at nine, item two at eleven, item three at two, item four at four.",
        ])
        #expect(!bubbles.contains("Clear skies tomorrow morning."))
        let voiceRows = buildRows(s).compactMap { row -> BackgroundResultRow? in if case .backgroundResult(let b) = row.kind, b.voice { return b } else { return nil } }
        #expect(voiceRows.count == 1)
        await talk.resetForTests()
    }

    /// Falling back from live voice to Standard Talk releases any in-flight/unheard delegated turn immediately while
    /// keeping already-heard live turns folded until the conversation ends.
    @Test func fallbackToStandardReleasesUnheardTurnImmediately() async throws {
        let (talk, box) = make()
        let (h, s) = try await openSession()
        let baseline = buildRows(s).filter(\.isBubble).count
        talk.setFront(s, onScreen: true)
        talk.start(in: s, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        let transport = try #require(box.transport)

        // Turn 1: heard.
        transport.play(#"{"type":"session.input_transcript.delta","delta":"Check the gate code","start_ms":0,"end_ms":500}"#)
        transport.play(#"{"type":"session.delegation.created","delegation":{"id":"del_1"}}"#)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 1 })
        await h.emit([
            h.event("message.start"),
            h.event("message.delta", ["text": "The code is four two nine zero."]),
            h.event("message.complete", ["text": "The code is four two nine zero.", "status": "complete"]),
            h.event("session.info", ["running": false]),
        ])
        #expect(await waitUntil { FixtureLiveVoice.sent.contains { $0.contains("four two nine zero") } })
        transport.onSpeaking?(true)
        transport.onSpeaking?(false)
        #expect(await waitUntil { talk.live?.heardLiveReplyIds.count == 1 })

        // Turn 2: still streaming when the live transport drops -> fallback to Standard!
        transport.play(#"{"type":"session.input_transcript.delta","delta":"Summarize the weekly notes","start_ms":1000,"end_ms":1600}"#)
        transport.play(#"{"type":"session.delegation.created","delegation":{"id":"del_2"}}"#)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working through the weekly notes…"])])
        #expect(buildRows(s).filter(\.isBubble).count == baseline)

        transport.onDropped?("network lost")
        #expect(await waitUntil { talk.live?.engine == .standard })
        let duringStandard = buildRows(s).compactMap { row -> String? in if case .bubble(let b) = row.kind { return b.text } else { return nil } }
        // Turn 2 is immediately visible during Standard Talk; Turn 1 remains folded waiting for the record at end.
        #expect(duringStandard.count == baseline + 2)
        #expect(duringStandard.contains("Working through the weekly notes…"))
        #expect(!duringStandard.contains("The code is four two nine zero."))
        await talk.resetForTests()
    }

    /// A conversation in which the person said nothing leaves nothing in the chat.
    @Test func aSilentConversationSendsNothing() async throws {
        let (talk, box) = make()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        let transport = try #require(box.transport)
        transport.play(#"{"type":"session.output_transcript.delta","delta":"Hello, I'm here.","start_ms":0,"end_ms":800}"#)
        #expect(await waitUntil { talk.live?.record.count == 1 })
        talk.end()
        #expect(await waitUntil { !talk.isLive })
        #expect(chat.records.isEmpty)
        await talk.resetForTests()
    }

    /// A chat that went away is sent nothing.
    @Test func aChatThatWentAwayIsSentNothing() async throws {
        let (talk, box) = make()
        let chat = FakeTalkChat()
        talk.setFront(chat, onScreen: true)
        talk.start(in: chat, name: "Ivy")
        #expect(await waitUntil { talk.view?.phase == .listening })
        let transport = try #require(box.transport)
        transport.play(#"{"type":"session.input_transcript.delta","delta":"Remind me about the launch","start_ms":0,"end_ms":900}"#)
        #expect(await waitUntil { talk.live?.record.count == 1 })
        talk.chatGone(chat)
        #expect(await waitUntil { !talk.isLive })
        #expect(chat.records.isEmpty)
        await talk.resetForTests()
    }
}

/// The real chat's side of it (`LiveChatSession.sendVoiceRecord`): build 1073 sent the record as a hidden message, so
/// the bot had the words and the chat drew nothing.
@MainActor @Suite("Voice record in the real chat", .serialized)
struct VoiceChatRecordSendTests {
    private static let record = VoiceChatRecord.message([.init(user: true, text: "Book the dentist for Friday."),
                                                         .init(user: false, text: "Done.")], seconds: 65) ?? ""

    private func open() async throws -> (ChatHarness, LiveChatSession) {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.queueDrainFallback = .milliseconds(30)
        #expect(await h.open())
        h.client.onCall { method, params in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.redirect": return ["status": "redirected", "text": params["text"] ?? ""]
            default: return [:]
            }
        }
        return (h, s)
    }

    private func lines(_ s: LiveChatSession) -> [BackgroundResultRow] {
        ChatRowBuilder.build(.init(messages: s.messages, isRunning: s.isRunning, botName: "Hermes", expanded: [])).compactMap {
            if case .backgroundResult(let b) = $0.kind, b.voice { return b } else { return nil }
        }
    }

    private func buildRows(_ s: LiveChatSession) -> [ChatRow] {
        var input = ChatRowBuilder.Input(messages: s.messages, isRunning: s.isRunning, botName: "Hermes", expanded: [])
        input.voiceFoldedIds = s.voiceFoldedMessageIds
        input.voiceFoldedRowIds = s.voiceFoldedRowIds
        input.answeringVoiceRecord = s.isAnsweringVoiceRecord
        return ChatRowBuilder.build(input)
    }

    /// In an idle chat it goes out at once as an ordinary turn, and the chat draws its line from the message.
    @Test func anIdleChatSendsItAsAnOrdinaryMessageAndShowsTheLine() async throws {
        let (h, s) = try await open()
        s.sendVoiceRecord(Self.record)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 1 })
        let call = try #require(h.client.calls("prompt.submit").first)
        #expect(call.params["text"]?.string == Self.record)
        #expect(call.params["display_kind"] == nil, "a hidden row is never drawn")
        #expect(s.messages.last?.role == .user)
        #expect(lines(s).map(\.title) == ["Voice Chat · 1:05"])
        #expect(s.queuedMessages.isEmpty)
    }

    /// Read back from the gateway's history (another device, or this one later): the line, and nothing for the bot's
    /// silent answer.
    @Test func historyShowsTheLineAndNothingForTheSilentAnswer() async throws {
        let h = try ChatHarness()
        let rows: [JSONValue] = [
            .object(["role": "user", "content": "Hello there", "row_id": 9_000, "timestamp": 1_791_600_000]),
            .object(["role": "assistant", "content": "Hi. What do you need?", "row_id": 9_001, "timestamp": 1_791_600_001]),
            .object(["role": "user", "content": .string(Self.record), "row_id": 9_002, "timestamp": 1_791_600_100]),
            .object(["role": "assistant", "content": "NO_REPLY", "row_id": 9_003, "timestamp": 1_791_600_101]),
        ]
        h.setPage("24", rows: rows, hasMore: false)
        let s = h.make()
        #expect(await h.open())
        let built = ChatRowBuilder.build(.init(messages: TimelineNotes.resolve(s.messages), isRunning: false, botName: "Hermes", expanded: []))
        let voice = built.compactMap { row -> BackgroundResultRow? in
            if case .backgroundResult(let b) = row.kind, b.voice { return b } else { return nil }
        }
        #expect(voice.map(\.title) == ["Voice Chat · 1:05"])
        #expect(voice.first?.result == "You: Book the dentist for Friday.\n\nVoice: Done.")
        let bubbles = built.compactMap { row -> String? in if case .bubble(let b) = row.kind { return b.text } else { return nil } }
        #expect(bubbles == ["Hello there", "Hi. What do you need?"])
        #expect(!built.contains { if case .notice = $0.kind { return true } else { return false } })
    }

    /// While a reply runs it waits its turn: never typed into that reply, whose answer its note would have silenced.
    @Test func aRunningReplyIsNeverSteeredOrStopped() async throws {
        let (h, s) = try await open()
        s.send("first")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working on it"])])
        s.sendVoiceRecord(Self.record)
        #expect(s.queuedMessages.map(\.text) == [Self.record])
        #expect(ChatQueueCard.rowText(s.queuedMessages[0]) == ("Voice Chat · 1:05", true))
        #expect(h.client.calls("session.redirect").isEmpty)
        #expect(h.client.calls("session.interrupt").isEmpty)
        #expect(lines(s).isEmpty)
        // Taken out of the queue, its words never fill the message box.
        #expect(s.removeQueued(s.queuedMessages[0].id) == nil)
        s.sendVoiceRecord(Self.record)
        await h.emit([h.event("message.complete", ["text": "Working on it", "status": "complete"]),
                      h.event("session.info", ["running": false])])
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["text"]?.string == Self.record)
        #expect(lines(s).count == 1)
    }

    /// Owner, 2026-11-18: Stop parked the record as a card, it was deleted, and the bot never had the talk. Stop holds
    /// typed messages only; the record can't be edited or deleted, and goes out once the stopped reply unwinds.
    @Test func stopNeverHoldsAVoiceChatsWords() async throws {
        let (h, s) = try await open()
        s.send("first")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working on it"])])
        s.sendVoiceRecord(Self.record)
        let id = try #require(s.queuedMessages.first?.id)
        #expect(!s.canEditQueued(id))
        s.stop()
        #expect(!s.isQueueParked)
        #expect(s.queuedMessages.map(\.text) == [Self.record])
        await h.emit([h.event("message.complete", ["text": "Working on it", "status": "interrupted"]),
                      h.event("session.info", ["running": false])])
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["text"]?.string == Self.record)
    }

    /// A typed message waiting beside it still pauses on Stop, as before.
    @Test func stopStillHoldsTypedMessagesBesideARecord() async throws {
        let (h, s) = try await open()
        s.send("first")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working on it"])])
        s.sendVoiceRecord(Self.record)
        s.queuesNextSend = true
        s.send("typed")
        #expect(s.queuedMessages.map(\.text) == [Self.record, "typed"])
        s.stop()
        #expect(s.isQueueParked)
    }

    /// During a live voice call, delegated user/assistant bubbles stay folded while LiveTalkLoop still reads the reply;
    /// ending the call embeds `[folded: ...]` turn hashes into the Voice Chat card and clears pending holds on ack.
    @Test func liveDelegatedTurnStaysFoldedDuringAndAfterVoiceCall() async throws {
        let (h, s) = try await open()
        h.client.onCall { method, _ in
            method == "prompt.submit" ? ["status": "streaming", "user_row_id": 701] : [:]
        }
        let baselineBubbles = buildRows(s).filter(\.isBubble).count
        s.setLiveVoiceActive(true)
        s.sendDelegated("Check tomorrow's schedule", voiceContext: "User: Check tomorrow's schedule")
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 1 })
        #expect(buildRows(s).filter(\.isBubble).count == baselineBubbles)
        await h.emit([
            h.event("message.start"),
            h.event("message.delta", ["text": "You have two meetings tomorrow morning."]),
            h.event("message.complete", ["text": "You have two meetings tomorrow morning.", "status": "complete",
                                         "persisted_turn": ["user_row_id": 701, "final_assistant_row_id": 702]]),
            h.event("session.info", ["running": false]),
        ])
        let reply = try #require(s.newestReply)
        #expect(reply.text == "You have two meetings tomorrow morning.")
        s.noteLiveVoiceHeard(messageId: reply.messageId)
        #expect(buildRows(s).filter(\.isBubble).count == baselineBubbles)
        let foldedTags = s.finishLiveVoice(heardReplyIds: [reply.messageId], sendingRecord: true)
        #expect(foldedTags.count == 1)
        let record = try #require(VoiceChatRecord.message([
            .init(user: true, text: "Check tomorrow's schedule"),
            .init(user: false, text: "You have two meetings tomorrow morning."),
        ], seconds: 42, foldedTags: foldedTags, includeExplicitMarker: true))
        s.sendVoiceRecord(record)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(s.voiceFoldedMessageIds.isEmpty, "pending fold hold cleared once record acknowledged")
        let built = buildRows(s)
        #expect(built.filter(\.isBubble).count == baselineBubbles)
        let voice = built.compactMap { row -> BackgroundResultRow? in if case .backgroundResult(let b) = row.kind, b.voice { return b } else { return nil } }
        #expect(voice.map(\.title) == ["Voice Chat · 0:42"])
    }

    /// Hanging up while a delegated reply is still streaming OR finished-but-unheard reveals the full turn immediately.
    @Test func hangingUpBeforeDelegatedReplyIsHeardRevealsItInChat() async throws {
        let (h, s) = try await open()
        h.client.onCall { method, _ in
            method == "prompt.submit" ? ["status": "streaming", "user_row_id": 801] : [:]
        }
        let baselineBubbles = buildRows(s).filter(\.isBubble).count
        s.setLiveVoiceActive(true)
        s.sendDelegated("Draft the weekly summary", voiceContext: "User: Draft the weekly summary")
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 1 })
        await h.emit([
            h.event("message.start"),
            h.event("message.delta", ["text": "Weekly summary complete with four action items."]),
            h.event("message.complete", ["text": "Weekly summary complete with four action items.", "status": "complete"]),
            h.event("session.info", ["running": false]),
        ])
        #expect(buildRows(s).filter(\.isBubble).count == baselineBubbles)
        // Hang up before playback finished (heardReplyIds is empty).
        let foldedTags = s.finishLiveVoice(heardReplyIds: [], sendingRecord: true)
        #expect(foldedTags.isEmpty)
        let bubblesAfterHangup = buildRows(s).compactMap { row -> String? in if case .bubble(let b) = row.kind { return b.text } else { return nil } }
        #expect(bubblesAfterHangup.count == baselineBubbles + 2)
        #expect(bubblesAfterHangup.suffix(2) == ["Draft the weekly summary", "Weekly summary complete with four action items."])
    }

    /// If a finished call's Voice Chat record is refused or removed from the queue, held turns immediately roll back
    /// so no Q&A disappears without a card.
    @Test func refusedAndRemovedVoiceRecordRollsBackFoldedTurns() async throws {
        let (h, s) = try await open()
        nonisolated final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func bump() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
            var current: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let submits = Counter()
        h.client.onCall { method, _ in
            guard method == "prompt.submit" else { return [:] }
            if submits.bump() == 2 {
                throw RPCError(code: 4007, message: "session unavailable", data: nil)
            }
            return ["status": "streaming", "user_row_id": 910]
        }
        let baselineBubbles = buildRows(s).filter(\.isBubble).count
        s.setLiveVoiceActive(true)
        s.sendDelegated("Check parcel delivery", voiceContext: "User: Check parcel delivery")
        #expect(await waitUntil { submits.current == 1 })
        await h.emit([
            h.event("message.start"),
            h.event("message.delta", ["text": "Arriving before five."]),
            h.event("message.complete", ["text": "Arriving before five.", "status": "complete"]),
            h.event("session.info", ["running": false]),
        ])
        let reply = try #require(s.newestReply)
        s.noteLiveVoiceHeard(messageId: reply.messageId)
        let tags = s.finishLiveVoice(heardReplyIds: [reply.messageId], sendingRecord: true)
        #expect(tags.count == 1)
        let record = try #require(VoiceChatRecord.message([
            .init(user: true, text: "Check parcel delivery"),
            .init(user: false, text: "Arriving before five."),
        ], seconds: 25, foldedTags: tags, includeExplicitMarker: true))
        // Record send is refused -> pending fold hold rolls back immediately so both bubbles reappear!
        s.sendVoiceRecord(record)
        #expect(await waitUntil { s.sendFailure != nil })
        let afterRefusal = buildRows(s).compactMap { row -> String? in if case .bubble(let b) = row.kind { return b.text } else { return nil } }
        #expect(afterRefusal.count == baselineBubbles + 2)
        #expect(afterRefusal.suffix(2) == ["Check parcel delivery", "Arriving before five."])
    }

    /// Typed messages and typed steers during a live call stay visible alongside their replies (never half-folded).
    @Test func typedSendAndTypedSteerDuringLiveCallStayVisible() async throws {
        let (h, s) = try await open()
        let baseline = buildRows(s).filter(\.isBubble).count
        s.setLiveVoiceActive(true)
        // 1. Typed message during an idle moment of a live call stays visible with its reply.
        s.send("Typed note during call")
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 1 })
        await h.emit([
            h.event("message.start"),
            h.event("message.delta", ["text": "Reply to typed note."]),
            h.event("message.complete", ["text": "Reply to typed note.", "status": "complete"]),
            h.event("session.info", ["running": false]),
        ])
        let afterTyped = buildRows(s).compactMap { row -> String? in if case .bubble(let b) = row.kind { return b.text } else { return nil } }
        #expect(afterTyped.count == baseline + 2)
        #expect(afterTyped.suffix(2) == ["Typed note during call", "Reply to typed note."])

        // 2. Typed steer into a running live-voice turn immediately unhides the running voice turn so everything stays paired.
        s.sendDelegated("Check train times", voiceContext: "User: Check train times")
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Looking up northbound trains"])])
        #expect(buildRows(s).filter(\.isBubble).count == baseline + 2)
        s.send("Actually check southbound instead")
        #expect(await waitUntil { h.client.calls("session.redirect").count == 1 })
        await h.emit([
            h.event("message.delta", ["text": "Southbound leaves at four fifteen."]),
            h.event("message.complete", ["text": "Southbound leaves at four fifteen.", "status": "complete"]),
            h.event("session.info", ["running": false]),
        ])
        let afterTypedSteer = buildRows(s).compactMap { row -> String? in if case .bubble(let b) = row.kind { return b.text } else { return nil } }
        #expect(afterTypedSteer.contains("Check train times"))
        #expect(afterTypedSteer.contains("Actually check southbound instead"))
        #expect(afterTypedSteer.contains("Southbound leaves at four fifteen."))
    }

    /// Steered voice delegations handle `.redirected`, `.queued` (next foreign turn), and late `.failed` after hang-up.
    @Test func voiceSteerRedirectedQueuedAndPostHangupFailure() async throws {
        // Case A: `.redirected` steer folds atomically with its turn (both live and after reload with joinMarker).
        let (h1, s1) = try await open()
        let base1 = buildRows(s1).filter(\.isBubble).count
        s1.setLiveVoiceActive(true)
        s1.sendDelegated("Check Monday flights", voiceContext: "User: Check Monday flights")
        #expect(await waitUntil { h1.client.calls("prompt.submit").count == 1 })
        await h1.emit([h1.event("message.start")])
        s1.sendDelegated("Make that Tuesday instead", voiceContext: "User: Make that Tuesday instead")
        #expect(await waitUntil { h1.client.calls("session.redirect").count == 1 })
        await h1.emit([
            h1.event("message.delta", ["text": "Tuesday has three morning departures."]),
            h1.event("message.complete", ["text": "Tuesday has three morning departures.", "status": "complete"]),
            h1.event("session.info", ["running": false]),
        ])
        let reply1 = try #require(s1.newestReply)
        s1.noteLiveVoiceHeard(messageId: reply1.messageId)
        let tags1 = s1.finishLiveVoice(heardReplyIds: [reply1.messageId], sendingRecord: true)
        #expect(tags1.count == 1)
        let rec1 = try #require(VoiceChatRecord.message([
            .init(user: true, text: "Check Monday flights. Make that Tuesday instead."),
            .init(user: false, text: "Tuesday has three morning departures."),
        ], seconds: 30, foldedTags: tags1, includeExplicitMarker: true))
        s1.sendVoiceRecord(rec1)
        #expect(await waitUntil { h1.client.calls("prompt.submit").count == 2 })
        #expect(buildRows(s1).filter(\.isBubble).count == base1)
        // Reloaded transcript with `[Additional user correction]` merged row folds cleanly too!
        let mergedPrompt = "Check Monday flights\n\n\(InflightCorrections.joinMarker)\nMake that Tuesday instead"
        let reloaded: [ChatMessage] = [
            ChatMessage(id: "rm-u", role: .user, parts: [.text(mergedPrompt)], timestamp: Date(), rowId: 10),
            ChatMessage(id: "rm-a", role: .assistant, parts: [.text("Tuesday has three morning departures.")], timestamp: Date(), rowId: 11),
            ChatMessage(id: "rm-r", role: .user, parts: [.text(rec1)], timestamp: Date(), rowId: 12),
        ]
        #expect(VoiceChatRecord.foldedIndices(in: reloaded) == [0, 1])

        // Case B: `.queued` (`.nextTurn`) steer pairs with the upcoming foreign-started turn.
        let (h2, s2) = try await open()
        h2.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.redirect": return ["status": "queued"]
            default: return [:]
            }
        }
        let base2 = buildRows(s2).filter(\.isBubble).count
        s2.setLiveVoiceActive(true)
        s2.sendDelegated("First request", voiceContext: "User: First request")
        #expect(await waitUntil { h2.client.calls("prompt.submit").count == 1 })
        await h2.emit([h2.event("message.start")])
        s2.sendDelegated("Queued follow-up", voiceContext: "User: Queued follow-up")
        #expect(await waitUntil { h2.client.calls("session.redirect").count == 1 })
        // First turn finishes, then queued follow-up runs as a foreign-started turn.
        await h2.emit([
            h2.event("message.delta", ["text": "First answer."]),
            h2.event("message.complete", ["text": "First answer.", "status": "complete"]),
            h2.event("session.info", ["running": false]),
        ])
        await h2.emit([
            h2.event("message.start"),
            h2.event("message.delta", ["text": "Follow-up answer."]),
            h2.event("message.complete", ["text": "Follow-up answer.", "status": "complete"]),
            h2.event("session.info", ["running": false]),
        ])
        // Both turns stayed hidden during the call (queued steer's reply paired with its prompt!).
        #expect(buildRows(s2).filter(\.isBubble).count == base2)

        // Case C: late `.failed` voice steer after hang-up never hides its fallback send.
        let (h3, s3) = try await open()
        nonisolated final class SteerGate: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<JSONValue, any Error>?
            func store(_ c: CheckedContinuation<JSONValue, any Error>) { lock.lock(); continuation = c; lock.unlock() }
            var waiting: Bool { lock.lock(); defer { lock.unlock() }; return continuation != nil }
            func fail(_ error: any Error) {
                lock.lock(); let c = continuation; continuation = nil; lock.unlock()
                c?.resume(throwing: error)
            }
        }
        let gate = SteerGate()
        h3.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.redirect":
                return try await withCheckedThrowingContinuation { gate.store($0) }
            default: return [:]
            }
        }
        s3.setLiveVoiceActive(true)
        s3.sendDelegated("Initial ask", voiceContext: "User: Initial ask")
        #expect(await waitUntil { h3.client.calls("prompt.submit").count == 1 })
        await h3.emit([h3.event("message.start")])
        s3.sendDelegated("Late steer", voiceContext: "User: Late steer")
        #expect(await waitUntil { gate.waiting })
        // Call ends BEFORE `session.redirect` answers!
        _ = s3.finishLiveVoice(heardReplyIds: [], sendingRecord: false)
        gate.fail(RPCError(code: 4010, message: "unsupported", data: nil))
        #expect(await waitUntil { h3.client.calls("session.interrupt").count == 1 })
        await h3.emit([
            h3.event("message.complete", ["text": "", "status": "interrupted"]),
            h3.event("session.info", ["running": false]),
        ])
        #expect(await waitUntil { h3.client.calls("prompt.submit").count == 2 })
        #expect(s3.voiceFoldedMessageIds.isEmpty, "post-hangup fallback send must never leak into hidden ids")
    }

    /// Incremental `ChatRowModel.rebuildNewest` widens back via `VoiceChatRecord.reach` so arriving records fold
    /// previously built bubbles identically to a full `ChatRowBuilder.build`.
    @Test func rowModelIncrementalRebuildFoldsEarlierBubblesWhenRecordArrives() throws {
        let base = Date(timeIntervalSince1970: 1_791_600_000)
        let u1 = ChatMessage(id: "u1", role: .user, parts: [.text("What is the weather in Riverton?")], timestamp: base.addingTimeInterval(10), rowId: 3)
        let a1 = ChatMessage(id: "a1", role: .assistant, parts: [.text("Sunny and 68 degrees in Riverton.")], timestamp: base.addingTimeInterval(20), rowId: 4)
        var messages: [ChatMessage] = [
            ChatMessage(id: "u0", role: .user, parts: [.text("Earlier typed note")], timestamp: base.addingTimeInterval(-300), rowId: 1),
            ChatMessage(id: "a0", role: .assistant, parts: [.text("Got it.")], timestamp: base.addingTimeInterval(-290), rowId: 2),
            u1,
            a1,
        ]
        var model = ChatRowModel()
        model.rebuildAll(.init(messages: messages, isRunning: false, botName: "Ivy", expanded: []), syncMessages: 20, oldestShown: nil)
        model.reveal(40)
        #expect(model.allRows.filter(\.isBubble).count == 4)
        let tag = try #require(VoiceChatRecord.turnFoldTag(users: [u1], assistants: [a1]))
        let rec = try #require(VoiceChatRecord.message([
            .init(user: true, text: "What is the weather in Riverton?"),
            .init(user: false, text: "Sunny and 68 degrees in Riverton."),
        ], seconds: 30, foldedTags: [tag], includeExplicitMarker: true))
        messages.append(ChatMessage(id: "vr", role: .user, parts: [.text(rec)], timestamp: base.addingTimeInterval(30), rowId: 5))
        let input = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Ivy", expanded: [])
        model.rebuildNewest(input, fromMessage: messages.count - 1)
        let full = Array(ChatRowBuilder.build(input).reversed())
        #expect(model.allRows.map(\.id) == full.map(\.id))
        #expect(model.allRows.filter(\.isBubble).count == 2)
    }
}

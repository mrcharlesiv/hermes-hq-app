import Foundation
import UIKit
import Testing
@testable import HermesHQNative

// Chat text audit of build 863 (group "chat text"): links in sentences, hidden thinking, Find, lists, VoiceOver,
// Try Again on stopped turns, long and right-to-left text, day separators.

@Suite("Chat text audit 863")
struct ChatTextAuditTests {
    private let style = ChatStyleCache.shared.style(for: .large)

    private func input(_ messages: [ChatMessage], running: Bool = false) -> ChatRowBuilder.Input {
        ChatRowBuilder.Input(messages: messages, isRunning: running, botName: "Ivy", expanded: [], scope: "test|ivy|s1")
    }

    private func prose(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for case .text(let s) in MarkdownRenderer.render(markdown, style: style).blocks { out.append(s) }
        return out
    }

    /// Each link in the text and the words it covers.
    private func links(_ text: NSAttributedString) -> [(words: String, url: String)] {
        var out: [(String, String)] = []
        text.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let url = value as? URL { out.append(((text.string as NSString).substring(with: range), url.absoluteString)) }
        }
        return out
    }

    // MARK: 01-1, 01-2 Web addresses in a sentence

    @Test func aClosingBracketTheAddressDidNotOpenIsTheSentences() {
        let text = prose("Details (see https://site.com/page) and [https://site.com/b].")
        #expect(links(text).map(\.url) == ["https://site.com/page", "https://site.com/b"])
        #expect(text.string.contains("page) and"))
        // Brackets the address opened stay in it.
        #expect(links(prose("Read https://en.wikipedia.org/wiki/Foo_(bar) now")).map(\.url) == ["https://en.wikipedia.org/wiki/Foo_(bar)"])
        #expect(links(prose("Read (https://x.com/a.)")).map(\.url) == ["https://x.com/a"])
    }

    @Test func fullWidthPunctuationEndsAnAddress() {
        #expect(links(prose("请看https://example.com/path。下一句")).map(\.url) == ["https://example.com/path"])
        #expect(links(prose("见 https://example.com/a，然后")).map(\.url) == ["https://example.com/a"])
        #expect(links(prose("（https://example.com/b）")).map(\.url) == ["https://example.com/b"])
    }

    @Test func markupCharactersInsideAnAddressStayInIt() {
        let text = prose("Open https://x.com/a/_draft_/b and https://x.com/~~old~~/c today")
        #expect(links(text).map(\.url) == ["https://x.com/a/_draft_/b", "https://x.com/~~old~~/c"])
        #expect(text.string.contains("https://x.com/a/_draft_/b and"))
        #expect(!text.string.contains("\\"))
        // Code keeps what was written: no escapes in a code span or a fence.
        let code = MarkdownRenderer.render("Run `curl https://x.com/_a_` then\n\n```\nhttps://x.com/_b_\n```", style: style)
        let written = code.blocks.map { block -> String in
            switch block {
            case .text(let s): return s.string
            case .code(_, let c, _, _): return c
            default: return ""
            }
        }.joined(separator: "\n")
        #expect(written.contains("https://x.com/_a_") && written.contains("https://x.com/_b_") && !written.contains("\\_"))
        // Emphasis outside an address still works.
        let styled = prose("_soon_ see https://x.com/_a_")
        let font = styled.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
    }

    // MARK: 01-5 .. 01-8 Hidden thinking

    @Test func thinkingTagsInCodeAreLeftAsWritten() {
        let reply = "Here is the parser:\n\n```xml\n<think>plan</think>\n<analysis>\n```\n\nDone."
        #expect(ReasoningTags.strip(reply) == reply)
        #expect(ReasoningTags.strip("Use `<think>` and `</think>` tags.") == "Use `<think>` and `</think>` tags.")
        // In prose they still go.
        #expect(ReasoningTags.strip("<think>plan it</think>\nThe answer is 4.") == "The answer is 4.")
        #expect(ReasoningTags.strip("The answer is <thought>hmm</thought>4.") == "The answer is 4.")
    }

    @Test func anUnclosedTagHidesTheRestOnlyWhereThinkingIsStillArriving() {
        // A settled reply: a later line that starts with a tag no longer wipes out what follows it.
        let settled = "Summary first.\n<analysis>\nThe numbers below matter.\n\nTotal: 12"
        #expect(ReasoningTags.strip(settled) == settled)
        // A thinking preamble whose close never came still hides.
        #expect(ReasoningTags.strip("<think>\nstill working it out").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // While streaming, the web's rule: an opening tag on its own line hides what is arriving after it.
        #expect(ReasoningTags.strip("Answer:\n<think>\nmore to come", streaming: true) == "Answer:\n")
    }

    @Test func copyShareAndVoiceOverLeaveTheThinkingOut() {
        let reply = ChatMessage(id: "a1", role: .assistant, parts: [.text("<think>secret plan</think>\nThe answer is 4.")],
                                timestamp: Date(), rowId: 2)
        #expect(ChatMenus.copyText(reply) == "The answer is 4.")
        let rendered = MarkdownRenderer.render("<think>secret plan</think>\nThe answer is 4.", style: style)
        #expect(rendered.plainText == "The answer is 4.")
        let transcript = ChatTranscript.text(title: nil, botName: "Ivy", messages: [reply])
        #expect(!transcript.contains("secret"))
        // The plain-text fallback for a huge reply hides it too.
        let huge = "<think>secret</think>\n" + String(repeating: "word ", count: 41_000)
        let big = MarkdownRenderer.render(huge, style: style)
        guard case .text(let s)? = big.blocks.first else { Issue.record("expected plain text"); return }
        #expect(!s.string.contains("secret") && !big.plainText.contains("secret"))
    }

    @Test func aPartThatIsOnlyThinkingDrawsNoBubble() {
        let user = ChatMessage(id: "u1", role: .user, parts: [.text("hi")], timestamp: Date(), rowId: 1)
        let reply = ChatMessage(id: "a1", role: .assistant, parts: [.text("<think>mulling</think>")], timestamp: Date(), rowId: 2)
        let rows = ChatRowBuilder.build(input([user, reply]))
        #expect(!rows.contains { $0.messageId == "a1" && { if case .bubble = $0.kind { true } else { false } }($0) })
        #expect(ReasoningTags.isBlank("  <thinking>a\nb</thinking>\n"))
        #expect(!ReasoningTags.isBlank("<think>a</think> Hello"))
    }

    // MARK: 01-3, 01-4 Find

    @Test func findSearchesTheWordsAsDrawn() {
        let text = ChatFind.drawnText("<think>needle</think>See [the guide](https://needle.example.com).\nMEDIA:/tmp/needle.png\nneedle")
        #expect(ChatFind.ranges(of: "needle", in: text).count == 1)
        #expect(text.contains("See the guide."))
    }

    @Test func aMatchInALaterJoinedPartGoesToTheBubbleThatDrawsIt() {
        let units = [
            ChatFindUnit(rowId: "a1|b0", messageId: "a1", text: "apple pie"),
            ChatFindUnit(rowId: "a1|b2", messageId: "a1", text: "apple and apple"),
            ChatFindUnit(rowId: "a1|b4", messageId: "a1", text: "one apple"),
        ]
        // Parts 0 and 2 are one bubble ("a1|b0"); part 4 has its own.
        let second = ChatFindMatch(rowId: "a1|b2", messageId: "a1", occurrence: 1)
        let place = ChatFind.drawnPlace(of: second, bubbleParts: [0, 4], units: units, query: "apple")
        #expect(place.rowId == "a1|b0" && place.occurrence == 2)
        let own = ChatFind.drawnPlace(of: ChatFindMatch(rowId: "a1|b4", messageId: "a1", occurrence: 0), bubbleParts: [0, 4],
                                      units: units, query: "apple")
        #expect(own.rowId == "a1|b4" && own.occurrence == 0)
        // Rows not built yet: the match keeps its own place.
        let unbuilt = ChatFind.drawnPlace(of: second, bubbleParts: nil, units: units, query: "apple")
        #expect(unbuilt.rowId == "a1|b2" && unbuilt.occurrence == 1)
    }

    // MARK: 01-9 Lists

    @Test func aWideNumberWidensItsListSoTheLinesLineUp() {
        let list = (100...102).map { "\($0). item number \($0) with words" }.joined(separator: "\n")
        let text = prose(list)
        guard let para = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else {
            Issue.record("no paragraph style"); return
        }
        let marker = ceil(("100." as NSString).size(withAttributes: [.font: style.body]).width)
        #expect(para.headIndent > marker)
        #expect(para.tabStops.first?.location == para.headIndent)
        // At the largest text size the indent grows with the text.
        let big = ChatStyle.make(category: .accessibilityExtraExtraExtraLarge)
        #expect(big.listIndent > 30)
    }

    @Test func aCodeBlockInAListItemSitsUnderTheItemsText() {
        let rendered = MarkdownRenderer.render("1. Install:\n\n   ```sh\n   pip install x\n   ```\n2. Run it", style: style)
        guard let index = rendered.blocks.firstIndex(where: { if case .code = $0 { true } else { false } }) else {
            Issue.record("no code block"); return
        }
        #expect((rendered.indents[index] ?? 0) >= style.listIndent)
        let row = ChatRow(id: "list|b0", messageId: "list", scope: "audit863", fingerprint: 863_1,
                          kind: .bubble(BubbleRow(mine: false, text: "1. Install:\n\n   ```sh\n   pip install x\n   ```\n2. Run it",
                                                  markdown: true, partIndex: 0, joinsAbove: false, joinsBelow: false, tail: true,
                                                  time: nil, pending: false, streaming: false)),
                          gapAbove: 6, variant: 0)
        guard case .bubble(let b) = TextLayout.make(row, width: 402, style: style).content,
              let card = b.blocks.first(where: { if case .code = $0.block { true } else { false } }),
              let words = b.blocks.first(where: { if case .text = $0.block { true } else { false } }) else {
            Issue.record("no card"); return
        }
        #expect(card.frame.minX >= words.frame.minX + style.listIndent - 0.5)
    }

    @Test func aTablesTitleLosesItsListNumber() {
        #expect(TableData.caption(before: "3.\tSales by region:") == "Sales by region")
        #expect(TableData.caption(before: "12) Costs:") == "Costs")
        #expect(TableData.caption(before: "▪\u{FE0E}\tNested:") == "Nested")
    }

    @Test func codeLanguagesAreNamedProperly() {
        #expect(MarkdownRenderer.codeLanguageLabel("hcl") == "HCL")
        #expect(MarkdownRenderer.codeLanguageLabel("csv") == "CSV")
        #expect(MarkdownRenderer.codeLanguageLabel("objective-c") == "Objective-C")
        #expect(MarkdownRenderer.codeLanguageLabel("scss") == "SCSS")
        #expect(MarkdownRenderer.codeLanguageLabel("python") == "Python")
        #expect(MarkdownRenderer.codeLanguageLabel("text") == nil)
    }

    // MARK: 01-10 Error card at large text

    @Test func errorButtonsGrowWithTheirWords() {
        let big = ChatStyle.make(category: .accessibilityExtraExtraExtraLarge)
        let error = ChatRow(id: "err|err", messageId: "err", scope: "audit863", fingerprint: 863_3,
                            kind: .error(ErrorRow(title: "Ivy couldn’t finish this reply", reason: "Overloaded", details: "x",
                                                  retry: true, chooseModel: false)), gapAbove: 8, variant: 0)
        guard case .error(let e) = TextLayout.make(error, width: 402, style: big).content, let retry = e.retryFrame else {
            Issue.record("no card"); return
        }
        #expect(retry.height >= ceil(big.errorBody.lineHeight) + 20)
        #expect(e.detailsFrame.minY >= retry.maxY)
        guard case .error(let small) = TextLayout.make(error, width: 402, style: style).content else { return }
        #expect(small.detailsFrame.height == 44)
    }

    @Test func theAppsOwnFallbackIsNotShownUnderTheBotsName() {
        let reason = ChatRowBuilder.errorReason("Hermes couldn't finish this turn.", retry: false, bot: "Luna")
        #expect(!reason.contains("Hermes") && reason.contains("Luna"))
    }

    // MARK: 01-13 .. 01-15 VoiceOver

    @Test func voiceOverSummarizesCodeAndTables() {
        let code = "```python\n" + (1...40).map { "x\($0) = \($0)" }.joined(separator: "\n") + "\n```"
        let said = SpokenMarkdown.plain("Try this:\n\n" + code + "\n\nThen:\n\n| Name | Score |\n|---|---|\n| A | 1 |\n| B | 2 |")
        #expect(said.contains("Code, Python, 40 lines: x1 = 1"))
        #expect(!said.contains("x40 = 40"))
        #expect(said.contains("Table, 2 rows, 2 columns. Name, Score"))
        #expect(!said.contains("B, 2"))
        #expect(SpokenMarkdown.plain("```\nls\n```").hasPrefix("Code, 1 line: ls"))
    }

    @Test func voiceOverNamesTheDayBeforeToday() {
        let now = Date()
        #expect(ChatBubbleCell.spokenWhen(now) == ChatRowBuilder.clock(now))
        let yesterday = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: now)!
        #expect(ChatBubbleCell.spokenWhen(yesterday).hasPrefix("Yesterday "))
    }

    // MARK: 01-16 Try Again on a stopped turn

    @Test func onlyTheNewestStoppedTurnOffersTryAgain() {
        let first = ChatMessage(id: "u1", role: .user, parts: [.text("first job")], timestamp: Date(), rowId: 1)
        var stopped1 = ChatMessage(id: "s1", role: .assistant, parts: [], timestamp: Date(), rowId: nil)
        stopped1.interrupted = true
        let second = ChatMessage(id: "u2", role: .user, parts: [.text("second job")], timestamp: Date(), rowId: 3)
        var stopped2 = ChatMessage(id: "s2", role: .assistant, parts: [], timestamp: Date(), rowId: nil)
        stopped2.interrupted = true
        let messages = [first, stopped1, second, stopped2]
        func retry(_ id: String, _ rows: [ChatRow]) -> Bool? {
            for row in rows where row.messageId == id { if case .stoppedEarly(_, let r) = row.kind { return r } }
            return nil
        }
        let rows = ChatRowBuilder.build(input(messages))
        #expect(retry("s1", rows) == false)
        #expect(retry("s2", rows) == true)
        #expect(ChatRowBuilder.retryPrompt(forStoppedAt: 3, input: input(messages)) == "second job")
        #expect(ChatRowBuilder.retryPrompt(forStoppedAt: 1, input: input(messages)) == nil)
        // Not while a reply runs.
        #expect(ChatRowBuilder.retryPrompt(forStoppedAt: 3, input: input(messages, running: true)) == nil)
        // A prompt with a picture can't be sent again whole: no Try Again rather than one that drops it.
        var withPhoto = input(messages)
        withPhoto.media = ChatMediaSnapshot(attachments: ["u2": [MessageAttachment(kind: .image, source: .gateway(path: "/tmp/a.png"), name: "a.png")]])
        #expect(ChatRowBuilder.retryPrompt(forStoppedAt: 3, input: withPhoto) == nil)
        // The row without Try Again is the line alone.
        guard let row = rows.first(where: { $0.messageId == "s1" }), case .line(let l) = TextLayout.make(row, width: 402, style: style).content else {
            Issue.record("no line"); return
        }
        #expect(l.retryFrame == nil)
    }

    // MARK: 01-17 Your long message, however it's made

    @Test func aLongMessageWithAQuoteClampsToo() {
        let text = "> Ivy said this earlier\n\n" + (1...30).map { "Line \($0) of my answer" }.joined(separator: "\n")
        let row = ChatRow(id: "clamp|b0", messageId: "clamp", scope: "audit863", fingerprint: ChatRowBuilder.bubbleFingerprint(text, mine: true, speaker: nil),
                          kind: .bubble(BubbleRow(mine: true, text: text, markdown: true, partIndex: 0, joinsAbove: false, joinsBelow: false,
                                                  tail: true, time: nil, pending: false, streaming: false)),
                          gapAbove: 6, variant: 0)
        let layout = TextLayout.make(row, width: 402, style: style)
        guard case .bubble(let b) = layout.content else { Issue.record("not a bubble"); return }
        #expect(b.blocks.count > 1)
        #expect(b.showMoreFrame != nil)
        let limit = style.bodyLineHeight * CGFloat(ChatMetrics.userClampLines) + 2
        #expect(b.blocks.allSatisfy { $0.frame.maxY <= limit + ChatMetrics.bubblePadV + 0.5 })
        // A message that is all quote clamps as well.
        let quoted = (1...30).map { "> Line \($0)" }.joined(separator: "\n")
        let q = ChatRow(id: "clampq|b0", messageId: "clampq", scope: "audit863", fingerprint: 863_4,
                        kind: .bubble(BubbleRow(mine: true, text: quoted, markdown: true, partIndex: 0, joinsAbove: false, joinsBelow: false,
                                                tail: true, time: nil, pending: false, streaming: false)),
                        gapAbove: 6, variant: 0)
        guard case .bubble(let qb) = TextLayout.make(q, width: 402, style: style).content else { return }
        #expect(qb.showMoreFrame != nil)
    }

    // MARK: 01-18 Very long paragraphs

    @Test func aHardCutNeverSplitsAnEmoji() {
        let flags = String(repeating: "🇯🇵", count: 1_200)   // no spaces, 4 UTF-16 units each
        let text = NSAttributedString(string: flags, attributes: [.font: style.body])
        let parts = TextSplit.split(text, maxLength: 2_001)
        #expect(parts.count > 1)
        for part in parts { #expect(part.text.string.count * 4 == part.text.length, "a flag was cut in two") }
        // A long paragraph breaks between sentences when it can.
        let sentences = String(repeating: "This sentence has a few words in it. ", count: 80)
        let cut = TextSplit.split(NSAttributedString(string: sentences, attributes: [.font: style.body]), maxLength: 2_000)
        #expect(cut.count > 1 && cut[0].text.string.hasSuffix("."))
    }

    // MARK: 01-19 Right to left

    @Test func aShortRightToLeftReplyGetsABubbleAsWideAsItsWords() {
        let text = "مرحبا بك"
        let row = ChatRow(id: "rtl|b0", messageId: "rtl", scope: "audit863", fingerprint: 863_2,
                          kind: .bubble(BubbleRow(mine: false, text: text, markdown: true, partIndex: 0, joinsAbove: false, joinsBelow: false,
                                                  tail: true, time: nil, pending: false, streaming: false)),
                          gapAbove: 6, variant: 0)
        guard case .bubble(let b) = TextLayout.make(row, width: 402, style: style).content else { Issue.record("not a bubble"); return }
        #expect(b.frame.width < TextLayout.replyWidth(402) / 2)
        // Laid out right to left (as on a phone set to Arabic), its lines start at the right edge: the pieces hug them.
        let para = NSMutableParagraphStyle()
        para.baseWritingDirection = .rightToLeft
        let rtl = NSAttributedString(string: text, attributes: [.font: style.body, .paragraphStyle: para])
        let laid = TextLayout.pieces(rtl, width: 340, keep: false)
        #expect(laid.shift > 200 && laid.width < 120)
        #expect(abs((laid.pieces[0].frame.minX + TextKitLayout(rtl, width: 340).inkMinX)) < 1)
        // Inline code reads left to right inside it.
        let code = prose("قل `npm run build` الآن")
        let range = (code.string as NSString).range(of: "npm run build")
        let direction = code.attribute(.writingDirection, at: range.location, effectiveRange: nil) as? [NSNumber]
        #expect(direction?.first?.intValue == NSWritingDirection.leftToRight.rawValue)
    }

    // MARK: 01-22 Day separators

    @Test func theNightTheClocksChangeKeepsMessagesOnTheirDay() throws {
        let york = try #require(TimeZone(identifier: "America/New_York"))
        // 2026-03-08: clocks go forward at 07:00 UTC. 04:30 UTC is still 23:30 on Mar 7 in New York.
        let late = Date(timeIntervalSince1970: 1_772_944_200)      // 2026-03-08 04:30 UTC
        let evening = Date(timeIntervalSince1970: 1_772_917_200)   // 2026-03-07 21:00 UTC (16:00 EST)
        let afternoon = Date(timeIntervalSince1970: 1_772_992_800) // 2026-03-08 18:00 UTC (14:00 EDT)
        #expect(LocalDay.number(late, zone: york) == LocalDay.number(evening, zone: york))
        #expect(LocalDay.number(afternoon, zone: york) == LocalDay.number(late, zone: york) + 1)
        LocalDay.reset()
    }

    // MARK: 01-21 Error words

    @Test func onlyABusyProviderIsCalledOverloaded() {
        #expect(TurnErrors.copy("Overloaded")?.title == "This model’s provider is overloaded")
        #expect(TurnErrors.copy("Error code: 500 - internal server error")?.title == "This model’s provider had a problem")
    }
}

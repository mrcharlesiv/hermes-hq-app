import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// [updates] Row-level groups (docs/briefs/chat-extras-v2.md): the small rows between the real ones fold into one
/// centred line, wherever they come from (a reply's work line, another bot's message, a note), and open as a card.
@MainActor
struct UpdateGroupRowsTests {
    private static let roster = [
        DeliveryMessages.Seat(profile: "default", name: "Hermes", head: ["v": 6, "theme": "shape", "color": "butter", "form": "round"]),
        DeliveryMessages.Seat(profile: "inbox", name: "Inbox", head: FakeChatSession.inboxHead),
    ]

    /// The chat as the screen sees it: deliveries, Hermes's replies and notes resolved, the default tool style.
    private func input(_ raw: [ChatMessage], expanded: Set<String> = [], style: ToolCallStyle = .bottom,
                       running: Bool = false) -> ChatRowBuilder.Input {
        var messages = DeliveryMessages.resolve(raw, roster: Self.roster).messages
        messages = BotDMs.resolve(messages, roster: Self.roster).messages
        messages = TimelineNotes.resolve(messages)
        var input = ChatRowBuilder.Input(messages: messages, isRunning: running, botName: "Inbox", expanded: expanded, scope: "t")
        input.bots = Self.roster
        input.activity.style = style
        return input
    }

    private var talk: [ChatMessage] { FakeChatSession.botTalkThread(now: Date(timeIntervalSince1970: 1_790_000_000)) }

    private func lines(_ rows: [ChatRow]) -> [(id: String, row: BackgroundResultRow)] {
        rows.compactMap { if case .backgroundResult(let b) = $0.kind { return ($0.id, b) } else { return nil } }
    }

    private func members(_ rows: [ChatRow]) -> [(id: String, row: UpdateMemberRow, message: String)] {
        rows.compactMap { if case .updateMember(let m) = $0.kind { return ($0.id, m, $0.messageId) } else { return nil } }
    }

    private func shape(_ rows: [ChatRow]) -> [String] {
        rows.filter { !$0.id.hasSuffix("|day") }.map { row in
            switch row.kind {
            case .bubble: return "bubble"
            case .backgroundResult(let b): return "line \(b.group?.count ?? 0)"
            case .toolRun(let t) where t.line != nil: return "work"
            case .updateMember: return "member"
            default: return "\(row.kind)".components(separatedBy: "(")[0]
            }
        }
    }

    /// The owner's screenshots (2026-10-28, Inbox's chat): never two small rows stacked. [exchange] Since 2026-10-29
    /// Inbox's update between Hermes's messages folds in with them (it talked with Hermes after your message, and wrote
    /// again after): "With Hermes · 6 messages", Inbox's last words, then "From Hermes · 2 messages".
    @Test func screenshotSequenceFolds() throws {
        let rows = ChatRowBuilder.build(input(talk))
        let found = lines(rows).filter { $0.row.group != nil }
        #expect(found.map(\.id) == ["bt-d1|grp", "bt-r2|grp"])
        #expect(found.map(\.row.group?.count) == [8, 2])
        #expect(found.map(\.row.title) == ["With Hermes", "From Hermes"])
        // The talk counts its messages (Inbox's words, Hermes's three, Inbox's two to it); the last two are both from
        // Hermes: "From Hermes · 2 messages", not "· 1 more" (review 2026-10-28).
        #expect(found.map(\.row.group?.tail) == ["6 messages", "2 messages"])
        // The work line keeps the One Line row's own words ("Worked for 8s"); the bot DMs say who they went to.
        let titles = found[0].row.group?.titles ?? []
        #expect(titles.count == 8 && titles[0] == "From Hermes" && titles[2...] == ["To Hermes", "To Hermes", "Inbox", "From Hermes",
                                                                                     "Helper finished", "To Hermes"])
        // Hermes's face leads every line, once however many of its rows the run has; the helper's glyph and the work
        // line's follow. Inbox's own face isn't a mark.
        for line in found { #expect(line.row.group?.marks.first.map { if case .face(let f) = $0 { f.name == "Hermes" } else { false } } == true) }
        #expect(found.map { $0.row.group?.marks.count } == [3, 1])
        let order = shape(rows)
        #expect(order == ["bubble", "bubble", "line 8", "bubble", "line 2"])
        #expect(!rows.contains { if case .toolRun(let t) = $0.kind { t.line != nil } else { false } }, "the work lines are in the groups")
        #expect(!shape(rows).contains("notice"))
    }

    /// At the largest text sizes a group line keeps its count: it shows fewer marks first, then " · +3", in both looks
    /// (review 2026-10-28: the iOS look at XL read "From Hermes" alone, as if one message).
    @Test func countSurvivesLargeText() throws {
        let rows = ChatRowBuilder.build(input(talk))
        for desktop in [false, true] {
            var state = ThemeTable.current.state
            state.desktopLook = desktop
            state.highContrast = false
            try ThemeTable.$testSet.withValue(ThemeResolver.resolve(state)) {
                for category in [UIContentSizeCategory.large, .accessibilityExtraLarge] {
                    let style = ChatStyle.make(category: category)
                    for row in rows {
                        guard case .backgroundResult(let b) = row.kind, let group = b.group, group.count > 1,
                              case .tool(let t) = TextLayout.layout(row, width: 402, style: style).content else { continue }
                        let fit = ChatToolCell.fitGroup(group, title: t.title, width: t.rowFrame.width, style: style)
                        let words = fit.text.string
                        #expect(words.hasPrefix(t.title), "\(row.id): the words are never cut")
                        #expect(words.hasSuffix(" · " + (group.tail ?? "")) || words.hasSuffix(" · +\(group.count - 1)"),
                                "\(row.id) at \(category.rawValue), desktop \(desktop): \(words)")
                        #expect(ceil(fit.text.size().width) <= fit.room)
                        #expect(!fit.shown.isEmpty)
                        // Normal text keeps every mark and the whole count.
                        if category == .large { #expect(fit.shown.count == min(3, group.marks.count) && words.hasSuffix(group.tail ?? "")) }
                    }
                }
            }
        }
    }

    /// Opened: a card row per member, in the chat's order, each owned by its own message; the last bubble stays.
    @Test func openedMembersKeepTheirOrderAndMessages() throws {
        let closed = ChatRowBuilder.build(input(talk))
        let line = try #require(lines(closed).first { ($0.row.group?.count ?? 0) == 8 })
        let rows = ChatRowBuilder.build(input(talk, expanded: [line.id]))
        let found = members(rows)
        #expect(found.map(\.message) == ["bt-d1", "bt-a2", "bt-a2", "bt-a2", "bt-a2", "bt-r1", "bt-n1", "bt-a3"])
        #expect(found.map(\.id) == ["bt-d1|dl|in", "bt-a2|line|in", "bt-a2|dm3|in", "bt-a2|dm5|in", "bt-a2|b6|in", "bt-r1|dl|in",
                                    "bt-n1|bg|in", "bt-a3|dm0|in"])
        #expect(found.map(\.row.first) == [true] + Array(repeating: false, count: 7))
        #expect(found.map(\.row.last) == Array(repeating: false, count: 7) + [true])
        #expect(found.map(\.row.title)[4...] == ["Inbox", "From Hermes", "Helper finished", "To Hermes"])
        #expect(found[5].row.preview.hasPrefix("Inbox found something worth attention"))
        #expect(found[4].row.preview.hasPrefix("The fresh iCloud check found a new operational warning"))
        // The bubble after the run is still there, right after the last member.
        let last = try #require(rows.firstIndex { $0.id == "bt-a3|dm0|in" })
        #expect(rows[last + 1].messageId == "bt-a3")
        if case .bubble = rows[last + 1].kind {} else { Issue.record("expected the reply's bubble after the card") }
        #expect(shape(rows).filter { $0 == "bubble" }.count == shape(closed).filter { $0 == "bubble" }.count)

        // A member opens on its whole formatted text.
        let opened = ChatRowBuilder.build(input(talk, expanded: [line.id, "bt-n1|bg|in"]))
        let helper = try #require(members(opened).first { $0.id == "bt-n1|bg|in" })
        #expect(helper.row.expanded && helper.row.full.contains("Gmail overview"))
        let layout = TextLayout.layout(try #require(opened.first { $0.id == "bt-n1|bg|in" }), width: 390,
                                       style: ChatStyle.make(category: .large))
        guard case .member(let m) = layout.content else { Issue.record("expected a member layout"); return }
        #expect(m.full != nil && m.card.width <= 390)

        // The reply's work line, a member of the first run, opens on its steps.
        let first = ChatRowBuilder.build(input(talk, expanded: ["bt-d1|grp"]))
        let work = try #require(members(first).first { $0.id == "bt-a2|line|in" })
        #expect(work.row.steps.count > 1 && work.row.opens)
        // Its title is its time alone; what it did and its helpers are the preview (review 2026-10-28: "Worked for 8s ·
        // 3 steps · 1 helper" pushed its time under it and disagreed with the four steps listed).
        #expect(work.row.title.hasPrefix("Worked ") && !work.row.title.contains(" · "))
        #expect(work.row.preview == UpdateGroups.counted(ChatRunSummary.summarize(work.row.steps, live: false) + " · 1 helper"))
        // A count never breaks from its noun ("1 task").
        #expect(work.row.preview.contains("1\u{00A0}helper") && !work.row.preview.contains("1 "))
        // Every member's time ends at the same edge, a caret or not (the caret's slot is kept on each row).
        let style = ChatStyle.make(category: .large)
        let ends = first.filter { if case .updateMember = $0.kind { true } else { false } }.compactMap { row -> CGFloat? in
            guard case .member(let m) = TextLayout.layout(row, width: 390, style: style).content, m.time != nil else { return nil }
            return m.timeFrame.maxX
        }
        #expect(ends.count == 8 && Set(ends).count == 1)
        // At accessibility sizes the time stays beside its title or goes: the whole time if it fits, else the short one,
        // else none, never on a line of its own (review 2026-10-28: "11:23 PM" alone on a line under the preview).
        // Same rule in both looks.
        for desktop in [false, true] {
            var state = ThemeTable.current.state
            state.desktopLook = desktop
            state.highContrast = false
            try ThemeTable.$testSet.withValue(ThemeResolver.resolve(state)) {
            #expect(HQShape.plainReplies == desktop)
            for category in [UIContentSizeCategory.accessibilityExtraLarge, .accessibilityExtraExtraExtraLarge] {
                let xl = ChatStyle.make(category: category)
                let xlMembers = first.compactMap { row -> (UpdateMemberLayout, UpdateMemberRow)? in
                    guard case .updateMember(let member) = row.kind,
                          case .member(let m) = TextLayout.layout(row, width: 390, style: xl).content else { return nil }
                    return (m, member)
                }
                #expect(xlMembers.count == 8)
                for (m, member) in xlMembers {
                    guard let time = m.time else {
                        #expect(m.timeFrame == .zero)
                        continue
                    }
                    let clock = try #require(member.time.map { ChatRowBuilder.clock($0) })
                    #expect(time == clock || time == UpdateMemberLayouts.shortClock(clock))
                    // On the title's line, clear of the title, and never below it.
                    #expect(m.timeFrame.minY < m.titleFrame.maxY && m.timeFrame.maxY > m.titleFrame.minY)
                    #expect(m.timeFrame.minX >= m.titleFrame.minX + ceil((m.title as NSString).size(withAttributes: [.font: xl.tool]).width))
                    #expect(m.previewFrame == .zero || m.timeFrame.maxY <= m.previewFrame.minY)
                }
                let shown = xlMembers.compactMap { $0.0.time == nil ? nil : $0.0.timeFrame.maxX }
                #expect(Set(shown).count <= 1)
            }
            }
        }
        #expect(UpdateMemberLayouts.shortClock("11:23\u{202F}PM") == "11:23" && UpdateMemberLayouts.shortClock("23:05") == "23:05")
    }

    /// One Line: a reply still working keeps its line out of any group (it's news, not an update) until it settles.
    @Test func liveLineDoesNotFold() {
        var messages = Array(talk.prefix(4))   // through bt-a2, the reply still running: write_file is its newest step
        messages[3].parts = Array(messages[3].parts.prefix(5)).map { part in
            guard case .tool(var call) = part, call.id == "bt-t5" else { return part }
            call.state = .running
            return .tool(call)
        }
        messages[3].isStreaming = true
        let live = ChatRowBuilder.build(input(messages, style: .line, running: true))
        #expect(live.contains { if case .toolRun(let t) = $0.kind { t.line != nil && t.live && t.group == nil } else { false } }, "the live line")
        // The rows on either side of it are lines of their own, not one group across it.
        #expect(lines(live).map(\.id) == ["bt-d1|dl", "bt-a2|dm3"])
        #expect(lines(live).map { $0.row.group?.count } == [1, 1])
        // Settled, it joins them.
        let settled = ChatRowBuilder.build(input(Array(talk.prefix(4)), expanded: ["bt-d1|grp"], style: .line))
        #expect(members(settled).contains { $0.id == "bt-a2|line|in" })
    }

    /// Tool Call Style › Rows draws every step: none of them fold.
    @Test func rowsStyleKeepsToolRowsReal() {
        let rows = ChatRowBuilder.build(input(talk, style: .rows))
        #expect(rows.contains { if case .toolRun(let t) = $0.kind { t.line == nil } else { false } })
        #expect(!members(rows).contains { $0.id.hasSuffix("|line|in") })
    }

    /// The model's rebuilds draw what a full build draws, from any message onward and for any one message.
    @Test func incrementalEqualsFull() {
        func ids(_ rows: [ChatRow]) -> [String] { rows.map { "\($0.id)#\($0.fingerprint)#\($0.variant)#\($0.gapAbove)" } }
        let opened: Set<String> = ["bt-r2|grp", "bt-d1|grp", "bt-n1|bg|in", "bt-a2|b6|in"]
        for style in [ToolCallStyle.bottom, .line, .rows, .header] {
            for open in [Set<String>(), opened] {
                let full = input(talk, expanded: open, style: style)
                let want = ids(ChatRowBuilder.build(full))
                // Messages arriving: the first k were drawn, the rest land.
                for k in 0..<talk.count {
                    var model = ChatRowModel()
                    model.rebuildAll(input(Array(talk.prefix(k)), expanded: open, style: style), syncMessages: 100, oldestShown: nil)
                    model.rebuildNewest(full, fromMessage: k)
                    #expect(ids(model.allRows.reversed()) == want, "\(style) rebuildNewest from \(k)")
                }
                // One message changed (its words): rebuilding it alone redraws its run's line too.
                for k in 0..<talk.count {
                    var before = talk
                    before[k].parts = before[k].parts.map { if case .text(let t) = $0 { return .text(t + " (draft)") } else { return $0 } }
                    var model = ChatRowModel()
                    model.rebuildAll(input(before, expanded: open, style: style), syncMessages: 100, oldestShown: nil)
                    model.rebuildMessages(full, k...k)
                    #expect(ids(model.allRows.reversed()) == want, "\(style) rebuildMessages \(k)")
                }
            }
            // A tap: the line or a member opens, and only its own message is rebuilt (as `chatCellToggle` does).
            var open = Set<String>()
            var model = ChatRowModel()
            model.rebuildAll(input(talk, style: style), syncMessages: 100, oldestShown: nil)
            for id in ["bt-r2|grp", "bt-d1|grp", "bt-n1|bg|in", "bt-a2|b6|in"] {
                open.insert(id)
                let full = input(talk, expanded: open, style: style)
                guard let row = model.allRows.first(where: { $0.id == id }),
                      let k = talk.firstIndex(where: { $0.id == row.messageId }) else { continue }
                model.rebuildMessages(full, k...k)
                #expect(ids(model.allRows.reversed()) == ids(ChatRowBuilder.build(full)), "\(style) toggling \(id)")
            }
        }
    }

    /// One reply that heads two runs ("To Hermes" twice, its words, "To Hermes" twice, its words). [exchange] Its first
    /// words came after it wrote to Hermes and it wrote again after them: they fold in, one line, then its last words.
    /// Two runs in one reply still get two ids: words before the first message to Hermes stand between a work line and
    /// the messages.
    @Test func oneMessageHeadingTwoRunsGivesTwoIds() throws {
        func dm(_ id: String, _ words: String) -> ChatPart {
            .tool(ToolCall(id: id, name: "message_agent", title: "message_agent",
                           argsText: #"{"target":"hermes","message":"\#(words)"}"#, summary: "Sent", state: .done, durationSeconds: 1))
        }
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let thread = [
            ChatMessage(id: "u", role: .user, parts: [.text("Ask Hermes twice")], timestamp: at, rowId: nil),
            ChatMessage(id: "a", role: .assistant, parts: [dm("c1", "One"), dm("c2", "Two"), .text("Asked."),
                                                          dm("c3", "Three"), dm("c4", "Four"), .text("Asked again.")],
                        timestamp: at.addingTimeInterval(5), rowId: nil),
        ]
        for style in [ToolCallStyle.bottom, .line, .header] {
            let rows = ChatRowBuilder.build(input(thread, style: style))
            #expect(Set(rows.map(\.id)).count == rows.count, "\(style) \(rows.map(\.id))")
            let grouped = lines(rows).filter { ($0.row.group?.count ?? 0) > 1 }
            #expect(grouped.map(\.id) == ["a|grp"] && grouped.first?.row.group?.count == 5, "\(style) \(rows.map(\.id))")
            #expect(rows.filter(\.isBubble).map(\.id) == ["u|b0", "a|b5"])
        }
        // A work line, words, then two messages to Hermes: two runs, two ids, each opening on its own.
        let terminal = ToolCall(id: "c0", name: "terminal", title: "terminal", argsText: #"{"command":"date"}"#, summary: "Thu",
                                state: .done, durationSeconds: 1)
        let split = [
            thread[0],
            ChatMessage(id: "a", role: .assistant, parts: [.tool(terminal), .text("Checked."), dm("c1", "One"), dm("c2", "Two")],
                        timestamp: at.addingTimeInterval(5), rowId: nil),
            ChatMessage(id: "b", role: .assistant, parts: [.tool(terminal), .tool(terminal)], timestamp: at.addingTimeInterval(9), rowId: nil),
        ]
        for style in [ToolCallStyle.bottom, .line] {
            let rows = ChatRowBuilder.build(input(split, style: style))
            #expect(Set(rows.map(\.id)).count == rows.count, "\(style) \(rows.map(\.id))")
            let found = lines(rows).filter { $0.row.group != nil } .map(\.id) + rows.compactMap { row in
                if case .toolRun(let t) = row.kind, t.group != nil { return row.id } else { return nil }
            }
            #expect(found.count == 2 && Set(found).count == 2, "\(style) \(rows.map(\.id))")
            #expect(found.contains("a|dm2|grp"), "\(style) \(found)")
            let opened = ChatRowBuilder.build(input(split, expanded: ["a|dm2|grp"], style: style))
            #expect(Set(opened.map(\.id)).count == opened.count)
            #expect(members(opened).map(\.id) == ["a|dm2|in", "a|dm3|in", "b|line|in"], "\(style) \(opened.map(\.id))")
        }
    }

    /// Older messages paged in under an opened group whose members are later messages: the rows match a full build.
    @Test func olderMessagesUnderAnOpenedGroup() {
        func ids(_ rows: [ChatRow]) -> [String] { rows.map { "\($0.id)#\($0.fingerprint)#\($0.variant)#\($0.gapAbove)" } }
        let all = talk
        for split in 1..<all.count {
            for open in [Set(["bt-d1|grp", "bt-r2|grp", "bt-n1|bg|in"]), Set(["bt-r2|grp"])] {
                let newer = Array(all[split...])
                // The group's line as the newer part draws it alone (its head may be the first newer message).
                let heads = Set(lines(ChatRowBuilder.build(input(newer))).map(\.id))
                var model = ChatRowModel()
                model.rebuildAll(input(newer, expanded: open.union(heads)), syncMessages: 100, oldestShown: nil)
                model.reveal(model.allRows.count)
                let full = input(all, expanded: open.union(heads))
                model.rebuildOldest(full, added: split)
                while let chunk = model.nextChunk(size: 50) {
                    model.appendBuilt(ChatRowBuilder.build(full, range: chunk), range: chunk, generation: model.generation, measured: true)
                }
                #expect(ids(model.allRows.reversed()) == ids(ChatRowBuilder.build(full)), "split at \(split)")
            }
        }
    }

    /// A /btw answer opens as it lands, even with updates beside it; folded, it joins them.
    @Test func openedAsideStandsAlone() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let aside = SideTaskRow.message(kind: .btw, taskId: "t1", asked: "what's the port?", text: "It listens on 8080.",
                                        at: at.addingTimeInterval(30))
        var thread = Array(talk.prefix(3))      // …, the delivery from Hermes
        thread.append(aside)
        thread.append(talk[3])                  // a reply whose work line and "To Hermes" rows lead it
        let id = "\(aside.id)|bg"
        let open = ChatRowBuilder.build(input(thread, expanded: [id]))
        let line = lines(open).first { $0.id == id }
        #expect(line?.row.expanded == true && line?.row.group?.count == 1, "\(open.map(\.id))")
        let folded = ChatRowBuilder.build(input(thread))
        #expect(!lines(folded).contains { $0.id == id })
        #expect(lines(folded).contains { $0.row.group?.titles.contains("By the way") == true })
        // Opening and folding it by rebuilding its own message draws what a full build draws.
        var model = ChatRowModel()
        model.rebuildAll(input(thread), syncMessages: 100, oldestShown: nil)
        model.rebuildMessages(input(thread, expanded: [id]), 3...3)
        #expect(model.allRows.reversed().map(\.id) == open.map(\.id))
        model.rebuildMessages(input(thread), 3...3)
        #expect(model.allRows.reversed().map(\.id) == folded.map(\.id))
    }

    /// Previews read as words: no echoed shell prompt, a goal set off from its report.
    @Test func previewsReadAsWords() {
        #expect(UpdateGroups.preview("> npm test\n128 passing (41s)", process: true) == "128 passing (41s)")
        #expect(UpdateGroups.preview("Check the flaky upload test\n\nThe upload test waits on a real timer.")
                == "Check the flaky upload test — The upload test waits on a real timer.")
        #expect(UpdateGroups.preview("Done.\nNext one.") == "Done. Next one.")
        #expect(BackgroundResults.botName("inbox") == "Inbox" && BackgroundResults.botName("iPhone bot") == "iPhone bot")
    }

    @Test func fromToAndHelperWords() {
        #expect(BackgroundResults.plainTitle("Background agents finished") == "Helpers finished")
        #expect(BackgroundResults.plainTitle("2 background agents finished") == "2 helpers finished")
        #expect(BackgroundResults.plainTitle("1 background agent finished") == "1 helper finished")
        #expect(BackgroundResults.plainTitle("background agent work finished") == "Helpers finished")
        #expect(BackgroundResults.plainTitle("Subagent Task Completed: Index") == "Helper finished: Index")
        // A message_agent call is "To Hermes"; one that failed sent nothing and draws no line. It ranks under Hermes's own
        // words.
        let call = ToolCall(id: "c", name: "message_agent", title: "message_agent", argsText: #"{"target":"hermes","message":"Hi"}"#,
                            summary: nil, state: .done, durationSeconds: 1)
        let m = ChatMessage(id: "a", role: .assistant, parts: [.tool(call)], timestamp: nil, rowId: nil)
        let sent = BotDMRows.sent(m, call: call, part: 0, input: input([]))
        var failed = call
        failed.state = .failed
        #expect(BotDMRows.sent(m, call: failed, part: 0, input: input([])) == nil)
        guard case .backgroundResult(let a)? = sent?.kind else { Issue.record("expected a line"); return }
        #expect(a.title == "To Hermes: Hi")
        #expect(a.group == nil, "folded by the build, not here")
        #expect(UpdateGroups.rank(sent!) == 4)
    }
}

#if DEBUG
import UIKit

/// A stand-in chat for the DEBUG harness: N generated messages with realistic markdown, code, tables, tool runs and
/// long replies; paging older history; and a simulated streaming reply (reasoning, tool calls, text) when you send,
/// with Stop.
class FakeChatSession: ChatSessionModel, ChatSessionDetails {
    let title: String
    /// `-HQDemoBotTalk`: Inbox's chat, with Inbox's face.
    let profile = ChatDemo.flag("-HQDemoBotTalk") ? "inbox" : "demo"
    var head: JSONValue? { ChatDemo.flag("-HQDemoBotTalk") ? FakeChatSession.inboxHead : nil }
    var layoutScope: String { "demo-account|\(profile)|\(title)" }
    /// `-HQDemoSessionOf <bot>`: the chat is one of that bot's sessions (its name shows under the title).
    var botName: String { ChatDemo.argument("-HQDemoSessionOf") ?? title }
    let modelName: String? = "Claude Opus"
    var seenThrough: Date? { messages.last(where: { $0.rowId != nil })?.timestamp }
    /// Streams the reply 60 characters per 16 ms (a fast provider), instead of 18 per 33 ms.
    var fastStream = false
    private(set) var messages: [ChatMessage]
    private(set) var isRunning = false
    private(set) var isLoadingOlder = false
    private(set) var connection: ConnectionState = .ready
    private(set) var statusText: String?
    var onChange: ((ChatChange) -> Void)?
    var hasOlder: Bool { !older.isEmpty }

    private var older: [ChatMessage]      // not loaded yet, oldest first
    private let pageSize: Int
    private var timers: [Timer] = []
    private var streamingId: String?
    private var counter = 0
    private var started = false

    /// `count` messages in all; `initial` of them (the newest) are "cached" and present at once.
    init(count: Int, initial: Int? = nil, pageSize: Int = 400, title: String = "Hermes", long: Bool = false,
         textPrefix: String? = nil) {
        self.title = title
        self.pageSize = pageSize
        var all = FakeChatSession.generate(count: count, long: long)
        if let textPrefix {
            // Same ids, different words: another bot's chat whose message ids collide with this one's.
            all = all.map { m in
                var m = m
                m.parts = m.parts.map { if case .text(let t) = $0 { return .text(textPrefix + t) } else { return $0 } }
                return m
            }
        }
        let first = min(all.count, initial ?? all.count)
        messages = Array(all.suffix(first))
        all.removeLast(first)
        older = all
        if ChatDemo.flag("-HQDemoDrafts") { messages += FakeChatSession.draftMessages }
    }

    /// `-HQDemoDrafts` [drafts]: two replies that each hold a draft for review (a Slack message, a long email).
    static var draftMessages: [ChatMessage] {
        func draft(_ id: String, _ args: [String: JSONValue]) -> ChatPart {
            .tool(ToolCall(id: id, name: DraftCards.tool, title: "Draft message", argsText: ChatJSON.stringify(.object(args)),
                           summary: nil, state: .done, durationSeconds: 0.1))
        }
        let mail = "Hi Ivy,\n\nThanks for sending the proposal over. I read it this morning and I like the direction, especially "
            + "the phased rollout.\n\nTwo things before we sign:\n\n1. The timeline in section 3 has the pilot ending in "
            + "December, but section 5 budgets for it through January. Which one is right?\n2. We'd want the support hours "
            + "spelled out for the pilot, not only for the full contract.\n\nIf those are quick fixes, I can get it to our "
            + "side for signature by Friday.\n\nBest,\nAlex"
        return [
            ChatMessage(id: "draft-u1", role: .user, parts: [.text("Tell Dana the Q3 numbers are ready and ask for a time on Thursday.")],
                        timestamp: Date().addingTimeInterval(-240), rowId: 9001),
            ChatMessage(id: "draft-a1", role: .assistant, parts: [
                draft("draft-c1", ["app": .string("Slack"), "to": .string("#finance"), "thread": .array([
                    .object(["from": .string("Priya Shah"), "when": .string("Fri 2:15 PM"), "text": .string("Heads up: the board meeting moved to the 21st, so the deck is due a week earlier.")]),
                    .object(["from": .string("Dana Okafor"), "when": .string("Fri 2:31 PM"), "text": .string("Thanks. That means I need final Q3 numbers by Wednesday at the latest.")]),
                    .object(["from": .string("Luis Ortega"), "when": .string("Fri 3:02 PM"), "text": .string("EMEA and APAC close on Monday. The Americas are already in the shared folder.")]),
                    .object(["from": .string("Priya Shah"), "when": .string("Mon 10:20 AM"), "text": .string("EMEA is in. APAC had a currency adjustment, so they're re-running it.")]),
                    .object(["from": .string("Luis Ortega"), "when": .string("Mon 1:48 PM"), "text": .string("I'll check with APAC this afternoon and post here.")]),
                    .object(["from": .string("Dana Okafor"), "when": .string("Mon 4:52 PM"), "text": .string("Are the Q3 numbers final yet? I need them for the board deck.")]),
                    .object(["from": .string("Luis Ortega"), "when": .string("Mon 5:10 PM"), "text": .string("Still waiting on two regions. Should be done tomorrow morning.")]),
                    .object(["from": .string("Dana Okafor"), "when": .string("Today 9:03 AM"), "text": .string("Morning! Any update? If they're ready I'd like to walk through them together this week.")])]),
                                   "body": .string("Hi Dana, the Q3 numbers are in the shared folder. Can we meet Thursday at 2 to go through them?")]),
                .text("The draft is ready.")], timestamp: Date().addingTimeInterval(-230), rowId: 9002),
            ChatMessage(id: "draft-u2", role: .user, parts: [.text("And reply to Ivy about the proposal.")],
                        timestamp: Date().addingTimeInterval(-120), rowId: 9003),
            ChatMessage(id: "draft-a2", role: .assistant, parts: [
                draft("draft-c2", ["app": .string("Email — from alex@example.com"), "to": .string("ivy.rivera@example.com"), "subject": .string("Re: Pilot proposal"),
                                   "thread": .array([.object(["from": .string("Ivy Rivera"), "when": .string("Today 8:41 AM"), "text": .string(
                                       "Hi Alex,\n\nAttached is the pilot proposal we talked about. The short version: a three-month pilot with "
                                       + "two of your teams, starting in October, then a phased rollout to everyone else if the numbers hold up.\n\n"
                                       + "Pricing for the pilot is in section 5 and the full contract terms are in section 7. Support during the "
                                       + "pilot is included.\n\nIf this looks right, could you sign by the end of next week so we can book the "
                                       + "onboarding sessions?\n\nThanks,\nSam")])]),
                                   "body": .string(mail)]),
                .text("The reply to Ivy is ready.")], timestamp: Date().addingTimeInterval(-110), rowId: 9004),
        ]
    }

    func start() { started = true }

    /// Replaces the messages wholesale (fresh history over cache): same ids, bumped revisions, one new at the end.
    func debugReset() {
        for i in messages.indices { messages[i].revision += 1 }
        counter += 1
        messages.append(ChatMessage(id: "reset-\(counter)", role: .assistant, parts: [.text("Fresh history arrived.")],
                                    timestamp: Date(), rowId: nil))
        onChange?(.reset)
    }

    func stopObserving() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
    }

    func loadOlder() {
        guard hasOlder, !isLoadingOlder else { return }
        isLoadingOlder = true
        schedule(0.25) { [weak self] in
            guard let self else { return }
            let page = Array(self.older.suffix(self.pageSize))
            self.older.removeLast(page.count)
            self.messages.insert(contentsOf: page, at: 0)
            self.isLoadingOlder = false
            self.onChange?(.prependedOlder(count: page.count))
        }
    }

    // MARK: Send / stream / stop

    func send(_ text: String) {
        counter += 1
        let id = "local-user-\(counter)"
        var m = ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: Date(), rowId: nil)
        m.isPending = true
        messages.append(m)
        onChange?(.appended(ids: [id]))
        isRunning = true
        statusText = "Thinking…"
        onChange?(.state)
        schedule(0.35) { [weak self] in self?.mutate(id) { $0.isPending = false } }
        if let found = DraftCards.answer(in: text) {
            // [drafts] An answer to a draft card: one short line back, as a bot that sent it (or left it) says.
            schedule(1.2) { [weak self] in
                guard let self else { return }
                self.counter += 1
                let reply = found.answer == .skip ? "Okay, I won’t send it." : "Sent."
                let new = ChatMessage(id: "local-draft-reply-\(self.counter)", role: .assistant, parts: [.text(reply)], timestamp: Date(), rowId: nil)
                self.messages.append(new)
                self.onChange?(.appended(ids: [new.id]))
                self.isRunning = false
                self.statusText = nil
                self.onChange?(.state)
            }
            return
        }
        schedule(0.9) { [weak self] in self?.beginReply(to: text) }
    }

    func stop() {
        guard isRunning else { return }
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        if let sid = streamingId {
            mutate(sid) { $0.isStreaming = false; $0.interrupted = true; $0.parts = $0.parts.map(Self.settle) }
        } else {
            counter += 1
            var m = ChatMessage(id: "local-assistant-\(counter)", role: .assistant, parts: [], timestamp: Date(), rowId: nil)
            m.interrupted = true
            messages.append(m)
            onChange?(.appended(ids: [m.id]))
        }
        streamingId = nil
        isRunning = false
        statusText = nil
        onChange?(.state)
    }

    private static func settle(_ part: ChatPart) -> ChatPart {
        if case .tool(var call) = part, call.state == .running { call.state = .done; return .tool(call) }
        return part
    }

    private func beginReply(to prompt: String) {
        guard isRunning else { return }
        counter += 1
        let id = "local-assistant-\(counter)"
        streamingId = id
        var m = ChatMessage(id: id, role: .assistant, parts: [.reasoning("")], timestamp: Date(), rowId: nil)
        m.isStreaming = true
        messages.append(m)
        onChange?(.appended(ids: [id]))
        // Reasoning, then two tools, then the text.
        let thought = "The user asked about \(prompt.prefix(40)). I should check the project first, then answer with an example."
        var t = 0.0
        for word in thought.split(separator: " ") {
            t += 0.04
            schedule(t) { [weak self] in
                self?.mutate(id) { m in
                    if case .reasoning(let r) = m.parts[0] { m.parts[0] = .reasoning(r.isEmpty ? String(word) : r + " " + word) }
                }
            }
        }
        t += 0.3
        let tools: [(String, String, String)] = [
            ("terminal", #"{"command":"cd ~/Projects/demo && swift build 2>&1 | tail -20"}"#, "Build complete (4.2 s)"),
            ("read_file", #"{"path":"Sources/Demo/ChatView.swift"}"#, "214 lines"),
        ]
        for (i, tool) in tools.enumerated() {
            let callId = "\(id)-tool-\(i)"
            schedule(t) { [weak self] in
                self?.statusText = "Running a command…"
                self?.onChange?(.state)
                self?.mutate(id) {
                    $0.parts.append(.tool(ToolCall(id: callId, name: tool.0, title: tool.0, argsText: tool.1, summary: nil,
                                                   state: .running, durationSeconds: nil)))
                }
            }
            // -HQDemoHoldStep: the first step runs on, so the thinking row (and its timer) can be looked at.
            if ChatDemo.flag("-HQDemoHoldStep") { return }
            t += 0.9
            schedule(t) { [weak self] in
                self?.mutate(id) { m in
                    m.parts = m.parts.map { part in
                        if case .tool(var call) = part, call.id == callId { call.state = .done; call.summary = tool.2; call.durationSeconds = 0.9; return .tool(call) }
                        return part
                    }
                }
            }
            t += 0.2
        }
        let reply = fastStream ? FakeChatSession.longReply(paragraphs: 24) : FakeChatSession.streamedReply
        var index = reply.startIndex
        schedule(t) { [weak self] in
            self?.statusText = "Writing…"
            self?.onChange?(.state)
            self?.mutate(id) { $0.parts.append(.text("")) }
        }
        // -HQDemoStreamStep <characters> / -HQDemoStreamInterval <seconds>: chunkier deltas (the hold-engage check).
        let step = ChatDemo.argument("-HQDemoStreamStep").flatMap(Int.init) ?? (fastStream ? 60 : 18)
        let interval = ChatDemo.argument("-HQDemoStreamInterval").flatMap(Double.init) ?? (fastStream ? 0.016 : 0.033)
        while index < reply.endIndex {
            let next = reply.index(index, offsetBy: step, limitedBy: reply.endIndex) ?? reply.endIndex
            let chunk = String(reply[index..<next])
            index = next
            t += interval
            schedule(t) { [weak self] in
                self?.mutate(id) { m in
                    if case .text(let s) = m.parts[m.parts.count - 1] { m.parts[m.parts.count - 1] = .text(s + chunk) }
                }
            }
        }
        t += 0.2
        schedule(t) { [weak self] in
            guard let self else { return }
            self.mutate(id) { $0.isStreaming = false }
            self.streamingId = nil
            self.isRunning = false
            self.statusText = nil
            self.onChange?(.state)
        }
    }

    private func mutate(_ id: String, _ change: (inout ChatMessage) -> Void) {
        guard let i = messages.lastIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
        messages[i].revision += 1
        onChange?(.updated(ids: [id]))
    }

    private func schedule(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { block() } }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    // MARK: Generated history

    static let streamedReply = """
    Here's what I found. The build is clean, and the chat view only needs **one change**: measure rows off the main \
    thread and keep the newest at the bottom.

    1. Lay out the visible rows before the push
    2. Measure the rest in the background
    3. Append them at the far end, so nothing moves

    ```swift
    func layoutInitialScreen(height: CGFloat) {
        var total: CGFloat = 0
        while total < height * 1.5, let row = next() {
            total += TextLayout.layout(row, width: width).height
        }
    }
    ```

    | Step | Time | Thread |
    |---|---:|---|
    | Build rows | 3 ms | main |
    | Measure screen | 9 ms | main |
    | Measure rest | 0.8 s | background |

    That keeps the first frame instant. Want me to wire it in?
    """

    private static let prompts = [
        "Can you check why the build is failing?",
        "What's on my calendar tomorrow?",
        "Summarize the last three emails from the team",
        "ok",
        "Thanks! That worked.",
        "Can you write a quick script that renames all the screenshots in ~/Desktop by date?\nKeep the originals in a folder.",
        "How do I make the composer stick to the keyboard in UIKit? I tried notifications and it lags behind by a frame or two when the keyboard opens.",
        "Run the tests again",
        "What does this error mean: `Thread 1: EXC_BAD_ACCESS (code=1, address=0x0)`",
        "Draft a reply to Ivy saying we'll ship on Friday",
        "Look up the weather in Lisbon this weekend",
        "👍",
        "Can you compare the three plans in a table?",
        "Please clean up the downloads folder",
        "Where did we leave the migration?",
    ]

    private static let replies = [
        "Done — the build passes now. The failure was a missing `import Markdown` in `TextLayout.swift`.",
        """
        Tomorrow you have:

        - **9:30** Standup (15 min)
        - **11:00** Design review with Priya
        - **14:00** Dentist — leave by 13:30

        Nothing after 4 PM, so the afternoon is free for the release.
        """,
        """
        Here are the three emails:

        1. **Ivy** — the release candidate is ready for QA; asks whether Friday still works.
        2. **Priya** — new mocks for the settings screen, link in the thread: https://example.com/mocks/settings
        3. **Ops** — the backup job failed twice last night, they're looking into it.

        > Nothing urgent, but Ivy is waiting on an answer.
        """,
        """
        Here's a script that does it:

        ```bash
        #!/bin/zsh
        cd ~/Desktop
        mkdir -p originals
        for f in Screenshot*.png; do
          d=$(stat -f %SB -t %Y-%m-%d_%H%M%S "$f")
          cp "$f" originals/
          mv "$f" "shot-$d.png"
        done
        ```

        Run it with `zsh rename.sh`. It copies each file into `originals/` first, so nothing is lost.
        """,
        """
        Use the **keyboard layout guide** instead of notifications. Pin the composer's bottom to \
        `view.keyboardLayoutGuide.topAnchor`, and UIKit moves it inside the keyboard's own animation:

        ```swift
        composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8).isActive = true
        tableView.keyboardDismissMode = .interactive
        ```

        That also tracks the interactive dismissal frame by frame, which notification math can't do.
        """,
        """
        All tests pass:

        | Suite | Tests | Time |
        |---|---:|---:|
        | MarkdownRendererTests | 14 | 0.08 s |
        | TextLayoutTests | 6 | 0.03 s |
        | ChatRowBuilderTests | 9 | 0.02 s |
        """,
        """
        `EXC_BAD_ACCESS` at address `0x0` means something dereferenced a **null pointer** — usually an unowned \
        reference to an object that was already freed, or a force-unwrapped C pointer.

        Check the stack trace for the first frame in your code; in Swift it's often an `unowned self` in a closure \
        that outlived its owner. Switching it to `[weak self]` and an early `guard let self` fixes most of these.
        """,
        "Here's a draft:\n\n> Hi Ivy — we're on track for Friday. QA starts Wednesday morning; I'll send the notes Thursday.\n\nWant me to send it?",
        """
        ## Lisbon this weekend

        **Saturday** — sunny, 24°C, light wind
        **Sunday** — clouds in the morning, 21°C, 20% chance of rain after 5 PM

        Good weekend for the coast; take a jacket for Sunday evening.
        """,
        """
        | Plan | Price | Storage | Seats |
        |---|---:|---:|---:|
        | Basic | $8 | 50 GB | 1 |
        | Team | $24 | 1 TB | 5 |
        | Business | $60 | 5 TB | 20 |

        **Team** is the best fit if you're under five people; Business only makes sense once you need SSO.
        """,
        """
        I cleaned up the downloads folder:

        - Moved 38 installers (`.dmg`, `.pkg`) to the Trash
        - Kept 12 PDFs and filed them under `Documents/Receipts`
        - Left 4 files I wasn't sure about in `Downloads/Review`

        That freed **6.2 GB**.
        """,
        """
        We stopped after step 3 of the migration. The schema is updated and the backfill ran for users, but \
        **orders** still need it. Long version below.

        The remaining work is:

        1. Run the backfill for `orders` (about 2.1M rows; ~40 minutes at the current batch size)
        2. Flip the read path to the new table behind the flag
        3. Watch error rates for a day, then drop the old columns

        I'd do step 1 tonight when traffic is low. The script is idempotent, so if it stops halfway you can run it \
        again and it picks up from the last finished batch. It logs progress every 10,000 rows to \
        `logs/backfill-orders.log`, and you can check on it with `tail -f`.

        One risk: the `orders.updated_at` index is missing on the replica, so the read-path flip could be slow for \
        the reports page. I'd add it before step 2:

        ```sql
        CREATE INDEX CONCURRENTLY IF NOT EXISTS orders_updated_at_idx ON orders (updated_at);
        ```

        Everything else looks fine — the last dry run finished without errors, and the row counts matched.
        """,
        "Sure.",
        "On it — I'll report back when it's done.",
    ]

    private static func toolRun(_ rng: inout SeededRNG, base: String) -> [ChatPart] {
        let options: [(String, String, String)] = [
            ("terminal", #"{"command":"cd ~/Projects/app && npm run typecheck 2>&1 | tail -30"}"#, "No errors"),
            ("terminal", #"{"command":"git status --short"}"#, " M src/chat.ts"),
            ("read_file", #"{"path":"src/ui-chat/composer.tsx"}"#, "312 lines"),
            ("search_files", #"{"query":"keyboardLayoutGuide","path":"ios/"}"#, "4 matches"),
            ("web_search", #"{"query":"UIKeyboardLayoutGuide interactive dismiss"}"#, "8 results"),
            ("web_extract", #"{"urls":["https://developer.apple.com/documentation/uikit/uikeyboardlayoutguide"]}"#, "Page text"),
            ("edit_file", #"{"path":"src/ui-chat/composer.tsx"}"#, "+12 −3"),
            ("browser_navigate", #"{"url":"https://example.com/status"}"#, "Loaded"),
            ("todo", #"{"todos":[]}"#, "ok"),
        ]
        let n = 1 + rng.next(4)
        var parts: [ChatPart] = []
        for i in 0..<n {
            let o = options[rng.next(options.count)]
            let failed = rng.next(14) == 0
            parts.append(.tool(ToolCall(id: "\(base)-t\(i)", name: o.0, title: o.0, argsText: o.1,
                                        summary: failed ? "Exit 1: command not found" : o.2,
                                        state: failed ? .failed : .done, durationSeconds: Double(rng.next(40)) / 10)))
        }
        return parts
    }

    /// A long reply: `paragraphs` paragraphs of prose with a list and a code fence in between (~1,100 characters each).
    static func longReply(paragraphs: Int) -> String {
        var out: [String] = []
        for p in 0..<paragraphs {
            out.append("Paragraph \(p): " + String(repeating: "The backfill keeps going in batches of ten thousand rows, logging as it goes, so a restart picks up where it stopped. ", count: 9))
            if p % 6 == 3 {
                out.append("- first point about step \(p)\n- second point, with `inline code`\n- third point")
            }
            if p % 8 == 5 {
                out.append("```swift\n" + (0..<12).map { "let value\($0) = compute(\($0)) // step \(p)" }.joined(separator: "\n") + "\n```")
            }
        }
        return out.joined(separator: "\n\n")
    }

    /// The long cases (`-HQDemoLong`): a 25,000-character reply, a 300-line fence, a write_file call with 200 KB of
    /// arguments, and a long message of yours (clamped at 10 lines).
    static func longShowcase(at now: Date) -> [ChatMessage] {
        let fence = "Here is the whole file:\n\n```python\n" + (0..<300).map { "def handler_\($0)(event):  # line \($0)\n    return process(event, retries=\($0 % 5))" }.joined(separator: "\n") + "\n```\n\nThat's all 300 handlers."
        let bigArgs = #"{"path":"src/generated/schema.json","content":""# + String(repeating: "abcdefghij", count: 20_000) + #""}"#
        let mine = (1...24).map { "Line \($0) of a long message I pasted, so the bubble has to clamp at ten lines and offer Show More." }.joined(separator: "\n")
        return [
            ChatMessage(id: "long-u1", role: .user, parts: [.text("Write me the whole migration guide, in detail")], timestamp: now.addingTimeInterval(-3000), rowId: 800_001),
            ChatMessage(id: "long-a1", role: .assistant, parts: [.text(longReply(paragraphs: 22))], timestamp: now.addingTimeInterval(-2990), rowId: 800_002),
            ChatMessage(id: "long-u2", role: .user, parts: [.text("And the generated handlers?")], timestamp: now.addingTimeInterval(-2900), rowId: 800_003),
            ChatMessage(id: "long-a2", role: .assistant, parts: [
                .tool(ToolCall(id: "big-w", name: "write_file", title: "write_file", argsText: bigArgs, summary: "Wrote 200 KB", state: .done, durationSeconds: 0.4)),
                .text(fence),
            ], timestamp: now.addingTimeInterval(-2890), rowId: 800_004),
            ChatMessage(id: "long-u3", role: .user, parts: [.text(mine)], timestamp: now.addingTimeInterval(-2800), rowId: 800_005),
        ]
    }

    /// `-HQDemoBusy`: a short, busy bot thread (thoughts, several step runs per reply, replies split by steps, gaps
    /// of 30+ minutes) for the thread-cleanup mockup.
    static func busyThread(now: Date = Date()) -> [ChatMessage] {
        var n = 0
        func t(_ name: String, _ args: String, _ summary: String, _ seconds: Double, failed: Bool = false) -> ChatPart {
            n += 1
            return .tool(ToolCall(id: "busy-t\(n)", name: name, title: name, argsText: args, summary: summary,
                                  state: failed ? .failed : .done, durationSeconds: seconds))
        }
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        func you(_ id: String, _ text: String, _ m: Double) -> ChatMessage {
            ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: at(m), rowId: nil)
        }
        func bot(_ id: String, _ m: Double, _ parts: [ChatPart]) -> ChatMessage {
            ChatMessage(id: id, role: .assistant, parts: parts, timestamp: at(m), rowId: nil)
        }
        return [
            you("busy-u1", "Morning! Did anything break overnight?", 150),
            bot("busy-a1", 149.5, [
                .reasoning("Check the deploy log and the error tracker first."),
                t("terminal", #"{"command":"git log --since=yesterday --oneline"}"#, "6 commits", 1.2),
                t("read_file", #"{"path":"logs/deploy.log"}"#, "880 lines", 0.3),
                t("search_files", #"{"query":"ERROR","path":"logs/"}"#, "2 matches", 0.4),
                .text("Two errors in the deploy log. Checking whether they're real."),
                t("terminal", #"{"command":"kubectl get pods -n prod"}"#, "All running", 2.1),
                t("web_search", #"{"query":"redis READONLY replica error after failover"}"#, "8 results", 3.4),
                .text("Nothing broke. The two errors were a Redis failover at 3:12 AM; it recovered on its own in 40 seconds. One warning is still there: the image cache is at **91%**."),
            ]),
            you("busy-u2", "Can you fix the cache warning?", 147),
            bot("busy-a2", 146, [
                .reasoning("Raise the limit or add eviction. Eviction is safer."),
                t("read_file", #"{"path":"config/cache.yml"}"#, "42 lines", 0.2),
                t("edit_file", #"{"path":"config/cache.yml"}"#, "+3 −1", 0.1),
                t("terminal", #"{"command":"npm test -- cache"}"#, "Tests passed", 41),
                .text("Added LRU eviction at 80%."),
                t("terminal", #"{"command":"git push origin fix/cache-eviction"}"#, "Pushed", 2.5),
                .text("Pushed to `fix/cache-eviction`. Want me to open a PR?"),
            ]),
            you("busy-u3", "Yes. And draft the release notes", 95),
            you("busy-u4", "keep them short", 94.5),
            bot("busy-a3", 94, [
                t("terminal", #"{"command":"gh pr create --fill"}"#, "PR #412", 3.1),
                t("terminal", #"{"command":"git log v2.3..HEAD --oneline"}"#, "9 commits", 0.6),
                t("read_file", #"{"path":"CHANGELOG.md"}"#, "210 lines", 0.2),
                .text("PR #412 is open. Release notes:\n\n- Export chats as Markdown or JSON\n- Faster sync on reconnect\n- Image cache no longer fills up"),
            ]),
            you("busy-u5", "What's on my calendar today?", 38),
            bot("busy-a4", 37.5, [
                .reasoning("Open the calendar page."),
                t("browser_navigate", #"{"url":"https://calendar.example.com/today"}"#, "Loaded", 4.2),
                t("web_extract", #"{"urls":["https://calendar.example.com/today"]}"#, "Page text", 1.8, failed: true),
                .text("The page didn't load fully, trying again."),
                t("browser_navigate", #"{"url":"https://calendar.example.com/today?view=list"}"#, "Loaded", 3.9),
                .text("Three things today: **design review** at 11, lunch with Ivy at 12:30, and the **launch sync** at 4."),
            ]),
            you("busy-u6", "Thanks!", 3),
            bot("busy-a5", 2.5, [.text("Anytime.")]),
        ]
    }

    /// `-HQDemoUpdates`: replies with finished work, another bot's messages, a scheduled run and notes between them
    /// ([updates] the centred group lines).
    static func updatesThread(now: Date = Date()) -> [ChatMessage] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        let ivy = ChatSender(key: "ivy", name: "Ivy", head: nil, profile: "ivy")
        let inbox = ChatSender(key: "inbox", name: "Inbox", head: nil, profile: "inbox")
        func you(_ id: String, _ text: String, _ m: Double) -> ChatMessage {
            ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: at(m), rowId: nil)
        }
        func bot(_ id: String, _ text: String, _ m: Double) -> ChatMessage {
            ChatMessage(id: id, role: .assistant, parts: [.text(text)], timestamp: at(m), rowId: nil)
        }
        func note(_ id: String, _ text: String, _ m: Double, report: String? = nil) -> ChatMessage {
            var msg = ChatMessage(id: id, role: .system, parts: [.text(text)], timestamp: at(m), rowId: nil)
            msg.report = report
            return msg
        }
        func from(_ who: ChatSender, _ id: String, _ text: String, _ m: Double, job: String? = nil) -> ChatMessage {
            var msg = ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: at(m), rowId: nil)
            msg.sender = who
            msg.job = job
            return msg
        }
        return [
            you("up-u1", "Run the tests and ask Ivy whether the October invoice went out", 20),
            bot("up-a1", "On it. The tests are running in the background and I've asked Ivy.", 19.5),
            note("up-n1", "Background Process Finished: npm test", 18, report: "> npm test\n\n  128 passing (41s)"),
            note("up-n2", "Subagent Task Completed: Check the flaky upload test", 17.5, report: "The upload test waits on a real timer; it passes with a fake clock."),
            from(ivy, "up-d1", "Yes, sent Oct 3, paid Oct 9.", 17),
            you("up-u2", "Great, thanks", 16),
            bot("up-a2", "Anytime.", 15.8),
            note("up-n3", "Model changed to gpt-5-mini", 12),
            you("up-u3", "Anything new in the inbox?", 6),
            bot("up-a3", "Two new emails since this morning, nothing urgent.", 5.8),
            from(inbox, "up-c1", "1 new inbound email from Dana about the launch date.", 3, job: "Inbox watch"),
            you("up-u4", "Did inbox fix the repeat alert?", 2),
            note("up-b1", "Background update", 1, report: "Message from 🤖 inbox (@inbox): **Repeat validation alert fixed** in my own script.\n\n"
                 + "- `validation_pending` returned True even though the delivery receipt was already verified: the cron's output file had been cleaned up.\n"
                 + "- `priority_poll_tick` now treats an operator-verified receipt as settled, even after log cleanup.\n"
                 + "- 3 new regression tests pass; live check is False as expected.\n\nNo provider, config, model or mailbox changes."),
        ]
    }

    /// `-HQDemoIdle`: a bot left alone for ten days, its scheduled runs and background updates one or two a day, each
    /// scheduled run answered silently ([idle] Northwind's chat, owner's screenshot 2026-11-10).
    static func idleThread(now: Date = Date()) -> [ChatMessage] {
        func at(_ days: Double, _ hour: Double) -> Date {
            Calendar.current.startOfDay(for: now).addingTimeInterval(-days * 86_400 + hour * 3_600)
        }
        let inbox = ChatSender(key: "inbox", name: "Inbox", head: nil, profile: "inbox")
        var out = [
            ChatMessage(id: "id-u1", role: .user, parts: [.text("Draft the launch post and keep an eye on the inbox")], timestamp: at(11, 23.9), rowId: nil),
            ChatMessage(id: "id-a1", role: .assistant, parts: [.text("Draft is in drafts/launch.md. I'll watch the inbox and tell you if anything needs you.")],
                        timestamp: at(11, 23.95), rowId: nil),
        ]
        let reports = ["Nothing new since the last check.", "1 new email from Dana about the launch date; no reply needed yet.",
                       "Inbox quiet.", "2 newsletters archived.", "Nothing new."]
        for d in stride(from: 10, through: 1, by: -1) {
            if d > 6 {
                var run = ChatMessage(id: "id-c\(d)", role: .user, parts: [.text(reports[d % reports.count])], timestamp: at(Double(d), 8.7), rowId: nil)
                run.sender = inbox
                run.job = "Inbox watch"
                var quiet = ChatMessage(id: "id-s\(d)", role: .assistant, parts: [], timestamp: at(Double(d), 8.75), rowId: nil)
                quiet.silentNote = true
                out += [run, quiet]
            } else {
                var update = ChatMessage(id: "id-b\(d)", role: .system, parts: [.text("Background update")], timestamp: at(Double(d), 9.7), rowId: nil)
                update.report = "Message from 🤖 inbox (@inbox): " + reports[d % reports.count]
                out.append(update)
            }
        }
        return out
    }

    /// `-HQDemoBotTalk`: an inbox bot's chat (a real one; ids, names and figures changed):
    /// Hermes asks for an overview, Inbox works with a helper and messages Hermes twice, then Hermes's
    /// replies and the helper's report land between Inbox's own words ([updates] the folded lines).
    static func botTalkThread(now: Date = Date()) -> [ChatMessage] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        func you(_ id: String, _ text: String, _ m: Double) -> ChatMessage {
            ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: at(m), rowId: nil)
        }
        func bot(_ id: String, _ m: Double, _ parts: [ChatPart]) -> ChatMessage {
            ChatMessage(id: id, role: .assistant, parts: parts, timestamp: at(m), rowId: nil)
        }
        func t(_ id: String, _ name: String, _ args: String, _ summary: String, card: ToolCard? = nil) -> ChatPart {
            var call = ToolCall(id: id, name: name, title: name, argsText: args, summary: summary, state: .done, durationSeconds: 2)
            call.card = card
            return .tool(call)
        }
        // What the gateway writes when the message_agent runner ends (BotDMs.swift): Hermes's reply, from Hermes.
        func reply(_ id: String, _ text: String, _ m: Double) -> ChatMessage {
            let output = String(data: (try? JSONSerialization.data(withJSONObject: ["reply": text, "status": "settled"])) ?? Data(),
                                encoding: .utf8) ?? "{}"
            let note = "[IMPORTANT: Background process proc_\(id) completed normally (exit code 0).\n"
                + "Command: /Users/x/.hermes/tools/python3 /Users/x/.hermes/hermes-agent/tools/bot_mode_dm.py --run-delivery "
                + "--author '{\"id\":\"bot:inbox\",\"name\":\"inbox\",\"is_bot\":true}' query-file /tmp/dm-\(id).txt "
                + "--profile-home /Users/x/.hermes /Users/x/.hermes/hermes-agent/.hermes/bin/hermes -p default\n"
                + "Output:\n\(output)\n]\n\n[INTERNAL NOTIFICATION — generated by the Hermes gateway, not written by a human user.]"
            return you(id, note, m)
        }
        let goal = "Read-only fresh current overview Gmail Personal+Work: unread counts, anything needing attention today"
        var helper = ChatMessage(id: "bt-n1", role: .system, parts: [.text("Subagent Task Completed: " + goal)], timestamp: at(12.5), rowId: nil)
        helper.report = "**Gmail overview as of Oct 28, 8:45 p.m.**\n\n- Unread Inbox conversations: Personal 12; Work 34\n"
            + "- Needs attention today: Vendor X legacy endpoint cutoff; Host storage warning for `shop-db`\n"
            + "- Nothing else time-sensitive; newsletters and receipts left unread."
        return [
            you("bt-u1", "Keep an eye on both inboxes this evening", 140),
            bot("bt-a1", 139, [.text("Will do. I'll check Personal and Work and tell you about anything that needs you today.")]),
            you("bt-d1", "Message from 🤖 hermes (@hermes): Alex asks for a current overview of both inboxes — what's unread and anything that needs attention today.", 15),
            bot("bt-a2", 14, [
                t("bt-t1", "delegate_task", #"{"goal":"\#(goal)"}"#, "1 helper",
                  card: .delegate(goals: [goal], results: [DelegateResult(status: "completed")], dispatchedGoals: nil)),
                t("bt-t2", "terminal", #"{"command":"date; mail status"}"#, "Tue Oct 28 20:44"),
                t("bt-t3", "terminal", #"{"command":"server thread 1234"}"#, "Host: storage warning"),
                t("bt-t4", "message_agent", #"{"target":"hermes","message":"Host shop-db >90% storage; please check live usage, read-only."}"#, "Sent"),
                t("bt-t5", "write_file", #"{"path":"notes/overview.md"}"#, "Written"),
                t("bt-t6", "message_agent", #"{"target":"hermes","message":"mail evidence attached; no action needed yet."}"#, "Sent"),
                .text("The fresh iCloud check found a new operational warning: the host reports `shop-db` is over 90% storage and could be suspended if it fills. Hermes has the details. The Gmail review is still running before I consolidate the overview."),
            ]),
            reply("bt-r1", "Inbox found something worth attention: the host warned that the shop database is over 90% full and could be suspended if it hits its limit. That's an email warning, not a confirmed outage. I've asked the app bot to check the live usage and options without changing or spending anything.", 13),
            helper,
            bot("bt-a3", 12, [
                t("bt-t8", "message_agent", #"{"target":"hermes","message":"CURRENT READ-ONLY OVERVIEW complete: Personal 12 unread, Work 34."}"#, "Sent"),
                .text("**Work is the busiest inbox, and the full review is still incomplete.** Fresh check at about **8:45pm**:\n\n| Inbox | Unread |\n|---|---|\n| Personal | 12 |\n| Work | 34 |\n\n- Vendor X's legacy endpoint cutoff is today\n- Host storage warning for `shop-db`"),
            ]),
            reply("bt-r2", "Inbox also found a receipt for the new desk chair. Nothing to do.", 11),
            reply("bt-r3", "Inbox found a few things needing attention: Vendor X's legacy endpoint cutoff is today, and the host's storage warning for the shop database. The rest can wait.", 10),
        ]
    }

    /// `-HQDemoBotExchange`: Hermes's chat on 2026-10-29 (a real one; ids and details changed, the    /// owner's flower watch): one voice memo, then Hermes and Home (and App) back and forth for five minutes, Hermes
    /// writing you a short update after each of their messages. [exchange] Only the last update stays a bubble. The demo
    /// goes on with `botExchangeFollowUp`.
    static func botExchangeThread(now: Date = Date()) -> [ChatMessage] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        func you(_ id: String, _ text: String, _ m: Double) -> ChatMessage {
            ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: at(m), rowId: nil)
        }
        func from(_ id: String, _ bot: String, _ text: String, _ m: Double) -> ChatMessage {
            you(id, "Message from 🤖 \(bot.capitalized) (@\(bot)): " + text, m)
        }
        func to(_ id: String, _ bot: String, _ text: String) -> ChatPart {
            .tool(ToolCall(id: id, name: "message_agent", title: "message_agent", argsText: #"{"target":"\#(bot)","message":"\#(text)"}"#,
                           summary: "Queued", state: .done, durationSeconds: 1))
        }
        func bot(_ id: String, _ m: Double, _ parts: [ChatPart]) -> ChatMessage {
            ChatMessage(id: id, role: .assistant, parts: parts, timestamp: at(m), rowId: nil)
        }
        return [
            you("fx-u1", "Morning. Anything I should know about today?", 240),
            bot("fx-a0", 239, [.text("Nothing urgent. Ivy's flowers are due today; everything else can wait.")]),
            you("fx-u2", "I can't keep an eye on the front door camera. Can you let me know when Ivy's flowers get delivered?", 6),
            bot("fx-a1", 5.9, [to("fx-t1", "home", "Alex asks to be alerted when Ivy's flowers arrive at the front door today."),
                               .text("I’ve asked the Home bot to set up a front-door watch for the flowers and alert you in the app. I’ll confirm once the watch is actually active.")]),
            from("fx-d1", "home", "I can own read-only camera/event checks, but need the supported app notification delivery target you want used for the bounded follow-up.", 5.8),
            bot("fx-a2", 5.7, [to("fx-t2", "home", "Use end of local day as expiry. Your bot-chat:home delivery is the natural HQ app destination."),
                               .text("The Home bot can check the camera, but the alert route still needs to be verified. I’ve asked it to use the app and stop watching at the end of today.")]),
            from("fx-d2", "home", "Home watch established and readback verified: job 0000demo0000 enabled, every 5m, date guard ends tonight at 23:59 local.", 5.1),
            bot("fx-a3", 5, [to("fx-t3", "app", "Need immediate operational guidance: Home has a bounded flower delivery camera watcher through tonight."),
                             to("fx-t4", "home", "Watch and expiry confirmed, thank you. Continue reporting detections to me immediately."),
                             .text("The front-door watch is active: Home is checking every five minutes through tonight and will look for actual flower evidence, not just motion.")]),
            from("fx-d3", "home", "Material verification correction: initial cron run returned [SILENT] with ZERO tool calls; not a real camera check.", 4.4),
            bot("fx-a4", 4.3, [to("fx-t5", "home", "Thanks for catching that. Please repair the watch so checks demonstrably execute."),
                               .text("Correction: the watch’s first scheduled run **didn’t actually check the camera**, so I was too quick to call it active. Home checked the camera manually just now and saw no flowers or package.")]),
            from("fx-d4", "app", "Verified installed supported route: Home DMs target hermes on detection, you produce a substantive final reply in your own main Bot Chat.", 4),
            bot("fx-a5", 3.9, [.text("The app notification route is configured: when Home confirms a delivery and messages me, my reply can trigger an HQ push.")]),
            from("fx-d5", "home", "Repair applied: existing flower watch now runs deterministic script flower_watch_probe.py each tick before agent review.", 3.6),
            bot("fx-a6", 3.5, [.text("Home repaired the watch and tested the camera-fetch script: it successfully retrieved images from both front-door cameras.")]),
            from("fx-d6", "home", "Verified repaired run evidence, but exact remaining blocker: scheduled agent again returns [SILENT] with zero tool calls.", 3.2),
            bot("fx-a7", 3.1, [to("fx-t6", "home", "Runtime investigation found 12:46 manual run vision_analyze calls on both snapshots in the Home session database."),
                               .text("Update: the test run **did inspect both camera images**, and no flowers were visible. The earlier conclusion that it made no tool calls was wrong. Home is checking the next normal scheduled run and the end-of-day expiry.")]),
        ]
    }

    /// The same chat after the flower watch's last update: Home's correction and Hermes's answer about
    /// the flowers, a scheduled job's report at 1:01 that starts a turn about the weekly review, your 1:21 message, Hermes
    /// asking Home what happened and its answer, then a short note after Home's runner ends. [exchange] Build 464 kept
    /// only the last reply of each stretch, so both answers folded away (owner, 2026-10-29: "never got an actual response
    /// from Hermes regarding what I sent in the voice memo").
    static func botExchangeFollowUp(now: Date = Date()) -> [ChatMessage] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        func you(_ id: String, _ text: String, _ m: Double) -> ChatMessage {
            ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: at(m), rowId: nil)
        }
        func bot(_ id: String, _ m: Double, _ parts: [ChatPart]) -> ChatMessage {
            ChatMessage(id: id, role: .assistant, parts: parts, timestamp: at(m), rowId: nil)
        }
        func t(_ id: String, _ name: String, _ args: String, _ summary: String, card: ToolCard? = nil) -> ChatPart {
            var call = ToolCall(id: id, name: name, title: name, argsText: args, summary: summary, state: .done, durationSeconds: 2)
            call.card = card
            return .tool(call)
        }
        // The gateway's note when Hermes's message to Home settles; Home's answer was the silent stand-in, so it draws nothing.
        func settled(_ id: String, _ m: Double) -> ChatMessage {
            let note = "[IMPORTANT: Background process proc_\(id) completed normally (exit code 0).\n"
                + "Command: /Users/x/.hermes/tools/python3 /Users/x/.hermes/hermes-agent/tools/bot_mode_dm.py --run-delivery "
                + "--author '{\"id\":\"bot:default\",\"name\":\"hermes\",\"is_bot\":true}' query-file /tmp/dm-\(id).txt "
                + "--profile-home /Users/x/.hermes/profiles/home /Users/x/.hermes/hermes-agent/.hermes/bin/hermes -p home\n"
                + "Output:\n{\"reply\": \"[Notification processed; no additional user-facing response.]\", \"status\": \"settled\"}\n]\n\n"
                + "[INTERNAL NOTIFICATION — generated by the Hermes gateway, not written by a human user.]"
            return you(id, note, m)
        }
        let goal = "Investigate weekly review cron paused due app delivery verification failure. Read-only inspect actual job, last run, delivery evidence."
        var helper = ChatMessage(id: "fx-n1", role: .system, parts: [.text("Subagent Task Completed: " + goal)], timestamp: at(20.3), rowId: nil)
        helper.report = "- **The review ran; delivery was unverified.** The October 25 run completed and saved its response.\n"
            + "- **Currently paused:** `weekly-review` shows `enabled: false`, paused October 29 at 1:01 p.m."
        return [
            you("fx-d7", "Message from 🤖 Home (@home): Independent DB verification corrects MY earlier claim: actual cron sessions contain vision calls even though output wrapper says API calls 0.", 35.8),
            bot("fx-a8", 35.7, [.text("Home independently confirmed the camera images **were being reviewed**, including on the original run. My earlier warning that the watch wasn’t examining them was incorrect.\n\nThe watch remains scheduled through tonight. No flowers were visible in the latest checked images.")]),
            settled("fx-r1", 35.6),
            you("fx-c1", "[Cronjob \"midday-alert\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\nThe weekly review ran successfully, but its app delivery failed verification. I paused that job and confirmed it’s disabled—contained, not repaired. Other jobs are unchanged.", 21.7),
            bot("fx-a9", 21.3, [
                t("fx-t7", "skill_view", #"{"name":"cron-model-routing-operations"}"#, "Loaded"),
                t("fx-t8", "delegate_task", #"{"goal":"\#(goal)"}"#, "1 helper",
                  card: .delegate(goals: [goal], results: [DelegateResult(status: "completed")], dispatchedGoals: nil)),
                .text("The weekly review is paused after its app delivery failed verification. I’m checking the actual delivery evidence before treating it as a confirmed failure."),
            ]),
            helper,
            bot("fx-a10", 20.2, [.text("The weekly review itself ran on Sunday; what’s unverified is whether it reached your app. A later delivery-path test succeeded, but that doesn’t prove the review arrived. The job remains paused, so it won’t run this coming Sunday unless restored.")]),
            you("fx-u3", "I never got a notification that they were delivered…", 1.8),
            bot("fx-a11", 1.4, [
                t("fx-t9", "message_agent", #"{"target":"home","message":"Alex says Ivy's flowers were delivered but he got no alert. Urgently inspect actual delivery time/event and watcher scheduled runs."}"#, "Queued"),
                .text("You’re right—I missed it. I’m sorry. I’ve asked Home to check the delivery event and the watch’s actual runs to find out whether it missed the flowers or failed to send the alert."),
            ]),
            you("fx-d8", "Message from 🤖 Home (@home): Incident result: camera history shows person Oct29 13:02:08–13:03:03 and doorbell at 13:02:15. Natural cron runs ALL final [SILENT], no alert/message_agent call. Thus no flower alert was generated; not evidence of app push loss.", 1.2),
            bot("fx-a12", 1, [.text("I found what happened: **no alert was generated**, so this wasn’t an app notification failure.\n\nThe camera recorded someone at the door and a doorbell at 1:02, but the watch only inspected snapshots every five minutes and failed to check those person and doorbell events. By its next check, the porch was empty. That was a flaw in the watch I set up, and I’m sorry—it didn’t do the job you asked.\n\nThe watch has now been removed since the flowers arrived.")]),
            settled("fx-r2", 0.7),
            bot("fx-a13", 0.6, [.text("The delivery watch is stopped. No further action is needed.")]),
        ]
    }

    /// `-HQDemoRestated`: Hermes's chat on 2026-10-30 (a real one, ids removed): your voice
    /// memo, Hermes's first answer, the request as Hermes restated it after compressing the chat at 9:38, Hermes and Home
    /// at work, then its answer. [restated] The restated request is a note, not a second bubble of yours.
    static func restatedThread(now: Date = Date()) -> [ChatMessage] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        func you(_ id: String, _ text: String, _ m: Double) -> ChatMessage {
            ChatMessage(id: id, role: .user, parts: [.text(text)], timestamp: at(m), rowId: nil)
        }
        func bot(_ id: String, _ m: Double, _ parts: [ChatPart]) -> ChatMessage {
            ChatMessage(id: id, role: .assistant, parts: parts, timestamp: at(m), rowId: nil)
        }
        let memo = "MEDIA:\"/Users/x/.hermes/attachments/voice-memo.m4a\"\n\nVoice memo transcript: I need you to work on it "
            + "until it's fixed, figure it out, get it working properly. I want the first actual scheduled test to work or the scheduled job."
        let header = "[STILL IN PROGRESS — this is the active request, restated after the compaction boundary because it was "
            + "not finished yet. Continue it; do not start over.]"
        return [
            you("rs-u1", memo, 212),
            bot("rs-a1", 211, [.text("I'm on it. My approach: take the \"decide when it's done\" step away from the bot. A script will run the review in small batches, and only a full count will mark it finished.")]),
            you("rs-u2", header + "\n" + memo, 205),
            bot("rs-a2", 30, [.tool(ToolCall(id: "rs-t1", name: "message_agent", title: "message_agent",
                                             argsText: #"{"target":"home","message":"Identify the owners of the stale scoring and wiki sync failures."}"#,
                                             summary: "Queued", state: .done, durationSeconds: 1)),
                              .text("I’ve asked Home to find who owns the two failing steps.")]),
            you("rs-d1", "Message from 🤖 Home (@home): Scoring is stale since Oct 28; wiki sync fails GitHub authentication.", 20),
            bot("rs-a3", 1, [.text("**KPI weekly reports are paused** because scoring is stale and wiki sync is failing GitHub authentication. Existing reports are preserved.\n\nI’ve asked Home to identify the owners and diagnose both failures. Reporting stays paused until the dependencies are repaired and verified; any credential change will need approval.")]),
        ]
    }

    /// `-HQDemoBotExchange`'s roster: Hermes, Home and App, each with a face.
    @MainActor static func botExchangeRoster() {
        func head(_ color: String, _ form: String, _ seed: Double) -> JSONValue {
            .object(["v": .number(6), "theme": .string("shape"), "color": .string(color), "form": .string(form), "seed": .number(seed),
                     "tile": .string("none")])
        }
        DeliveryRoster.set([
            DeliveryMessages.Seat(profile: "default", name: "Hermes", head: head("butter", "round", 20260924)),
            DeliveryMessages.Seat(profile: "home", name: "Home", head: head("mint", "blob", 4141)),
            DeliveryMessages.Seat(profile: "app", name: "App", head: head("coral", "round", 777)),
        ])
    }

    /// `-HQDemoBotTalk`'s roster: Hermes with a face, Inbox with its sky blob (the owner's).
    @MainActor static func botTalkRoster() {
        func head(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }
        DeliveryRoster.set([
            DeliveryMessages.Seat(profile: "default", name: "Hermes",
                                  head: head(["v": .number(6), "theme": .string("shape"), "color": .string("butter"), "form": .string("round"),
                                              "look": .string("happy"), "seed": .number(20260924), "tile": .string("none")])),
            DeliveryMessages.Seat(profile: "inbox", name: "Inbox", head: inboxHead),
        ])
    }

    static let inboxHead: JSONValue = .object(["v": .number(6), "theme": .string("shape"), "color": .string("sky"), "form": .string("blob"),
                                               "look": .string("ovals"), "seed": .number(416723), "tile": .string("none")])

    /// `-HQDemoPage <path>`: a sales bot's chat (2026-10-31, details changed), the reply carrying its chart as a `::preview` line.
    static func pageThread(_ path: String, now: Date = Date()) -> [ChatMessage] {
        let ask = "Can you chart our follow-ups by channel and by outcome? I need to know where to stop following up."
        let reply = "I built a chart for exactly this. For each channel, it shows how many replies every follow-up produces. "
            + "Drag the red line to where a follow-up stops being worth it, and the table shows which attempt to stop at for each "
            + "channel and how much time that frees up.\n\n::preview{file=\"\(path)\"}\n\n**At 1 reply per 100 follow-ups, here's where to stop:**\n\n"
            + "- **Skip entirely:** List A, List B, List C, List D.\n- **Stop early:** Web Form after attempt 3, Partner B after 4."
        return [
            ChatMessage(id: "pg-u1", role: .user, parts: [.text(ask)], timestamp: now.addingTimeInterval(-120), rowId: nil),
            ChatMessage(id: "pg-a1", role: .assistant, parts: [.text(reply)], timestamp: now.addingTimeInterval(-60), rowId: nil),
        ]
    }

    /// [mac-audit] `-HQDemoLinks`: short plain replies (their time on the last line) and two bare links, one a page
    /// with no title (pair with `-HQNLinkPreviewStub 'https://example.com/=>-;https://example.org/guide=>The Guide'`).
    static func linksThread(now: Date = Date()) -> [ChatMessage] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        return [
            ChatMessage(id: "ln-u1", role: .user, parts: [.text("Where are the docs?")], timestamp: at(9), rowId: nil),
            ChatMessage(id: "ln-a1", role: .assistant, parts: [.text("Answer 2 in this synthetic chat.")], timestamp: at(8), rowId: nil),
            ChatMessage(id: "ln-u2", role: .user, parts: [.text("And the site?")], timestamp: at(6), rowId: nil),
            ChatMessage(id: "ln-a2", role: .assistant, parts: [.text("Here it is:\n\nhttps://example.com/\n\nAnd the guide:\n\nhttps://example.org/guide\n\nAll set for today.")],
                        timestamp: at(5), rowId: nil),
        ]
    }

    /// [wide-tables] `-HQDemoWideTable`: a three-column table of long rows, as the tester's (2026-11-06), with words
    /// before and after it.
    static func wideTableThread(now: Date = Date()) -> [ChatMessage] {
        let rows = [
            ("Claims ERROR #05 — auto attribution doesn't update the linked URL count", "ABC-168 Triage", "No fix merged"),
            ("Claims SUG #06 — Tips view grouped by format, full card", "ABC-169 Triage (+ ABC-130 In Progress for full cards)", "Reverted 1a2b3c4"),
            ("Claims SUG #07 — extend the blur to Media, Evolution and Tips", "ABC-170 In Review", "Only one in review"),
            ("Events OBS #01 IMPORTANT — JSON export only exports highlights", "ABC-172 Triage", "No fix merged"),
            ("Actors OBS #01 — short URLs (t.co, share.google) create fake actors", "ABC-174 Triage", "No fix merged"),
        ]
        let table = "| Doc item | Linear | Note |\n|---|---|---|\n" + rows.map { "| \($0.0) | \($0.1) | \($0.2) |" }.joined(separator: "\n")
        let reply = "## Pending with an issue\n\nEvery one has GitHub OPEN and Linear in Triage, Backlog, Todo, In Progress or In Review. "
            + "No fix commit has been merged.\n\n\(table)\n\n**No issue created:** none of these turned up in Linear (a search of 250 issues) or GitHub."
        return [
            ChatMessage(id: "wt-u1", role: .user, parts: [.text("Which of the doc's items still have open issues?")],
                        timestamp: now.addingTimeInterval(-120), rowId: nil),
            ChatMessage(id: "wt-a1", role: .assistant, parts: [.text(reply)], timestamp: now.addingTimeInterval(-60), rowId: nil),
        ]
    }

    /// [transcript] `-HQDemoMath`: a reply of formulas a tester named (2026-11-09): inline, display, aligned, cases
    /// and matrices.
    static func mathThread(now: Date = Date()) -> [ChatMessage] {
        let reply = #"""
        The quadratic formula is $x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$, and Euler's identity is \(e^{i\pi} + 1 = 0\). For a vector $\vec{v} \in \mathbb{R}^n$ the norm is $\lVert \vec{v} \rVert = \sqrt{\sum_{i=1}^{n} v_i^2}$.

        A sum and an integral:

        $$\sum_{i=1}^{n} i = \frac{n(n+1)}{2} \qquad \int_{0}^{\infty} e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}$$

        Aligned steps:

        $$\begin{aligned}
        (a+b)^2 &= (a+b)(a+b) \\
                &= a^2 + 2ab + b^2
        \end{aligned}$$

        Cases:

        \[
        f(x) = \begin{cases} x^2 & \text{if } x \ge 0 \\ -x & \text{otherwise} \end{cases}
        \]

        Matrices:

        $$A = \begin{pmatrix} a & b \\ c & d \end{pmatrix}, \quad \det A = \begin{vmatrix} a & b \\ c & d \end{vmatrix} = ad - bc, \quad I = \begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix}$$

        \begin{align}
        \nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \\
        \nabla \times \mathbf{B} &= \mu_0 \mathbf{J} + \mu_0 \varepsilon_0 \frac{\partial \mathbf{E}}{\partial t}
        \end{align}

        It costs $5 and $10, which is not math.
        """#
        return [
            ChatMessage(id: "math-u1", role: .user, parts: [.text("Show me some formulas: $E = mc^2$ and a matrix")],
                        timestamp: now.addingTimeInterval(-120), rowId: nil),
            ChatMessage(id: "math-a1", role: .assistant, parts: [.text(reply)], timestamp: now.addingTimeInterval(-60), rowId: nil),
        ]
    }

    static func generate(count: Int, long: Bool = false) -> [ChatMessage] {
        guard count > 0 else { return [] }
        if ChatDemo.flag("-HQDemoMath") { return mathThread() }
        if ChatDemo.flag("-HQDemoWideTable") { return wideTableThread() }
        if ChatDemo.flag("-HQDemoLinks") { return linksThread() }
        if ChatDemo.flag("-HQDemoBusy") { return busyThread() }
        if ChatDemo.flag("-HQDemoUpdates") { return updatesThread() }
        if ChatDemo.flag("-HQDemoIdle") { return idleThread() }
        if ChatDemo.flag("-HQDemoBotTalk") { return botTalkThread() }
        if ChatDemo.flag("-HQDemoBotExchange") { return botExchangeThread(now: Date().addingTimeInterval(-35 * 60)) + botExchangeFollowUp() }
        if ChatDemo.flag("-HQDemoRestated") { return restatedThread() }
        if let page = ChatDemo.argument("-HQDemoPage") { return pageThread(page) }
        var rng = SeededRNG(seed: 42)
        var out: [ChatMessage] = []
        out.reserveCapacity(count)
        var time = Date().addingTimeInterval(-Double(count) * 900)
        var i = 0
        let showcase = 5
        while out.count < count - showcase {
            i += 1
            // Time moves forward: a turn every few minutes to a few hours, sometimes days.
            let gaps: [Double] = [30, 90, 240, 600, 3600, 4 * 3600, 26 * 3600]
            let gap = gaps[rng.next(gaps.count)]
            time = time.addingTimeInterval(gap * Double(1 + rng.next(3)) / 2)
            if rng.next(40) == 0 {
                out.append(ChatMessage(id: "m\(i)-sys", role: .system, parts: [.text(["Model changed to claude-opus-5", "Background process finished", "Resumed interrupted turn"][rng.next(3)])],
                                       timestamp: time, rowId: i * 10))
                continue
            }
            out.append(ChatMessage(id: "m\(i)-u", role: .user, parts: [.text(prompts[rng.next(prompts.count)])], timestamp: time, rowId: i * 10 + 1))
            if rng.next(6) == 0 {
                time = time.addingTimeInterval(20)
                out.append(ChatMessage(id: "m\(i)-u2", role: .user, parts: [.text(prompts[rng.next(prompts.count)])], timestamp: time, rowId: i * 10 + 2))
            }
            time = time.addingTimeInterval(Double(5 + rng.next(80)))
            var parts: [ChatPart] = []
            if rng.next(4) == 0 { parts.append(.reasoning("Let me think about what they need here, then check the files before answering.")) }
            if rng.next(2) == 0 { parts += toolRun(&rng, base: "m\(i)") }
            if rng.next(5) == 0 {
                parts.append(.text("Checking one more thing first."))
                parts += toolRun(&rng, base: "m\(i)b")
            }
            parts.append(.text(replies[rng.next(replies.count)]))
            var a = ChatMessage(id: "m\(i)-a", role: .assistant, parts: parts, timestamp: time, rowId: i * 10 + 3)
            if rng.next(60) == 0 { a.error = "The model provider returned an error (overloaded). Tap Try Again to send it again." }
            else if rng.next(50) == 0 { a.interrupted = true }
            out.append(a)
        }
        // Shift the history so it ends an hour ago (the gaps above run forward from an arbitrary start).
        let now = Date()
        if let last = out.last?.timestamp {
            let shift = now.addingTimeInterval(-3600).timeIntervalSince(last)
            for i in out.indices { out[i].timestamp = out[i].timestamp?.addingTimeInterval(shift) }
        }
        if long { out += longShowcase(at: now) }
        // A deterministic showcase at the newest end (what the screen shows when it opens).
        out.append(ChatMessage(id: "show-u1", role: .user, parts: [.text("Can you check the chat module and show me the plan as a table?")],
                               timestamp: now.addingTimeInterval(-420), rowId: 900_001))
        out.append(ChatMessage(id: "show-a1", role: .assistant, parts: [
            .reasoning("Look at the layout code first, then summarise."),
            .tool(ToolCall(id: "s1", name: "read_file", title: "read_file", argsText: #"{"path":"App/Chat/ChatViewController.swift"}"#, summary: "540 lines", state: .done, durationSeconds: 0.2)),
            .tool(ToolCall(id: "s2", name: "search_files", title: "search_files", argsText: #"{"query":"estimatedRowHeight"}"#, summary: "1 match", state: .done, durationSeconds: 0.3)),
            .tool(ToolCall(id: "s3", name: "terminal", title: "terminal", argsText: #"{"command":"scripts/build.sh test"}"#, summary: "Tests passed", state: .done, durationSeconds: 41)),
            .text(streamedReply),
        ], timestamp: now.addingTimeInterval(-400), rowId: 900_002))
        out.append(ChatMessage(id: "show-u2", role: .user, parts: [.text("Looks good")], timestamp: now.addingTimeInterval(-120), rowId: 900_003))
        out.append(ChatMessage(id: "show-u3", role: .user, parts: [.text("Ship it 🚀")], timestamp: now.addingTimeInterval(-100), rowId: 900_004))
        out.append(ChatMessage(id: "show-a2", role: .assistant, parts: [
            .tool(ToolCall(id: "s4", name: "edit_file", title: "edit_file", argsText: #"{"path":"App/Chat/ComposerView.swift"}"#, summary: "+4 −1", state: .done, durationSeconds: 0.1)),
            .text("Shipped. The composer now sits **8 pt** above the keys and 29 pt above the screen bottom when the keyboard is down."),
        ], timestamp: now.addingTimeInterval(-60), rowId: 900_005))
        return Array(out.suffix(count))
    }
}

/// Deterministic generator (SplitMix64) so the demo chat is the same on every launch.
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(_ bound: Int) -> Int { Int(nextUInt64() % UInt64(max(1, bound))) }
}
#endif

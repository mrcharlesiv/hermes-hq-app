#if DEBUG
import UIKit

// [threads] `-HQDemoThreads`: the demo chat as a bot's chat with threads, no gateway (pictures and hand checks).
//
//   -HQDemoThreads                 the chat: a CRM shortlist, its answer, and (with `later`) the finished comparison
//   -HQDemoThreads later           … with a finished thread folded under "Yes. Build the full comparison sheet…"
//   -HQDemoThreadTap <s>           presses the thread button that long after the chat opened (pair with
//                                  `-HQDemoSend <request> -HQDemoHoldStep -HQDemoDraft <question>`: a reply running
//                                  and words typed); the made-up thread answers 1.6 s later
//   -HQDemoThreadOpen <s>          opens the newest thread's own chat that long after the chat opened

/// Threads with made-up answers, kept in memory.
@MainActor
final class DemoThreadsHost: ChatThreadsHost {
    var onChange: (() -> Void)?
    private var list: [ChatThread] = []
    private var counter = 0

    var tint: ThreadTint {
        let rgb = HeadTones.accent(Head.resolve(nil, profile: "demo").color)
        return .accent(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    init(later: Bool, now: Date = Date()) {
        guard later else { return }
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        list = [ChatThread(id: "demo-thread-0", storedId: "demo-thread-0", title: "Flight on Friday", startedAt: at(8),
                           anchorMessageId: "th-u2", anchorRow: nil,
                           messages: [
                               ChatMessage(id: "tt-u1", role: .user, parts: [.text("Also, what time is my flight on Friday?")], timestamp: at(8), rowId: nil),
                               ChatMessage(id: "tt-a1", role: .assistant, parts: [.text(Self.flightAnswer)], timestamp: at(7.6), rowId: nil),
                               ChatMessage(id: "tt-u2", role: .user, parts: [.text("Put it on my calendar with an alarm at 5:00.")], timestamp: at(6), rowId: nil),
                               ChatMessage(id: "tt-a2", role: .assistant, parts: [.text("Done. It is on Friday’s calendar with a 5:00 AM alarm.")], timestamp: at(5.8), rowId: nil),
                           ], running: false, problem: nil, scope: "demo-account|demo|demo-thread-0")]
    }

    static let flightAnswer = "American 1482 leaves DFW at 7:05 AM Friday. Boarding starts at 6:25."

    func threads() -> [ChatThread] { list }
    func markSeen(_ keys: [String]) {}

    func start(text: String, under anchor: ChatMessage?) -> String? {
        counter += 1
        let key = "demo-thread-\(counter)"
        let now = Date()
        list.append(ChatThread(id: key, storedId: key, title: nil, startedAt: now, anchorMessageId: anchor?.id, anchorRow: anchor?.rowId,
                               messages: [ChatMessage(id: "\(key)-u1", role: .user, parts: [.text(text)], timestamp: now, rowId: nil)],
                               running: true, problem: nil, scope: "demo-account|demo|\(key)"))
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, let index = self.list.firstIndex(where: { $0.id == key }) else { return }
            self.list[index].messages.append(ChatMessage(id: "\(key)-a1", role: .assistant, parts: [.text(Self.flightAnswer)],
                                                         timestamp: Date(), rowId: nil))
            self.list[index].running = false
            self.list[index].title = "Flight on Friday"
            self.onChange?()
        }
        return key
    }

    func open(_ key: String, from screen: ChatViewController) {
        guard let thread = list.first(where: { $0.id == key }) else { return }
        FakeChatSession.script = thread.messages
        let session = FakeChatSession(count: 1, title: ThreadRules.name(thread))
        let chat = ChatViewController(session: session)
        let head = HeadView(side: 34)
        head.configure(raw: session.head, profile: session.profile, follows: true)
        chat.titleAccessoryView = head
        ChatMenus.install(on: chat, account: nil) {}
        screen.navigationController?.pushViewController(chat, animated: true)
    }

    var newestKey: String? { list.last?.id }
}

extension FakeChatSession {
    /// A scripted transcript for the next demo chat made (a thread's own chat).
    nonisolated(unsafe) static var script: [ChatMessage]?

    /// `-HQDemoThreads [later]`: the chat the mockups drew.
    static func threadsThread(now: Date = Date()) -> [ChatMessage] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        var out = [
            ChatMessage(id: "th-u1", role: .user, parts: [.text("We need a CRM for the sales team. Shortlist three that work for 12 people.")],
                        timestamp: at(12), rowId: nil),
            ChatMessage(id: "th-a1", role: .assistant,
                        parts: [.text("Three fit a 12-person team: **HubSpot**, **Pipedrive** and **Close**. All three have a phone app, email sync and a pipeline view. Want a side-by-side with prices?")],
                        timestamp: at(11.5), rowId: nil),
        ]
        guard ChatDemo.argument("-HQDemoThreads") == "later" else { return out }
        out += [
            ChatMessage(id: "th-u2", role: .user, parts: [.text("Yes. Build the full comparison sheet with prices for 12 seats.")],
                        timestamp: at(9), rowId: nil),
            ChatMessage(id: "th-a2", role: .assistant,
                        parts: [.text("The comparison sheet is ready. **Pipedrive** is the cheapest for 12 seats at $588 a month. **HubSpot** has the best phone app, and **Close** has calling built in. Want it as a spreadsheet file?")],
                        timestamp: at(1), rowId: nil),
        ]
        return out
    }
}

extension ChatDemo {
    /// The demo chat gets its threads (`-HQDemoThreads`), and the flags that press the button or open a thread.
    @MainActor static func installThreads(on chat: ChatViewController) {
        guard flag("-HQDemoThreads") else { return }
        let host = DemoThreadsHost(later: argument("-HQDemoThreads") == "later")
        chat.threadsHost = host
        if let after = argument("-HQDemoThreadTap").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak chat] in
                guard let chat else { return }
                let text = ChatText.trimmed(chat.composer.text)
                guard !text.isEmpty else { return }
                chat.composer.text = ""
                chat.startThread(text)
            }
        }
        if let after = argument("-HQDemoThreadOpen").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak chat, weak host] in
                guard let chat, let key = host?.newestKey else { return }
                chat.openThread(key: key)
            }
        }
    }
}
#endif

#if DEBUG
import UIKit

/// DEBUG harness: `-HQDemoChat <N>` launches into a plain list that pushes a chat with N generated messages, so the
/// push, the scroll and the composer can be judged without a gateway.
///
/// Other launch arguments:
/// - `-HQDemoAutoOpen` push the chat 1.2 s after launch (`-HQDemoOpenDelay <s>` to change)
/// - `-HQDemoFocusComposer` focus the composer once open (keyboard up); `-HQDemoFocusAfter <s>` /
///   `-HQDemoDismissAfter <s>` focus it / dismiss the keyboard that long after opening
/// - `-HQDemoScrollUp <points>` scroll that far up from the newest end once open
/// - `-HQDemoAutoScroll` run the scroll probe (newest → oldest → newest) and log dropped frames
/// - `-HQDemoSend <text>` send a message once open (streams a fake reply)
/// - `-HQDemoExpandTools` open the newest tool rows
/// - `-HQDemoInitial <n>` only the newest n messages are present at open (the rest page in)
/// - `-HQDemoLong` add the long cases (25k-character reply, 300-line fence, 200 KB tool arguments, long message)
/// - `-HQDemoFastStream` stream the sent reply fast (60 characters per 16 ms, a long reply)
/// - `-HQDemoHoldStep` the sent reply's first step runs on (the thinking row stays, its timer counts)
/// - `-HQDemoOpenIndex <i>` which list entry `-HQDemoAutoOpen` opens; `-HQDemoThenOpen <i>` pops and opens another
///   (entry 3 "Other bot" has the same message ids as entry 1 with different words: the cache-scope check)
/// - `-HQDemoUpdates` / `-HQDemoBotTalk` the [updates] threads (BotTalk: Inbox's chat with Hermes, the owner's
///   2026-10-28 screenshots); `-HQDemoOpenGroups` opens every grouped line, `-HQDemoOpenMember <n>` then opens the
///   first group's n-th member (1 = the top one); `-HQDemoBotExchange` Hermes and Home's back-and-forth (2026-10-29)
/// - `-HQDemoIdle` [idle] a bot left alone for ten days: scheduled runs and background updates, one a day (2026-11-10)
/// - `-HQDemoRestated` Hermes's chat with a request it restated after compressing the chat (2026-10-30)
/// - `-HQDemoShot <name>` the window as tmp/<name>.png 8 s after the chat opens
/// - `-HQDemoPage <path>` (`-HQDemoOpenPage` opens it) Otto's reply with a `::preview` page card for the HTML file at <path> on this Mac (2026-10-31)
/// - `-HQDemoWideTable` [wide-tables] a reply with a three-column table of long rows (tester 2026-11-06)
/// - `-HQDemoDrafts` [drafts] two replies that each hold a draft card (a Slack message, a long email)
/// - `-HQDemoLinks` [mac-audit] short plain replies and two bare links (one page without a title)
enum ChatDemo {
    /// `-HQDemoPage`: a media context whose files are read from this Mac's disk (`MediaLoader.file`).
    static var pageContext: MediaContext? {
        argument("-HQDemoPage") == nil ? nil : MediaContext(accountId: MediaContext.demoAccount, profile: "default")
    }

    static func makeRoot(count: Int) -> UIViewController {
        let list = ChatDemoListViewController(count: count)
        let nav = UINavigationController(rootViewController: list)
        nav.navigationBar.prefersLargeTitles = true
        return nav
    }

    static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func flag(_ name: String) -> Bool { ProcessInfo.processInfo.arguments.contains(name) }
}

final class BlankProbeViewController: UIViewController {
    private var logged = false
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = .systemBackground; ChatPerf.mark("blank.viewDidLoad") }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); ChatPerf.mark("blank.viewWillAppear") }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !logged { logged = true; ChatPerf.firstContentLaidOut() }
    }
}

final class ChatDemoListViewController: UITableViewController {
    private let count: Int
    private var entries: [(String, Int)] { [(ChatDemo.flag("-HQDemoBotTalk") ? "Inbox" : "Hermes", count), ("Short chat", 12), ("Empty chat", 0), ("Other bot", 12)] }

    init(count: Int) {
        self.count = count
        super.init(style: .insetGrouped)
        title = "Bots"
        navigationItem.backButtonDisplayMode = .minimal
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !prewarmed && !ChatDemo.flag("-HQDemoNoPrewarm") {
            prewarmed = true
            let t = CACurrentMediaTime()
            ChatViewController.prewarm()
            print(String(format: "[ChatPerf] prewarm (main part) %.1f ms", (CACurrentMediaTime() - t) * 1000))
        }
        if ChatDemo.flag("-HQDemoAutoOpen"), presentedChatOnce == false {
            presentedChatOnce = true
            let index = ChatDemo.argument("-HQDemoOpenIndex").flatMap(Int.init) ?? 0
            // After the idle prewarm (0.6 s), as a person's first tap would be.
            let delay = ChatDemo.argument("-HQDemoOpenDelay").flatMap(Double.init) ?? 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.open(min(max(0, index), self.entries.count - 1), touch: false) }
        }
    }

    private var presentedChatOnce = false
    private var prewarmed = false

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = entries[indexPath.row].0
        content.secondaryText = "\(entries[indexPath.row].1) messages"
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        open(indexPath.row, touch: true)
    }

    private var openedNext = false
    func openOnce(_ index: Int) {
        guard !openedNext else { return }
        openedNext = true
        open(min(max(0, index), entries.count - 1), touch: false)
    }

    private var reopened = false
    func reopen() {
        guard !reopened else { return }
        reopened = true
        open(0, touch: true)
    }

    private func open(_ index: Int, touch: Bool) {
        if ChatDemo.flag("-HQDemoBlankFirst") && !reopened {
            // Experiment: the cost of a first push of a plain view controller.
            ChatPerf.pushStart = CACurrentMediaTime()
            let blank = BlankProbeViewController()
            navigationController?.pushViewController(blank, animated: true)
            return
        }
        let entry = entries[index]
        if touch { Haptics.play(.soft) }
        ChatPerf.pushStart = CACurrentMediaTime()
        ChatPerf.mark("demo.push.start")
        let initial = ChatDemo.argument("-HQDemoInitial").flatMap(Int.init)
        let session = FakeChatSession(count: entry.1, initial: initial, title: entry.0, long: ChatDemo.flag("-HQDemoLong") && index == 0,
                                      textPrefix: index == 3 ? "OTHER BOT: " : nil)
        session.fastStream = ChatDemo.flag("-HQDemoFastStream")
        ChatPerf.mark("demo.session.made")
        if ChatDemo.flag("-HQDemoBotTalk") { FakeChatSession.botTalkRoster() }
        if ChatDemo.flag("-HQDemoBotExchange") || ChatDemo.flag("-HQDemoRestated") { FakeChatSession.botExchangeRoster() }
        let chat = ChatViewController(session: session)
        // MENUS (spec 1x §4.2): the demo chat isn't live, so ⋯ holds Share and Info only.
        ChatMenus.install(on: chat, account: nil) { [weak chat] in
            guard let chat else { return }
            chat.present(ChatInfoSheet.make(model: chat.session, account: nil, modelName: "hermes-4"), animated: true)
        }
        navigationController?.pushViewController(chat, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Self.afterOpen(chat) }
    }

    private static var thenOpened = false

    private static func afterOpen(_ chat: ChatViewController) {
        if let up = ChatDemo.argument("-HQDemoScrollUp").flatMap(Double.init) {
            chat.debugScroll(by: CGFloat(up))
        }
        if ChatDemo.flag("-HQDemoExpandTools") {
            chat.debugExpandNewestTools()
        }
        if ChatDemo.flag("-HQDemoOpenGroups") {   // [updates]
            chat.debugOpenGroups(member: ChatDemo.argument("-HQDemoOpenMember").flatMap(Int.init))
        }
        // Sheets (screenshots): -HQDemoInfoSheet, -HQDemoStepSheet (the newest tool call, with a demo detail).
        if ChatDemo.flag("-HQDemoInfoSheet") {
            chat.present(ChatInfoSheet.make(model: chat.session, account: nil, modelName: "hermes-4"), animated: true)
        }
        if ChatDemo.flag("-HQDemoStepSheet"), let call = chat.session.messages.reversed().lazy.compactMap({ m in
            m.parts.lazy.compactMap { part -> ToolCall? in if case .tool(let c) = part { return c } else { return nil } }.first
        }).first {
            var detail = ToolDetail()
            detail.command = "git log v2.3..HEAD --oneline"
            detail.stdout = "a41f2c9 Export chats as Markdown or JSON\nb22e1d0 Faster sync on reconnect\nc11d0e9 Fix the jump arrow\nd00c9f8 Tidy the composer"
            detail.exitCode = 0
            chat.present(ChatStepSheet.make(title: "Ran git log", call: call, detail: detail), animated: true)
        }
        if ChatDemo.flag("-HQDemoFootprint") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                print(String(format: "[ChatPerf] footprint %.0f MB, table rows %d", ChatPerf.footprintMB(), chat.debugCounts.shown))
            }
        }
        if ChatDemo.flag("-HQDemoOpenPage"), let path = ChatDemo.argument("-HQDemoPage"),
           let url = MarkdownMedia.linkURL(MediaRef(kind: .file, attachment: MessageAttachment(kind: .file, source: .gateway(path: path), name: (path as NSString).lastPathComponent), label: "")) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { _ = chat.openMediaLink(url) }   // the page card's tap
        }
        if let name = ChatDemo.argument("-HQDemoShot") {   // the window as a picture (the Mac's screen can't be recorded)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard let window = chat.view.window else { return }
                // An open sheet on its own (the Mac hosts sheets where the window's picture doesn't reach).
                var top: UIViewController? = chat
                while let next = top?.presentedViewController { top = next }
                let shot: UIView = top === chat ? window : (top?.view ?? window)
                let image = UIGraphicsImageRenderer(bounds: shot.bounds).image { _ in
                    _ = shot.drawHierarchy(in: shot.bounds, afterScreenUpdates: true)
                }
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(name).png")
                try? image.pngData()?.write(to: url)
                print("[HQDemoShot] \(url.path)")
                // The Mac app's folder is closed to scripts: `-HQDemoShotPost <url>` sends the picture to a listener.
                if let post = ChatDemo.argument("-HQDemoShotPost").flatMap(URL.init(string:)), let data = image.pngData() {
                    var request = URLRequest(url: post.appending(path: "\(name).png"))
                    request.httpMethod = "POST"
                    URLSession.shared.uploadTask(with: request, from: data).resume()
                }
            }
        }
        if ChatDemo.flag("-HQDemoFocusComposer") { chat.focusComposer() }
        if let after = ChatDemo.argument("-HQDemoFocusAfter").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { chat.focusComposer() }
        }
        if let after = ChatDemo.argument("-HQDemoDismissAfter").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { chat.view.endEditing(true) }
        }
        if ChatDemo.flag("-HQDemoTraceScroll") {
            // Where the newest reply's first row sits on screen, twice a second (keyboard checks).
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { if let top = chat.debugAnchorRowTop { print(String(format: "[Scroll] anchor row top %.1f", top)) } }
            }
        }
        if let text = ChatDemo.argument("-HQDemoSend") {
            chat.composer.text = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { chat.debugSendComposer() }
            // -HQDemoStopAfter <s>: Stop that long after the send (0.5 s: before the reply's first token).
            if let after = ChatDemo.argument("-HQDemoStopAfter").flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + after) { chat.session.stop() }
            }
        }
        if let next = ChatDemo.argument("-HQDemoThenOpen").flatMap(Int.init), !thenOpened, let nav = chat.navigationController,
           let list = nav.viewControllers.first as? ChatDemoListViewController {
            thenOpened = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                nav.popViewController(animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { list.openOnce(next) }
            }
        }
        if ChatDemo.flag("-HQDemoReopen"), let nav = chat.navigationController, let list = nav.viewControllers.first as? ChatDemoListViewController {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                nav.popViewController(animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { list.reopen() }
            }
        }
        if ChatDemo.flag("-HQDemoReset"), let fake = chat.session as? FakeChatSession {
            let after = ChatDemo.argument("-HQDemoResetAfter").flatMap(Double.init) ?? 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { fake.debugReset() }
        }
        if ChatDemo.flag("-HQDemoAutoScroll") {
            let speed = ChatDemo.argument("-HQDemoScrollSpeed").flatMap(Double.init) ?? 4000
            let seconds = ChatDemo.argument("-HQDemoScrollSeconds").flatMap(Double.init) ?? 12
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                ChatScrollProbe(chat: chat, speed: CGFloat(speed), legSeconds: seconds).start()
            }
        }
    }
}
#endif

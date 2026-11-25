#if DEBUG
import ImageIO
import UIKit

/// DEBUG harness: `-HQDemoChat <N>` launches into a plain list that pushes a chat with N generated messages, so the
/// push, the scroll and the composer can be judged without a gateway.
///
/// Other launch arguments:
/// - `-HQDemoAutoOpen` push the chat 1.2 s after launch (`-HQDemoOpenDelay <s>` to change)
/// - `-HQDemoFocusComposer` focus the composer once open (keyboard up); `-HQDemoFocusAfter <s>` /
///   `-HQDemoDismissAfter <s>` focus it / dismiss the keyboard that long after opening
/// - `-HQDemoScrollUp <points>` scroll that far up from the newest end once open (`-HQDemoScrollAfter <s>`: later)
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
///   2026-10-28 screenshots); `-HQDemoOpenGroups` opens the newest grouped line's sheet (`-HQDemoOpenGroup <n>` the
///   n-th newest), `-HQDemoOpenMember <n>` at its n-th member (1 = the top one); `-HQDemoBotExchange` Hermes and Home's back-and-forth (2026-10-29)
/// - `-HQDemoIdle` [idle] a bot left alone for ten days: scheduled runs and background updates, one a day (2026-11-10)
/// - `-HQDemoWorkFold` [files] a long turn of wordless replies that each changed files, between helpers' deliveries (2026-11-10)
/// - `-HQDemoRestated` Hermes's chat with a request it restated after compressing the chat (2026-10-30)
/// - `-HQDemoShot <name>` the window as tmp/<name>.png 8 s after the chat opens
/// - `-HQDemoPage <path>` (`-HQDemoOpenPage` opens it) Otto's reply with a `::preview` page card for the HTML file at <path> on this Mac (2026-10-31)
/// - `-HQDemoWideTable` [wide-tables] a reply with a three-column table of long rows (tester 2026-11-06)
/// - `-HQDemoDrafts` [drafts] two replies that each hold a draft card (a Slack message, a long email)
/// - `-HQDemoSkippedQuestion` [questions] a question that went unanswered, then the reply waiting on it (Answer Now);
///   `-HQDemoAnswerNow` taps Answer Now, `-HQDemoAnswerSend <text>` sends that answer
/// - `-HQDemoShopping` [shopping] replies with 1, 2, 5 and 12 product cards, then an order card;
///   `-HQDemoShoppingOpen <n>` opens the n-th product's page (`-HQDemoShoppingPageScroll <points>` scrolls it),
///   `-HQDemoOrderState waiting|approved|cancelled|replaced`, `-HQDemoShoppingShow <row id prefix>` scrolls that
///   row near the top (shop-a1|shop the one product, shop-a2|shop the pair, shop-a5|order the order card),
///   `-HQDemoShoppingShowTop <points>` puts its top there instead of 110 pt down (negative: above the screen),
///   `-HQDemoShoppingExpand` opens the twelve's "7 more"
/// - `-HQDemoAskCard` [asks] a reply that ends with an ask-to-act card; `-HQDemoAskState waiting|answered|other|sent`
///   adds your answer after it; `-HQDemoAskOther` taps its "Something else…" (`-HQDemoAskOtherText <words>` types them);
///   `-HQDemoAskPick <n>` picks choice n (1-based), showing its ready reply
/// - `-HQDemoLinks` [mac-audit] short plain replies and two bare links (one page without a title)
/// - `-HQDemoThreads [later]` [threads] a bot's chat with threads (Threads/ThreadsDemo.swift lists its flags);
///   `-HQDemoDraft <text>` leaves words typed once `-HQDemoSend`'s message is out
/// - `-HQDemoVoiceRecord` [voice record] a chat that ends with a live voice chat's line (`-HQDemoVoiceRecordOpen` opens it)
/// - `-HQDemoPhotos <folder>` [photo-grid] messages made from the pictures in <folder> on this Mac: `<set>-<n>.png`
///   files are one message per set, in name order; a set whose name starts with "me" is yours, any other the bot's,
///   and `<set>.txt` beside them is its words (2026-11-16)
enum ChatDemo {
    /// `-HQDemoPage`, `-HQDemoPhotos`: a media context whose files are read from this Mac's disk (`MediaLoader`).
    static var pageContext: MediaContext? {
        argument("-HQDemoPage") == nil && argument("-HQDemoPhotos") == nil ? nil
            : MediaContext(accountId: MediaContext.demoAccount, profile: "default")
    }

    /// `-HQDemoPhotos`: the folder's sets, in name order (each set's pictures in name order, and its words).
    static let photoSets: [(name: String, mine: Bool, files: [String], words: String)] = {
        guard var folder = argument("-HQDemoPhotos") else { return [] }
        if folder == "generated" { folder = generatedPhotos() }   // [Mac AAA 2026-11-16] the sandboxed Mac app can't read a folder of ours
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        var sets: [String: [String]] = [:]
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "heic"].contains(ext), let dash = name.lastIndex(of: "-") else { continue }
            sets[String(name[..<dash]), default: []].append((folder as NSString).appendingPathComponent(name))
        }
        return sets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            let words = (try? String(contentsOfFile: (folder as NSString).appendingPathComponent(key + ".txt"), encoding: .utf8)) ?? ""
            return (key, key.hasPrefix("me"), sets[key] ?? [], words.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }()

    /// `-HQDemoPhotos generated`: drawn stand-in photos in the app's own temporary folder (a bot's single photo, a
    /// bot's two, your three with words, a bot's six with words, your four), so a sandboxed Mac build can show them.
    private static func generatedPhotos() -> String {
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("demo-photos")
        try? FileManager.default.removeItem(atPath: folder)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let sets: [(String, [CGSize], String?)] = [
            ("a1", [CGSize(width: 1600, height: 1200)], "Here is the view from the deck."),
            ("b2", [CGSize(width: 1200, height: 1600), CGSize(width: 1200, height: 1600)], nil),
            // [Mac AAA 2026-11-17] Q4: a bot's photo alone, your tall photo alone (the demo's replies never learn their
            // pictures' sizes, yours carry them), your photo with words.
            ("c1", [CGSize(width: 1600, height: 1200)], nil),
            ("me1", [CGSize(width: 1000, height: 2000)], nil),
            ("me2", [CGSize(width: 1600, height: 1000)], "Sunset from the pier"),
            ("me3", Array(repeating: CGSize(width: 1600, height: 1200), count: 3), "Three from the trip"),
            ("p4", (0..<6).map { CGSize(width: 1400, height: $0 % 2 == 0 ? 1000 : 1400) }, "All six from the walk."),
            ("me5", Array(repeating: CGSize(width: 1200, height: 1200), count: 4), nil),
        ]
        for (setIndex, (key, sizes, words)) in sets.enumerated() {
            for (i, size) in sizes.enumerated() {
                let hue = CGFloat((setIndex * 5 + i) % 12) / 12
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    let colors = [UIColor(hue: hue, saturation: 0.55, brightness: 0.9, alpha: 1).cgColor,
                                  UIColor(hue: hue + 0.08, saturation: 0.6, brightness: 0.45, alpha: 1).cgColor] as CFArray
                    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                        context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                    }
                    UIColor(white: 0.97, alpha: 1).setFill()
                    UIBezierPath(ovalIn: CGRect(x: size.width * 0.3, y: size.height * 0.25, width: size.width * 0.4, height: size.height * 0.4)).fill()
                }
                try? image.pngData()?.write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent("\(key)-\(i + 1).png")))
            }
            if let words { try? words.write(toFile: (folder as NSString).appendingPathComponent(key + ".txt"), atomically: true, encoding: .utf8) }
        }
        return folder
    }

    /// `-HQDemoPhotos`: your messages' photos by message id (a reply's are `MEDIA:` lines in its words).
    static let photoAttachments: [String: [MessageAttachment]] = {
        var out: [String: [MessageAttachment]] = [:]
        for set in photoSets where set.mine {
            out["ph-" + set.name] = set.files.map { path in
                var a = MessageAttachment(kind: .image, source: .gateway(path: path), name: (path as NSString).lastPathComponent)
                if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                   let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    a.pixelWidth = info[kCGImagePropertyPixelWidth] as? Int
                    a.pixelHeight = info[kCGImagePropertyPixelHeight] as? Int
                }
                return a
            }
        }
        return out
    }()

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
        let sessionTitle = (index == 2 && ChatDemo.argument("-HQDemoProject") != nil) ? "New Chat" : entry.0
        let session = FakeChatSession(count: entry.1, initial: initial, title: sessionTitle, long: ChatDemo.flag("-HQDemoLong") && index == 0,
                                      textPrefix: index == 3 ? "OTHER BOT: " : nil)
        session.fastStream = ChatDemo.flag("-HQDemoFastStream")
        ChatPerf.mark("demo.session.made")
        if ChatDemo.flag("-HQDemoBotTalk") { FakeChatSession.botTalkRoster() }
        if ChatDemo.flag("-HQDemoBotExchange") || ChatDemo.flag("-HQDemoRestated") { FakeChatSession.botExchangeRoster() }
        let chat = ChatViewController(session: session)
        if let project = ChatDemo.argument("-HQDemoProject"), !project.isEmpty {
            let color = ChatDemo.argument("-HQDemoProjectColor").flatMap(Int.init).map { SessionsOrganizer.uiColor($0) }
            chat.sessionProject = ChatProjectBadge(name: project, emoji: ChatDemo.argument("-HQDemoProjectEmoji"), color: color)
        }
        // MENUS (spec 1x §4.2): the demo chat isn't live, so ⋯ holds Share and Info only.
        ChatMenus.install(on: chat, account: nil) { [weak chat] in
            guard let chat else { return }
            chat.present(ChatInfoSheet.make(model: chat.session, account: nil, modelName: "hermes-4"), animated: true)
        }
        ChatDemo.installThreads(on: chat)   // [threads] -HQDemoThreads
        navigationController?.pushViewController(chat, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Self.afterOpen(chat) }
    }

    private static var thenOpened = false
    private static var resized = false

    private static func afterOpen(_ chat: ChatViewController) {
        #if targetEnvironment(macCatalyst)
        // [Mac AAA 2026-11-17] `-HQDemoWindowWidth <points>`: the window that wide (as far as its smallest size lets
        // it), to see the chat's rows in a narrow column; the scroll waits for the new width.
        if let width = ChatDemo.argument("-HQDemoWindowWidth").flatMap(Double.init), let scene = chat.view.window?.windowScene,
           !resized {
            resized = true
            scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 80, y: 60, width: width, height: 800))) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Self.afterOpen(chat) }
            return
        }
        #endif
        if let up = ChatDemo.argument("-HQDemoScrollUp").flatMap(Double.init) {
            // [Mac AAA 2026-11-17] `-HQDemoScrollAfter <s>`: that much later (after `-HQDemoSend`'s message is in), so
            // your newest message passes under the message box.
            let after = ChatDemo.argument("-HQDemoScrollAfter").flatMap(Double.init) ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { chat.debugScroll(by: CGFloat(up)) }
        }
        if ChatDemo.flag("-HQDemoExpandTools") {
            chat.debugExpandNewestTools()
        }
        if ChatDemo.flag("-HQDemoVoiceRecordOpen") { chat.debugOpenVoiceRecords() }   // [voice record]
        if ChatDemo.flag("-HQDemoShoppingExpand"), let list = chat.rows.first(where: { $0.id.hasPrefix("shop-a4|shop") }) {
            chat.draftCardToggle(rowId: list.id)   // [shopping] the twelve's "7 more", as tapped
        }
        if let row = ChatDemo.argument("-HQDemoShoppingShow") {   // [shopping] e.g. shop-a1|shop: that row near the top
            let top = ChatDemo.argument("-HQDemoShoppingShowTop").flatMap(Double.init).map { CGFloat($0) } ?? 110
            chat.debugScrollToRow(prefix: row, top: top)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { chat.debugScrollToRow(prefix: row, top: top) }   // after late measures
        }
        if let n = ChatDemo.argument("-HQDemoShoppingOpen").flatMap(Int.init) {   // [shopping]
            let after: Double = ChatDemo.argument("-HQDemoShoppingBuy") == nil ? 1 : 3   // after a demo Buy has landed
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { chat.debugOpenProduct(n) }
        }
        if let n = ChatDemo.argument("-HQDemoShoppingBuy").flatMap(Int.init) {   // [shopping] the n-th product's Buy, as tapped
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { chat.debugOpenProduct(n, buy: true) }
        }
        if ChatDemo.flag("-HQDemoAskOther") {   // [asks] the card's "Something else…", as tapped
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { chat.debugAskOther(typing: ChatDemo.argument("-HQDemoAskOtherText")) }
        }
        if let n = ChatDemo.argument("-HQDemoAskPick").flatMap(Int.init) {   // [asks v2] choice n picked (its ready reply shows)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { chat.debugAskPick(n) }
        }
        if ChatDemo.flag("-HQDemoOpenGroups") {   // [updates]
            chat.debugOpenGroups(group: ChatDemo.argument("-HQDemoOpenGroup").flatMap(Int.init),
                                 member: ChatDemo.argument("-HQDemoOpenMember").flatMap(Int.init))
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
        // [questions] -HQDemoAnswerNow: Answer Now on the newest question card that has a blank; -HQDemoAnswerSend <text>:
        // its Send with that answer (as a pick and Send would).
        if ChatDemo.flag("-HQDemoAnswerNow") || ChatDemo.argument("-HQDemoAnswerSend") != nil,
           let found = chat.session.messages.reversed().lazy.compactMap({ m -> (ChatMessage, [ClarifyQA])? in
               for case .tool(let c) in m.parts where c.name == "clarify" {
                   if let rows = ClarifySettled.rows(fromSummary: c.summary), !rows.isEmpty { return (m, rows) }
               }
               return nil
           }).first {
            let (message, rows) = found
            let card = SettledClarifyCard(rows: rows, key: ClarifyLate.key(rows.map(\.question)), messageId: message.id,
                                          answerable: true, answeredLater: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let answer = ChatDemo.argument("-HQDemoAnswerSend") {
                    let open = rows.filter { $0.answer.isEmpty }.map { (question: $0.question, answer: answer) }
                    chat.sendLateAnswer(ClarifyLate.message(key: card.key, answers: open), messageId: message.id)
                } else {
                    chat.clarifyCardAnswer(card)
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
            // [threads] -HQDemoDraft <text>: words left typed in the field once the send is out (with -HQDemoHoldStep:
            // a reply running and words typed, the state the thread button shows in).
            if let draft = ChatDemo.argument("-HQDemoDraft") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { chat.composer.text = draft }
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

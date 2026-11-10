import UIKit

// The step sheet, made complete (docs/spec/1x-activity.md §12): "Terminal" or the step's title, a subtitle, a coloured
// diff, sections paged 20,000 characters at a time, server-side output paged through the performance plugin, Copy; and
// the Steps sheet of In Header and Show Steps (§10.4), whose rows push the step inside the same sheet. Both are system
// sheets in `ChatSheet.wrap` (spec 06 §8.8).

/// Reads a tool row's full output through the performance plugin (spec 03 §2.4). Off the main actor: Copy's whole
/// output can be up to 8 MiB of JSON to parse.
nonisolated struct StepOutputSource: Sendable {
    var client: any GatewayClient
    var routeName: String
    var ref: JSONValue

    private var base: String? {
        guard let sid = ref["session_id"]?.string, let row = ref["row_id"]?.int else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let s = sid.addingPercentEncoding(withAllowedCharacters: allowed) ?? sid
        return "/api/plugins/\(routeName)/sessions/\(s)/messages/\(row)/content"
    }

    private var profileQuery: [URLQueryItem] {
        ref["profile"]?.string.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
    }

    enum Failure: Error, Equatable {
        /// The row or its session is gone (a 404 the plugin answered).
        case gone
        /// No plugin route (FastAPI's own `{"detail":"Not Found"}`) or no compatible adapter (503).
        case unavailable
        case failed
        case tooLarge
        /// The plugin refused this output with its own words (422, e.g. binary control data).
        case refused(String)
    }

    struct Page: Sendable { var text: String; var offset: Int; var total: Int?; var nextOffset: Int? }

    /// The plugin's answer for a failed read (`plugin_api.py`: 404 "Tool content not found", 413, 422, 503).
    static func failure(_ error: HTTPError) -> Failure {
        let detail = error.body.flatMap { ChatJSON.parse(string: $0) }?["detail"]
        switch error.status {
        case 503: return .unavailable
        case 404: return detail?.string == "Not Found" ? .unavailable : .gone
        case 413: return .tooLarge
        case 422:
            let words = detail?["message"]?.string ?? detail?.string
            return words.map { .refused($0) } ?? .failed
        default: return .failed
        }
    }

    @concurrent func page(offset: Int) async throws -> Page {
        guard let base else { throw Failure.unavailable }
        do {
            let data = try await client.rest("GET", base + "/preview", query: profileQuery + [
                URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "max_chars", value: "20000"),
            ], body: nil)
            let json = try JSONValue.parse(data)
            guard json["schema"]?.string == "tool.preview.v1", let content = json["content"]?.string else { throw Failure.failed }
            return Page(text: content, offset: json["offset"]?.int ?? offset, total: json["total_chars"]?.int,
                        nextOffset: json["next_offset"]?.int)
        } catch let error as HTTPError {
            throw Self.failure(error)
        }
    }

    /// The whole output for Copy (≤ 8 MiB; 413 → too large). Rows stored as JSON come back decoded (an object or a
    /// list, `parseToolContent`): those are copied as pretty JSON.
    @concurrent func full() async throws -> String {
        guard let base else { throw Failure.unavailable }
        do {
            let data = try await client.rest("GET", base, query: profileQuery, body: nil)
            guard case .object(let row) = try JSONValue.parse(data), let content = row["content"] else { throw Failure.failed }
            switch content {
            case .string(let text): return text
            case .null: return ""
            default: return ChatJSON.stringifyPretty(content)
            }
        } catch let error as HTTPError {
            throw Self.failure(error)
        }
    }
}

// MARK: - Step detail

final class StepDetailViewController: UIViewController {
    private let call: ToolCall
    private var detail: ToolDetail?
    private let source: StepOutputSource?
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var serverBlock: PagedTextBlock?
    private var serverPages: [Int] = [0]        // offsets of the pages seen (Previous goes back)
    private var serverPageIndex = 0
    private var serverNext: Int?
    private var serverTotal: Int?
    private var serverText: String?

    /// `detail` updates in place when the fresh detail arrives (a cached head first, §12 item 7).
    var detailProvider: (() -> ToolDetail?)?
    /// [screen] What a computer_use / browser step's screenshot loads with (docs/spec/3x-screen.md §5.3).
    var screenshotContext: StepScreenshotBlock.Context?
    private var screenshotExpired = false

    init(call: ToolCall, detail: ToolDetail?, source: StepOutputSource?) {
        self.call = call
        self.detail = detail
        self.source = source
        super.init(nibName: nil, bundle: nil)
        title = Self.title(call)
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func isTerminal(_ call: ToolCall) -> Bool { call.name == "terminal" || call.name == "execute_code" }

    /// `tool_describe`: the tools the bot read about, one per line in words ("google docs drive createFolder"), in
    /// the Input's place; its JSON said nothing a person reads (tester 2026-11-07). Nil for any other call.
    static func describedTools(_ call: ToolCall, args: [String: JSONValue]) -> String? {
        guard call.name.trimmingCharacters(in: .whitespaces) == "tool_describe" else { return nil }
        let raw = args["names"] ?? args["name"] ?? args["tool"] ?? args["tools"] ?? args["tool_name"]
        let names = (raw?.array?.compactMap(\.string) ?? raw?.string.map { [$0] } ?? [])
            .map(ToolWords.toolWords).filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: "\n")
    }

    /// "Terminal" for a command; else the step's own title ("Edited app.ts", "Ran 1 command").
    static func title(_ call: ToolCall) -> String {
        isTerminal(call) ? "Terminal" : ChatRunSummary.summarize([call], live: call.state == .running)
    }

    static func meta(_ call: ToolCall, detail: ToolDetail?) -> String? {
        if isTerminal(call), let code = detail?.exitCode, code != 0 { return "Exit \(code)" }
        if call.state == .failed { return "Failed" }
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.sheetPage
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])
        build()
        if detail?.payloadRef != nil, source != nil { loadServerPage(offset: 0) }
    }

    /// The fresh detail arrived: redraw in place.
    func refresh() {
        guard let fresh = detailProvider?(), fresh != detail else { return }
        detail = fresh
        build()
    }

    private func build() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        // The bar holds the title ("Terminal" or the step's own words); a command's step names itself under it.
        let args = ChatRunSummary.args(call)
        let stepTitle = ChatRunSummary.summarize([call], live: call.state == .running)
        if Self.isTerminal(call) {
            let heading = ShelfText.label(HQFont.preferred(.headline))
            heading.text = stepTitle
            stack.addArrangedSubview(heading)
        }
        // Subtitle: a file edit's full path when it differs from the title, then the meta.
        var subtitle: [String] = []
        if ChatRunSummary.isFileEdit(call.name) {
            let path = ChatRunSummary.firstString(args, ["path", "file", "filepath"])
            if !path.isEmpty, path != stepTitle { subtitle.append(path) }
        }
        if let meta = Self.meta(call, detail: detail) { subtitle.append(meta) }
        if !subtitle.isEmpty {
            let sub = ShelfText.label(HQFont.preferred(.footnote), color: call.state == .failed ? ChatPalette.red : ChatPalette.label2)
            sub.text = subtitle.joined(separator: " · ")
            sub.accessibilityIdentifier = "step.subtitle"
            stack.addArrangedSubview(sub)
        }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(16, after: last) }
        // [screen] The step's screenshot, or the note that the gateway no longer has it.
        if let shot = detail?.screenshot, let screenshotContext {
            let block = StepScreenshotBlock(shot: shot, toolCallId: call.id, context: screenshotContext,
                                            expired: screenshotExpired) { [weak self] in
                guard let self, !screenshotExpired else { return }
                screenshotExpired = true
                build()
            }
            stack.addArrangedSubview(block)
            stack.setCustomSpacing(18, after: block)
        }
        let gone = screenshotExpired || detail?.screenshot?.expired == true      // [screen] the Output starts with the note

        // The diff first (a file edit, ≤ 20,000 characters).
        let diff = detail?.inlineDiff.map(StepRules.stripChrome) ?? ""
        let isEdit = ChatRunSummary.isFileEdit(call.name)
        if !diff.isEmpty, diff.count <= StepRules.pageSize {
            addLabel("Changes")
            stack.addArrangedSubview(DiffPanel(lines: StepRules.diffLines(diff)))
            stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)
        } else if !diff.isEmpty {
            addSection("Changes", diff)
        }
        // Command or Input.
        if Self.isTerminal(call) {
            addSection("Command", detail?.command ?? ChatRunSummary.firstString(args, ["command", "code"]))
        } else if let tools = Self.describedTools(call, args: args) {
            addSection("Tools", tools)
        } else if !isEdit {
            addSection("Input", detail?.input ?? call.argsText)
        }
        // Output: the server's pages, else the detail's sections.
        if detail?.payloadRef != nil, source != nil {
            addLabel("Output")
            let block = PagedTextBlock(text: serverText ?? "Loading output…", mono: serverText != nil)
            block.onPrevious = { [weak self] in self?.serverPrevious() }
            block.onNext = { [weak self] in self?.serverNextPage() }
            block.onRetry = { [weak self] in self?.loadServerPage(offset: self?.serverPages.last ?? 0) }
            serverBlock = block
            stack.addArrangedSubview(block)
            stack.setCustomSpacing(18, after: block)
            updateServerPager()
        } else if let detail {
            if detail.stdout != nil || detail.stderr != nil {
                addSection("Output", detail.stdout)
                addSection("Error output", detail.stderr)
            } else if !(isEdit && !diff.isEmpty) {
                let text = detail.errorText ?? detail.detail ?? call.summary
                addSection(call.state == .failed ? "Error" : "Output", gone ? ToolScreenshots.expiredOutput(text) : text)   // [screen]
            }
            if Self.isTerminal(call), let code = detail.exitCode, code != 0 { addSection("Exit code", String(code), mono: false) }
        } else {
            addSection(call.state == .failed ? "Error" : "Output", call.summary)
        }
        // The tool cards' words ("12m 34s"), not "754.3 s".
        if let d = call.durationSeconds, !ToolCards.formatDurationSeconds(d).isEmpty {
            addSection("Duration", ToolCards.formatDurationSeconds(d), mono: false)
        }
        if !stack.arrangedSubviews.contains(where: { $0 is PagedTextBlock || $0 is DiffPanel }) {
            addSection("Details", "No details for this step.", mono: false)
        }
        if detail?.isCacheCopy == true {
            let note = ShelfText.label(HQFont.preferred(.footnote), color: ChatPalette.label2)
            note.text = "Showing the start. The rest loads when the chat finishes opening."
            stack.addArrangedSubview(note)
        }
        // Copy.
        var config = UIButton.Configuration.hqSheetAction()   // [glass-design] solid like the cards, not glass on the glass
        config.title = "Copy"
        config.image = UIImage(systemName: "doc.on.doc")
        config.imagePadding = 6
        let copy = UIButton(configuration: config, primaryAction: UIAction { [weak self] action in self?.copyAll(action.sender as? UIButton) })
        copy.accessibilityIdentifier = "sheet.copy"
        let row = UIStackView(arrangedSubviews: [copy, UIView()])
        stack.addArrangedSubview(row)
    }

    private func addLabel(_ text: String) {
        let label = ShelfText.label(HQFont.preferred(.footnote), color: ChatPalette.label2)
        label.text = text
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(6, after: label)
    }

    private func addSection(_ name: String, _ value: String?, mono: Bool = true) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let bare = value.filter { !$0.isWhitespace }
        if bare == "{}" || bare == "[]" { return }
        addLabel(name)
        let block = PagedTextBlock(text: value, mono: mono)
        stack.addArrangedSubview(block)
        stack.setCustomSpacing(18, after: block)
    }

    // MARK: Server output

    private func loadServerPage(offset: Int) {
        guard let source else { return }
        serverBlock?.setBusy(true)
        Task { [weak self] in
            do {
                let page = try await source.page(offset: offset)
                guard let self else { return }
                self.serverText = page.text
                self.serverNext = page.nextOffset
                self.serverTotal = page.total
                if let i = self.serverPages.firstIndex(of: offset) { self.serverPageIndex = i } else {
                    self.serverPages.append(offset)
                    self.serverPageIndex = self.serverPages.count - 1
                }
                self.serverBlock?.setText(page.text, mono: true)
                self.updateServerPager()
            } catch let failure as StepOutputSource.Failure {
                guard let self else { return }
                switch failure {
                case .gone: self.serverBlock?.setText("This output is no longer available.", mono: false)
                case .unavailable: self.serverBlock?.setText("This version of Hermes can’t page the output. Copy gets all of it.", mono: false)
                case .refused(let words): self.serverBlock?.setText(words, mono: false)
                default: self.serverBlock?.showRetry("Couldn’t load this page. \(DeviceWord.Tap) to retry.")
                }
            } catch {
                self?.serverBlock?.showRetry("Couldn’t load this page. \(DeviceWord.Tap) to retry.")
            }
        }
    }

    private func updateServerPager() {
        guard let total = serverTotal, total > StepRules.pageSize else { serverBlock?.setPager(nil); return }
        let pages = Int((Double(total) / Double(StepRules.pageSize)).rounded(.up))
        let current = min(pages, (serverPages[serverPageIndex] / StepRules.pageSize) + 1)
        serverBlock?.setPager((current: current, count: pages, previous: serverPageIndex > 0, next: serverNext != nil))
    }

    private func serverPrevious() {
        guard serverPageIndex > 0 else { return }
        loadServerPage(offset: serverPages[serverPageIndex - 1])
    }

    private func serverNextPage() {
        guard let next = serverNext else { return }
        loadServerPage(offset: next)
    }

    // MARK: Copy

    private func copyAll(_ button: UIButton?) {
        var parts: [String] = []
        if let diff = detail?.inlineDiff.map(StepRules.stripChrome), !diff.isEmpty { parts.append(diff) }
        for case let block as PagedTextBlock in stack.arrangedSubviews where block !== serverBlock { parts.append(block.fullText) }
        func finish(_ extra: String?, note: String?) {
            var all = parts
            if let extra { all.append(extra) }
            UIPasteboard.general.string = all.joined(separator: "\n\n")
            Haptics.play(.success)
            var config = button?.configuration
            config?.title = note ?? "Copied"
            config?.image = UIImage(systemName: "checkmark")
            button?.configuration = config
        }
        guard detail?.payloadRef != nil, let source else { finish(nil, note: nil); return }
        Task {
            do {
                finish(try await source.full(), note: nil)
            } catch StepOutputSource.Failure.tooLarge {
                finish(serverText, note: "Output too large to copy in full")
            } catch {
                // The complete output wouldn't come: say that only the shown page went to the pasteboard.
                finish(serverText, note: "Copied what is shown")
            }
        }
    }
}

/// A labelled monospace block that pages text over 20,000 characters (Previous · N of M · Next, 44 pt buttons).
final class PagedTextBlock: UIView {
    private let body = UITextView()
    private let pager = UIStackView()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let position = UILabel()
    private let retry = UIButton(type: .system)
    private(set) var fullText: String
    private var page = 0
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onRetry: (() -> Void)?
    private var external = false

    init(text: String, mono: Bool) {
        fullText = text
        super.init(frame: .zero)
        backgroundColor = HQPalette.sheetCard   // [glass] frosted on a glass sheet, solid off it
        layer.cornerRadius = HQShape.radius(14, .card)
        layer.cornerCurve = .continuous
        hqGlassEdge()   // [glass-design] its thin edge on the glass
        body.isEditable = false
        body.isScrollEnabled = false
        body.backgroundColor = .clear
        body.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        body.textContainer.lineFragmentPadding = 0
        body.adjustsFontForContentSizeCategory = true
        body.textColor = ChatPalette.label
        previousButton.setTitle("Previous", for: .normal)
        nextButton.setTitle("Next", for: .normal)
        position.font = HQFont.preferred(.footnote)
        position.textColor = ChatPalette.label2
        position.textAlignment = .center
        previousButton.addAction(UIAction { [weak self] _ in self?.go(-1) }, for: .touchUpInside)
        nextButton.addAction(UIAction { [weak self] _ in self?.go(1) }, for: .touchUpInside)
        for b in [previousButton, nextButton] { b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true }
        pager.addArrangedSubview(previousButton)
        pager.addArrangedSubview(position)
        pager.addArrangedSubview(nextButton)
        pager.distribution = .equalSpacing
        pager.isLayoutMarginsRelativeArrangement = true
        pager.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 4, right: 12)
        retry.isHidden = true
        retry.titleLabel?.numberOfLines = 0
        retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        let column = UIStackView(arrangedSubviews: [body, retry, pager])
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setText(text, mono: mono)
        external = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setText(_ text: String, mono: Bool) {
        fullText = text
        retry.isHidden = true
        body.font = mono ? UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.mono(ofSize: 13, weight: .regular))
            : HQFont.preferred(.footnote)
        page = 0
        render()
    }

    func setBusy(_ busy: Bool) { body.alpha = busy ? 0.5 : 1 }

    func showRetry(_ text: String) {
        setBusy(false)
        retry.setTitle(text, for: .normal)
        retry.isHidden = false
    }

    /// Server-driven paging (the block shows one page the server gave).
    func setPager(_ state: (current: Int, count: Int, previous: Bool, next: Bool)?) {
        external = true
        setBusy(false)
        guard let state else { pager.isHidden = true; return }
        pager.isHidden = false
        position.text = "\(state.current) of \(state.count)"
        previousButton.isEnabled = state.previous
        nextButton.isEnabled = state.next
    }

    private func render() {
        let pages = StepRules.pages(fullText)
        body.text = pages > 1 ? StepRules.page(fullText, page) : fullText
        pager.isHidden = pages <= 1
        position.text = "\(page + 1) of \(pages)"
        previousButton.isEnabled = page > 0
        nextButton.isEnabled = page < pages - 1
    }

    private func go(_ delta: Int) {
        if external { delta < 0 ? onPrevious?() : onNext?(); return }
        page = max(0, min(StepRules.pages(fullText) - 1, page + delta))
        render()
    }
}

/// The coloured diff (§12 item 3): added lines on green 12 %, removed on red 12 %, monospace footnote, no wrapping,
/// scrolling sideways, radius 14 on the elevated cell colour.
final class DiffPanel: UIView {
    private let scroll = UIScrollView()
    private let column = UIStackView()
    /// The room under the last line: 8 pt, or the scroll bar's lane while the lines run past the panel (owner
    /// 2026-10-29: the bar sat on the last line on the Mac).
    private var bottomRoom: NSLayoutConstraint!
    /// The widest line's width (its font is fixed when the panel is made).
    private var natural: CGFloat = 0

    init(lines: [StepRules.DiffLine]) {
        super.init(frame: .zero)
        backgroundColor = HQPalette.sheetCard   // [glass] frosted on a glass sheet, solid off it
        layer.cornerRadius = HQShape.radius(14, .card)
        layer.cornerCurve = .continuous
        hqGlassEdge()   // [glass-design] its thin edge on the glass
        clipsToBounds = true
        accessibilityIdentifier = "step.diff"
        scroll.showsHorizontalScrollIndicator = true
        scroll.alwaysBounceHorizontal = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.mono(ofSize: 13, weight: .regular))
        for line in lines {
            let label = PaddedLabel()
            label.font = font
            label.text = line.text.isEmpty ? " " : line.text
            label.textColor = ChatPalette.label
            label.numberOfLines = 1
            switch line.kind {
            case .added:
                label.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.12)
                label.accessibilityLabel = "Added: \(line.text)"
            case .removed:
                label.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
                label.accessibilityLabel = "Removed: \(line.text)"
            case .context:
                label.backgroundColor = .clear
            }
            column.addArrangedSubview(label)
            natural = max(natural, label.intrinsicContentSize.width)
        }
        bottomRoom = column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            bottomRoom,
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            column.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor),
            scroll.frameLayoutGuide.heightAnchor.constraint(equalTo: scroll.contentLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let room = bounds.width > 0 && natural > bounds.width + 0.5 ? max(8, ScrollBarLane.height) : 8
        if bottomRoom.constant != -room { bottomRoom.constant = -room }
    }
}

/// A label with padding around its text: lines break at the padded width and are drawn inside it (a wrapping label
/// that only inset its drawing broke lines 24 pt too wide and clipped their ends).
final class PaddedLabel: UILabel {
    var padding = UIEdgeInsets(top: 1, left: 12, bottom: 1, right: 12) { didSet { invalidateIntrinsicContentSize() } }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let inner = super.textRect(forBounds: bounds.inset(by: padding), limitedToNumberOfLines: numberOfLines)
        return inner.inset(by: UIEdgeInsets(top: -padding.top, left: -padding.left, bottom: -padding.bottom, right: -padding.right))
    }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: padding)) }
}

// MARK: - Steps (In Header, Show Steps)

/// "Steps": the turn's tool calls as a timeline (live while it runs) — a badge per step on a rail down the leading
/// edge, and beside it the step's own card: its words, how long it took, its code; a card pushes its step sheet inside
/// the same sheet (DECISION: pages in one sheet, M:sheet-pages.md).
/// [glass-design] Owner 2026-11-01 ("the tool calls look bad with all of the Liquid Glass"): the steps were one solid
/// group the height of the sheet, so the glass showed only as a tinted rim around a grey slab. Each step is now its
/// own card with the glass between them, and the badges and rail stand on the glass.
final class StepsListViewController: UITableViewController {
    struct Step { var messageId: String; var call: ToolCall }
    private var steps: [Step]
    private let live: Bool
    var openStep: ((Step) -> UIViewController)?
    /// [mac-layout] The Mac inspector's narrow panel: smaller words, so a file path isn't four lines (sweep 2026-11-03).
    /// [inspector] Owner 2026-11-09: there the steps are the panel's flat rows (`StepPanelCell`) under a grey summary
    /// line, not the sheet's cards on a rail.
    var compact = false { didSet { if isViewLoaded { dressForPanel(); updateSubtitle(); updateEmptyLine(); tableView.reloadData() } } }
    private weak var copyItem: UIBarButtonItem?

    init(steps: [Step], live: Bool) {
        self.steps = steps
        self.live = live
        // Plain: each row draws its own card (`StepLineCell`), so no group clips them into one.
        super.init(style: .plain)
        title = "Steps"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = HQPalette.sheetPage
        tableView.register(StepLineCell.self, forCellReuseIdentifier: "step")
        tableView.register(StepPanelCell.self, forCellReuseIdentifier: "panel")
        tableView.accessibilityIdentifier = "steps.list"
        // The rail joins the rows, so no rules between them; the first card starts just under the bar.
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        tableView.sectionHeaderHeight = 0
        tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 4))
        tableView.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 12))
        dressForPanel()
        updateSubtitle()
        let copy = UIBarButtonItem(title: "Copy", image: nil, primaryAction: UIAction { [weak self] _ in self?.copyAll() })
        copy.accessibilityIdentifier = "steps.copy"
        navigationItem.rightBarButtonItem = copy
        copyItem = copy
        updateEmptyLine()
    }

    /// [mac-layout] Mac polish #61: in the inspector the empty line stands where its other tabs' do (the panel's middle,
    /// 40 pt up, as `MacInspector`'s own and Helpers'), in the same grey, not under the tabs in the glass's ink.
    private func updateEmptyLine() {
        guard compact, steps.isEmpty else {
            if tableView.backgroundView != nil { tableView.backgroundView = nil }
            return
        }
        // [mac-ui-issues] The glyph, title and line every empty tab of the inspector has (`InspectorEmptyView`).
        let label = live
            ? InspectorEmptyView(symbol: "checklist", title: "No Steps Yet", hint: "The tools a bot runs for a reply are listed here as it works.")
            : InspectorEmptyView(symbol: "checklist", title: "No Steps", hint: "This reply ran no tools.")
        label.translatesAutoresizingMaskIntoConstraints = false
        let host = UIView()
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor, constant: -40),
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -24),
        ])
        tableView.backgroundView = host
    }

    /// "3 steps · 12s", "4 steps · 1 running", "2 steps · 1 failed · 8.4s".
    static func subtitle(_ calls: [ToolCall]) -> String {
        var parts = [calls.count == 1 ? "1 step" : "\(calls.count) steps"]
        let running = calls.filter { $0.state == .running }.count
        let failed = calls.filter { $0.state == .failed }.count
        if running > 0 { parts.append("\(running) running") }
        if failed > 0 { parts.append("\(failed) failed") }
        let seconds = calls.compactMap(\.durationSeconds).reduce(0, +)
        if running == 0, seconds > 0 { parts.append(ToolCards.formatDurationSeconds(seconds)) }
        return parts.joined(separator: " · ")
    }

    private func updateSubtitle() {
        navigationItem.subtitle = Self.subtitle(steps.map(\.call))
        guard compact, isViewLoaded else { return }
        // [inspector] The sheet's subtitle, as the grey line over the panel's rows.
        tableView.tableHeaderView = steps.isEmpty ? nil : InspectorLook.summary(Self.subtitle(steps.map(\.call)))
    }

    private func dressForPanel() {
        guard compact else { return }
        InspectorLook.dress(tableView)
        tableView.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 12))
    }

    /// The live list moved on.
    func update(_ next: [Step]) {
        guard next.map(\.call) != steps.map(\.call) else { return }
        // Following the run: the reader hasn't scrolled, or the newest row is in sight, so the running one stays in
        // sight as rows arrive. A reader who scrolled back (to the top, too) keeps their place.
        let follow = live && isViewLoaded && (steps.isEmpty || !userScrolled || lastRowVisible)
        let grew = next.count > steps.count
        steps = next
        updateSubtitle()
        updateEmptyLine()
        tableView.reloadData()
        guard follow, grew, let row = steps.lastIndex(where: { $0.call.state == .running }) ?? steps.indices.last else { return }
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .bottom, animated: !HQMotion.reduced)
    }

    /// The reader dragged the list; cleared when the newest row comes back into view.
    private var userScrolled = false

    private var lastRowVisible: Bool {
        !steps.isEmpty && tableView.indexPathsForVisibleRows?.contains(IndexPath(row: steps.count - 1, section: 0)) == true
    }

    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { userScrolled = true }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if userScrolled, !scrollView.isDragging, lastRowVisible { userScrolled = false }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { steps.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if compact {
            let cell = tableView.dequeueReusableCell(withIdentifier: "panel", for: indexPath) as! StepPanelCell
            cell.configure(steps[indexPath.row].call)
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "step", for: indexPath) as! StepLineCell
        cell.configure(steps[indexPath.row].call, first: indexPath.row == 0, last: indexPath.row == steps.count - 1)
        cell.setCompact(compact)
        return cell
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard steps.isEmpty, !compact else { return nil }   // the inspector's: `updateEmptyLine`
        // [glass-design] On the glass itself: the primary label there (label 2 measured 3.2:1 over the blurred chat).
        let label = ShelfText.label(HQFont.preferred(.subheadline), color: HQPalette.glassInk2)
        label.text = live ? "No steps yet." : "This reply ran no tools."
        label.textAlignment = .center
        let host = UIView()
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
        ])
        return host
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        steps.isEmpty && !compact ? UITableView.automaticDimension : .leastNonzeroMagnitude
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let page = openStep?(steps[indexPath.row]) else { return }
        Haptics.play(.selection)
        navigationController?.pushViewController(page, animated: true)
    }

    private func copyAll() {
        UIPasteboard.general.string = steps.map { ToolLines.line($0.call).copyText }.joined(separator: "\n")
        Haptics.play(.success)
        // "Copied" for a moment, as a step sheet's own Copy says it. Its own item: on the Mac the trailing item is the
        // parked Done (`SheetStyle`), so Copy never changed (stress test 2026-10-31).
        let item = copyItem
        item?.title = "Copied"
        HQAnnounce.say("Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak item] in item?.title = "Copy" }
    }
}

/// One timeline row: a round badge with the step's emoji on a rail that joins the rows above and below, both on the
/// sheet's page (the glass, at half height) · beside it the step's own card: the line's words (Body, wraps) with its
/// time and a chevron at the trailing edge (the braille spinner while it runs, "Failed" in red when it failed) · its
/// code under the words, full width, up to 3 lines each cut at the edge rather than wrapped · the finished call's
/// short note ("10 KB output") in Footnote.
/// [glass-design] The card and the badge are solid (no glass on glass, words on a card); the rail is a line, not words.
final class StepLineCell: UITableViewCell {
    private let card = UIView()
    private let badge = UIView()
    /// A failed step's red wash over the badge's solid fill.
    private let badgeWash = UIView()
    private let emoji = UILabel()
    private let railUp = UIView()
    private let railDown = UIView()
    private let text = UILabel()
    private let meta = UILabel()
    private let chevron = UIImageView()
    /// The code block: one label per line so each is cut at the edge (a label cuts only its last line).
    private let code = UIView()
    private let codeLines = UIStackView()
    private let note = UILabel()
    /// The braille spinner every other running step in the activity UI shows (§7.4).
    private let spinner = GlyphSpinner(style: .braille, color: ChatPalette.label2, size: HQFont.symbolSize(17, like: .body, cap: 28))
    private var running = false

    static let codeLineCount = 3
    /// Words inside a card, from its edges; the code block's corners are the card's less this, so the two nest.
    static let cardPadding: CGFloat = 12
    static let codeRadius: CGFloat = 8
    /// The glass between two cards.
    static let cardGap: CGFloat = 8
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundConfiguration = .clear()
        let side = HQFont.symbolSize(30, like: .body, cap: 44)
        badge.layer.cornerRadius = side / 2
        badge.layer.cornerCurve = .circular
        badge.clipsToBounds = true
        badgeWash.backgroundColor = ChatPalette.red.withAlphaComponent(0.18)
        emoji.font = HQFont.scaled(15, like: .body, cap: 22)
        emoji.textAlignment = .center
        for rail in [railUp, railDown] { rail.backgroundColor = ChatPalette.separator }
        card.layer.cornerCurve = .continuous

        text.font = HQFont.preferred(.body)
        text.adjustsFontForContentSizeCategory = true
        text.numberOfLines = 0
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meta.font = HQFont.digits(15, like: .subheadline)
        meta.adjustsFontForContentSizeCategory = true
        meta.setContentHuggingPriority(.required, for: .horizontal)
        meta.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(font: HQFont.style(.footnote, weight: .semibold)))
        chevron.tintColor = HQPalette.cardNote   // [glass-design] label 3 measured 2.1:1 on the card
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        codeLines.axis = .vertical
        codeLines.spacing = 2
        codeLines.translatesAutoresizingMaskIntoConstraints = false
        code.addSubview(codeLines)
        NSLayoutConstraint.activate([
            codeLines.topAnchor.constraint(equalTo: code.topAnchor, constant: 7),
            codeLines.bottomAnchor.constraint(equalTo: code.bottomAnchor, constant: -7),
            codeLines.leadingAnchor.constraint(equalTo: code.leadingAnchor, constant: 10),
            codeLines.trailingAnchor.constraint(equalTo: code.trailingAnchor, constant: -10),
        ])
        for _ in 0...Self.codeLineCount {      // the lines, then "+N more lines"
            let label = UILabel()
            label.font = HQFont.mono(13, like: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.lineBreakMode = .byTruncatingTail
            codeLines.addArrangedSubview(label)
        }
        code.backgroundColor = HQPalette.sheetCode
        code.layer.cornerRadius = Self.codeRadius
        code.layer.cornerCurve = .continuous
        note.font = HQFont.preferred(.footnote)
        note.adjustsFontForContentSizeCategory = true
        note.textColor = HQPalette.cardNote
        note.numberOfLines = 1

        let head = UIStackView(arrangedSubviews: [text, meta, spinner, chevron])
        head.spacing = 6
        head.alignment = .firstBaseline
        let column = UIStackView(arrangedSubviews: [head, code, note])
        column.axis = .vertical
        column.spacing = 8
        column.setCustomSpacing(6, after: code)

        for v in [card, railUp, railDown, badge, badgeWash, emoji, column] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        badge.addSubview(badgeWash)
        badge.addSubview(emoji)
        contentView.addSubview(railUp)
        contentView.addSubview(railDown)
        contentView.addSubview(badge)
        contentView.addSubview(card)
        card.addSubview(column)
        let margins = contentView.layoutMarginsGuide
        let pad = Self.cardPadding
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: side),
            badge.heightAnchor.constraint(equalTo: badge.widthAnchor),
            badge.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            // The badge sits centred on the card's first line of words.
            badge.centerYAnchor.constraint(equalTo: text.firstBaselineAnchor, constant: -HQFont.preferred(.body).capHeight / 2),
            badgeWash.topAnchor.constraint(equalTo: badge.topAnchor),
            badgeWash.bottomAnchor.constraint(equalTo: badge.bottomAnchor),
            badgeWash.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            badgeWash.trailingAnchor.constraint(equalTo: badge.trailingAnchor),
            emoji.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            emoji.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            railUp.widthAnchor.constraint(equalToConstant: 2),
            railUp.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            railUp.topAnchor.constraint(equalTo: contentView.topAnchor),
            railUp.bottomAnchor.constraint(equalTo: badge.topAnchor, constant: -4),
            railDown.widthAnchor.constraint(equalToConstant: 2),
            railDown.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            railDown.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 4),
            railDown.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.cardGap / 2),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.cardGap / 2),
            card.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad + 2),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad - 2),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The code's first lines (blank ones at either end dropped), each to be cut at the edge so a path or a long
    /// command reads as code, not as a paragraph wrapped mid-word; and how many lines are left out.
    static func codePreview(_ code: String) -> (lines: [String], more: Int) {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\t", with: "    ") }
        var kept = Array(lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty }))
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
        return (Array(kept.prefix(codeLineCount)), max(0, kept.count - codeLineCount))
    }

    func setCompact(_ on: Bool) {
        // HQFont.preferred lifts the small styles to body for legibility, so the size is given outright here.
        text.font = on ? HQFont.scaled(15, like: .body, cap: 22) : HQFont.preferred(.body)
        // Two lines at most there, a long path losing its middle rather than breaking inside a word.
        text.numberOfLines = on ? 2 : 0
        text.lineBreakMode = on ? .byTruncatingMiddle : .byWordWrapping
        meta.font = on ? HQFont.digits(13, like: .footnote) : HQFont.digits(15, like: .subheadline)
    }

    func configure(_ call: ToolCall, first: Bool, last: Bool) {
        let line = ToolLines.line(call)
        emoji.text = line.emoji
        let failed = call.state == .failed
        running = call.state == .running
        badgeWash.isHidden = !failed
        railUp.isHidden = first
        railDown.isHidden = last
        // Hermes's own progress line says just "terminal" for a command; the sheet words it like "Running code". The
        // calls the chat's row words itself ("Checked how to use 3 tools", not "tool_describe…") read the same here.
        let plain = failed ? nil : ToolWords.plainLabel(name: call.name, args: ChatRunSummary.args(call), preview: call.title)
        text.text = plain ?? (call.name == "terminal" && line.text == "terminal" ? "Running a command" : line.text)
        text.textColor = ChatPalette.label
        let time = call.durationSeconds.map(ToolCards.formatDurationSeconds)
        meta.text = failed ? "Failed" : time
        meta.textColor = failed ? ChatPalette.red : HQPalette.cardNote   // [glass-design] label 2 on the card
        meta.isHidden = running || meta.text?.isEmpty != false
        spinner.isHidden = !running
        let preview = line.code.map(Self.codePreview) ?? (lines: [], more: 0)
        code.isHidden = preview.lines.isEmpty
        for (i, view) in codeLines.arrangedSubviews.enumerated() {
            guard let label = view as? UILabel else { continue }
            if i < Self.codeLineCount {
                label.text = i < preview.lines.count ? preview.lines[i] : nil
                label.textColor = ChatPalette.codeText
                label.isHidden = i >= preview.lines.count
            } else {
                label.text = preview.more == 1 ? "+1 more line" : "+\(preview.more) more lines"
                label.textColor = HQPalette.cardNote   // [glass-design] label 2 on the card
                label.isHidden = preview.more == 0
            }
        }
        let words = call.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        note.text = words
        note.isHidden = running || words?.isEmpty != false
        accessibilityLabel = [text.text, line.code, failed ? "Failed" : nil, running ? "running" : time, note.isHidden ? nil : words]
            .compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = .button
        paint()
        setNeedsUpdateConfiguration()
    }

    /// The card's and the badge's fill: in the iOS look the sheets' card (`HQPalette.sheetCard`, frosted on the glass,
    /// solid off it); none in the Desktop Look, whose grouped rows are bare inside an outline (its card colour is the
    /// code block's own, so the code vanished into a filled card); the Mac's grouped card on the Mac.
    private var fill: UIColor {
        if GlassSheetKit.designed { return HQPalette.sheetCard }
        return Theme.isDesktop ? .clear : HQPalette.card
    }

    /// The colours a layer holds (resolved now, again when the look or the appearance changes) and the corners.
    private func paint() {
        // The Desktop Look outlines its cards (no glass, no shadows), as a project's card on Sessions. On the glass a
        // hairline lifts the card off it (`HQPalette.glassEdge`, as every glass sheet's cards): the dark card measured
        // 1.05:1 against the dark glass between the cards. At full height the page is opaque and there is none.
        let ink = (Theme.isDesktop ? HQPalette.stroke : GlassSheetKit.designed ? HQPalette.glassEdge : nil)?
            .resolvedColor(with: traitCollection).cgColor
        let edge = ink.flatMap { $0.alpha > 0 ? $0 : nil }
        // 20: the code block's 8 plus the 12 pt between; the Desktop Look's cards are 10 (a project's on Sessions).
        card.layer.cornerRadius = GlassSheetKit.designed ? 20 : Theme.isDesktop ? 10 : 12
        card.layer.borderWidth = edge == nil ? 0 : 1
        card.layer.borderColor = edge
        badge.backgroundColor = fill
        // A running step's badge rings in the tint; a still one has the cards' edge.
        badge.layer.borderWidth = running ? 1.5 : (edge == nil ? 0 : 1)
        badge.layer.borderColor = running ? ChatPalette.tint.resolvedColor(with: traitCollection).cgColor : edge
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        backgroundConfiguration = .clear()
        let pressed = state.isHighlighted || state.isSelected
        #if targetEnvironment(macCatalyst)
        if DeviceWord.isMac, let mark = MacSelection.fill(selected: state.isSelected, pressed: state.isHighlighted, in: .list) {
            card.backgroundColor = mark
            return
        }
        #endif
        card.backgroundColor = pressed ? HQPalette.cellPressed : fill
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        paint()
        setNeedsUpdateConfiguration()
    }
}

// MARK: - Goal details (§6.3)

final class GoalDetailsViewController: UIViewController {
    private let goal: GoalSnapshot

    init(goal: GoalSnapshot) {
        self.goal = goal
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func formatDate(_ seconds: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let sections = ControlRules.detailSections(goal, formatDate: Self.formatDate)
        let body = ChatBlocksViewController(heading: nil, blocks: sections.map { .init(label: $0.label, text: $0.text, mono: $0.mono) })
        addChild(body)
        body.view.frame = view.bounds
        body.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(body.view)
        body.didMove(toParent: self)
    }
}

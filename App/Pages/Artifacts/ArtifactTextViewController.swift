// The text viewer (docs/spec/1x-pages.md §5.6): a file's text, read-only, pushed on the tab's stack. Markdown gets a
// bottom toolbar Preview | Source (Preview through the chat's renderer, front matter as a facts block); code and text
// read monospaced 13 pt with the chat's highlighter, lines wrapping at words. Share in the bar. Never edits (§8).

import SwiftUI
import UIKit
import WebKit

final class ArtifactTextViewController: UIViewController, UITextViewDelegate {
    private let markdown: Bool
    private let language: String?
    private let load: () async throws -> String
    /// What Share hands over (a downloaded file, or nil to share the text).
    var shareItem: (() async throws -> Any)?
    /// Offered when the text can't be read (not for a missing file).
    var openInQuickLook: (() -> Void)?
    private let backTitle: String?
    // [morepages] Linked notes (3x-morepages §3). `linkOpener` gets a link to another file as written, its `#fragment`
    // and this page; the Artifacts page resolves it in this note's folder and pushes the next viewer.
    var linkOpener: ((_ target: String, _ fragment: String?, _ from: ArtifactTextViewController) -> Void)?
    /// Says so while the note downloads ("Loading plan.md…"); nil = the spinner alone.
    var loadingText: String?
    /// The failed state's title ("Couldn’t open plan.md here."); nil = "Couldn’t Open This File".
    var failureTitle: String?
    /// A heading to scroll to once the note is drawn (a link "plan.md#usage").
    var pendingFragment: String?
    private let loadingLabel = UILabel()
    /// An HTML file: Preview is the page live (its scripts run), Source the text.
    var htmlPreview: URL?
    private var previewWeb: WKWebView?
    private var linkGuard: PageLinkGuard?
    private var hasModes: Bool { markdown || htmlPreview != nil }

    /// The chat's layout manager draws the Preview's code: inline code in the chat's rounded box (the system text view
    /// drew a square block the line's height), a code block as one padded box.
    private let textView = ChatLayoutManager.textView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// The Preview's tables as the chat's table cards, laid over their places in the text.
    private lazy var tableCards = PreviewTableCards(textView: textView) { [weak self] table in
        guard let self else { return }
        TableSheetController.open(table, from: self)
    }
    /// Preview (0) or Source (1), whichever control shows it.
    private let mode = ArtifactFilterChoice()
    private var text = ""
    private var loaded = false
    private var loadTask: Task<Void, Never>?
    /// Rendered Markdown Preview per text size and appearance (switching Preview / Source never renders again).
    private var previews: [String: NSAttributedString] = [:]
    private var renderGeneration = 0

    init(title: String, backTitle: String? = nil, markdown: Bool, language: String?, load: @escaping () async throws -> String) {
        self.markdown = markdown
        self.language = language
        self.load = load
        self.backTitle = backTitle
        super.init(nibName: nil, bundle: nil)
        self.title = title
        navigationItem.largeTitleDisplayMode = .never
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.page
        view.accessibilityIdentifier = "artifact.text"
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = HQPalette.page
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        textView.adjustsFontForContentSizeCategory = true
        textView.dataDetectorTypes = [.link]
        textView.delegate = self   // [morepages]
        textView.accessibilityIdentifier = "artifact.text.body"
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        // [morepages] "Loading <name>…" under the spinner for a linked note.
        loadingLabel.font = HQFont.preferred(.subheadline)
        loadingLabel.adjustsFontForContentSizeCategory = true
        loadingLabel.textColor = HQPalette.label2
        loadingLabel.textAlignment = .center
        loadingLabel.numberOfLines = 0
        loadingLabel.isHidden = true
        loadingLabel.accessibilityIdentifier = "artifact.text.loading"
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingLabel)
        NSLayoutConstraint.activate([loadingLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
                                     loadingLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
                                     loadingLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor)])
        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in self?.share() })
        share.accessibilityLabel = "Share"
        share.isEnabled = false
        navigationItem.rightBarButtonItem = share
        if hasModes {
            buildModes()
            NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.buildModes() }
            }
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (vc: ArtifactTextViewController, _) in
            vc.render()
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasModes, contentUnavailableConfiguration == nil { navigationController?.setToolbarHidden(false, animated: animated) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if hasModes { navigationController?.setToolbarHidden(true, animated: animated) }
    }

    private func reload() {
        spinner.startAnimating()
        loadingLabel.text = loadingText
        loadingLabel.isHidden = loadingText == nil
        contentUnavailableConfiguration = nil
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.load()
                self.text = text
                self.loaded = true
                if self.hasModes, self.viewIfLoaded?.window != nil { self.navigationController?.setToolbarHidden(false, animated: false) }
                self.loadingLabel.isHidden = true
                self.spinner.stopAnimating()
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                self.render()
            } catch {
                guard !(error is CancellationError) else { return }
                self.loadingLabel.isHidden = true
                self.spinner.stopAnimating()
                self.showFailure(error)
            }
        }
    }

    private func showFailure(_ error: Error) {
        var config = UIContentUnavailableConfiguration.empty().hqScaled()
        config.image = UIImage(systemName: "doc.questionmark")
        config.text = failureTitle ?? "Couldn’t Open This File"
        config.secondaryText = ArtifactFiles.failureText(error, image: false)
        var retry = UIButton.Configuration.hqMacPush(or: .filled(), capsule: true)   // [mac] Stress test 2026-10-28 #55 (round 6)
        retry.title = "Try Again"
        config.button = retry
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.reload() }
        if let openInQuickLook, !ArtifactFiles.isMissing(error) {
            var ql = UIButton.Configuration.plain()
            ql.title = "Open in Quick Look"
            config.secondaryButton = ql
            config.secondaryButtonProperties.primaryAction = UIAction { _ in openInQuickLook() }
        }
        contentUnavailableConfiguration = config
        // [morepages] Nothing to preview: Preview | Source would do nothing.
        if hasModes { navigationController?.setToolbarHidden(true, animated: false) }
    }

    private var showsSource: Bool { mode.index == 1 }

    /// Preview | Source under the page: the system's control in the iOS look; in the Desktop Look the desktop's
    /// outlined strip (UISegmentedControl draws iOS 26's pill whatever it is given, and there showed neither half chosen).
    private func buildModes() {
        let control: UIView
        if Theme.isDesktop {
            let host = UIHostingController(rootView: ArtifactModeStrip(choice: mode) { [weak self] in self?.render() })
            host.view.backgroundColor = .clear
            host.sizingOptions = .intrinsicContentSize
            control = host.view
        } else {
            let segments = UISegmentedControl(items: ["Preview", "Source"])
            segments.selectedSegmentIndex = mode.index
            segments.addAction(UIAction { [weak self, weak segments] _ in
                guard let self, let segments else { return }
                self.mode.index = segments.selectedSegmentIndex
                self.render()
            }, for: .valueChanged)
            control = segments
        }
        control.accessibilityIdentifier = "artifact.text.mode"
        // The control is its own capsule: without this the bar's glass drew a second ring around it.
        let item = UIBarButtonItem(customView: control)
        item.hidesSharedBackground = true
        toolbarItems = [.flexibleSpace(), item, .flexibleSpace()]
    }

    /// The HTML Preview: the page drawn live, its scripts running (`HTMLPageSheet`'s web view; Quick Look drew a
    /// script-drawn chart blank).
    private func showPreviewChild(_ shown: Bool) {
        if shown, previewWeb == nil, let url = htmlPreview {
            let web = HTMLPageSheet.makeWebView(traits: traitCollection)
            let guardian = PageLinkGuard(file: url, host: self)
            web.navigationDelegate = guardian
            linkGuard = guardian
            web.frame = view.bounds
            web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            web.accessibilityIdentifier = "artifact.page"
            view.insertSubview(web, belowSubview: spinner)
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            previewWeb = web
        }
        previewWeb?.isHidden = !shown
        textView.isHidden = shown
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let web = previewWeb, web.frame != view.bounds { web.frame = view.bounds }
        tableCards.placeIfWidthChanged()   // a turn or a Mac window resize moves the text under the cards
    }

    private func render() {
        if htmlPreview != nil {
            showPreviewChild(!showsSource)
            if !showsSource { return }
        }
        guard loaded else { return }
        renderGeneration += 1
        let generation = renderGeneration
        let category = traitCollection.preferredContentSizeCategory
        if markdown && !showsSource {
            // The Preview renders off the main thread (a bot's report can be hundreds of KB); the spinner shows meanwhile.
            let key = "\(category.rawValue)|\(traitCollection.userInterfaceStyle.rawValue)"
            if let cached = previews[key] {
                spinner.stopAnimating()
                textView.attributedText = cached
                tableCards.place()
                scrollToPendingFragment()
                return
            }
            spinner.startAnimating()
            let text = self.text, label = HQPalette.label, label2 = HQPalette.label2
            Task { [weak self] in
                let rendered = await Self.renderPreview(text, category: category, label: label, label2: label2)
                guard let self, self.text == text else { return }
                self.previews[key] = rendered.value
                guard generation == self.renderGeneration else { return }
                self.spinner.stopAnimating()
                self.textView.attributedText = rendered.value
                self.tableCards.place()
                self.scrollToPendingFragment()
            }
            return
        }
        spinner.stopAnimating()
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: HQFont.mono(ofSize: 13, weight: .regular))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping   // "Rossio" was split "R" / "ossio"; a word too long still breaks
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: HQPalette.label,
                                                                             .paragraphStyle: paragraph])
        textView.attributedText = attributed
        tableCards.place()
        let tag = markdown ? "markdown" : language
        let code = text
        Task.detached(priority: .userInitiated) {
            guard let tokens = SyntaxHighlighter.tokens(code, language: tag) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.text == code, generation == self.renderGeneration else { return }
                let colored = NSMutableAttributedString(attributedString: self.textView.attributedText)
                SyntaxHighlighter.apply(tokens, to: colored)
                let offset = self.textView.contentOffset
                self.textView.attributedText = colored
                self.textView.setContentOffset(offset, animated: false)
            }
        }
    }

    /// A rendered Preview handed back to the main thread (built here, never shared).
    nonisolated struct RenderedPreview: @unchecked Sendable { let value: NSAttributedString }

    /// Front matter as facts, then the body through the chat's renderer, off the main thread.
    @concurrent
    nonisolated static func renderPreview(_ text: String, category: UIContentSizeCategory, label: UIColor,
                                          label2: UIColor) async -> RenderedPreview {
        let (facts, body) = frontMatter(text)
        let out = NSMutableAttributedString()
        if !facts.isEmpty {
            let font = HQFont.preferred(.footnote, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
            for (key, value) in facts {
                out.append(NSAttributedString(string: key + "  ", attributes: [.font: font.pagesWeight(.semibold), .foregroundColor: label2]))
                out.append(NSAttributedString(string: value + "\n", attributes: [.font: font, .foregroundColor: label]))
            }
            out.append(NSAttributedString(string: "\n"))
        }
        out.append(PagesMarkdown.attributed(body, category: category, tableCards: true))
        boxCodeBlocks(out)
        linkify(out)
        return RenderedPreview(value: out)
    }

    /// Code blocks (the flattened text's backgrounds that aren't inline code) as one padded box each: their lines move
    /// in from the box's edges and the block gets room above and below (`ChatLayoutManager` draws the box).
    nonisolated static func boxCodeBlocks(_ text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        var blocks: [NSRange] = []
        text.enumerateAttribute(.backgroundColor, in: whole) { value, range, _ in
            guard value != nil, text.attribute(.inlineCodeBox, at: range.location, effectiveRange: nil) == nil else { return }
            if let last = blocks.last, NSMaxRange(last) == range.location { blocks[blocks.count - 1].length += range.length }
            else { blocks.append(range) }
        }
        let string = text.string as NSString
        for block in blocks {
            text.addAttribute(.codeBlockBox, value: true, range: block)
            let paragraphs = string.paragraphRange(for: block)
            string.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
                let at = enclosing.location
                let style = (text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy()
                    as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.firstLineHeadIndent += 12
                style.headIndent += 12
                style.tailIndent = -12
                if range.location == paragraphs.location { style.paragraphSpacingBefore += 10 }
                if NSMaxRange(enclosing) >= NSMaxRange(paragraphs) { style.paragraphSpacing += 10 }
                text.addAttribute(.paragraphStyle, value: style, range: enclosing)
            }
        }
    }

    // MARK: Links in a note ([morepages], 3x-morepages §3)

    /// Every Markdown link becomes a text-view link: a web link as itself, a note or heading link under the viewer's
    /// own scheme (the delegate handles the tap; the system never opens it). Anything else stays plain text.
    nonisolated static func linkify(_ text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        var links: [(NSRange, URL)] = []
        text.enumerateAttribute(.markdownDestination, in: whole) { value, range, _ in
            guard let destination = value as? String else { return }
            switch ArtifactLinks.classify(href: destination) {
            case .external(let url): links.append((range, url))
            case .file, .hash:
                if let url = ArtifactLinks.viewerURL(destination: destination) { links.append((range, url)) }
            case .inert: break
            }
        }
        for (range, url) in links {
            text.addAttribute(.link, value: url, range: range)
            text.addAttribute(.foregroundColor, value: MarkdownTheme.bot.link, range: range)
        }
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, let destination = ArtifactLinks.destination(of: url) else { return defaultAction }
        return UIAction { [weak self] _ in self?.follow(destination) }
    }

    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        // A note link has no web address to copy or preview: no menu.
        if case .link(let url) = textItem.content, ArtifactLinks.destination(of: url) != nil { return nil }
        return .init(menu: defaultMenu)
    }

    private func follow(_ destination: String) {
        switch ArtifactLinks.classify(href: destination) {
        case .hash(let fragment): scroll(toFragment: fragment)
        case .file(let target, let fragment): linkOpener?(target, fragment, self)
        case .external(let url): UIApplication.shared.open(url)
        case .inert: break
        }
    }

    private func scrollToPendingFragment() {
        guard let fragment = pendingFragment else { return }
        pendingFragment = nil
        // After this pass's layout: the text was set a moment ago.
        Task { [weak self] in self?.scroll(toFragment: fragment) }
    }

    /// Scrolls the Preview to the heading a `#fragment` names; false when the note has no such heading.
    @discardableResult
    func scroll(toFragment fragment: String) -> Bool {
        guard markdown, !showsSource else { return false }
        let wanted = ArtifactLinks.headingSlug(fragment)
        let headings = ArtifactLinks.headings(in: Self.frontMatter(text).body)
        guard let index = headings.firstIndex(where: { $0.id == fragment || $0.id == wanted }) else { return false }
        let heading = headings[index].text
        // The same words may stand in a paragraph above: take the line that is exactly the heading, the nth for the nth.
        let nth = headings[..<index].filter { $0.text == heading }.count
        let shown = textView.text as NSString
        var seen = 0
        var found: NSRange?
        shown.enumerateSubstrings(in: NSRange(location: 0, length: shown.length), options: .byLines) { line, range, _, stop in
            guard let line, line.trimmingCharacters(in: .whitespaces) == heading else { return }
            if seen == nth { found = range; stop.pointee = true }
            seen += 1
        }
        guard let range = found, let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length), let span = textView.textRange(from: start, to: end) else { return false }
        textView.layoutIfNeeded()
        let rect = textView.firstRect(for: span)
        guard !rect.isNull, !rect.isInfinite else { textView.scrollRangeToVisible(range); return true }
        let top = -textView.adjustedContentInset.top
        let bottom = max(top, textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
        let y = min(max(rect.minY - textView.adjustedContentInset.top - 12, top), bottom)
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: y), animated: !HQMotion.reduced)
        lastFragment = fragment
        return true
    }

    /// The last heading a link scrolled to (read by UI tests through the page's accessibility value).
    private(set) var lastFragment: String? { didSet { view.accessibilityValue = lastFragment.map { "#" + $0 } } }

    /// "---\nkey: value\n---" at the top → facts and the rest (`frontMatterFacts`).
    nonisolated static func frontMatter(_ text: String) -> (facts: [(String, String)], body: String) {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return ([], text)
        }
        let head = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
        var facts: [(String, String)] = []
        var key: String?
        var lines: [String] = []
        func flush() {
            guard let k = key else { return }
            let values = lines.map { $0.pgTrim }.filter { !$0.isEmpty }
            let said = values.allSatisfy({ $0.hasPrefix("- ") }) && !values.isEmpty
                ? values.map { String($0.dropFirst(2)) }.joined(separator: ", ") : values.joined(separator: "; ")
            if !said.isEmpty { facts.append((JobWords.titleCase(k), said.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))) }
        }
        for line in head.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let match = RX.c(#"^([A-Za-z_][\w-]*):\s*(.*)$"#).exec(line) {
                flush()
                key = match[1]
                lines = [match[2] ?? ""]
            } else {
                lines.append(line)
            }
        }
        flush()
        var rest = String(text[end.upperBound...])
        if rest.hasPrefix("\n") { rest.removeFirst() }
        return (facts, rest)
    }

    private func share() {
        let button = navigationItem.rightBarButtonItem
        Task { [weak self] in
            guard let self else { return }
            var item: Any = self.text
            if let shareItem = self.shareItem { item = (try? await shareItem()) ?? self.text }
            let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceItem = button
            self.present(sheet, animated: true)
        }
    }
}

/// The Desktop Look's Preview | Source: the desktop's outlined strip, the chosen half filled.
private struct ArtifactModeStrip: View {
    @Bindable var choice: ArtifactFilterChoice
    let changed: () -> Void

    var body: some View {
        DesktopSegmentStrip(options: [("Preview", 0), ("Source", 1)],
                            selection: Binding(get: { choice.index }, set: { choice.index = $0; changed() }), wholeLabels: true)
            .frame(minWidth: 180)
    }
}

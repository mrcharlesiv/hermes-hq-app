// [asks] Real brand icons for external apps shown on Ask and Draft decision cards.
// Third-party apps resolve via `CatalogLogoStore` (with synchronous memory + disk cache hits) using an alias table
// and URL-host / email-domain inference; Apple first-party system apps (Messages, Apple Mail, Calendar, Reminders,
// Notes, Phone) use clean App-Review-safe colored rounded-rect SF Symbol tiles.

import UIKit

nonisolated enum AppBrandResolver {
    enum Spec: Equatable, Sendable {
        /// Apple first-party / generic system channel rendered with a crisp SF Symbol on a brand-tinted rounded tile.
        case firstParty(symbol: String, bgHex: UInt32, fgHex: UInt32)
        /// Third-party app icon fetched & cached through `CatalogLogoStore`, with an SF Symbol fallback while loading
        /// or offline.
        case remote(key: String, slugs: [String], site: URL?, fallbackSymbol: String)
    }

    private struct RemoteEntry {
        var key: String
        var slugs: [String]
        var site: String
        var fallback: String
    }

    private static let remotes: [String: RemoteEntry] = [
        "slack": RemoteEntry(key: "brand:slack", slugs: ["slack"], site: "https://slack.com", fallback: "number"),
        "gmail": RemoteEntry(key: "brand:gmail", slugs: ["gmail"], site: "https://mail.google.com", fallback: "envelope.fill"),
        "google mail": RemoteEntry(key: "brand:gmail", slugs: ["gmail"], site: "https://mail.google.com", fallback: "envelope.fill"),
        "outlook": RemoteEntry(key: "brand:outlook", slugs: ["outlook", "microsoft_outlook"], site: "https://outlook.live.com", fallback: "envelope.fill"),
        "microsoft outlook": RemoteEntry(key: "brand:outlook", slugs: ["outlook", "microsoft_outlook"], site: "https://outlook.live.com", fallback: "envelope.fill"),
        "linear": RemoteEntry(key: "brand:linear", slugs: ["linear"], site: "https://linear.app", fallback: "checklist"),
        "notion": RemoteEntry(key: "brand:notion", slugs: ["notion"], site: "https://notion.so", fallback: "doc.text"),
        "github": RemoteEntry(key: "brand:github", slugs: ["github"], site: "https://github.com", fallback: "chevron.left.forwardslash.chevron.right"),
        "gitlab": RemoteEntry(key: "brand:gitlab", slugs: ["gitlab"], site: "https://gitlab.com", fallback: "arrow.triangle.branch"),
        "google calendar": RemoteEntry(key: "brand:googlecalendar", slugs: ["googlecalendar"], site: "https://calendar.google.com", fallback: "calendar"),
        "gcal": RemoteEntry(key: "brand:googlecalendar", slugs: ["googlecalendar"], site: "https://calendar.google.com", fallback: "calendar"),
        "google drive": RemoteEntry(key: "brand:googledrive", slugs: ["googledrive"], site: "https://drive.google.com", fallback: "folder"),
        "google docs": RemoteEntry(key: "brand:googledrive", slugs: ["googledocs", "googledrive"], site: "https://docs.google.com", fallback: "doc.text"),
        "whatsapp": RemoteEntry(key: "brand:whatsapp", slugs: ["whatsapp"], site: "https://whatsapp.com", fallback: "bubble.left.fill"),
        "telegram": RemoteEntry(key: "brand:telegram", slugs: ["telegram"], site: "https://telegram.org", fallback: "paperplane.fill"),
        "discord": RemoteEntry(key: "brand:discord", slugs: ["discord"], site: "https://discord.com", fallback: "bubble.left.and.bubble.right.fill"),
        "teams": RemoteEntry(key: "brand:microsoft_teams", slugs: ["microsoft_teams", "msteams"], site: "https://teams.microsoft.com", fallback: "video.fill"),
        "microsoft teams": RemoteEntry(key: "brand:microsoft_teams", slugs: ["microsoft_teams", "msteams"], site: "https://teams.microsoft.com", fallback: "video.fill"),
        "ms teams": RemoteEntry(key: "brand:microsoft_teams", slugs: ["microsoft_teams", "msteams"], site: "https://teams.microsoft.com", fallback: "video.fill"),
        "x": RemoteEntry(key: "brand:twitter", slugs: ["twitter"], site: "https://x.com", fallback: "at"),
        "twitter": RemoteEntry(key: "brand:twitter", slugs: ["twitter"], site: "https://x.com", fallback: "at"),
        "jira": RemoteEntry(key: "brand:jira", slugs: ["jira"], site: "https://atlassian.com", fallback: "ticket"),
        "asana": RemoteEntry(key: "brand:asana", slugs: ["asana"], site: "https://asana.com", fallback: "checkmark.circle"),
        "figma": RemoteEntry(key: "brand:figma", slugs: ["figma"], site: "https://figma.com", fallback: "paintbrush"),
        "zoom": RemoteEntry(key: "brand:zoom", slugs: ["zoom"], site: "https://zoom.us", fallback: "video.fill"),
        "hubspot": RemoteEntry(key: "brand:hubspot", slugs: ["hubspot"], site: "https://hubspot.com", fallback: "person.2"),
        "salesforce": RemoteEntry(key: "brand:salesforce", slugs: ["salesforce"], site: "https://salesforce.com", fallback: "cloud"),
        "stripe": RemoteEntry(key: "brand:stripe", slugs: ["stripe"], site: "https://stripe.com", fallback: "creditcard"),
        "zendesk": RemoteEntry(key: "brand:zendesk", slugs: ["zendesk"], site: "https://zendesk.com", fallback: "lifepreserver"),
        "intercom": RemoteEntry(key: "brand:intercom", slugs: ["intercom"], site: "https://intercom.com", fallback: "bubble.left.fill"),
        "trello": RemoteEntry(key: "brand:trello", slugs: ["trello"], site: "https://trello.com", fallback: "rectangle.3.group"),
        "airtable": RemoteEntry(key: "brand:airtable", slugs: ["airtable"], site: "https://airtable.com", fallback: "tablecells"),
        "dropbox": RemoteEntry(key: "brand:dropbox", slugs: ["dropbox"], site: "https://dropbox.com", fallback: "tray.full"),
        "linkedin": RemoteEntry(key: "brand:linkedin", slugs: ["linkedin"], site: "https://linkedin.com", fallback: "person.crop.square"),
    ]

    /// Infers a concrete brand key from a link host or sender/account address when the bot wrote a generic app label
    /// such as "Email" or left `app` empty.
    static func inferredBrand(linkURL: URL? = nil, addressHints: [String] = []) -> String? {
        if let host = linkURL?.host?.lowercased() {
            if host.contains("mail.google.com") { return "gmail" }
            if host.contains("calendar.google.com") { return "google calendar" }
            if host.contains("drive.google.com") { return "google drive" }
            if host.contains("docs.google.com") { return "google docs" }
            if host.contains("outlook.office") || host.contains("outlook.live") { return "outlook" }
            if host.contains("slack.com") { return "slack" }
            if host.contains("linear.app") { return "linear" }
            if host.contains("notion.so") || host.contains("notion.site") { return "notion" }
            if host.contains("github.com") { return "github" }
            if host.contains("gitlab.com") { return "gitlab" }
            if host.contains("teams.microsoft.com") { return "microsoft teams" }
            if host.contains("discord.com") { return "discord" }
            if host.contains("atlassian.net") { return "jira" }
            if host.contains("figma.com") { return "figma" }
            if host.contains("asana.com") { return "asana" }
            if host.contains("zoom.us") { return "zoom" }
            if host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter.com") { return "twitter" }
            if host.contains("telegram.org") || host == "t.me" { return "telegram" }
            if host.contains("whatsapp.com") || host == "wa.me" { return "whatsapp" }
            if host.contains("linkedin.com") { return "linkedin" }
        }
        for raw in addressHints {
            let lower = raw.lowercased()
            guard let at = lower.lastIndex(of: "@") else { continue }
            let domain = String(lower[lower.index(after: at)...]).trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).inverted)
            if domain == "gmail.com" || domain == "googlemail.com" { return "gmail" }
            if domain == "outlook.com" || domain == "hotmail.com" || domain == "live.com" { return "outlook" }
            if domain == "icloud.com" || domain == "me.com" { return "apple mail" }
        }
        return nil
    }

    static func resolve(app: String, linkURL: URL? = nil, addressHints: [String] = []) -> Spec? {
        let stripped = DraftCards.split(app: app).name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = stripped.lowercased()

        // If `app` is empty or generic ("Email", "Mail", "Text", "DM"), try inferring a specific provider from URL/address.
        let genericNames: Set<String> = ["", "email", "mail", "text", "sms", "message", "messages", "chat", "dm"]
        let lookup: String
        if genericNames.contains(lower), let inferred = inferredBrand(linkURL: linkURL, addressHints: addressHints) {
            lookup = inferred
        } else {
            lookup = lower
        }

        guard !lookup.isEmpty else { return nil }

        // 1. Known third-party brands (exact alias match).
        if let entry = remotes[lookup] {
            return .remote(key: entry.key, slugs: entry.slugs, site: URL(string: entry.site), fallbackSymbol: entry.fallback)
        }

        // 2. First-party / native system apps (App-Review-safe colored SF Symbol tiles).
        switch lookup {
        case "messages", "imessage", "sms", "text", "text message", "message":
            return .firstParty(symbol: "message.fill", bgHex: 0x34C759, fgHex: 0xFFFFFF)
        case "apple mail", "mail", "email":
            return .firstParty(symbol: "envelope.fill", bgHex: 0x007AFF, fgHex: 0xFFFFFF)
        case "apple calendar", "calendar":
            return .firstParty(symbol: "calendar", bgHex: 0xFF3B30, fgHex: 0xFFFFFF)
        case "reminders":
            return .firstParty(symbol: "checklist", bgHex: 0x007AFF, fgHex: 0xFFFFFF)
        case "notes", "apple notes":
            return .firstParty(symbol: "note.text", bgHex: 0xFFCC00, fgHex: 0x1F2328)
        case "phone", "call", "facetime":
            return .firstParty(symbol: "phone.fill", bgHex: 0x34C759, fgHex: 0xFFFFFF)
        case "signal":
            return .firstParty(symbol: "bubble.left.fill", bgHex: 0x3A76F0, fgHex: 0xFFFFFF)
        default:
            break
        }

        // 3. Substring check for compound names like "Slack DM", "Gmail Work", "Linear Issues".
        for (alias, entry) in remotes where alias.count >= 4 && lookup.contains(alias) {
            return .remote(key: entry.key, slugs: entry.slugs, site: URL(string: entry.site), fallbackSymbol: entry.fallback)
        }

        // 4. Unknown third-party app: try normalized Composio slug + origin site if link exists, else ConnectorSymbol.
        let compact = lookup.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        let underscored = lookup.split { !$0.isLetter && !$0.isNumber }.joined(separator: "_")
        var slugs: [String] = []
        if !underscored.isEmpty { slugs.append(underscored) }
        if !compact.isEmpty, compact != underscored { slugs.append(compact) }
        let origin: URL? = linkURL.flatMap { url in
            guard let scheme = url.scheme, let host = url.host else { return nil }
            return URL(string: "\(scheme)://\(host)")
        }
        return .remote(key: "brand:\(compact.isEmpty ? lookup : compact)", slugs: slugs, site: origin,
                       fallbackSymbol: ConnectorSymbol.of(stripped))
    }

    static func resolve(ask: AskCards.Ask) -> Spec? {
        var hints: [String] = []
        if let from = ask.replyTo?.from, !from.isEmpty { hints.append(from) }
        if let to = ask.replyTo?.to, !to.isEmpty { hints.append(to) }
        if !ask.from.isEmpty { hints.append(ask.from) }
        let app = ask.app.isEmpty ? (ask.replyTo?.app ?? "") : ask.app
        return resolve(app: app, linkURL: ask.link?.url, addressHints: hints)
    }

    static func resolve(draft: DraftCards.Draft) -> Spec? {
        let hints = [draft.from, draft.to].filter { !$0.isEmpty }
        return resolve(app: DraftCards.name(draft), linkURL: nil, addressHints: hints)
    }
}

/// UIKit brand icon tile for Ask & Draft card headers and receipts: fixed-slot square rounded rect that paints
/// synchronously from memory/disk cache when available and fetches asynchronously with cell-reuse cancellation.
@MainActor final class AppBrandTileView: UIView {
    private let imageView = UIImageView()
    private var spec: AppBrandResolver.Spec?
    private var loadedImage: UIImage?
    private var loadedKey: String?
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        clipsToBounds = true
        layer.cornerCurve = .continuous
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: AppBrandTileView, _) in
            view.applyAppearance()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    func configure(_ newSpec: AppBrandResolver.Spec?) {
        guard let newSpec else {
            cancel()
            spec = nil
            loadedImage = nil
            loadedKey = nil
            isHidden = true
            return
        }
        isHidden = false
        if spec == newSpec {
            // Re-check cache in case another cell finished loading the same logo while this cell stayed mounted.
            if case .remote(let key, _, _, _) = newSpec, loadedImage == nil,
               let cached = CatalogLogoStore.shared.cachedImage(key: key) {
                loadedImage = cached
                loadedKey = key
                applyAppearance()
            }
            return
        }
        cancel()
        spec = newSpec
        loadedImage = nil
        loadedKey = nil
        switch newSpec {
        case .firstParty:
            applyAppearance()
        case .remote(let key, let slugs, let site, _):
            if let cached = CatalogLogoStore.shared.cachedImage(key: key) {
                loadedImage = cached
                loadedKey = key
                applyAppearance()
            } else {
                applyAppearance()
                loadTask = Task { [weak self] in
                    let fetched = await CatalogLogoStore.shared.image(key: key, slugs: slugs, site: site)
                    guard !Task.isCancelled, let self, self.spec == newSpec else { return }
                    if let fetched {
                        self.loadedImage = fetched
                        self.loadedKey = key
                        self.applyAppearance()
                    }
                }
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        layer.cornerRadius = min(7, (side * 0.27).rounded())
        let inset = imageInset(for: side)
        imageView.frame = bounds.insetBy(dx: inset, dy: inset)
        if loadedImage == nil {
            updateSymbolSize(side: side)
        }
    }

    private func imageInset(for side: CGFloat) -> CGFloat {
        guard let spec else { return 0 }
        switch spec {
        case .firstParty:
            return (side * 0.19).rounded(.down)
        case .remote(let key, _, _, _):
            if let img = loadedImage {
                let darkMark = CatalogLogoTone.isDarkMark(img, key: key)
                return (side * (darkMark ? 0.18 : 0.13)).rounded(.down)
            }
            return (side * 0.20).rounded(.down)
        }
    }

    private func updateSymbolSize(side: CGFloat) {
        guard let spec, side > 0 else { return }
        switch spec {
        case .firstParty(let symbol, _, _):
            let cfg = UIImage.SymbolConfiguration(pointSize: side * 0.52, weight: .semibold)
            imageView.image = UIImage(systemName: symbol, withConfiguration: cfg)?.withRenderingMode(.alwaysTemplate)
        case .remote(_, _, _, let fallback):
            guard loadedImage == nil else { return }
            let cfg = UIImage.SymbolConfiguration(pointSize: side * 0.50, weight: .medium)
            imageView.image = UIImage(systemName: fallback, withConfiguration: cfg)?.withRenderingMode(.alwaysTemplate)
        }
    }

    private func applyAppearance() {
        guard let spec else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        let hair = HQShape.pixel(traitCollection.displayScale)
        let side = min(bounds.width, bounds.height)
        switch spec {
        case .firstParty(let symbol, let bgHex, let fgHex):
            backgroundColor = UIColor(hex: bgHex)
            layer.borderWidth = 0
            layer.borderColor = nil
            imageView.tintColor = UIColor(hex: fgHex)
            if side > 0 {
                let cfg = UIImage.SymbolConfiguration(pointSize: side * 0.52, weight: .semibold)
                imageView.image = UIImage(systemName: symbol, withConfiguration: cfg)?.withRenderingMode(.alwaysTemplate)
            } else {
                imageView.image = UIImage(systemName: symbol)?.withRenderingMode(.alwaysTemplate)
            }
        case .remote(let key, _, _, let fallback):
            if let img = loadedImage {
                let darkMark = CatalogLogoTone.isDarkMark(img, key: key)
                backgroundColor = dark ? UIColor(white: 1, alpha: 0.08) : ChatPalette.fill4.resolvedColor(with: traitCollection)
                layer.borderColor = ChatPalette.decisionEdge.resolvedColor(with: traitCollection).cgColor
                layer.borderWidth = hair
                if darkMark {
                    imageView.image = img.withRenderingMode(.alwaysTemplate)
                    imageView.tintColor = ChatPalette.label
                } else {
                    imageView.image = img.withRenderingMode(.alwaysOriginal)
                    imageView.tintColor = nil
                }
            } else {
                backgroundColor = ChatPalette.fill4.resolvedColor(with: traitCollection)
                layer.borderColor = ChatPalette.decisionEdge.resolvedColor(with: traitCollection).cgColor
                layer.borderWidth = hair
                imageView.tintColor = ChatPalette.label2
                if side > 0 {
                    let cfg = UIImage.SymbolConfiguration(pointSize: side * 0.50, weight: .medium)
                    imageView.image = UIImage(systemName: fallback, withConfiguration: cfg)?.withRenderingMode(.alwaysTemplate)
                } else {
                    imageView.image = UIImage(systemName: fallback)?.withRenderingMode(.alwaysTemplate)
                }
            }
        }
        setNeedsLayout()
    }
}

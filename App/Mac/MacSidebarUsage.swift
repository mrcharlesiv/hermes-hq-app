// [sidebar-usage] Owner 2026-11-28: "make it so that usage bars can show up on the bottom" of the sidebar. What is
// left on each signed-in plan, at the sidebar's foot: a bar per allowance beside its name while the sidebar is open, a
// ring with percentage and plan name on the folded rail. The numbers are ⋯ › Usage & Limits' own
// (`UsageLimitsModel.blocks`, cut down by `SidebarUsage`).
//
// Event-driven updates — zero periodic background polling:
//   1. Piggybacks on `ModelCatalogCache.didStore` whenever any menu/sheet already fetched `model.options` (0 extra HTTP).
//   2. Refreshes once ~3 s after a chat turn completes (`LiveChatSession.turnCompleted`), throttled to 2 min.
//   3. Refreshes on app activation (`UIScene.didActivateNotification`) only if >= 5 min stale.
//   4. Refreshes on click (>= 1 min stale) or immediately from the popover's Refresh button.
//   5. Schedules one exact one-shot timer for the soonest upcoming window reset instead of a repeating timer.

import SwiftUI
import UIKit

#if targetEnvironment(macCatalyst)

/// The plans' numbers for the sidebar's foot: one store for the app, read by the sidebar.
@MainActor
final class SidebarUsageStore {
    static let shared = SidebarUsageStore()
    static let changed = Notification.Name("HQSidebarUsageChanged")
    static let shownKey = "HQMacSidebarUsage"
    static let shownChanged = Notification.Name("HQMacSidebarUsageShownChanged")

    enum RefreshReason {
        /// Initial load, gateway change, or turning the setting on.
        case initial
        /// App came back to the foreground (stale >= 5 min).
        case foreground
        /// A chat turn finished (coalesced 3 s later, throttled to 2 min).
        case afterTurn
        /// User clicked the sidebar usage block to open the popover (stale >= 1 min).
        case click
        /// User tapped the explicit Refresh button in the popover (always fetches immediately).
        case manual
    }

    /// Held for the launch, as the sidebar's other switches are (`MacSidebar.botsInSidebar`). On unless turned off:
    /// with no plan that reports an allowance there is nothing to draw, so the block is not there either.
    private static var storedShown = UserDefaults.standard.object(forKey: shownKey) == nil || UserDefaults.standard.bool(forKey: shownKey)
    static var shown: Bool {
        get { storedShown }
        set {
            guard newValue != storedShown else { return }
            storedShown = newValue
            UserDefaults.standard.set(newValue, forKey: shownKey)
            NotificationCenter.default.post(name: shownChanged, object: nil)
            if newValue { shared.refresh(reason: .initial) }
        }
    }

    private struct ProfileSnapshot {
        var options: ModelOptions
        var askedAt: Date
        var updatedAt: Date
    }

    private weak var services: (any AppServices)?
    private var options: ModelOptions?
    private var account: String?
    /// Active bot profile (`nil` for the gateway's default profile).
    private var activeProfile: String?
    private var lastAsked: Date?
    private var cacheByProfile: [String: ProfileSnapshot] = [:]
    /// False when the window is too short to display the usage block (skips network reads while hidden).
    private var visible = true
    private var reading: Task<Void, Never>?
    private var pendingTurnRefresh: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// Counts the reads, so an answer for a gateway/profile since left is dropped.
    private var generation = 0
    private(set) var blocks: [UsageBlock] = []
    private(set) var updatedAt: Date?
    private(set) var isRefreshing = false

    var rows: (rows: [SidebarUsageRow], more: Int) { SidebarUsage.rows(blocks) }

    /// Normalized profile cache key (`""` for default).
    private var profileKey: String { Self.normalizeProfile(activeProfile) }

    private static func normalizeProfile(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == "default" ? "" : trimmed
    }

    /// The sidebar is up: subscribe to catalog & turn events and load once. Zero repeating timer.
    func attach(_ services: any AppServices) {
        self.services = services
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: ModelCatalogCache.didStore, object: nil, queue: .main) { [weak self] note in
                let acc = note.userInfo?["account"] as? String
                let prof = note.userInfo?["profile"] as? String
                let scope = note.userInfo?["scope"] as? String
                MainActor.assumeIsolated { self?.catalogStored(account: acc, profile: prof, scope: scope) }
            })
            observers.append(center.addObserver(forName: LiveChatSession.turnCompleted, object: nil, queue: .main) { [weak self] note in
                let acc = note.userInfo?["account"] as? String
                let prof = note.userInfo?["profile"] as? String
                MainActor.assumeIsolated { self?.turnCompleted(account: acc, profile: prof) }
            })
        }
        refresh(reason: .initial)
    }

    /// Called by `MacSidebar` when window height hides or reveals the usage block.
    func setVisible(_ isVisible: Bool) {
        guard isVisible != visible else { return }
        visible = isVisible
        if isVisible {
            refresh(reason: .foreground)
        } else {
            pendingTurnRefresh?.cancel()
            pendingTurnRefresh = nil
        }
    }

    /// Called by `MacSidebar` when the selected bot changes so per-bot credentials show their own plans.
    func setProfile(_ profile: String?) {
        let nextKey = Self.normalizeProfile(profile)
        guard nextKey != profileKey else { return }
        activeProfile = nextKey.isEmpty ? nil : nextKey
        pendingTurnRefresh?.cancel()
        pendingTurnRefresh = nil
        reading?.cancel()
        reading = nil
        isRefreshing = false
        generation += 1

        // 1. Reuse our in-memory snapshot for this profile if we already loaded it.
        if let snap = cacheByProfile[nextKey] {
            options = snap.options
            lastAsked = snap.askedAt
            updatedAt = snap.updatedAt
            show(snap.options)
            scheduleNextReset()
            // Refresh silently in background only if stale (>= 5 min).
            refresh(reason: .foreground)
            return
        }

        // 2. Otherwise piggyback on ModelCatalogCache if a chat under this bot already read `model.options`.
        if let acc = services?.account?.id,
           let cached = ModelCatalogCache.shared.sibling(.init(account: acc, profile: nextKey, scope: "global")) {
            let now = Date()
            cacheByProfile[nextKey] = ProfileSnapshot(options: cached, askedAt: now, updatedAt: now)
            options = cached
            lastAsked = now
            updatedAt = now
            show(cached)
            scheduleNextReset()
            return
        }

        // 3. First time seeing this profile: load once (keeping current bars until the answer lands to avoid flash).
        lastAsked = nil
        refresh(reason: .initial)
    }

    /// Piggybacks on any `model.options` fetch made by Model Menu, Usage & Limits, or chat warm-up: zero extra HTTP.
    private func catalogStored(account acc: String?, profile prof: String?, scope: String?) {
        guard Self.shown, let acc, acc == services?.account?.id, let scope else { return }
        let key = ModelCatalogCache.Key(account: acc, profile: prof ?? "", scope: scope)
        guard let loaded = ModelCatalogCache.shared.cached(key) else { return }
        let normalized = Self.normalizeProfile(prof)
        let now = Date()
        cacheByProfile[normalized] = ProfileSnapshot(options: loaded, askedAt: now, updatedAt: now)
        guard normalized == profileKey else { return }
        options = loaded
        lastAsked = now
        updatedAt = now
        show(loaded)
        scheduleNextReset()
    }

    /// A chat turn finished: Hermes's own post-turn `session.usage` fetch lands in `account_usage_cache` within a
    /// couple seconds, so coalesce into one delayed read throttled to `afterTurnMinimum` (2 min).
    private func turnCompleted(account acc: String?, profile prof: String?) {
        guard Self.shown, visible else { return }
        guard acc == nil || acc == services?.account?.id else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        if let prof, Self.normalizeProfile(prof) != profileKey { return }
        pendingTurnRefresh?.cancel()
        pendingTurnRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SidebarUsage.afterTurnDelay))
            guard !Task.isCancelled else { return }
            self?.pendingTurnRefresh = nil
            self?.refresh(reason: .afterTurn)
        }
    }

    /// Schedules a single one-shot wake at the soonest upcoming window reset so refilled gauges update cleanly
    /// without a 60-second repeating timer.
    private func scheduleNextReset() {
        resetTask?.cancel()
        resetTask = nil
        guard Self.shown, let next = SidebarUsage.nextReset(in: blocks, now: Date()) else { return }
        let delay = max(2, next.timeIntervalSinceNow + 2)
        // Cap absurdly far timers (> 24h) — foreground activation will handle multi-day windows.
        guard delay <= 86_400 else { return }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.resetTask = nil
            if let options = self.options { self.show(options) }
            self.scheduleNextReset()
            if self.visible, UIApplication.shared.applicationState == .active {
                self.refresh(reason: .click)
            }
        }
    }

    /// Asks the gateway only when the triggering event justifies a read and the last answer is stale enough.
    /// A failed read keeps what was shown.
    func refresh(reason: RefreshReason = .foreground) {
        guard Self.shown else { return }
        #if DEBUG
        if let demo = Self.demoBlocks() {
            if demo != blocks { blocks = demo; updatedAt = Date(); announce() }
            return
        }
        #endif
        // Never hit the network while hidden in a short window, except when the user explicitly clicked/refreshed.
        if !visible, reason != .click, reason != .manual { return }
        guard let services, var api = (services as? GatewaySettingsServices)?.settingsAPI else { forget(); return }
        let id = services.account?.id
        if id != account {   // another gateway: its own plans, never the last one's
            account = id
            forget()
        }
        // Before hitting the network on initial/foreground load, check if ModelCatalogCache already holds a fresh copy.
        if reason != .manual, reason != .afterTurn, lastAsked == nil, let id,
           let cached = ModelCatalogCache.shared.sibling(.init(account: id, profile: profileKey, scope: "global")) {
            let now = Date()
            cacheByProfile[profileKey] = ProfileSnapshot(options: cached, askedAt: now, updatedAt: now)
            options = cached
            lastAsked = now
            updatedAt = now
            show(cached)
            scheduleNextReset()
            return
        }
        guard reading == nil else { return }
        let now = Date()
        let interval: TimeInterval = switch reason {
        case .initial: SidebarUsage.foregroundStaleAfter
        case .foreground: SidebarUsage.foregroundStaleAfter
        case .afterTurn: SidebarUsage.afterTurnMinimum
        case .click: SidebarUsage.clickMinimum
        case .manual: 0
        }
        if interval > 0, !SidebarUsage.due(last: lastAsked, now: now, every: interval) { return }
        lastAsked = now
        generation += 1
        let mine = generation
        let targetProfile = activeProfile
        let targetKey = profileKey
        api.profile = targetProfile
        let scopedAPI = api
        isRefreshing = true
        announce()
        reading = Task { [weak self] in
            defer {
                if let self, self.generation == mine {
                    self.reading = nil
                    if self.isRefreshing {
                        self.isRefreshing = false
                        self.announce()
                    }
                }
            }
            let first: ModelOptions
            do { first = try await scopedAPI.modelCatalog() } catch {
                AppLog.note("mac", "sidebar usage: the catalog read failed (\(error))")
                return
            }
            self?.heard(first, forProfile: targetKey, read: mine)
            // The gateway asks the providers after a read: a login it hadn't heard from is often known a moment later.
            guard UsageLimitsModel.worthAskingAgain(first) else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let again = try? await scopedAPI.modelCatalog() else { return }
            self?.heard(again, forProfile: targetKey, read: mine)
        }
    }

    private func heard(_ options: ModelOptions, forProfile key: String, read: Int) {
        guard read == generation else { return }
        let now = Date()
        cacheByProfile[key] = ProfileSnapshot(options: options, askedAt: now, updatedAt: now)
        self.options = options
        updatedAt = now
        isRefreshing = false
        show(options)
        scheduleNextReset()
        let signedIn = options.providers.filter { $0.authenticated != false }.count
        AppLog.note("mac", "sidebar usage: \(signedIn) signed-in providers, \(blocks.count) report a plan, \(rows.rows.count) at the foot")
    }

    private func show(_ options: ModelOptions) {
        let next = UsageLimitsModel.blocks(options, currentProvider: "")
        let changed = next != blocks
        blocks = next
        if changed || isRefreshing == false { announce() }
    }

    /// Signed out, or another gateway: nothing of the last one's stays, and a read under way is dropped.
    private func forget() {
        generation += 1
        reading?.cancel()
        reading = nil
        pendingTurnRefresh?.cancel()
        pendingTurnRefresh = nil
        resetTask?.cancel()
        resetTask = nil
        options = nil
        cacheByProfile = [:]
        lastAsked = nil
        updatedAt = nil
        isRefreshing = false
        guard !blocks.isEmpty else { return }
        blocks = []
        announce()
    }

    private func announce() { NotificationCenter.default.post(name: Self.changed, object: nil) }

    #if DEBUG
    /// `-HQDemoUsage YES` (pictures): two plans with their allowances, no gateway asked. `low` shows a plan nearly out.
    private static func demoBlocks() -> [UsageBlock]? {
        guard let kind = UserDefaults.standard.string(forKey: "HQDemoUsage"), kind != "NO" else { return nil }
        let now = Date()
        func gauge(_ id: String, _ title: String, _ left: Double, hours: Double) -> UsageGauge {
            let resets = now.addingTimeInterval(hours * 3600)
            return UsageGauge(id: id, title: title, left: left, reset: "resets \(UsageDates.until(resets, now: now))", resetsAt: resets)
        }
        let low = kind == "low"
        return [
            UsageBlock(id: "anthropic", provider: "anthropic", title: "Claude", account: nil, current: false,
                       gauges: [gauge("a.0", "Current session", low ? 0.07 : 0.62, hours: 2.2), gauge("a.1", "Current week", low ? 0.19 : 0.41, hours: 75)],
                       notes: []),
            UsageBlock(id: "openai-codex", provider: "openai-codex", title: "Codex", account: nil, current: false,
                       gauges: [gauge("c.0", "Session", 0.88, hours: 3.5), gauge("c.1", "Weekly", 0.73, hours: 120)],
                       notes: []),
        ]
    }
    #endif
}

/// The block at the sidebar's foot.
final class MacSidebarUsage: UIView {
    /// A click on a plan: the sidebar opens the panel hung from `view`.
    var onOpen: ((UIView) -> Void)?
    private let stack = UIStackView()
    private var signature = ""
    private(set) var isEmpty = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        accessibilityIdentifier = "mac-sidebar.usage"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Draws `rows` for the open sidebar (bars) or the folded rail (rings). Nothing to draw: no height at all.
    func show(_ rows: [SidebarUsageRow], more: Int, folded: Bool) {
        let chrome = MacSidebar.chrome
        let next = "\(folded)|\(chrome)|\(more)|" + rows.map { row in
            row.id + row.title + row.shortName + (row.note ?? "") + row.all.map { "\($0.title)\(Int($0.left * 1000))\($0.reset ?? "")" }.joined()
        }.joined(separator: "|")
        guard next != signature else {
            stack.arrangedSubviews.forEach { $0.setNeedsLayout() }   // the theme may have changed: the rings' ink again
            return
        }
        signature = next
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        isEmpty = rows.isEmpty
        isHidden = rows.isEmpty
        stack.spacing = folded ? (6 * chrome).rounded() : (4 * chrome).rounded()
        stack.alignment = folded ? .center : .fill
        for row in rows {
            let plan: UIControl = folded ? UsageRing(row: row) : UsagePlan(row: row)
            plan.addAction(UIAction { [weak self, weak plan] _ in
                guard let self, let plan else { return }
                self.onOpen?(plan)
            }, for: .touchUpInside)
            stack.addArrangedSubview(plan)
        }
        if more > 0, !folded {
            let label = UILabel()
            label.text = "\(more) more"
            label.font = MacSidebar.font(MacSidebar.scheme.count)
            label.textColor = MacSidebar.quietInk
            let box = UIView()
            label.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: MacSidebar.contentLeading),
                label.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
                label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            ])
            stack.addArrangedSubview(box)
        }
    }

    /// The ink of a bar or a ring: quiet while there is plenty, orange under a quarter, red under a tenth (the page's
    /// own steps). The sidebar's own ink while fine, not the accent: nothing here asks to be looked at until it should.
    fileprivate static func ink(_ gauge: UsageGauge) -> UIColor {
        switch SidebarUsage.level(gauge) {
        case .fine: HQPalette.label.withAlphaComponent(0.58)
        case .warning: HQPalette.orange
        case .low: HQPalette.red
        }
    }

    fileprivate static let track = UIColor { traits in
        HQPalette.label.resolvedColor(with: traits).withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.14 : 0.11)
    }
}

/// One plan in the open sidebar: its name, then a line per allowance (name, bar, what is left).
private final class UsagePlan: UIControl {
    private var hovered = false

    init(row: SidebarUsageRow) {
        super.init(frame: .zero)
        let chrome = MacSidebar.chrome
        let type = MacSidebar.scheme
        let lines = UIStackView()
        lines.axis = .vertical
        lines.spacing = (3 * chrome).rounded()
        lines.isUserInteractionEnabled = false
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        let pad = (5 * chrome).rounded()
        NSLayoutConstraint.activate([
            lines.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacSidebar.contentLeading),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacSidebar.edgeInset),
        ])

        let title = UILabel()
        title.text = row.title
        title.font = MacSidebar.font(type.heading, weight: .semibold)
        title.textColor = HQPalette.label2
        title.lineBreakMode = .byTruncatingTail
        lines.addArrangedSubview(title)

        // One column for the names, one for the figures, so the bars start and end together down the block.
        let nameFont = MacSidebar.font(type.count)
        let nameWidth = row.gauges.map { (SidebarUsage.shortTitle($0) as NSString).size(withAttributes: [.font: nameFont]).width }.max() ?? 0
        let figureFont = HQFont.monoDigit(ofSize: nameFont.pointSize, weight: .regular)
        let figureWidth = ("100%" as NSString).size(withAttributes: [.font: figureFont]).width
        for gauge in row.gauges {
            let name = UILabel()
            name.text = SidebarUsage.shortTitle(gauge)
            name.font = nameFont
            name.textColor = HQPalette.label.withAlphaComponent(0.74)
            name.lineBreakMode = .byTruncatingTail
            let bar = UsageBarView(left: gauge.left, ink: MacSidebarUsage.ink(gauge))
            let figure = UILabel()
            figure.text = SidebarUsage.figure(gauge)
            figure.font = figureFont
            figure.textAlignment = .right
            figure.textColor = SidebarUsage.level(gauge) == .fine ? HQPalette.label.withAlphaComponent(0.74) : MacSidebarUsage.ink(gauge)
            let line = UIStackView(arrangedSubviews: [name, bar, figure])
            line.axis = .horizontal
            line.alignment = .center
            line.spacing = (8 * chrome).rounded()
            NSLayoutConstraint.activate([
                name.widthAnchor.constraint(equalToConstant: min(ceil(nameWidth), (96 * chrome).rounded())),
                figure.widthAnchor.constraint(equalToConstant: ceil(figureWidth)),
                bar.heightAnchor.constraint(equalToConstant: UsageBarView.height),
            ])
            lines.addArrangedSubview(line)
        }
        if row.gauges.isEmpty, let note = row.note {
            let label = UILabel()
            label.text = note
            label.font = nameFont
            label.textColor = HQPalette.orange
            label.lineBreakMode = .byTruncatingTail
            lines.addArrangedSubview(label)
        }

        layer.cornerRadius = MacSelection.radius
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = SidebarUsage.spoken(row)
        accessibilityHint = "Shows every plan"
        accessibilityIdentifier = "mac-sidebar.usage." + row.id
        toolTip = SidebarUsage.tip(row)
        MacHover.drawsOwnHover(self)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool { didSet { recolor() } }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        hovered = recognizer.state == .began || recognizer.state == .changed
        recolor()
    }

    private func recolor() {
        backgroundColor = isHighlighted || hovered ? MacSidebar.rowHover : .clear
    }
}

/// One plan on the folded rail: a circular progress ring with the percentage left inside and the plan's name
/// directly underneath — instantly readable at a glance without cryptic initials.
private final class UsageRing: UIControl {
    private let ringHost = UIView()
    private let trackLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let left: Double
    private let ink: UIColor
    private var hovered = false
    private let side: CGFloat

    init(row: SidebarUsageRow) {
        let chrome = MacSidebar.chrome
        side = (34 * chrome).rounded()
        left = row.tightest?.left ?? 0
        ink = row.tightest.map(MacSidebarUsage.ink) ?? HQPalette.orange
        super.init(frame: .zero)

        ringHost.isUserInteractionEnabled = false
        ringHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ringHost)

        let line = max(2.5, (2.75 * chrome).rounded())
        for shape in [trackLayer, ringLayer] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = line
            shape.lineCap = .round
            ringHost.layer.addSublayer(shape)
        }

        let value = UILabel()
        let text = row.ringText
        value.text = text
        let valueSize: CGFloat = text.count >= 4 ? 9.5 : 10.5
        value.font = HQFont.monoDigit(ofSize: (valueSize * chrome).rounded(), weight: .semibold)
        let warn = row.tightest.map { SidebarUsage.level($0) != .fine } ?? true
        value.textColor = warn ? ink : HQPalette.label.withAlphaComponent(0.84)
        value.textAlignment = .center
        value.adjustsFontSizeToFitWidth = true
        value.minimumScaleFactor = 0.78
        value.isUserInteractionEnabled = false
        value.translatesAutoresizingMaskIntoConstraints = false
        ringHost.addSubview(value)

        let caption = UILabel()
        caption.text = row.shortName
        caption.font = MacSidebar.font(10.5, weight: .medium)
        caption.textColor = HQPalette.label2
        caption.textAlignment = .center
        caption.lineBreakMode = .byTruncatingTail
        caption.isUserInteractionEnabled = false
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)

        let boxWidth = max(side + 16, (54 * chrome).rounded())
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: boxWidth),
            ringHost.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            ringHost.centerXAnchor.constraint(equalTo: centerXAnchor),
            ringHost.widthAnchor.constraint(equalToConstant: side),
            ringHost.heightAnchor.constraint(equalToConstant: side),
            value.centerXAnchor.constraint(equalTo: ringHost.centerXAnchor),
            value.centerYAnchor.constraint(equalTo: ringHost.centerYAnchor),
            value.widthAnchor.constraint(lessThanOrEqualTo: ringHost.widthAnchor, constant: -(line * 2 + 2)),
            caption.topAnchor.constraint(equalTo: ringHost.bottomAnchor, constant: 2),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])

        layer.cornerRadius = MacSelection.radius
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = SidebarUsage.spoken(row)
        accessibilityHint = "Shows every plan"
        accessibilityIdentifier = "mac-sidebar.usage." + row.id
        toolTip = SidebarUsage.tip(row)
        MacHover.drawsOwnHover(self)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (ring: UsageRing, _) in ring.colour() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let line = trackLayer.lineWidth
        let radius = (side - line) / 2
        let centre = CGPoint(x: ringHost.bounds.midX, y: ringHost.bounds.midY)
        // From twelve o'clock, clockwise: what is left of the allowance.
        let whole = UIBezierPath(arcCenter: centre, radius: radius, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true)
        trackLayer.path = whole.cgPath
        ringLayer.path = whole.cgPath
        ringLayer.strokeEnd = left <= 0 ? 0 : max(0.02, left)
        colour()
    }

    private func colour() {
        trackLayer.strokeColor = MacSidebarUsage.track.resolvedColor(with: traitCollection).cgColor
        ringLayer.strokeColor = ink.resolvedColor(with: traitCollection).cgColor
    }

    override var isHighlighted: Bool { didSet { recolor() } }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        hovered = recognizer.state == .began || recognizer.state == .changed
        recolor()
    }

    private func recolor() {
        backgroundColor = isHighlighted || hovered ? MacSidebar.rowHover : .clear
    }
}

/// A thin bar of what is left, from the leading edge.
private final class UsageBarView: UIView {
    static var height: CGFloat { max(3, (4 * MacSidebar.chrome).rounded()) }
    private let fill = UIView()
    private let left: Double

    init(left: Double, ink: UIColor) {
        self.left = max(0, min(1, left))
        super.init(frame: .zero)
        backgroundColor = MacSidebarUsage.track
        fill.backgroundColor = ink
        addSubview(fill)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        fill.layer.cornerRadius = bounds.height / 2
        // Something left always shows as at least a dot; nothing left shows nothing.
        let width = left <= 0 ? 0 : max(bounds.height, bounds.width * left)
        fill.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
    }
}

// MARK: - Every plan in full (the panel a click opens)

@MainActor
enum SidebarUsagePanel {
    /// The panel hung from `source`: every plan and allowance with its reset time, and the way on to the open chat's
    /// Usage & Limits page when a chat is on show.
    static func present(from source: UIView, in host: UIViewController, openPage: (() -> Void)?) {
        let store = SidebarUsageStore.shared
        store.refresh(reason: .click)
        let page = UIHostingController(rootView: SidebarUsagePanelView(openPage: openPage.map { open in
            { [weak host] in host?.dismiss(animated: true) { open() } }
        }))
        page.modalPresentationStyle = .popover
        page.preferredContentSize = CGSize(width: SidebarUsagePanelView.width, height: SidebarUsagePanelView.height(button: openPage != nil))
        page.view.backgroundColor = .clear
        if let popover = page.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
            popover.permittedArrowDirections = [.left, .down]
        }
        host.present(page, animated: true)
    }
}

private struct SidebarUsagePanelView: View {
    var openPage: (() -> Void)?
    @State private var blocks = SidebarUsageStore.shared.blocks
    @State private var updated = SidebarUsageStore.shared.updatedAt
    @State private var refreshing = SidebarUsageStore.shared.isRefreshing
    @State private var now = Date()

    /// False only to measure: the panel is as tall as what it lists, and a scroll view has no height of its own.
    var scrolls = true

    static let width: CGFloat = 420

    /// The panel's own height for what the store holds now (a guessed one left a strip of empty glass under the
    /// button), up to a cap past which it scrolls.
    static func height(button: Bool) -> CGFloat {
        let probe = UIHostingController(rootView: SidebarUsagePanelView(openPage: button ? {} : nil, scrolls: false))
        let fit = probe.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return min(560, max(80, fit.height.rounded(.up)))
    }

    var body: some View {
        Group {
            if scrolls { ScrollView { sheet } } else { sheet }
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarUsageStore.changed)) { _ in
            blocks = SidebarUsageStore.shared.blocks
            updated = SidebarUsageStore.shared.updatedAt
            refreshing = SidebarUsageStore.shared.isRefreshing
            now = Date()
        }
        .task {
            // Local-only countdown tick while the popover is open — stops immediately on dismiss.
            guard scrolls else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { now = Date() }
            }
        }
        .accessibilityIdentifier("mac-sidebar.usage.panel")
    }

    private var sheet: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Plan Usage").font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                    Spacer()
                    if let line = UsageLimitsModel.freshness(updated, now: now, offline: false) {
                        Text(line).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    }
                    Button {
                        SidebarUsageStore.shared.refresh(reason: .manual)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(Font.hq(.footnote).weight(.medium))
                            .foregroundStyle(Color.hqLabel2)
                            .opacity(refreshing ? 0.45 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(refreshing)
                    .help("Refresh Plan Usage")
                    .accessibilityLabel("Refresh Plan Usage")
                    .accessibilityIdentifier("mac-sidebar.usage.refresh")
                }
                if blocks.isEmpty {
                    Text("No signed-in plan reports an allowance yet.")
                        .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
                ForEach(blocks) { block in
                    VStack(alignment: .leading, spacing: 10) {
                        Text([block.title, block.account].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel)
                        ForEach(block.gauges) { gauge in
                            let label = SidebarUsage.shortTitle(gauge)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(label).foregroundStyle(Color.hqLabel).lineLimit(1)
                                    Spacer(minLength: 12)
                                    // One line: "7% left · resets in 2h 12m" broke after "in" at the panel's width.
                                    Text(gauge.detail).foregroundStyle(Color.hqLabel2).monospacedDigit()
                                        .lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
                                }
                                .font(Font.hq(.footnote))
                                UsageBar(left: gauge.left, elapsed: gauge.elapsed, height: 6)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(label), \(gauge.detail)")
                        }
                        ForEach(block.notes, id: \.self) { note in
                            Text(note).font(Font.hq(.footnote)).foregroundStyle(Color.hqOrange)
                        }
                    }
                }
                if let openPage {
                    Button("Open Usage & Limits…", action: openPage)
                        .font(Font.hq(.subheadline))
                        .accessibilityIdentifier("mac-sidebar.usage.open-page")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif

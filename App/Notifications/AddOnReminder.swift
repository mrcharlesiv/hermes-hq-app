// [addon-reminder] Owner 2026-10-30: someone who says Not Now to the add-on offer shouldn't get one chance and then
// nothing, nor an alert every week. The alert shows once for each add-on level a build asks for
// (`PushPolicy.offerLevel`); after that the app reminds quietly on every launch, as iOS shows Software Update: a count
// on the tab that holds Settings (More, or Settings when it is a tab of its own), a badge on More's Settings row, and
// an "Add-on Update Available" row at the top of Settings that runs the same update. Kept per account, so the count is
// there the moment the app opens; `PushSetupOffer.check` sets it from what the gateway says (a failed read never
// sets or clears it).
// [browser-update] The browser add-on (hermes-hq-browser) out of date counts too: the same count, row and update.

import Observation
import SwiftUI
import UIKit

@MainActor @Observable final class AddOnReminder {
    static let shared = AddOnReminder()
    static let didChange = Notification.Name("push.addOnReminder.didChange")

    nonisolated enum Need: Equatable, Codable, Sendable {
        /// The gateway has no add-on at all.
        case missing
        /// The main bot's copy is older than this build asks for.
        case outdated
        /// The main bot's copy is current; these bots (names) have none of their own, or an old one.
        case bots([String])
    }

    private(set) var need: Need?
    /// [addon-progress] The add-on version this build needs, found not out yet (an update got an older one): the row
    /// says so with no red count, since there is nothing to update to. Kept a day per account, then the count is back
    /// and a tap looks again.
    private(set) var notOut: String?
    /// [browser-update] The browser add-on is installed and needs `BrowserAddOn.wantedVersion` (kept per account, as
    /// `need` is; only a read of its /health sets or clears it).
    private(set) var browser: BrowserAddOn.Need?
    @ObservationIgnored private var account = ""
    @ObservationIgnored var defaults: UserDefaults = .standard
    @ObservationIgnored var now: () -> Date = Date.init

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ account: String) -> String { "push.addOnReminder.\(account)" }
    private func notOutKey(_ account: String) -> String { "push.addOnReminder.notOut.\(account)" }
    private func browserKey(_ account: String) -> String { "push.addOnReminder.browser.\(account)" }

    /// How long a "not out yet" holds before the reminder counts again.
    nonisolated static let notOutHold: TimeInterval = 24 * 60 * 60

    /// The red count on the tab and on More's Settings row: something to update to.
    var badged: Bool { (need != nil && notOut == nil) || browser != nil }

    /// The signed-in account's reminder; "" (signed out) has none.
    func use(account: String) {
        guard account != self.account else { return }
        self.account = account
        let saved = account.isEmpty ? nil : defaults.data(forKey: key(account)).flatMap { try? JSONDecoder().decode(Need.self, from: $0) }
        notOut = account.isEmpty ? nil : savedNotOut(account)
        browser = account.isEmpty ? nil : defaults.string(forKey: browserKey(account)).flatMap(BrowserAddOn.Need.init(rawValue:))
        show(saved, force: true)
    }

    /// [addon-progress] An update found the newest add-on out older than `want`.
    func noteNotOut(account: String, want: String) {
        guard !account.isEmpty else { return }
        use(account: account)
        defaults.set(["want": want, "at": now().timeIntervalSince1970], forKey: notOutKey(account))
        notOut = want
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func savedNotOut(_ account: String) -> String? {
        guard let saved = defaults.dictionary(forKey: notOutKey(account)), let want = saved["want"] as? String,
              let at = saved["at"] as? Double,
              Self.notOutHolds(want: want, at: Date(timeIntervalSince1970: at), now: now(), needed: PushSetupOffer.neededVersion(main: true))
        else { return nil }
        return want
    }

    /// Still worth saying: the same version is needed (a newer build asks afresh) and the day isn't over.
    nonisolated static func notOutHolds(want: String, at: Date, now: Date, needed: String) -> Bool {
        want == needed && now.timeIntervalSince(at) < notOutHold && now >= at
    }

    /// What the gateway said about its add-on. `.unknown` changes nothing.
    func report(account: String, state: PushPolicy.PluginState, without bots: [String]) {
        guard state != .unknown, !account.isEmpty else { return }
        use(account: account)
        let value = Self.need(state: state, without: bots)
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key(account)) }
        else { defaults.removeObject(forKey: key(account)) }
        // [addon-progress] Nothing needed any more: no "not out yet" either.
        let wasNotOut = notOut
        if value == nil { defaults.removeObject(forKey: notOutKey(account)) }
        notOut = value == nil ? nil : savedNotOut(account)
        show(value, force: notOut != wasNotOut)
    }

    /// [browser-update] What the browser add-on's /health said: `nil` when it needs nothing (current, or not there).
    /// A failed read isn't reported, so it neither sets nor clears it.
    func reportBrowser(account: String, need value: BrowserAddOn.Need?) {
        guard !account.isEmpty else { return }
        use(account: account)
        if let value { defaults.set(value.rawValue, forKey: browserKey(account)) } else { defaults.removeObject(forKey: browserKey(account)) }
        guard value != browser else { return }
        browser = value
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Signing out of an account forgets its reminder.
    func signOut(account: String) {
        defaults.removeObject(forKey: key(account))
        defaults.removeObject(forKey: notOutKey(account))
        defaults.removeObject(forKey: browserKey(account))
        if account == self.account { notOut = nil; browser = nil; show(nil, force: true) }
    }

    /// What to remind about, from a gateway's answer (`bots`: the other bots without a current copy of their own).
    nonisolated static func need(state: PushPolicy.PluginState, without bots: [String]) -> Need? {
        switch state {
        case .unknown: nil
        case .missing: .missing
        case .outdated: bots.isEmpty ? .outdated : .bots(bots)
        case .ready: bots.isEmpty ? nil : .bots(bots)
        }
    }

    private func show(_ value: Need?, force: Bool = false) {
        guard value != need || force else { return }
        need = value
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: Words

    /// The row at the top of Settings.
    var title: String? {
        // [browser-update] An update to make (the browser add-on's) wins over "not out yet" (the notification add-on's).
        if browser != nil { return need == .missing ? "Add-on Needed" : "Add-on Update Available" }
        if need != nil, let notOut { return "Add-on \(notOut) Not Out Yet" }
        switch need {
        case nil: return nil
        case .missing: return "Add-on Needed"
        case .outdated, .bots: return "Add-on Update Available"
        }
    }

    /// Under the row: what isn't working, in one sentence.
    var footer: String? {
        if let browser { return Self.footer(need: notOut == nil ? need : nil, browser: browser) }
        if need != nil, let notOut {
            return "This version of \(AppIdentity.current.displayName) needs add-on \(notOut), and the newest one out is older. Some new features won’t work until it’s out. \(DeviceWord.Tap) to check again."
        }
        return need.map(Self.footer)
    }

    /// [addon-progress] The same words for any need (the update sheet's question).
    nonisolated static func footer(_ need: Need) -> String {
        let app = AppIdentity.current.displayName
        switch need {
        case .missing:
            return "Hermes needs a small add-on so \(app) can alert you while it’s closed and bots can ask you things on a card."
        case .outdated:
            return "Hermes’s add-on for \(app) is out of date, so some alerts and features don’t work."
        case .bots(let names):
            let one = names.count == 1
            return "\(Self.names(names)) \(one ? "doesn’t" : "don’t") have Hermes’s add-on for \(app) yet, so \(one ? "its" : "their") approvals and questions can’t reach you."
        }
    }

    /// [browser-update] The browser add-on's sentence, alone or after the notification add-on's.
    nonisolated static func footer(need: Need?, browser: BrowserAddOn.Need) -> String {
        let alone = browser == .off
            ? "Hermes’s browser add-on switched itself off after Hermes updated, so you can’t watch a bot’s browser. Add-on \(BrowserAddOn.wantedVersion) turns it back on."
            : "Hermes’s browser add-on is out of date, so watching a bot’s browser may not work."
        guard let need else { return alone }
        let also = browser == .off ? "The browser add-on is off until it’s updated too." : "The browser add-on needs an update too."
        return "\(footer(need)) \(also)"
    }

    /// For VoiceOver on the tab and More's Settings row.
    var spoken: String? { !badged ? nil : (need == .missing && browser == nil ? "Add-on needed" : "Add-on update available") }

    /// "Gym", "Gym and Ivy", "Gym, Ivy and 3 more".
    nonisolated static func names(_ names: [String]) -> String {
        let shown = Array(names.prefix(2)), rest = names.count - shown.count
        if rest > 0 { return shown.joined(separator: ", ") + " and \(rest) more" }
        return shown.count == 2 ? "\(shown[0]) and \(shown[1])" : shown.first ?? ""
    }
}

// MARK: - The red count (iOS Settings' Software Update badge)

/// A red pill with a count, white digits, as iOS Settings marks a row that needs you. Grows with the text.
enum CountBadge {
    static func view(_ count: Int) -> UIView { Pill(count: count) }

    private final class Pill: UIView {
        private let label = UILabel()

        init(count: Int) {
            super.init(frame: .zero)
            label.text = "\(count)"
            label.font = HQFont.scaled(16, weight: .regular, like: .callout, design: .rounded)
            label.textColor = .white
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor),
                                         label.centerYAnchor.constraint(equalTo: centerYAnchor)])
            backgroundColor = .systemRed
            layer.cornerCurve = .continuous
            isAccessibilityElement = false
            frame.size = intrinsicContentSize
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var intrinsicContentSize: CGSize {
            let text = label.intrinsicContentSize, side = ceil(label.font.lineHeight + 3)
            return CGSize(width: max(side, ceil(text.width) + side / 2), height: side)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = bounds.height / 2
        }
    }
}

/// The same pill in SwiftUI rows.
struct CountBadgeView: View {
    let count: Int
    // [ui-sizing 2026-11-09] The digit and the pill grow together, as the UIKit pill: the pill followed the text size
    // and UI Scale while the digit followed UI Scale only, so at the largest text sizes a 64 pt red pill held a 16 pt "1".
    @ScaledMetric(relativeTo: .callout) private var textSide: CGFloat = 22
    private var side: CGFloat { min(textSide, 34) * HQFont.scale }

    var body: some View {
        Text("\(count)")
            .font(.system(size: side * 16 / 22, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, side / 4)
            .frame(minWidth: side, minHeight: side)
            .background(Capsule().fill(Color(uiColor: .systemRed)))
            .accessibilityHidden(true)
    }
}

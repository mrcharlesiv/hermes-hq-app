// [a11y] One way to speak (spec 3x-a11y §2.4): errors may interrupt, progress waits its turn. A caller that can fire
// repeatedly for one event (a countdown, a retry, a status that re-publishes) passes `coalesce: true`, and the same
// words within 2 s are then said once. Everything else is spoken every time ("Copied" on two messages in a row). DEBUG keeps the last 20 for UI tests (`debug.announce`).

import UIKit

enum HQAnnounce {
    /// With `coalesce`, the same text inside this window is dropped.
    static let window: TimeInterval = 2
    private static var recent: [String: Date] = [:]
    /// Newest last; at most 20. Filled only when VoiceOver (or its DEBUG override) is on, or in tests.
    private(set) static var log: [String] = []
    /// Tests: record even when VoiceOver is off.
    static var alwaysLog = false
    static var now: () -> Date = { Date() }

    /// Speaks `text` if VoiceOver is running. `.high` interrupts speech (errors, a reply peek); `.default` waits its
    /// turn; `.low` is dropped if anything else is speaking.
    @discardableResult
    static func say(_ text: String?, priority: UIAccessibilityPriority = .default, coalesce: Bool = false) -> Bool {
        guard let text, !text.isEmpty else { return false }
        // Read now, not from the cached flag: an announcement posted in the same turn VoiceOver starts must not be lost.
        guard HQAccessibility.overrides.voiceOver || UIAccessibility.isVoiceOverRunning || alwaysLog else { return false }
        let time = now()
        recent = recent.filter { time.timeIntervalSince($0.value) < window }
        if coalesce, recent[text] != nil { return false }
        recent[text] = time
        log.append(text)
        if log.count > 20 { log.removeFirst(log.count - 20) }
        #if DEBUG
        HQAnnounceProbe.update()
        #endif
        let spoken = NSAttributedString(string: text, attributes: [.accessibilitySpeechAnnouncementPriority: priority])
        UIAccessibility.post(notification: .announcement, argument: spoken)
        return true
    }

    /// The words were left to the element VoiceOver was moved to (no announcement posted). DEBUG logs it as
    /// "focus: <words>" so a UI test can tell "spoken once" from "never spoken".
    static func noteFocusSpoke(_ text: String) {
        #if DEBUG
        guard HQAccessibility.overrides.voiceOver || UIAccessibility.isVoiceOverRunning || alwaysLog else { return }
        log.append("focus: " + text)
        if log.count > 20 { log.removeFirst(log.count - 20) }
        HQAnnounceProbe.update()
        #endif
    }

    static func screenChanged(_ focus: Any? = nil) { UIAccessibility.post(notification: .screenChanged, argument: focus) }
    static func layoutChanged(_ focus: Any? = nil) { UIAccessibility.post(notification: .layoutChanged, argument: focus) }

    static func resetForTests() { recent = [:]; log = []; now = { Date() } }
}

#if DEBUG
/// UI tests: a one-point element on the key window whose value is the announcements so far, newest last, joined by
/// " | " (the pattern `debug.cue-count` uses). Present only with an `-HQA11y…` override or `-HQA11yAudit YES`.
@MainActor enum HQAnnounceProbe {
    private static weak var label: UILabel?

    static var wanted: Bool { HQAccessibility.overrides != .init() || UserDefaults.standard.bool(forKey: "HQA11yAudit") }

    static func update() {
        guard wanted else { return }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let probe = label ?? {
            let made = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            made.isAccessibilityElement = true
            made.accessibilityIdentifier = "debug.announce"
            made.accessibilityLabel = "announcements"
            label = made
            return made
        }()
        if probe.window !== window { window.addSubview(probe) }
        probe.accessibilityValue = HQAnnounce.log.joined(separator: " | ")
    }
}
#endif

// [offline] DEBUG-only launch arguments for the offline stream's UI tests and screenshots (compiled out of Release;
// docs/spec/3x-offline.md §8). None carries a secret.
//
// - `-HQDebugResetCaches YES`            forget the local caches (lists, transcripts, the remembered chat), keep the
//                                        saved sign-ins: the state after an app update that wiped caches
// - `-HQDebugRestoreFailure <code>`      the saved sign-in "cannot be opened" with that Keychain reason
//                                        (keychain-locked | keychain-unavailable | keychain-unreadable), until Try Again
//                                        has been used `-HQDebugRestoreFailureCount <n>` times (default: for good)
// - `-HQDebugOfflineReason <code>`       the offline screen words itself for that reason whatever the connection met
//                                        (tls and tailscale-off cannot be produced against a loopback stand-in)
// - `-HQDebugStorageFailure YES|switch`  the account's storage check fails (the storage sentence): always, or only
//                                        before a gateway switch
// - `-HQDebugPowerSaving YES|NO`         Low Power Mode on or off for the polls (simctl cannot toggle it)
// - `-HQDebugProcessClaim <stored id>:<process id>`  a running background-process claim for that chat (the claim
//                                        source is the composer stream's row L461)
// - `-HQDebugLaunchHold <seconds>`       keep the launch screen up that long (screenshots of its states)
// - `-HQDebugExposeStatus YES`           the offline screen's visible countdown is readable by UI tests (VoiceOver
//                                        hears fixed words, never the number, so tests could not see it otherwise)
// - `-HQDebugNoticeStay <seconds>`       the reconnect notice stays that long instead of 6 s (a UI test taps the
//                                        bar buttons under it)
// With `-HQDebugExposeStatus YES` the window also carries a one-point element "debug.activations" whose value counts
// the activations that were returns and the ones that were not ("returns=1 moments=2"), so a UI test can tell that a
// pull of the notification shade really reached `sceneDidBecomeActive`, and (once the reconnect notice has shown) an
// element "debug.notice" whose value is the record of every sentence the notice put up: when, for how long, where.
// [settings] … and "debug.power" ("saving still" / "normal moving"). `notifyutil -p hqn.power.toggle` (or the same
// Darwin notification posted by a UI test) flips saving while the app runs.

#if DEBUG
import UIKit

enum OfflineDebug {
    private static var defaults: UserDefaults { .standard }
    private static var restoreFailuresServed = 0

    static func applyBeforeLaunch() {
        if defaults.bool(forKey: "HQDebugResetCaches") {
            TranscriptCache.shared.purgeAll()
            try? FileManager.default.removeItem(at: AppModel.listsCacheDirectory)
            LaunchChatMemory.shared.forgetAll()
        }
        if defaults.object(forKey: "HQDebugPowerSaving") != nil {
            PowerState.shared.override = defaults.bool(forKey: "HQDebugPowerSaving")
        }
        // [settings] `xcrun simctl spawn <UDID> notifyutil -p hqn.power.toggle` flips saving while the app runs
        // (docs/spec/3x-settings.md §3: simctl cannot toggle Low Power Mode).
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in PowerState.shared.toggleOverride() }
        }, "hqn.power.toggle" as CFString, nil, .deliverImmediately)
    }

    /// The Keychain failure a restore should pretend to meet, nil once the scripted count is spent.
    static func restoreFailure() -> GatewayFailure? {
        guard let code = defaults.string(forKey: "HQDebugRestoreFailure"), let failure = GatewayFailure.forCode(code),
              OfflineCopy.keychainReasons.contains(code) else { return nil }
        let limit = defaults.object(forKey: "HQDebugRestoreFailureCount") == nil ? Int.max : defaults.integer(forKey: "HQDebugRestoreFailureCount")
        guard restoreFailuresServed < limit else { return nil }
        restoreFailuresServed += 1
        return failure
    }

    static var offlineReason: String? { defaults.string(forKey: "HQDebugOfflineReason").flatMap { $0.isEmpty ? nil : $0 } }
    static var storageFailure: Bool { defaults.string(forKey: "HQDebugStorageFailure") == "YES" }
    static var launchHold: TimeInterval { defaults.double(forKey: "HQDebugLaunchHold") }
    static var exposesStatus: Bool { defaults.bool(forKey: "HQDebugExposeStatus") }
    static var noticeStay: TimeInterval? {
        let seconds = defaults.double(forKey: "HQDebugNoticeStay")
        return seconds > 0 ? seconds : nil
    }

    // The reconnect notice's record: "debug.notice" carries one line per sentence put up, oldest first (the last 16):
    // "<shown at, seconds since 1970>;<seconds it stayed, -1 while up>;<x>,<y>,<width>,<height>;<sentence>".
    private struct NoticeEntry { var start: Date; var end: Date?; var frame: CGRect; var sentence: String }
    private static var notices: [NoticeEntry] = []
    private static var noticeCount = 0
    private static weak var noticeView: UIView?

    static func noticeShown(_ sentence: String, frame: CGRect, in window: UIWindow?) {
        guard exposesStatus else { return }
        notices.append(NoticeEntry(start: Date(), end: nil, frame: frame, sentence: sentence))
        noticeCount += 1
        if notices.count > 16 { notices.removeFirst(notices.count - 16) }
        publishNotices(in: window)
    }

    static func noticeGone() {
        guard exposesStatus, let last = notices.indices.last, notices[last].end == nil else { return }
        notices[last].end = Date()
        publishNotices(in: noticeView?.window)
    }

    private static func publishNotices(in window: UIWindow?) {
        let view = noticeView ?? {
            let view = UIView(frame: CGRect(x: 2, y: 0, width: 1, height: 1))
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = "debug.notice"
            noticeView = view
            return view
        }()
        if let window, view.superview !== window { window.addSubview(view) }
        let lines = notices.map { entry -> String in
            let stayed = entry.end.map { String(format: "%.2f", $0.timeIntervalSince(entry.start)) } ?? "-1"
            let frame = [entry.frame.minX, entry.frame.minY, entry.frame.width, entry.frame.height].map { String(Int($0.rounded())) }.joined(separator: ",")
            return String(format: "%.2f", entry.start.timeIntervalSince1970) + ";\(stayed);\(frame);\(entry.sentence)"
        }
        view.accessibilityValue = "n=\(noticeCount)\n" + lines.joined(separator: "\n")
    }

    private static var returns = 0
    private static var moments = 0
    private static weak var activationsView: UIView?

    /// An activation happened (`returned`: it followed the background or was the first).
    static func noteActivation(returned: Bool, in window: UIWindow?) {
        guard exposesStatus, let window else { return }
        if returned { returns += 1 } else { moments += 1 }
        let view = activationsView ?? {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = "debug.activations"
            activationsView = view
            return view
        }()
        if view.superview !== window { window.addSubview(view) }
        view.accessibilityValue = "returns=\(returns) moments=\(moments)"
    }

    // [settings] With `-HQDebugExposeStatus YES` the window also carries "debug.power": "saving" or "normal", and
    // whether heads and decorative loops are held still ("saving still" / "normal moving"), kept current as the
    // power state changes (docs/spec/3x-settings.md §3).
    private static weak var powerView: UIView?
    private static var powerWatch: NSObjectProtocol?

    static func notePower(in window: UIWindow?) {
        guard exposesStatus, let window else { return }
        let view = powerView ?? {
            let view = UIView(frame: CGRect(x: 1, y: 0, width: 1, height: 1))
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = "debug.power"
            powerView = view
            return view
        }()
        if view.superview !== window { window.addSubview(view) }
        func write() {
            powerView?.accessibilityValue = (PowerState.shared.saving ? "saving" : "normal")
                + (HeadMotionSettings.shared.isStill && HQMotion.decorativeStill ? " still" : " moving")
        }
        write()
        if powerWatch == nil {
            // After the heads' own observer (registered when the first head was made), so the value is the settled one.
            powerWatch = NotificationCenter.default.addObserver(forName: PowerState.changed, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DispatchQueue.main.async { MainActor.assumeIsolated { write() } } }
            }
        }
    }

    /// `<stored id>:<process id>` → the two halves.
    static var processClaim: (stored: String, process: String)? {
        guard let raw = defaults.string(forKey: "HQDebugProcessClaim"), let colon = raw.lastIndex(of: ":") else { return nil }
        let stored = String(raw[..<colon]), process = String(raw[raw.index(after: colon)...])
        return stored.isEmpty || process.isEmpty ? nil : (stored, process)
    }
}
#endif

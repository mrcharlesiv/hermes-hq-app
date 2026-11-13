// [offline] What the offline screen says, by the connection's reason: never an address in a sentence and never a raw
// code (docs/spec/3x-offline.md §3.5, §3.6). Ported from the web app's `OFFLINE_COPY` and `showOffline`
// (`src/main.ts:331-381`), `retryCountdown` and `CONNECTING` (`src/connection-offline.ts:52-55`). Pure.

import Foundation

nonisolated enum OfflineCopy {
    struct Screen: Equatable, Sendable {
        var title: String
        var recovery: String
    }

    /// The card under the words: the gateway as people name it over "host:port · account".
    struct Card: Equatable, Sendable {
        var name: String
        var detail: String
    }

    static let tryAgain = "Try Again"
    /// The sign-in form prefilled with the saved gateway's address and username (UX study #125: the web's "Sign In to a
    /// Different Gateway" promised another gateway, and the form opens on the same one).
    static let differentGateway = "Change Address or Sign In"
    static let signInAgain = "Sign In Again"
    /// Another saved gateway, the switch the title menu makes (UX study #125).
    static func switchTo(_ name: String) -> String { "Switch to \(name)" }
    static let cancel = "Cancel"
    static let connecting = "Connecting…"
    /// VoiceOver hears this once per countdown: a count read later would already be wrong.
    static let retryingSpoken = "Trying again automatically"
    static let unreadableDetail = "Your saved sign-in could not be read."

    static let signInAgainTitle = "Sign In Again?"
    static let signInAgainMessage = "Hermes HQ couldn’t read your saved sign-in. Drafts on this \(DeviceWord.name) are kept aside and won’t move to the account you sign in with."

    static let keychainUnreadable = "keychain-unreadable"
    static let keychainLocked = "keychain-locked"
    static let keychainUnavailable = "keychain-unavailable"
    static let keychainReasons: Set<String> = [keychainLocked, keychainUnavailable, keychainUnreadable]

    private static let byReason: [String: Screen] = [
        // Audit 06-10: this phone has no network path (`GatewayFailure.offline`): not the computer's fault.
        "network": Screen(title: "You’re Offline",
                          recovery: "\(DeviceWord.Subject) isn’t connected to the internet. Hermes HQ reconnects as soon as it is."),
        "tailscale-off": Screen(title: "Turn On Tailscale",
                                recovery: "Turn on Tailscale to reach \(HostWord.phrase). Hermes HQ reconnects as soon as it’s on."),
        "timeout": Screen(title: "Hermes Isn’t Answering",
                          recovery: "The computer running Hermes may be asleep or on another network. Hermes HQ keeps trying."),
        "tls": Screen(title: "Can’t Verify Hermes",
                      recovery: "\(DeviceWord.Subject) doesn’t trust the HTTPS certificate of \(HostWord.phrase). Hermes HQ keeps trying; if this continues, sign in with a trusted address."),
        "gateway-outdated": Screen(title: "Update Hermes",
                                   recovery: "\(HostWord.sentence) has a version of Hermes that’s too old for Hermes HQ. Update Hermes there; Hermes HQ keeps trying."),
        "rate-limited": Screen(title: "Hermes Is Busy",
                               recovery: "It is limiting sign-ins right now. Hermes HQ will try again shortly."),
        "host-rejected": Screen(title: "Hermes Isn’t Accepting This Address",
                                recovery: "Hermes no longer accepts connections at the saved address. On the computer running Hermes, check HERMES_DASHBOARD_PUBLIC_URL in ~/.hermes/.env; Hermes HQ keeps trying."),
        "not-hermes": Screen(title: "Can’t Reach Hermes",
                             recovery: "The saved address answered, but not as Hermes. Hermes HQ keeps trying; check \(HostWord.phrase), or sign in with its current address."),
        // [kept-session] A proxy, Cloudflare or the network answered for Hermes with a refusal of its own.
        "blocked": Screen(title: "Something Is Blocking Hermes",
                          recovery: "The saved address answered, but something in front of Hermes turned \(DeviceWord.subject) away: a proxy, a firewall or the network you’re on. You’re still signed in, and Hermes HQ keeps trying."),
        keychainLocked: Screen(title: "Unlock Your \(DeviceWord.name)",
                               recovery: "Your saved sign-in is protected until \(DeviceWord.subject) is unlocked. Hermes HQ reconnects as soon as it is."),
        keychainUnavailable: Screen(title: "Can’t Open Your Saved Sign-In",
                                    recovery: "\(DeviceWord.Subject) couldn’t open it just now. Hermes HQ keeps trying. Your local drafts are being kept."),
        keychainUnreadable: Screen(title: "Can’t Read Your Saved Sign-In",
                                   recovery: "Sign in again to continue. Drafts on this \(DeviceWord.name) are kept aside, not moved to the account you sign in with."),
    ]

    static let defaultTitle = "Can’t Reach Hermes"
    static let defaultRecovery = "The computer running Hermes may be asleep or on another network. Hermes HQ keeps trying."
    static let noAddressRecovery = "\(DeviceWord.Tap) Try Again to recover your saved connection before changing sign-in. Your local drafts are being kept."

    /// Audit 06-11: a Nous agent has no computer to be asleep; it may be stopped (it never starts by itself) or starting.
    static let nousRecovery = "Your Nous agent may be stopped or still starting. If it’s stopped, start it on Nous Portal. Hermes HQ keeps trying."
    /// The status line while this phone has no network (nothing dials, so there is no countdown).
    static let waitingForNetwork = "Waiting for a connection…"

    /// Title and recovery for a reason (`GatewayFailure.code`); any reason without its own words gets the default pair.
    /// `nous`: the gateway is a Nous agent (`nousHosted`): "the computer running Hermes" words don't fit it.
    static func screen(reason: String?, hasAddress: Bool, nous: Bool = false) -> Screen {
        if nous, hasAddress, reason == "timeout" { return Screen(title: byReason["timeout"]!.title, recovery: nousRecovery) }
        if let reason, let known = byReason[reason] { return known }
        return Screen(title: defaultTitle, recovery: !hasAddress ? noAddressRecovery : nous ? nousRecovery : defaultRecovery)
    }

    /// A gateway Nous hosts (`<name>.agents.nousresearch.com`, as `CloudGatewayFlow.isCloud`).
    static func nousHosted(_ url: URL?) -> Bool { url?.host?.lowercased().hasSuffix(".agents.nousresearch.com") == true }

    /// The card's two lines; nil when it is hidden (no address known and the Keychain is the reason: the title and
    /// words already say what happened, and "could not be read" would contradict "Unlock Your iPhone").
    /// `label` is the name given on this phone; `accountName` is the username, or "Nous account".
    static func card(reason: String?, url: URL?, label: String?, accountName: String?) -> Card? {
        guard let url else {
            return keychainReasons.contains(reason ?? "") ? nil : Card(name: unnamedCard, detail: unreadableDetail)
        }
        let given = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let friendly = GatewayNaming.friendlyName(url)
        let name = !given.isEmpty ? given : friendly == GatewayNaming.unnamed ? unnamedCard : friendly
        var host = GatewayNaming.host(url, port: true)
        if host.isEmpty { host = url.absoluteString.removingPercentEncoding ?? url.absoluteString }
        let detail = [host, accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""].filter { !$0.isEmpty }
            .joined(separator: " · ")
        return Card(name: name, detail: detail)
    }

    /// The card's name for a gateway with no name of its own (an IP address, localhost): the computer, not "Your
    /// Gateway" (UX study #24; the switcher and Settings › Gateway keep their own word).
    static let unnamedCard = HostWord.sentence

    /// Failed Keychain reads after which a saved sign-in that still can't be opened offers "Sign In Again" too.
    static let unavailableReadsBeforeSignIn = 3

    /// "Change Address or Sign In" needs an address to start from; "Sign In Again" is for an unreadable sign-in, or
    /// one the Keychain still can't open after `unavailableReadsBeforeSignIn` reads (never a locked phone: unlocking
    /// fixes that). Either way it asks first, drafts kept aside.
    static func showsDifferentGateway(hasAddress: Bool) -> Bool { hasAddress }
    static func showsSignInAgain(reason: String?, failedReads: Int = 0) -> Bool {
        reason == keychainUnreadable || (reason == keychainUnavailable && failedReads >= unavailableReadsBeforeSignIn)
    }

    /// `Trying Again in N s`: a no-break space before `s`, N never below 1.
    static func countdown(_ seconds: TimeInterval) -> String {
        "Trying Again in \(max(1, Int(seconds.rounded(.up))))\u{00A0}s"
    }
}

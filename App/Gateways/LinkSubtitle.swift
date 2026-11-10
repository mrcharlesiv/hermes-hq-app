import UIKit

/// "Offline" / "Reconnecting…" under a page tab's title with one saved gateway, worded and timed as the Bots list's own
/// (spec 02 §6.5: shown only once a problem has lasted 2 s, so a blip never bounces the bar). Verify round 2: with one
/// unreachable gateway Bots and Sessions said "Reconnecting…" under a smaller title while Jobs, Kanban, Artifacts and
/// More kept the large title with no word of it, so the header changed size between tabs. With two or more gateways the
/// `GatewayTitleSwitcher` owns the subtitle (it leads with the same words) and this stays quiet.
@MainActor final class LinkSubtitle {
    weak var host: UIViewController?
    let services: any AppServices
    /// The switcher shows its own subtitle (two or more gateways): nothing to do here.
    var isSuppressed: () -> Bool = { false }
    private var timer: Timer?

    init(host: UIViewController, services: any AppServices) {
        self.host = host
        self.services = services
    }

    isolated deinit { timer?.invalidate() }

    private var words: String? { OutageClock.shared.words(services.connection) }   // [offline] one reading for every header

    /// The link changed (or the switcher went away): show, keep or clear the line.
    func update() {
        guard let item = host?.navigationItem else { return }
        guard !isSuppressed() else { timer?.invalidate(); timer = nil; return }
        let subtitle = words
        guard item.subtitle != subtitle else { timer?.invalidate(); timer = nil; return }
        if subtitle != nil && item.subtitle == nil {
            guard timer == nil else { return }
            let next = Timer(timeInterval: BotsViewController.subtitleDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.timer = nil
                    self?.apply()
                }
            }
            RunLoop.main.add(next, forMode: .common)
            timer = next
            return
        }
        timer?.invalidate()
        timer = nil
        apply()
    }

    private func apply() {
        guard let host, !isSuppressed() else { return }
        let subtitle = words
        let item = host.navigationItem
        guard item.subtitle != subtitle else { return }
        let heightChanges = (subtitle == nil) != (item.subtitle == nil)
        guard heightChanges, host.viewIfLoaded?.window != nil, !HQMotion.reduced,
              let navigation = host.navigationController else {
            item.subtitle = subtitle
            host.navigationController?.navigationBar.setNeedsLayout()
            return
        }
        navigation.view.layoutIfNeeded()
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {   // motion-ok: Reduce Motion returned in the guard above
            item.subtitle = subtitle
            navigation.navigationBar.setNeedsLayout()
            navigation.view.setNeedsLayout()
            navigation.view.layoutIfNeeded()
        }
    }
}

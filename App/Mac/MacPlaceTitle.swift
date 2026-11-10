// [mac-ui-issues] Owner 2026-11-09 ("really refine the app"): the sidebar's places didn't agree on where a page's
// title goes. Sessions, Jobs, Kanban, Artifacts and More lead the bar with it (a tab's inline title); the Tools made
// from More's rows (Files, Changes, Tiles, Tasks, Status & Maintenance, Marketplace, Terminal, Usage…) are pushed-page
// classes standing as a place's first page, so theirs sat in the middle of the bar. A place's first page now leads
// the bar with its title too. Not the inline large title: that one moves to the middle once rows scroll under the bar
// unless the page pins it (`ListBarAppearance.pinTitle`), which these pages don't.

#if targetEnvironment(macCatalyst)
import UIKit

@MainActor
enum MacPlaceTitle {
    private static var markKey: UInt8 = 0
    private static var watchKey: UInt8 = 0

    /// `page` is a sidebar place's first page: its title leads the bar when it first shows.
    static func mark(_ page: UIViewController) {
        objc_setAssociatedObject(page, &markKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Before a place's first page shows. The page's own bar is made by then (its view is loaded here), so a page with
    /// leading buttons or a title view of its own keeps them.
    static func leadIfMarked(_ page: UIViewController) {
        guard objc_getAssociatedObject(page, &markKey) != nil else { return }
        lead(page)
    }

    /// [mac-ui-issues] A page of the Settings window (the right side's stack): its title leads the bar too, after Back
    /// on a page a row opened, as System Settings names its pages. Settings in the main window's pane keeps the app's
    /// pushed-page title.
    static func leadInSettingsPane(_ page: UIViewController, in stack: UINavigationController) {
        guard stack.parent is SettingsRootController else { return }
        lead(page, afterBack: stack.viewControllers.first !== page)
    }

    private static func lead(_ page: UIViewController, afterBack: Bool = false) {
        guard objc_getAssociatedObject(page, &watchKey) == nil else { return }
        page.loadViewIfNeeded()
        let item = page.navigationItem
        guard item.titleView == nil, item.leftBarButtonItems?.isEmpty ?? true, item.largeTitleDisplayMode != .inline else { return }
        if afterBack { item.leftItemsSupplementBackButton = true }
        let label = UILabel()
        label.font = MacType.pageTitle
        label.textColor = HQPalette.label
        label.adjustsFontForContentSizeCategory = true
        label.text = item.title ?? page.title
        label.accessibilityTraits = .header
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // As far in as a tab's own title (Sessions, More): the bar starts its buttons 10 pt nearer the edge.
        let box = UIView()
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: afterBack ? 2 : 10),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            label.topAnchor.constraint(equalTo: box.topAnchor),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        let lead = UIBarButtonItem(customView: box)
        lead.hidesSharedBackground = true   // words on the bar, not a glass button
        item.leftBarButtonItem = lead
        item.titleView = UIView()           // the middle of the bar stays empty; `title` still names the page (Back, VoiceOver)
        // A page that renames itself (Gateway → Gateways, a folder) renames the label.
        let watch = [item.observe(\.title, options: [.new]) { [weak label, weak page] item, _ in
            MainActor.assumeIsolated { label?.text = item.title ?? page?.title}
        }, page.observe(\.title, options: [.new]) { [weak label, weak item] page, _ in
            MainActor.assumeIsolated { label?.text = item?.title ?? page.title}
        }]
        objc_setAssociatedObject(page, &watchKey, watch, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
#endif

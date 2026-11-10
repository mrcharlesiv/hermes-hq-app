import UIKit

/// [mac-layout] Owner 2026-11-03 (the Mac layout study, phone leftovers): the Mac has no pull-to-refresh. A list's
/// refresh control is kept for ⌘R (View › Refresh, `KeyCommands.hqRefresh`) but never hangs off the scroll view
/// there, so nothing spins in at the top when a trackpad overscrolls. The iPhone and iPad pull as before.
enum KeyOnlyRefresh {
    static let key = malloc(1)!
}

extension UIScrollView {
    /// Installs `control` as this list's refresh: pulled on the iPhone and iPad, ⌘R only on the Mac.
    func hqInstallRefresh(_ control: UIRefreshControl) {
        #if targetEnvironment(macCatalyst)
        objc_setAssociatedObject(self, KeyOnlyRefresh.key, control, .OBJC_ASSOCIATION_RETAIN)
        #else
        refreshControl = control
        #endif
    }

    /// The refresh ⌘R sends to: the pulled control, or on the Mac the one kept for the key.
    var hqKeyRefresh: UIRefreshControl? {
        refreshControl ?? objc_getAssociatedObject(self, KeyOnlyRefresh.key) as? UIRefreshControl
    }
}

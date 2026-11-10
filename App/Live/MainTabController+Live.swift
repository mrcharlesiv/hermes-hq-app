// [live] A job's Lock Screen progress, tapped: `<scheme>://job/<owner|id>` opens Jobs on that job's page
// (docs/spec/3x-jobs.md §12). A turn's opens its chat through the existing `<scheme>://session/<id>` link.

import UIKit

extension MainTabController {
    func openJob(_ key: String) {
        Task { @MainActor in
            // As a tapped alert does (spec S23): what is presented closes, a sheet with unsaved edits asks first.
            guard await clearForRoute(), let jobs = pages?.jobs, let navigation = jobs.navigationController,
                  let index = viewControllers?.firstIndex(where: { $0 === navigation }) else { return }
            selectedIndex = index
            navigation.popToViewController(jobs, animated: false)
            jobs.openDetail(key)   // nothing more when the list doesn't have it (yet): Jobs shows
        }
    }
}

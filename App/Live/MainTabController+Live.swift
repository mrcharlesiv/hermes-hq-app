// [live] A job's Lock Screen progress, tapped: `<scheme>://job/<owner|id>` opens Jobs on that job's page
// (docs/spec/3x-jobs.md §12). A turn's opens its chat through the existing `<scheme>://session/<id>` link.

import UIKit

extension MainTabController {
    func openJob(_ key: String) {
        Task { @MainActor in
            // As a tapped alert does (spec S23): what is presented closes, a sheet with unsaved edits asks first.
            guard await clearForRoute(), let jobs = showJobsPage() else { return }
            jobs.loadViewIfNeeded()
            jobs.openDetail(key)   // nothing more when the list doesn't have it (yet): Jobs shows
        }
    }

    /// Shows the Jobs page: its own tab (swapped into a Mac slot when beyond the 5-slot cap), else More › Jobs when hidden.
    @discardableResult
    func showJobsPage() -> JobsViewController? {
        if let jobs = pages?.jobs, let navigation = jobs.navigationController, slotIndex(for: navigation) != nil {
            #if targetEnvironment(macCatalyst)
            if let split { split.switchPlace(to: navigation) { self.show(navigation) } } else { show(navigation) }
            #else
            show(navigation)
            #endif
            navigation.popToViewController(jobs, animated: false)
            return jobs
        }
        guard let more = pages?.more, let stack = more.navigationController, let index = slotIndex(for: stack) else {
            return nil
        }
        selectedIndex = index
        if let page = stack.topViewController as? JobsViewController {
            return page
        }
        if let page = more.openedPageOnScreen as? JobsViewController {
            if let nav = page.navigationController, nav.topViewController !== page {
                nav.popToViewController(page, animated: false)
            }
            return page
        }
        stack.popToRootViewController(animated: false)
        more.loadViewIfNeeded()
        let opened = more.open(rowId: "jobs")
        if let page = (stack.topViewController as? JobsViewController) ?? (opened as? JobsViewController) {
            return page
        }
        guard let page = pages?.makeJobs() as? JobsViewController else { return nil }
        stack.pushViewController(page, animated: false)
        return page
    }
}
